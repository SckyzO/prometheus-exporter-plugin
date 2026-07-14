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

### The misnamed timeout flag

`mains/multi/main.go.tmpl:71` declares `--collector.example.timeout` and
passes it to `NewHandler` as `maxTimeout` (line 91). The flag does not
configure the `example` collector: it is the ceiling on *every* probe's
timeout. The underlying model is correct (a probe has one time budget,
inherited from Prometheus's `X-Prometheus-Scrape-Timeout-Seconds` header,
clamped, then handed to the collector). Only the name is wrong, and the name
stops making sense entirely once a probe runs more than one collector.

## 3. Design

Delivered in two phases, per the project's two-phase rule for reshaping a
shipped contract. Phase 1 is independently useful: it unblocks
`/add-collector`. Phase 2 layers on a seam that is already correct.

### 3.1 Phase 1: `Handler` holds N named factories

`internal/probe/probe.go.tmpl`:

```go
// Factory builds one collector scoped to one probe target. Unchanged.
type Factory func(target string, timeout time.Duration) prometheus.Collector

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
		New: func(target string, timeout time.Duration) prometheus.Collector {
			return collector.NewExampleCollector(log, collector.NewClient(target, timeout))
		},
	})
```

`mains/multi/main.go.tmpl` declares `var factories []probe.NamedFactory`
immediately before the `// @@PROBE_FACTORIES@@` marker, so the frag has a
slice to append to, and passes it to `NewHandler`.

### 3.3 Phase 1: rename the timeout flag

`--collector.example.timeout` becomes **`--probe.timeout`** (default `5s`,
same value, same role as `maxTimeout`). This is a breaking flag change for a
repository scaffolded with v0.3.0, and it is absorbed by the migration in
§3.6. It is justified: the old name asserts something false about what the
flag does, and it becomes actively misleading with more than one collector.

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

| `module=` | Behavior |
|---|---|
| absent | every registered collector runs. This preserves the v0.3.0 contract exactly. |
| known | only that module's collectors, in their declared order. |
| unknown | `400 Bad Request`, alongside the existing target-floor and allowlist rejections. |

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

- `internal/probe/probe.go.tmpl` — `NamedFactory`, `Handler.factories`,
  `NewHandler` signature, module map, module selection, startup validation,
  the `ServeHTTP` loop.
- `internal/probe/probe_test.go.tmpl` — see §5.
- `mains/multi/main.go.tmpl` — `var factories`, `--probe.timeout`,
  `--probe.module`, `NewHandler` call.
- `code/http/wiring/probe_factory.frag` — becomes an `append`.

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

The generated exporter's own `probe_test.go.tmpl` covers: N factories all
gathered under their correct tracker names; module absent runs everything;
a known module runs only its members; an unknown module returns 400; and a
module naming an unknown collector fails startup validation.

The plugin's golden test gets the assertion that actually proves the hole is
closed: **scaffold a multi-target exporter, then run the `/add-collector`
procedure on it, and prove the two-collector result builds and passes
`make check`.** Everything else in this design is unfalsifiable without that
cell. A unit test on the template cannot show that a second collector
compiles into a real repository.

## 6. Non-regression guarantees

- Single-target scaffolds are untouched. No shared file changes: single drops
  `internal/probe/` and uses different markers, a different main, and a
  different wiring frag.
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
  the probe's clamped time budget, which is Blackbox's model too.
