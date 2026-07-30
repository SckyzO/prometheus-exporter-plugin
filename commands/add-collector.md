---
description: Add one new collector (the full five-piece pattern, its test triad, registry wiring, docs, and a proposed business alert) to an existing scaffolded Prometheus exporter repository. The most-repeated action after scaffolding.
argument-hint: <name>
disable-model-invocation: true
---

Add exactly **one** new collector to an already-scaffolded exporter repository
in the current working directory. This edits real, already-committed files
(`cmd/*/main.go`, `docs/metrics.md`, `monitoring/prometheus/alerts.yml`) and
writes new ones, so only run it when the user explicitly invokes this
command, and walk through every step below in order rather than skipping
ahead.

Candidate collector name from the command argument: $ARGUMENTS

## 0. Confirm this is a scaffolded exporter, and detect its I/O flavor

Refuse to guess at a repository that was never scaffolded by this plugin.
Confirm `internal/collector/` and a `cmd/*/main.go` both exist; if either is
missing, stop and point the user at `/new-prometheus-exporter` instead.

Detect the flavor from what actually lives in `internal/collector/`. Never
ask the user something you can check yourself:

| Found | Flavor | Why |
|---|---|---|
| `internal/collector/client.go` (defines `NewClient`) | **http** | The HTTP flavor's injectable `Client` boundary |
| `internal/collector/execute.go` (defines `var Execute`) | **cli** | The CLI flavor's injectable command-execution boundary |
| Neither, or somehow both | n/a | **Ask the user** which flavor this repo is. Don't guess: the wrong flavor produces a collector with the wrong factory signature and wires it against the wrong shared self-instrumentation. |

Everything below has two columns, **http** and **cli**, for exactly these two
v0.1 flavors.

## Multi-target scaffolds

Detect the target model from what is on disk. Never ask what you can check:

```sh
if [ -d internal/instance ]; then echo multi-instance
elif [ -d internal/probe ]; then echo multi
else echo single; fi
```

