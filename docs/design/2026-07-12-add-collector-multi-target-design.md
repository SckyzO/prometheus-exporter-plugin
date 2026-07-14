# `/add-collector` on multi-target scaffolds: widening the probe seam

**Status:** design approved 2026-07-12. Closes the two follow-ups the v0.3
ROADMAP section names: `/add-collector` multi-target awareness, and the
`module` query parameter. Builds directly on sub-project 3b
(`2026-07-10-multi-target-design.md`).

## 1. Goal

Let `/add-collector` work on a repository scaffolded with
`--target-model multi`, and give the resulting exporter a `module` query
parameter so a scrape can select a subset of its collectors.

Today `/add-collector` refuses on a multi-target scaffold
(`commands/add-collector.md:51-59`) and points the user at a manual
procedure. The refusal is honest, not lazy: the shipped runtime cannot hold
more than one collector, so there is nothing for the command to wire a second
collector *into*. This design fixes the runtime first, then the command.

### Non-goals

- **Single-target is not touched.** The two entry-point models are disjoint
  by construction (`scaffold.sh` selects exactly one of `mains/single/` or
  `mains/multi/`, and drops `internal/probe/` entirely for single). Nothing
  here reaches `register()`, the `@@CLIENT_INIT@@` / `@@COLLECTOR_REGISTRY@@`
  markers, or the `--[no-]collector.<name>` flags. Single-target remains the
  default and is byte-for-byte unchanged.
- **A module does not define probe behavior.** In Blackbox, a YAML module
  describes the probe itself (HTTP method, expected status, TLS settings).
  Here the collectors are compiled Go, so a module can only *select among*
  collectors that are already built in. It is a scrape profile, not a probe
  definition. This design does not claim Blackbox parity beyond the query
  parameter's shape.
- **No per-collector enable/disable flags in multi.** The `module` parameter
  covers the same need per-request, which is strictly more useful. Adding
  global `--[no-]collector.<name>` flags to multi as well would be two
  mechanisms for one job.
- **No CLI multi-target.** `scaffold.sh:190` already refuses
  `--target-model multi` outside `--flavor http`. Unchanged.

## 2. Background: the one-factory seam

The v0.3.0 multi runtime holds exactly one collector. This is stated in the
seam's own header comment and is visible throughout:

| Location | What it does today |
|---|---|
| `internal/probe/probe.go.tmpl:37` | `type Factory func(target string, timeout time.Duration) prometheus.Collector` |
| `internal/probe/probe.go.tmpl:40-45` | `Handler` holds a single `factory Factory` |
| `internal/probe/probe.go.tmpl:49` | `NewHandler(log, factory Factory, allowlist, maxTimeout)` |
| `internal/probe/probe.go.tmpl:72` | `tracker.Add("example", h.factory(target, timeout))`, with the collector name hardcoded |
| `code/http/wiring/probe_factory.frag` | declares `factory := func(...)`, a single variable |
| `mains/multi/main.go.tmpl:91` | `probe.NewHandler(log, factory, *probeTargetAllowlist, *exampleTimeout)` |

Two consequences follow. A second `factory := ...` at the
`// @@PROBE_FACTORIES@@` marker is a redeclaration, so it does not compile.
And even if it did, `Handler` has nowhere to put it and `ServeHTTP` would
never gather it.