Three models now exist, and the two multi ones ship different seams:
`multi` (`internal/probe/`) and `multi-instance` (`internal/instance/`) are
not interchangeable. If detection printed `multi-instance`, skip the
`multi`-only seam check immediately below (it is specific to
`internal/probe`'s `NamedFactory`) and jump to the multi-instance seam check
further down, just above "Multi-instance wiring": that seam has its own
shape history too and needs the same current-vs-outdated check before
anything is appended.

For a **multi** repository, check the seam's shape before touching anything:

```sh
grep -q 'hc \*http\.Client' internal/probe/probe.go && echo current || echo outdated
```

**If the shape is `outdated`**, this repository was scaffolded before
per-module credentials existed. Its `probe.Factory` takes three parameters,
not four, and its `main.go` builds one HTTP client shared by every target.
The factory block below would not compile there.

**Stop and say so. Do not migrate it, and do not append anyway.** This
plugin is pre-1.0 and ships no migration path on purpose: an in-place seam
rewrite touches four files in a repository you do not own, and no gate in
this plugin can test that it worked. Tell the user plainly that their
exporter predates this seam, and that the supported route is to rescaffold
with `/new-prometheus-exporter` and port their collector bodies across. A
collector's five pieces and its test triad move over unchanged; it is only
the wiring that differs, so this is a smaller and far more verifiable
operation than an automated rewrite. Point them at `CHANGELOG.md` for what
changed between their version and this one.

**If the shape is `current`**, proceed.

Then materialize the collector exactly as for single-target (the five-piece
shape, the test triad, the `docs/metrics.md` entry, the proposed business
alert), and append **one** `probe.NamedFactory` block at the
`// @@PROBE_FACTORIES@@` marker in `cmd/*/main.go`:

```go
	factories = append(factories, probe.NamedFactory{
		Name: "<name>",
		New: func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
			if hc != nil {
				return collector.New<Name>Collector(ctx, log, collector.NewClientFor(target, hc)), nil
			}
			return collector.New<Name>Collector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
```

Nothing else is needed. `hc` is the client the handler resolved from the
module the request named, built once at boot in `main` and shared by every
collector, so this collector honours whatever authentication the operator
configured without building a client of its own. Earlier versions of this
command pasted a per-collector client-build block here; that is what the
current seam exists to remove.

Append, never replace: the marker stays in place for the next collector.

**Never touch modules.** The config file's `modules:` section references
collector names. Adding a collector cannot invalidate an existing module, and
composing scrape profiles is an operator decision, not yours.

**Refuse `--variant background` on a multi-target scaffold.** A background
collector refreshes a cache from a goroutine on a fixed interval. In multi,
collectors are built fresh per request and discarded when the probe returns:
a goroutine per probe is an unbounded leak, and the cache it fills would
never be read twice. Say exactly that, and offer the standard variant
instead.

**On a multi-instance scaffold, the mirror rule holds: refuse the SYNCHRONOUS
variant.** Every collector there is a background poller by construction (a
scrape serves N instances through one /metrics and must never block on a dead
machine). A synchronous collector would reintroduce exactly that coupling. Say
so and use the background variant.

For a **multi-instance** repository, check the seam's shape before touching
anything:

```sh
grep -q 'New *func(h ' internal/instance/instance.go && echo current || echo outdated
```

**If the shape is `outdated`**, this repository was scaffolded before the
instance-`Handle` seam existed. Its `instance.Factory.New` takes an address
and an HTTP client config pointer
(`func(addr string, hcfg *promconfig.HTTPClientConfig) (BackgroundCollector, error)`),
not a `*instance.Handle`, and each collector built its own transport instead
of sharing one per machine. The factory block below would not compile there.

**Stop and say so. Do not migrate it, and do not append anyway.** This
plugin is pre-1.0 and ships no migration path on purpose: an in-place seam
rewrite touches several files in a repository you do not own, and no gate in
this plugin can test that it worked. Tell the user plainly that their
exporter predates this seam, and that the supported route is to rescaffold
with `/new-prometheus-exporter` and port their collector bodies across. A
collector's five pieces and its test triad move over unchanged; it is only
the wiring that differs, so this is a smaller and far more verifiable
operation than an automated rewrite. Point them at `CHANGELOG.md` for what
changed between their version and this one.

**If the shape is `current`**, proceed.

**Multi-instance wiring.** Read the collector's identity (step 2) and
materialize the BACKGROUND collector file and its test (step 3-4, background
templates) exactly as for a single-target background collector. Then, at the
`// @@INSTANCE_FACTORIES@@` marker in `cmd/*/main.go`, append (after the last
existing `factories = append(...)` block, never replacing the marker):

```go
	<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-request timeout for the <name> collector.").Default("5s").Duration()
	<name>Interval := kingpin.Flag("collector.<name>.interval", "Background refresh interval for the <name> collector.").Default("5m").Duration()
	<name>Enabled := kingpin.Flag("collector.<name>", "Enable the <name> collector.").Default("true").Bool()
	factories = append(factories, instance.Factory{
		Name:    "<name>",
		Enabled: <name>Enabled,
		New: func(h *instance.Handle) (instance.BackgroundCollector, error) {
			c, err := h.ClientFor(*<name>Timeout)
			if err != nil {
				return nil, err
			}
			return collector.New<Name>Collector(log, c, *<name>Interval), nil
		},
	})
```

`New` takes the instance's `*instance.Handle`, not an address and a client
config: the Handle owns the transport every collector of that machine shares,
built once per machine so a reload can swap it underneath them without
restarting any poller. `h.ClientFor(*<name>Timeout)` binds this collector's
own per-request timeout to that shared transport and returns an error if the
timeout is non-positive (the shared transport carries no deadline of its
own, so a collector reaching it without one would hang its poller forever);
that error must propagate out of `New`, exactly as shown, never be
swallowed.

There is no `@@CLIENT_INIT@@`/`@@CLIENT_BUILD@@`/`@@COLLECTOR_REGISTRY@@` in a
multi-instance main (it carries only `@@INSTANCE_FACTORIES@@`), and no
`--collector.<name>.target` flag (the target is each instance's address).

## 1. Read this repo's real values

A scaffolded repo has no `@@VAR@@` sentinels left. Every value below is read
from real code, not substituted from a template:

| Value | How to read it |
|---|---|
| `NAMESPACE` | The literal in `cmd/*/main.go`'s `const namespace = "<literal>"` |
| `MODULE_PATH` | The `module <path>` line in `go.mod` |
| `EXPORTER_NAME` | The single subdirectory name under `cmd/` |
| (http only) the existing base-URL default | Any existing `--collector.<x>.target` flag's `.Default("<literal>")` in `cmd/*/main.go`: the new collector's own target flag should default to this same value unless the user says this collector really talks to a different base URL |

### The project journal

Read `docs/exporter-journal.md` if it exists, following
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/project-journal.md`.
That reference owns the format, the section ownership, and the reconciliation
and degradation rules. All this step adds is where each disk truth it asks for
has already been read in this command:

| Journal claim | Beaten by |
|---|---|
| `I/O flavor` | the flavor detection in step 0 |
| `Target model` | the target-model detection in `## Multi-target scaffolds` |
| `Namespace` | `const namespace` in `cmd/*/main.go`, read just above |
| A `## Collectors` box | the `## <Name>Collector` headers in `docs/metrics.md` |

Correct the file, mark each corrected line `(reconciled <date>)`, add one
`## Session log` line, and **tell the user what you corrected and why**. This
is the ordinary case, not an error: a collector built by hand, an interrupted
run, a colleague who pushed.

**Absent or corrupt**: apply the degradation rules in `project-journal.md`.
Continue this command to the end either way. Never refuse: a repository
scaffolded before the journal existed has none, and must keep working.

## 2. Collect the new collector's identity

**Name.** Use $ARGUMENTS as the candidate if given, otherwise ask. Validate
before deriving anything else from it or touching a single file:

- reject if empty, contains `/`, contains `..`, contains any whitespace, or
  starts with a leading `.` (same hard-reject shape as
  `/new-prometheus-exporter`'s `EXPORTER_NAME` check);
- **additionally reject if it is not a valid Go identifier**
  (`^[A-Za-z_][A-Za-z0-9_]*$`). Unlike `EXPORTER_NAME`, this name is spliced
  directly into Go identifiers (`<name>Data`, `<name>GetMetrics`, ...) in step
  3, so a shape a directory name tolerates (say, a leading digit) would still
  break compilation here.
- Non-blocking suggestion: lowercase `snake_case`, matching the existing
  collector-naming convention (`example`, `http_client_requests`/
  `command_exec`), not a hard rule.

**Variant: synchronous or background.** Two collector shapes exist:
**synchronous** (default, fetches on every scrape) and **background**
(fetches on a fixed interval in a goroutine, serving the last cached result
on every scrape; use when the backend is slow or expensive enough that a
scrape should never wait on it directly, see
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/exporter-architecture.md`'s background-refresh note). Decide
which applies to this collector before going further:

- If $ARGUMENTS included a trailing `--variant background` token, strip it
  and use the background variant.
- Otherwise ask: "Is this backend slow or expensive enough (seconds per
  call, rate-limited, or otherwise not built for high-frequency polling)
  that it should refresh on a fixed background interval instead of
  synchronously on every scrape?" A "yes" selects the background variant; a
  "no", or no clear signal, selects the synchronous variant (the default).
- If the journal's `## Collectors` already lists this collector with a
  variant, read that back to the user for confirmation rather than asking
  from scratch.

**Idempotent refusal.** Before writing anything, check:

```sh
[ -e internal/collector/<name>.go ] || [ -e internal/collector/<name>_test.go ]
grep -q 'register("<name>"' cmd/*/main.go
```

If either is true, **stop and refuse**: tell the user a collector named
`<name>` already exists (naming the colliding file/registration) and do not
overwrite or double-register it. Pick a different name, or this is the wrong
command if the goal is to *change* an existing collector.

The `register("<name>"` grep above only matches the **single** target
model's registry call. Neither multi model calls `register(` at all: `multi`
appends a `probe.NamedFactory{Name: "<name>", ...}` and `multi-instance`
appends an `instance.Factory{Name: "<name>", ...}`, the same struct-literal
shape in both. On either multi model, replace that grep with:

```sh
grep -q 'Name: *"<name>"' cmd/*/main.go
```

**Derive `<Name>`** (PascalCase) from `<name>` mechanically: uppercase the
first letter and the first letter following each underscore, then drop the
underscores: `queue` → `Queue`, `job_queue` → `JobQueue`. The lowercase
`<name>` form (underscores intact) is used verbatim as the registry string,
the flag name, and the file name; `<Name>` is used only inside Go identifiers.

**Ask the data source:**

| Flavor | Meaning | Example |
|---|---|---|
| http | The endpoint **path** this collector fetches (the base URL is shared, see step 1) | `/api/queue` |
| cli | The **command and its arguments**, as separate tokens (not one shell string: `exec.CommandContext` never goes through a shell) | command `queue-cli`, args `stats` |

**Ask the target metrics**: name(s), labels (if any), and help text for each.
Remind the user (and yourself, when writing step 3's code):

- Metric names and label **keys** must be **static** (a plain string
  literal, or `prometheus.BuildFQName(ns, sub, name)` with string-literal
  arguments), never computed. `make docs-check`
  (`internal/collector/docs_check_test.go`) statically extracts metrics at
  exactly this precision; anything else is invisible to it or, worse, flagged
  as an unresolvable warning.
- Ask what a **healthy-but-empty** scrape looks like for this data (e.g. "the
  queue can legitimately be empty"). This decides whether you need an
  always-emitted summary gauge alongside a per-item one. See step 3's
  collector-authoring rule.

**Apply the shared label vocabulary.** If the journal's
`## Architecture decisions` carries a `Shared label vocabulary:` line, the
label keys chosen here must come from it wherever the concept matches. If
this collector genuinely needs a new label, add it to that line and say so.
Do not invent a spelling that differs from an existing one by an underscore
or a suffix: `pool` and `pool_name` cannot be joined in any query, and
nothing on disk states which one is the rule.

**Check the planned budget.** If the journal's `## Cardinality budget` carries
a line for this collector, read it back: labels, worst-case series, any
planned reduction flag. Ask whether the metrics just described still fit. If
they do not, resolve it here, before writing code, and record what changed.

## 3. Materialize the collector file

Read the flavor's template directly. Do **not** run `scaffold.sh` against
this repository: it copies a whole tree and expects an empty (or
`--force`-wiped) destination, which would clobber this already-customized
repo's `go.mod`/`Makefile`/`README.md`/etc. wholesale. A single new file is a
plain adaptation, not a re-scaffold.

**Synchronous variant (default):**

- http: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/http/collector.go.tmpl`
- cli: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/cli/collector.go.tmpl`

**Background variant (step 2 selected it):**

- http: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/http/variants/background_collector.go.tmpl`
- cli: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/cli/variants/background_collector.go.tmpl`

The background variant keeps the same five-piece shape and the same
`example`/`Example` placeholder identifiers as the synchronous template, so
every rename in the table below applies to it unchanged. It additionally
introduces `interval time.Duration` (a new constructor parameter, see step
5's new interval flag), `lastRefreshDesc *prometheus.Desc` (the always-emitted
freshness gauge, metric name literal
`"@@NAMESPACE@@_example_last_refresh_timestamp_seconds"`: rename this
EXACTLY like any other `"@@NAMESPACE@@_..."` literal in the table below;
its `_last_refresh_timestamp_seconds` suffix is a locked, non-negotiable part
of the name, only `example`→`<name>` and `@@NAMESPACE@@` ever change in it),
`Start(ctx context.Context)`, and `Done() <-chan struct{}`. None of these
need a new rename rule beyond the existing `example`→`<name>`/`Example`→`<Name>`
pair, since none of those identifiers contain "example"/"Example" themselves.
`New<Name>Collector` for this variant returns the **concrete** `*<Name>Collector`
(never `prometheus.Collector`): step 5's registry snippet calls `.Start(ctx)`
on it, which the bare interface does not expose.

Write the result to `internal/collector/<name>.go`, applying these renames:

| Template identifier | Becomes |
|---|---|
| `example` (lowercase, in identifiers/strings) | `<name>` |
| `Example` (in identifiers) | `<Name>` |
| `exampleStats` (http) / `exampleMetric` (cli) | `<name>Stats` / `<name>Metric` |
| `exampleData` | `<name>Data` |
| `parseExample` | `parse<Name>` |
| `exampleGetMetrics` | `<name>GetMetrics` |
| `ExampleCollector` | `<Name>Collector` |
| `NewExampleCollector` | `New<Name>Collector` |
| `"@@NAMESPACE@@_..."` metric name literals | the user's chosen static metric names (already real, e.g. `demo_items` in this repo, never a leftover `@@...@@`) |
| `@@MODULE_PATH@@` in the import line | the real module path from step 1 |
| `@@DATA_SOURCE_PATH@@` (http) | the endpoint path from step 2 |
| `"@@DATA_SOURCE@@"` (cli, inside `<name>Data`'s `Execute(ctx, ...)` call) | the command from step 2, as its own string, followed by each arg as its **own** additional string literal: `Execute(ctx, "queue-cli", "stats")`, never `Execute(ctx, "queue-cli stats")` |

**cli only**: keep `<name>Data`'s `context.WithTimeout(ctx, c.timeout)` call
immediately before its `Execute(ctx, ...)` call, exactly as `exampleData`
already has it. `Execute` rejects a `ctx` with no deadline once
`--exporter.max-requests-per-target` is configured (a real ceiling attached to
`collector.CommandLimiter`), so any new call site that reaches `Execute` with
a bare `context.Background()` fails loudly instead of hanging a poller
forever in `CommandLimiter.Acquire`. This only bites a call site that skips
`exampleData`'s pattern; following the rename above keeps it intact.

Do **not** blindly find-and-replace `example` through the whole file text.
That would also mangle prose. Only the identifiers/literals above move
mechanically. Separately, **rewrite the doc comments**: drop the template's
"this is a placeholder... replace it when adapting this collector" framing
(that's no longer true, this collector already targets its real source) and
write real documentation of what it actually does. Keep comments that explain
a durable invariant of this exporter as-is (why `Collect` logs-and-returns
zero metrics on error, why `StatusTracker` treats that as failure, why a
duplicate label set breaks `Gather` for the whole scrape): those stay true for
every collector, not just the one being replaced. Within such a kept comment,
any embedded `@@…@@` sentinel or `collector="example"` illustration must still
be updated to the real namespace / new collector name: the "why" prose stays;
the concrete example values get updated.

**Adapt the shape to the user's real metrics**, not just the field count the
template happens to ship:

- Keep the five-piece shape: `<name>Data` (I/O only) → `parse<Name>` (pure)
  → `<name>GetMetrics` (glue) → `Describe`/`Collect`, regardless of how many
  fields or metrics you end up with.
- **Collector-authoring rule** (non-negotiable): on a successful scrape,
  always emit every metric, with zero *values* when there's nothing to
  report, never zero metrics. The shared `StatusTracker` counts emitted
  metrics per scrape and reports `success=0` for the collector when a
  `Collect` call sends nothing at all, indistinguishable from a real failure.
  If any of this collector's metrics has variable labels and can legitimately
  have zero entries on a healthy scrape (an empty queue, an empty list, ...),
  keep (or add) a fixed-shape, always-emitted gauge alongside it (exactly
  what the template's `items`/`entries` field already demonstrates) so a
  "nothing to report" scrape still sends at least one metric.
- More or fewer than the template's two metrics, and any number of labels,
  are all fine: adapt the struct fields, `*prometheus.Desc` fields, and
  `Collect` body freely to match what step 2 asked for.

## 4. Materialize the full test triad + fixture

Read the flavor's test template(s), choosing the SAME variant step 2 selected
(synchronous or background). Never mix a synchronous collector file with a
background test file or vice versa:

**Synchronous variant (default):**

- http: `.../code/http/collector_test.go.tmpl` → write `internal/collector/<name>_test.go`
- cli: `.../code/cli/collector_test.go.tmpl` **and** `.../code/cli/parser_test.go.tmpl` → merge both into one `internal/collector/<name>_test.go`. (The shipped repo keeps these split only because the *first* collector's files are generically named `collector_test.go`/`parser_test.go`; your new collector already has a unique name, so one file is simpler and matches the http flavor's own convention.) Both templates declare `package collector` and have overlapping imports (`"os"`, `"testing"`, etc.); the merge must keep **one** `package collector` line and a **single deduplicated import block**: a literal concatenation would cause a duplicate-package/duplicate-import compile error.

**Background variant (step 2 selected it):**

- http: `.../code/http/variants/background_collector_test.go.tmpl` → write `internal/collector/<name>_test.go`. Already the complete triad in one file (parser test + lifecycle tests): no separate parser template exists for this variant.
- cli: `.../code/cli/variants/background_collector_test.go.tmpl` → write `internal/collector/<name>_test.go`. Already merged (parser test + lifecycle tests): do not also read `.../code/cli/parser_test.go.tmpl`, which is the SYNCHRONOUS flavor's separate parser file and would duplicate `TestParse<Name>`.

Either variant:

Apply the same identifier renames as step 3 (whichever of that table's rows
actually occur in the test template: the endpoint-path/command rows won't,
since the test stubs I/O via `httptest`/an `Execute` swap instead of calling
the real target). Then **drop these declarations from the copy**: they are
shared, package-level, and already declared exactly once by this repo's first
collector's own test file. Copying them again is a Go compile error
("redeclared in this block"), not a warning:

| Flavor | Drop this declaration | It tests |
|---|---|---|
| http | `const statusTrackerSuccessMetric = "..."` | (shared name, reused below) |
| http | `func TestRequestDuration_CustomRegistryReachable` | the shared `RequestDuration` histogram in `client.go` |
| cli | `const statusTrackerSuccessMetric = "..."` | (shared name, reused below) |
| cli | `func TestExecute_Success` | the shared `Execute` var in `execute.go` |
| cli | `func TestExecute_CommandNotFound` | the shared `Execute` var in `execute.go` |
| cli | `func TestCommandDuration_CustomRegistryReachable` | the shared `CommandDuration` histogram in `execute.go` |
| cli | `func TestExecute_RecordsCommandDurationOnAnAbandonedLimiterWait` | the shared `CommandDuration`/`CommandLimiter` interaction in `execute.go` |

Reuse `statusTrackerSuccessMetric` (already in scope, package-wide) in your
own `Test<Name>Collector_StatusTracker*` tests instead of redeclaring it.

General rule if a future template edit adds more shared declarations: any
top-level declaration in the test template (`func Test...`, `const ...`,
`var ...`, `type ...`, or a method on a shared helper type) whose name does
**not** contain `Example`/`example` is testing shared per-flavor
infrastructure, not the starter collector itself: never copy it into a
second collector's test file. This includes a shared helper type together
with its methods, not just `func Test...`/`const .../var ...`: for example
`type refusingRoundTripper struct{}` and its `RoundTrip` method (http),
which exist only to support `TestTransportSetIsVisibleToExistingClients`, a
shared test the rule above already excludes. Copy a helper type only if
every test that needs it is also being kept, never the type alone and never
orphaned from the test that used it. If one slips through anyway, `go
build`/`go vet`/`make test` reports "redeclared in this block": that error
always means exactly this, not a mystery to debug from scratch.

Keep, renamed: the parser test (`TestParse<Name>`, with its
malformed/empty/edge-case sub-tests), `Test<Name>Collector_Collect`,
`_Describe`, `_ErrorHandling`, and the `_StatusTrackerSuccess`/
`_StatusTrackerFailure` (http) or `_StatusTrackerSuccessOnEmptyOutput` (cli)
pair. Update the exact counts to match your real metric shape, not the
template's "2":

- `_Describe`'s expected count = however many `*prometheus.Desc` fields your
  new collector's struct holds.
- `_Collect`'s `GatherAndCount` expected total = one per fixed-shape metric,
  plus one per label-combination any variable-label metric actually emits
  for your fixture.
- The expected exposition-text block in `_Collect`: `Registry.Gather` sorts
  metric families by name and, within a family, by label value. Write the
  expected block in that order (it is deterministic, not incidental).

Add a `testdata/<name>.{json,txt}` fixture (http: JSON matching your struct;
cli: whatever `parse<Name>` expects) with realistic, anonymized sample data
(see this repo's own `CONTRIBUTING.md`, "Test Data").

**Prefer deriving it from `samples/`.** If `samples/` exists and holds
material covering this collector's endpoint or command, build the fixture
from that instead of inventing one:

1. Find the file. Match on the endpoint path or command recorded in step 2.
   If several could match, show the candidates and ask; never guess.
2. **Trim** it to the shape `parse<Name>` actually reads. A capture commonly
   covers several resources; the fixture covers one.
3. **Anonymize** it per
   `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/collector-pattern.md`'s
   Fixtures rules, which own the substitutions: real hostnames and endpoints
   become `host1`/`example.internal`, usernames become `user1`/`alice`/`bob`,
   account or tenant names become `team_a`/`org_b`, and anything else
   identifying gets a placeholder that preserves shape (field count, rough
   magnitude) without preserving content. Never commit a fixture copy-pasted
   straight from a production system, which is exactly what a `samples/` file
   is.
4. **State what you anonymized**, field by field, in your reply. The user is
   the only one who can tell you that something you left alone was actually
   sensitive.
5. **Leave the original in `samples/`.** Never move or delete it: one capture
   feeds several collectors, and a later session should not have to go back
   to the live target.

If `samples/` is absent or covers nothing relevant, say so in one line and
write the fixture as before. This is a shortcut, never a requirement.

## 5. Register the collector

`// @@CLIENT_INIT@@`, `// @@COLLECTOR_REGISTRY@@`, and `// @@CLIENT_BUILD@@`
all already exist verbatim in `cmd/*/main.go` (they survive scaffolding for
exactly this purpose). Insert **after the last existing line** of each block:
never replace the marker comment itself, and never re-declare `log`, which the
closures below capture by reference.

`// @@CLIENT_BUILD@@` only matters for the **http** flavor: it is where a
collector's `*collector.Client` is actually built, once flags are parsed, so it
can honor an operator's `http_client_config:` section. For the **cli** flavor,
the block already spliced there rejects `http_client_config` outright (this
exec-only flavor has no HTTP transport to authenticate) and does not reference
any particular collector, so adding a cli collector never needs a new entry at
that marker; the cli variants below only touch `@@CLIENT_INIT@@`/
`@@COLLECTOR_REGISTRY@@`, exactly as before.

Before touching either http variant below, check whether this repository even
has the configuration layer:

```sh
grep -q 'cfg, err := config.Load(' cmd/*/main.go && echo has-config || echo pre-config-layer
```

**`pre-config-layer`**: this repository was scaffolded before `--config.file`
existed, so there is no `cfg` variable anywhere in `cmd/*/main.go`. Skip the
`@@CLIENT_BUILD@@` step below entirely and use the plain, single-flag shape
this command taught before that layer existed: declare only the target/timeout
(and, for the background variant, interval) flags at `@@CLIENT_INIT@@`, and
build the client inline, inside the `register(...)` closure, with
`collector.NewClient(*<name>Target, *<name>Timeout)`. Never paste a block that
reads `cfg` into a repository that does not declare one.

**`has-config`**: one more layer to check before following the three-step http
blocks below, since `--exporter.max-requests-per-target` (the request
concurrency ceiling) arrived after `--config.file` did, so a `has-config`
repository can still predate it:

```sh
grep -q 'maxRequestsPerTarget' cmd/*/main.go && echo has-limiter || echo pre-limiter-layer
```

**`pre-limiter-layer`**: this repository was scaffolded before
`--exporter.max-requests-per-target` existed, so neither `maxRequestsPerTarget`
nor `collector.Limiters` exists anywhere in `cmd/*/main.go`. Paste the
`// @@CLIENT_BUILD@@` block below verbatim EXCEPT its three ceiling-related
pieces: the `if collector.Limiters == nil { ... }` construction, the
boot-time `*maxRequestsPerTarget > 0 && ...` refusal, and the trailing
`.WithLimiter(...)` line. What remains is exactly the
`if cfg.HTTPClientConfig != nil { ... } else { ... }` shape. This collector
simply has no ceiling, symmetric with every other collector already in that
repository, not a regression: the whole repository predates this feature.
Never paste a reference to `maxRequestsPerTarget` or `collector.Limiters` into
a repository that declares neither.

**`has-limiter`**: follow the three-step http blocks below exactly as written.

**Synchronous variant (default): http**. After the last existing flag line
under `// @@CLIENT_INIT@@`:

```go
<name>Target := kingpin.Flag("collector.<name>.target", "Base URL the <name> collector scrapes.").Default("<base URL from step 1>").String()
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-request timeout for the <name> collector.").Default("5s").Duration()
// Declared here, assigned at // @@CLIENT_BUILD@@ once flags are parsed.
// The registry closure below captures it by reference and only
// dereferences it later, in main's construction loop.
var <name>Client *collector.Client
```

then, after the last existing block under `// @@CLIENT_BUILD@@`:

```go
// One ceiling per distinct target address, so two collectors pointed at
// the same machine share it and two pointed at different machines do not.
// collector.Limiters (see limiter.go) is the single, shared LimiterSet
// every collector's client_build wiring consults; THIS block only builds
// it the first time it runs. That nil check is load-bearing, not
// defensive-for-its-own-sake: this exact block is spliced once per
// collector, by scaffold.sh for the first one and by /add-collector for
// every one after, so with a second collector this block runs a second
// time in the same main(). A plain `limiters := collector.NewLimiterSet(...)`
// local declaration would either fail to compile the second time ("no
// new variables on left side of :="), or, built as an unconditional
// package-level assignment instead, would silently replace the first
// collector's LimiterSet with an empty one, breaking the very sharing
// guarantee this comment opens with for any two collectors that happen
// to target the same address. Guarding on nil is what makes every
// collector after the first reuse the SAME set instead.
if collector.Limiters == nil {
	collector.Limiters = collector.NewLimiterSet(*maxRequestsPerTarget)
}

// A limiter with no bound on its own wait is exactly the silent-queueing
// failure mode a concurrency ceiling exists to prevent (see
// Client.WithLimiter's own doc comment, which names this exact check as
// the thing that must happen here, at flag-parse time). Reject at boot,
// naming the collector, the same way instance.Handle.ClientFor already
// refuses a non-positive NewClientOn timeout.
if *maxRequestsPerTarget > 0 && *<name>Timeout <= 0 {
	fmt.Fprintln(os.Stderr, fmt.Errorf("collector %q: a positive --collector.<name>.timeout is required when --exporter.max-requests-per-target is set, got %v (the limiter wait would otherwise be unbounded)", "<name>", *<name>Timeout))
	stop()     // release the signal handler explicitly before bypassing defer via os.Exit
	os.Exit(1) //nolint:gocritic // stop() called explicitly above
}

if cfg.HTTPClientConfig != nil {
	<name>Client, err = collector.NewClientWithConfig(*<name>Target, *<name>Timeout, *cfg.HTTPClientConfig)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
} else {
	// No http_client_config section: keep the transport every existing
	// deployment already runs.
	<name>Client = collector.NewClient(*<name>Target, *<name>Timeout)
}
// A nil limiter (the default ceiling of 0) leaves this a no-op.
<name>Client = <name>Client.WithLimiter(collector.Limiters.For(*<name>Target))
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	return collector.New<Name>Collector(context.Background(), log, <name>Client)
}, true)
```

**Synchronous variant (default): cli**. After the last existing flag line
under `// @@CLIENT_INIT@@`:

```go
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-command timeout for the <name> collector.").Default("5s").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	return collector.New<Name>Collector(context.Background(), log, *<name>Timeout)
}, true)
```

**Background variant (step 2 selected it): http**. After the last existing
flag line under `// @@CLIENT_INIT@@` (the SAME target/timeout flags as the
synchronous branch above, plus one new interval flag):

```go
<name>Target := kingpin.Flag("collector.<name>.target", "Base URL the <name> collector scrapes.").Default("<base URL from step 1>").String()
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-request timeout for the <name> collector.").Default("5s").Duration()
<name>Interval := kingpin.Flag("collector.<name>.interval", "Refresh interval for the <name> collector.").Default("5m").Duration()
// Declared here, assigned at // @@CLIENT_BUILD@@ once flags are parsed.
// The registry closure below captures it by reference and only
// dereferences it later, in main's construction loop.
var <name>Client *collector.Client
```

then, after the last existing block under `// @@CLIENT_BUILD@@` (same shape as
the synchronous variant above, this marker does not vary by variant):

```go
// One ceiling per distinct target address, so two collectors pointed at
// the same machine share it and two pointed at different machines do not.
// collector.Limiters (see limiter.go) is the single, shared LimiterSet
// every collector's client_build wiring consults; THIS block only builds
// it the first time it runs. That nil check is load-bearing, not
// defensive-for-its-own-sake: this exact block is spliced once per
// collector, by scaffold.sh for the first one and by /add-collector for
// every one after, so with a second collector this block runs a second
// time in the same main(). A plain `limiters := collector.NewLimiterSet(...)`
// local declaration would either fail to compile the second time ("no
// new variables on left side of :="), or, built as an unconditional
// package-level assignment instead, would silently replace the first
// collector's LimiterSet with an empty one, breaking the very sharing
// guarantee this comment opens with for any two collectors that happen
// to target the same address. Guarding on nil is what makes every
// collector after the first reuse the SAME set instead.
if collector.Limiters == nil {
	collector.Limiters = collector.NewLimiterSet(*maxRequestsPerTarget)
}

// A limiter with no bound on its own wait is exactly the silent-queueing
// failure mode a concurrency ceiling exists to prevent (see
// Client.WithLimiter's own doc comment, which names this exact check as
// the thing that must happen here, at flag-parse time). Reject at boot,
// naming the collector, the same way instance.Handle.ClientFor already
// refuses a non-positive NewClientOn timeout.
if *maxRequestsPerTarget > 0 && *<name>Timeout <= 0 {
	fmt.Fprintln(os.Stderr, fmt.Errorf("collector %q: a positive --collector.<name>.timeout is required when --exporter.max-requests-per-target is set, got %v (the limiter wait would otherwise be unbounded)", "<name>", *<name>Timeout))
	stop()     // release the signal handler explicitly before bypassing defer via os.Exit
	os.Exit(1) //nolint:gocritic // stop() called explicitly above
}

if cfg.HTTPClientConfig != nil {
	<name>Client, err = collector.NewClientWithConfig(*<name>Target, *<name>Timeout, *cfg.HTTPClientConfig)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
} else {
	// No http_client_config section: keep the transport every existing
	// deployment already runs.
	<name>Client = collector.NewClient(*<name>Target, *<name>Timeout)
}
// A nil limiter (the default ceiling of 0) leaves this a no-op.
<name>Client = <name>Client.WithLimiter(collector.Limiters.For(*<name>Target))
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	<name>Coll := collector.New<Name>Collector(log, <name>Client, *<name>Interval)
	<name>Coll.Start(ctx)
	backgroundCollectors = append(backgroundCollectors, <name>Coll)
	return <name>Coll
}, true)
```

**Background variant (step 2 selected it): cli**. After the last existing
flag line under `// @@CLIENT_INIT@@`:

```go
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-command timeout for the <name> collector.").Default("5s").Duration()
<name>Interval := kingpin.Flag("collector.<name>.interval", "Refresh interval for the <name> collector.").Default("5m").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	<name>Coll := collector.New<Name>Collector(log, *<name>Timeout, *<name>Interval)
	<name>Coll.Start(ctx)
	backgroundCollectors = append(backgroundCollectors, <name>Coll)
	return <name>Coll
}, true)
```

**Why the eager construction, `Start`, and `append` all live INSIDE the
`register(...)` closure, never as bare statements before it:** both markers
sit textually BEFORE `kingpin.Parse()` in `main.go`. `register(...)`'s call
itself must run there (it just stores the closure), but `log` is still `nil`
and every flag pointer (`*<name>Target`, `*<name>Interval`, ...) still holds
its zero value until `kingpin.Parse()` runs, further down. Putting
`<name>Coll := collector.New<Name>Collector(log, ...)` directly at the
marker (outside the closure) would construct the collector with a nil
logger and a zero-value interval, silently broken. Wrapping construction,
`Start(ctx)`, and the `backgroundCollectors` append inside the closure
(which Go closures capture by reference) defers all of it to the registry
loop later in `main()`, which runs AFTER `kingpin.Parse()` and after `log`
is assigned, exactly how the existing synchronous closures above already
behave, and how `main.go`'s own `backgroundCollectors` seam (Task 1) expects
to be populated. `ctx` and `backgroundCollectors` are both declared up-front,
right after `var log` and BEFORE these two markers (Task 1's seam), precisely
so this closure can capture them; the closure only *dereferences* `ctx` (in
`Start(ctx)`) at invocation time, long after `kingpin.Parse()`, exactly as it
does `log`. (In the pristine `main.go.tmpl`, `ctx` used to be declared far
below these markers in the shutdown block, Task 1 moved it up for exactly
this reason: a Go closure cannot close over a name declared textually after
it.)

**Where `// @@CLIENT_BUILD@@` sits, and why the http variants above assign
`<name>Client` there instead of building it right where it's declared:**
`// @@CLIENT_INIT@@` and `// @@COLLECTOR_REGISTRY@@` both sit textually
BEFORE `kingpin.Parse()`, exactly like the two markers discussed above, but
`// @@CLIENT_BUILD@@` sits AFTER it, still before `log` is constructed.
`<name>Client` has to be declared as a `var` at `@@CLIENT_INIT@@` (before
the parse) purely so the `register(...)` closure can close over it, the same
reason `ctx`/`backgroundCollectors` were moved up front; it can only be
safely built once `*<name>Target`/`*<name>Timeout` hold their real parsed
values and the configuration file has actually been loaded, both of which
are true only once `@@CLIENT_BUILD@@` runs. Because `log` does not exist yet
at that point either, the `@@CLIENT_BUILD@@` block reports a failure with
`fmt.Fprintln(os.Stderr, err)` plus `stop()`/`os.Exit(1)`, the same pattern
`cfg.Load`/`cfg.Validate`'s own error paths just above it already use, not
`log.Error`.

`register()` auto-declares the negatable `--[no-]collector.<name>` flag
(defaulting to enabled), nothing else to wire for that, in either variant.

This insertion point is anchor-based (last line of each marker's existing
block), so it works the same way regardless of how many collectors already
exist, it is never specific to "the second collector".

## 6. Update `docs/metrics.md`

Insert a new section immediately before `## Self-instrumentation`, in the same
4-cell table format the file's own header comment documents:

```markdown
## <Name>Collector

Defined in `internal/collector/<name>.go`.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `<metric_name>` | Gauge | `<label>` or `-` | <help text> |
```

**Background variant only:** add one further row for the always-emitted
freshness gauge, using its exact, locked name and help text (see step 3's
note on why this metric name is not user-chosen):

```markdown
| `<namespace>_<name>_last_refresh_timestamp_seconds` | Gauge | - | Unix time of the last successful <name> refresh. Alert if time() - this > 2 x the collector's configured interval. |
```

The names/labels here **must exactly match** what step 3's code emits: this
is what `make docs-check` verifies (fails the build on a documented metric
the code can't produce; only warns on the reverse). Every row's Type should
reflect what step 3 actually constructed (`Gauge`/`Counter`/`Histogram`/
`Summary`).

Optional, not gated by any automated check but cheap and worth doing:
add `<name>` to `docs/configuration.md`'s "Available collectors" table and,
if you added a `--collector.<name>.*` flag, its own flags table too. This
keeps that reference from going stale.

### Regenerate the README's collector block

`README.md` carries a generated block:

```
<!-- BEGIN GENERATED COLLECTORS -->
<!-- Regenerated from docs/metrics.md. Edits inside this block are overwritten. -->
- [`example`](docs/metrics.md#examplecollector)
<!-- END GENERATED COLLECTORS -->
```

Replace **everything between the two markers** with one line per
`## <Name>Collector` header now present in `docs/metrics.md`, in the order
they appear:

```
- [`<name>`](docs/metrics.md#<anchor>)
```

`<name>` is the **registered collector name**, read from `cmd/*/main.go`:
`register("<name>"` on the single target model, `Name: "<name>"` on either
multi model, the same two greps step 2's idempotent refusal already uses.
Never recover it by inverting the header's PascalCase, which cannot tell
`job_queue` from `jobqueue`: because this block is regenerated in full on
every run, a guess silently rewrites a correct line the next time a collector
is added. `docs/metrics.md`'s own `Defined in` line is not a source either;
the bundled first collector's section names `internal/collector/collector.go`,
not its collector name.

Only headers ending in `Collector` are collectors. `## Self-instrumentation`,
and the multi-target and configuration-reload sections that may sit below it,
are not, and never appear in this list.

The anchor is the GitHub-flavored slug of the `## <Name>Collector` header
itself, never of `<name>`: lowercase it and drop spaces and punctuation.
`## PoolsCollector` becomes `#poolscollector`, and `## JobQueueCollector`
becomes `#jobqueuecollector`. Mind the underscore: a collector named
`job_queue` has a header spelled `## JobQueueCollector` with no underscore in
it, so its anchor has none either, while its link text keeps the underscore.

Keep the second comment line: it is what tells the next reader the block is
not theirs to edit. Regenerate in full; never append. The block is a
projection of a file `make docs-check` already locks, which is what stops it
drifting and lets it repair itself if someone edits it by hand.

**If either marker is missing**, skip this silently and change nothing. A
repository scaffolded before the markers existed, or an owner who removed
them, is not an error. Do not inject them.

Touch nothing else in `README.md`. Nothing else in it goes stale when a
collector is added.

## 7. Propose a business alert

Open `monitoring/prometheus/alerts.yml`. Insert a new, real (uncommented)
block immediately before the existing:

```
      # ──────────────────────────────────────────────────────────────────
      # EXAMPLE: business alert (commented out: not loaded by Prometheus)
      # ──────────────────────────────────────────────────────────────────
```

Leave that shipped teaching comment in place; don't delete it. Use the same
tiered pattern already established by the health alerts above it:

```yaml
      # ──────────────────────────────────────────────────────────────────
      # Business: <Name>Collector (added via /add-collector)
      # ──────────────────────────────────────────────────────────────────
      - alert: <Name>Degraded
        expr: <namespace>_<metric>{<label selector, if any>} > <warning threshold>
        for: 10m
        labels:
          severity: warning
          component: exporter
        annotations:
          summary: '<exporter_name> <one-line summary>'
          description: '{{ $labels.instance }} has reported {{ $value }} for 10 minutes (threshold: <warning threshold>).'

      - alert: <Name>Degraded
        expr: <namespace>_<metric>{<label selector, if any>} > <critical threshold>
        for: 10m
        labels:
          severity: critical
          component: exporter
        annotations:
          summary: '<exporter_name> <one-line summary, critically>'
          description: '{{ $labels.instance }} has reported {{ $value }} for 10 minutes (threshold: <critical threshold>).'
```

Pick whichever new metric from step 2 has a natural "too high"/"too low"
direction (a backlog, a saturation ratio, an error count) and propose
concrete, round-number default thresholds (same spirit as the shipped
commented example's `100`/`500`), noting they're defaults to adjust per
deployment, not something to leave unexamined. PromQL must reference only
metrics that step 3 actually emits. No other metric name is acceptable here.
If none of this collector's metrics has a sensible "bad" direction (a pure
informational gauge, say), say so explicitly and skip proposing an alert
rather than inventing a meaningless threshold.

## 8. Verify

```sh
make test
make docs-check
```

Show the real output. Both must be green: `make test` compiles and runs
everything (a redeclaration from step 4, a wiring typo from step 5, or a
missing import all surface here as build failures), and `make docs-check`
fails if step 6 documents something step 3 doesn't produce, or logs a WARNING
if step 3 produces something step 6 doesn't document: either mismatch means
go back and fix steps 3/6 against each other, not silence the check.

For extra confidence before handing this back, `make lint`/`make vet` (fast)
and the full `make check` (vet + lint + test + vuln + actionlint + zizmor +
`deadcode` + docs-check) are worth running too: `deadcode` in particular
would catch a new collector file that never made it into step 5's registry.

## 8b. Complete the journal

Only once `make test` and `make docs-check` have both printed green in step 8.
Never before: a journal that records a collector the build rejects is exactly
the lie this file exists to prevent.

If `docs/exporter-journal.md` is absent, offer to create it now, per
`project-journal.md`'s degradation rules, writing all eight headers from its
`## Format` with a placeholder line under every section this step cannot fill
yet (its `## Section ownership` rule), then continue. A file holding only the
three sections below would be missing headers, which is exactly what
`## Degradation` calls corrupt, so the next command would open with a
rebuild-or-leave prompt on a perfectly healthy repository. If the journal is
already corrupt, ask before writing anything.

Three edits:

1. **Tick the collector** under `## Collectors`, appending the date:

   ```
   - [x] `<name>`  <variant>  built <date>
   ```

   If it was not on the list at all (a collector nobody planned), add it,
   already ticked, and say so.

2. **Record the observed cardinality** under `## Cardinality budget`, next to
   the planned figure rather than replacing it. The gap between intent and
   observation is the interesting part:

   ```
   - `<name>`: labels <list>; worst case ~<N> series; observed <N>
   ```

   Count from the fixture: one series per fixed-shape metric, plus one per
   label combination the variable-label metrics actually emit. That is the
   same count step 4's `GatherAndCount` assertion already uses.

   If no planned line exists for this collector (the unplanned case item 1
   admits), write `worst case unplanned` in place of the figure. Never
   back-fill it from the observation: that would manufacture an intention
   nobody had, and the gap this line exists to show would read as zero.

3. **Append one `## Session log` line**, dated, naming the collector, its
   variant, and where the fixture came from.

## 9. What's next

- Run the built binary against the real target and confirm the new metric(s)
  with `curl -s http://localhost:<port>/metrics | grep <metric_name>` (this
  repo's own `CONTRIBUTING.md` Definition of Done, steps 5-8).
- Read the remaining unticked entries from the journal's `## Collectors` and
  name the next one explicitly. Do not say "repeat for the rest of the list":
  the point of the journal is that the list is on disk and can be named.
- Commit with `feat(collector): add <name> collector` (see `CONTRIBUTING.md`'s
  commit-message convention).

End with the resumption block `project-journal.md` defines:

```
Collector `<name>` added. make test and make docs-check are green.
Journal: <N> of <M> collectors built. Next planned: `<next>` (<variant>).

Safe to /clear now: everything above is in docs/exporter-journal.md.
Then run:

    /add-collector <next>
```

When no unticked collector remains, suggest `/generate-dashboard` instead.
Print the block; never invoke the command.

With no usable journal (absent and step 8b's offer declined, or corrupt and
left untouched at its prompt) there is no list to read from. Drop the `Journal:` line rather than inventing counts, suggest
`/add-collector <name>` with a name the user must choose, and say plainly that
this one is a placeholder rather than something read from the journal. The
rest of the block still holds: the gate is green and the work is on disk.