Multi also has no `register()` at all (single's `main.go.tmpl` has 15
`register`-related lines; multi's has none), so multi collectors have never
been individually selectable.

### The misnamed timeout flag, and the inert context behind it

`mains/multi/main.go.tmpl:71` declares `--collector.example.timeout` and
passes it to `NewHandler` as `maxTimeout` (line 91). The flag does not
configure the `example` collector: it is the ceiling on *every* probe's
timeout. With one collector the two are the same thing, so the lie is
invisible.

With N collectors it becomes load-bearing, because **`StatusTracker.Collect`
runs its entries sequentially** (`internal/collector/status_tracker.go.tmpl:74-107`:
`for _, e := range st.entries`, each fully drained via `<-done` before the
next). Four collectors with a 5s budget each therefore make a probe that can
run for 20s, long after Prometheus gave up on it. A flag named
`--probe.timeout` that permits a 4x overrun would simply be a new lie.

The root cause sits one layer down. `code/http/collector.go.tmpl:107`:

```go
func (c *ExampleCollector) Collect(ch chan<- prometheus.Metric) {
	stats, err := c.exampleGetMetrics(context.Background())
```

The context threaded through the five-piece pattern (`exampleData(ctx)`,
`Client.Fetch(ctx, path)`) is **inert**: `Collect` mints a fresh
`context.Background()` that is never cancelled. The only real bound anywhere
is `http.Client{Timeout: …}` (`code/http/client.go.tmpl:57`). Cancellation is
plumbed and then thrown away.

This is not an oversight in the scaffold so much as an API constraint:
`prometheus.Collector.Collect(ch)` takes no context. Blackbox sidesteps it
entirely by *not* using the Collector interface for probing at all, calling
ctx-taking prober functions that populate a registry directly. That option is
closed to us: reusing the same collector shape in both target models is
precisely what lets `/add-collector` work here at all, and is the point of
this epic.

So the context has to reach the collector some other way. See §3.3.

## 3. Design

Delivered in two phases, per the project's two-phase rule for reshaping a
shipped contract. Phase 1 is independently useful: it unblocks
`/add-collector`. Phase 2 layers on a seam that is already correct.

### 3.1 Phase 1: `Handler` holds N named factories

`internal/probe/probe.go.tmpl`:

```go
// Factory builds one collector scoped to one probe target, under the probe's
// deadline. The ctx is what makes the deadline in §3.3 real.
type Factory func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector

// NamedFactory pairs a Factory with the collector name the StatusTracker
// and the module selector both key on.
type NamedFactory struct {
	Name string
	New  Factory
}

type Handler struct {
	log        *logger.Logger
	factories  []NamedFactory // was: factory Factory
	allowlist  []string
	maxTimeout time.Duration
}

func NewHandler(log *logger.Logger, factories []NamedFactory, allowlist []string, maxTimeout time.Duration) *Handler
```

`ServeHTTP` replaces the hardcoded single `tracker.Add` with a loop over every
registered factory, which removes the `"example"` literal:

```go
for _, nf := range h.factories {
	tracker.Add(nf.Name, nf.New(target, timeout))
}
```

Phase 2 changes only the source of that loop, from `h.factories` to the subset
a `module` selects. In Phase 1 there is no `module`, and every registered
collector runs on every probe, which is exactly what a v0.3.0 exporter does
with its one collector.

Everything downstream of the gather is unchanged: one `reg.Gather()`, the
`probe_success` / `probe_duration_seconds` meta registry, and the
`gatheredFamilies` replay all keep working as designed, because they operate
on the gathered families, not on the collector count.

**A slice, not a map.** Go randomizes map iteration order by design. A map
would make collector ordering, error messages, and startup validation output
nondeterministic for no benefit. A slice preserves declaration order and
appends naturally at a marker, which is exactly what `/add-collector` needs.

### 3.2 Phase 1: the appendable frag

`code/http/wiring/probe_factory.frag` becomes an `append`, so that N of them
can stack at the marker:

```go
	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector {
			return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout))
		},
	})
```

The single-target `registry.frag` gains the same argument, passing
`context.Background()`, which is what its collectors already use today:

```go
	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, collector.NewClient(*exampleTarget, *exampleTimeout))
	}, true)
```

`mains/multi/main.go.tmpl` declares `var factories []probe.NamedFactory`
immediately before the `// @@PROBE_FACTORIES@@` marker, so the frag has a
slice to append to, and passes it to `NewHandler`.

### 3.3 Phase 1: a real deadline, injected at construction

The collector constructor takes the context, and `Collect` uses it instead of
minting `context.Background()`:

```go
type ExampleCollector struct {
	ctx    context.Context // the probe's deadline; context.Background() in single-target
	log    *logger.Logger
	client *Client
	// ... Desc fields
}

func NewExampleCollector(ctx context.Context, log *logger.Logger, client *Client) prometheus.Collector

func (c *ExampleCollector) Collect(ch chan<- prometheus.Metric) {
	stats, err := c.exampleGetMetrics(c.ctx) // was: context.Background()
}
```

Storing a context in a struct is normally discouraged in Go. It is the
standard escape hatch for `prometheus.Collector`, whose `Collect(ch)` predates
`context` and offers no other channel. The template says so in a comment,
because the plugin teaches this shape to every exporter it generates.

**This is behavior-preserving for single-target.** Passing
`context.Background()` explicitly reproduces exactly what `Collect` does
today, line for line. Single's `registry.frag` gains one argument; the code
that runs is identical, the bounds are identical. Nothing about the default
model changes at runtime. Only multi passes a context that can actually fire.

**The probe's deadline** follows Blackbox's calculation:

```
effective = min(X-Prometheus-Scrape-Timeout-Seconds - timeoutOffset, probeTimeout)
```

- `--probe.timeout` (default `5s`) replaces the misnamed
  `--collector.example.timeout`, and now genuinely bounds the probe.
- `--probe.timeout-offset` (default `0.5s`) is subtracted from Prometheus's
  scrape timeout so the exporter answers *before* Prometheus abandons the
  scrape. Without it, a probe that uses its full budget is always a wasted
  scrape.

The handler builds `context.WithTimeout(r.Context(), effective)`, hands it to
every factory, and `defer cancel()`s it. When the deadline fires, the
in-flight HTTP request is cancelled and the sequential collector chain aborts
immediately rather than grinding through the remaining collectors for a
response nobody will read.

`probe_timeout_seconds` is exported alongside `probe_success` and
`probe_duration_seconds`, mirroring Blackbox, so the effective deadline is
visible to whoever is debugging a slow target.

The v0.3.0 flag rename is a breaking change for a repository scaffolded with
v0.3.0, absorbed by the migration in §3.6.

### 3.4 Phase 2: `--probe.module`, a repeatable flag

Modules are runtime configuration, not scaffold-time structure. They are
declared with a repeatable kingpin flag, which needs no new dependency, no
config file to ship or mount, and no YAML parser in every generated multi
exporter:

```
--probe.module=basic:disks,pools
--probe.module=full:disks,pools,perf
```

Parsed into `map[string][]string` and passed to `NewHandler`. The grammar is
`<module>:<collector>[,<collector>...]`. Collector names are Go identifiers
(`/add-collector` enforces `^[A-Za-z_][A-Za-z0-9_]*$`), so they can never
contain the `:` or `,` separators and the split is unambiguous.

**Validated at startup, not at probe time.** The boot fails, naming the
offender, on any of:

| Condition | Why it is fatal |
|---|---|
| a module names a collector that is not registered | the module could never produce what it promises |
| the same module name is declared twice | silently keeping one of two conflicting definitions hides an operator mistake |
| a module declares an empty collector list | a module that runs nothing is always a typo, never an intent |

Discovering a typo when the process starts is strictly better than
discovering it on a probe at 3am. This follows the same fail-fast posture the
scaffold already takes with its startup warnings.

### 3.5 Phase 2: `/probe` module semantics

`module` is **repeatable and comma-separated**, and the named modules
**combine**, exactly as SNMP's `/snmp?target=X&module=a,b` does. Both
`?module=a&module=b` and `?module=a,b` select the union of `a` and `b`.

| `module=` | Behavior |
|---|---|
| absent | every registered collector runs. This preserves the v0.3.0 contract exactly. |
| one or more known modules | the union of their collectors, deduplicated, in the handler's declared factory order. |
| any unknown module named | `400 Bad Request`, alongside the existing target-floor and allowlist rejections. |

The union is deduplicated (a collector named by two selected modules runs
once) and emitted in the handler's declared order rather than the order the
modules were listed, so a probe's output is stable regardless of how the
scrape config spells its module list.

An absent `module` meaning "all collectors" is what makes Phase 2 additive: a
v0.3.0 Prometheus scrape config that only sets `target` keeps working
untouched.

### 3.6 `/add-collector`: detection, migration, wiring

The command already detects a multi scaffold (`[ -d internal/probe ]`). It
gains a **shape check** on top: does `internal/probe/probe.go` hold
`factories []NamedFactory` (current) or `factory Factory` (v0.3.0)?

- **Old shape:** migrate it. `internal/probe/probe.go` and the multi
  `main.go` probe wiring are *generic shipped files*: the scaffold writes
  them and users have no reason to edit them. The command rewrites both from
  the current templates, shows the diff before writing, then proceeds with
  the collector. The user gets what they asked for instead of a homework
  assignment.
- **Current shape:** proceed directly.

Then, exactly as it already does for single-target, the command materializes
the collector (the five-piece shape, the test triad, the `docs/metrics.md`
entry, the proposed business alert) and appends one `probe.NamedFactory`
block at `// @@PROBE_FACTORIES@@`.

**It never touches modules.** Because modules are runtime flags that
reference collector names, adding a collector cannot invalidate a module, and
composing profiles stays an operator decision. The two ROADMAP follow-ups
turn out to decouple cleanly.

### 3.7 Two refusals that stay refusals

- **`--variant background` on multi.** A background collector refreshes a
  cache from a goroutine on a fixed interval. In multi, collectors are built
  fresh per request and discarded when the probe returns: a goroutine per
  probe is an unbounded leak, and the cache it fills would never be read
  twice. The command refuses and explains why.
- **`--flavor cli` on multi.** Already impossible at scaffold time
  (`scaffold.sh:190`); the command does not need to handle a repository that
  cannot exist.

## 4. Files touched

### Modified (assets, shipped into scaffolds)

Multi-target only:

- `internal/probe/probe.go.tmpl` — `NamedFactory`, `Handler.factories`,
  `NewHandler` signature, the deadline (`context.WithTimeout`, timeout
  offset), `probe_timeout_seconds`, the module map, module selection and
  union, startup validation, the `ServeHTTP` loop.
- `internal/probe/probe_test.go.tmpl` — see §5.
- `mains/multi/main.go.tmpl` — `var factories`, `--probe.timeout`,
  `--probe.timeout-offset`, `--probe.module`, `NewHandler` call.
- `code/http/wiring/probe_factory.frag` — becomes an `append`, passes `ctx`.

Shared by both target models (the context injection, §3.3):

- `code/http/collector.go.tmpl`, `code/cli/collector.go.tmpl` — constructor
  takes `ctx`, `Collect` uses `c.ctx` instead of `context.Background()`.
- `code/http/variants/background_collector.go.tmpl`,
  `code/cli/variants/background_collector.go.tmpl` — same, for consistency of
  the taught shape. The background variant is single-target only (§3.7), so
  its `ctx` is always `context.Background()`; it takes it anyway so that every
  collector the plugin generates has one constructor shape.
- `code/http/wiring/registry.frag`, `code/cli/wiring/registry.frag` — pass
  `context.Background()`. Behavior-identical to today.
- The matching `*_test.go.tmpl` files, for the new constructor argument.

### Modified (plugin knowledge, never shipped)

- `commands/add-collector.md` — replace the refusal section with the
  multi-target procedure: shape detection, migration, factory append,
  background refusal.
- `skills/prometheus-exporter/references/exporter-architecture.md` — the
  multi runtime now holds N collectors and selects them per probe.
- `ROADMAP.md` — both v0.3 follow-ups close.
- `CHANGELOG.md` — `[Unreleased]`.

### Modified (plugin tests, never shipped)

- `test/scaffold_multitarget_test.sh` — assert the new seam shape.
- `test/golden-smoke.sh` — see §5.

## 5. Testing strategy

The generated exporter's own `probe_test.go.tmpl` covers:

- N factories all gathered, under their correct tracker names.
- **The deadline is real**: a collector wired to a target that never responds
  must abort when the probe's context fires, not when its HTTP client timeout
  does. This is the test that would have caught the inert context, and it is
  the one that must fail before the fix and pass after it.
- The timeout calculation: `min(scrape_timeout - offset, probe.timeout)`,
  including the case where Prometheus sends no header at all.
- Module absent runs everything; a known module runs only its members; two
  modules combine as a deduplicated union in declared order; an unknown module
  returns 400.
- Startup validation rejects an unknown collector in a module, a duplicate
  module name, and an empty module.

The plugin's golden test gets the assertion that actually proves the hole is
closed: **scaffold a multi-target exporter, then run the `/add-collector`
procedure on it, and prove the two-collector result builds and passes
`make check`.** Everything else in this design is unfalsifiable without that
cell. A unit test on the template cannot show that a second collector
compiles into a real repository.

## 6. Non-regression guarantees

- **Single-target's runtime behavior is unchanged, and this is provable rather
  than asserted.** The context injection (§3.3) reaches single's collector
  templates, but single passes `context.Background()`, which is exactly the
  value `Collect` mints for itself today (`collector.go.tmpl:107`). The same
  code runs under the same bounds. The constructor grows an argument; nothing
  else moves. `make check` and the golden cells for `{http,cli}×{none,github}`
  are the proof obligation.
- Single keeps its own entry point, markers, and wiring frag, and never gets
  `internal/probe/`, a probe deadline, or a module flag.
- An existing scaffold is never reached into. A repository generated by v0.3.0
  keeps compiling and running as it does now; a collector added to it by
  `/add-collector` simply carries the new constructor shape, which is
  per-collector and coexists with the old one.
- A v0.3.0 multi scaffold that is never re-run through `/add-collector` keeps
  working. Nothing reaches into an existing repository on its own.
- A v0.3.0 Prometheus scrape config (`target` only, no `module`) keeps
  working against a rebuilt exporter, because an absent `module` runs every
  collector.
- The only breaking change is `--collector.example.timeout` to
  `--probe.timeout`, and it only reaches a repository that opts into the
  migration by running `/add-collector`.

## 7. Open questions / assumptions

- **Assumption:** users do not hand-edit `internal/probe/probe.go`. It is
  generic, shipped, and has no per-exporter content. The migration shows the
  diff before writing, so a user who did edit it can decline. If this
  assumption proves wrong in practice, the fallback is the refuse-and-document
  path.
- **Assumption:** essentially no v0.3.0 multi-target scaffolds exist in the
  wild (v0.3.0 was published 2026-07-11). The migration is built anyway, on
  principle, because it costs little and silently breaking a user is not an
  option.

## 8. Out of scope

- Modules that define probe behavior (Blackbox-style YAML), rather than
  selecting compiled collectors. See Non-goals.
- The lazy TTL-cache collector variant, still a fast-follow from v0.2.
- Per-collector timeouts within one probe. Every collector in a probe shares
  the probe's deadline, which is Blackbox's model too.
- **Concurrent collection.** `StatusTracker.Collect` is sequential, so a probe
  costs the *sum* of its collectors, not the slowest. Making it concurrent
  would speed up both target models (a single-target exporter with 15
  collectors scrapes them one after another today), but it changes shared,
  concurrency-sensitive code on the default path and deserves its own epic
  with its own race-detector budget. The deadline in §3.3 bounds the damage in
  the meantime: a probe that runs out of time stops, rather than running long.
