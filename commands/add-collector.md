---
description: Add one new collector — the full five-piece pattern, its test triad, registry wiring, docs, and a proposed business alert — to an existing scaffolded Prometheus exporter repository. The most-repeated action after scaffolding.
argument-hint: <name>
disable-model-invocation: true
---

Add exactly **one** new collector to an already-scaffolded exporter repository
in the current working directory. This edits real, already-committed files
(`cmd/*/main.go`, `docs/metrics.md`, `monitoring/prometheus/alerts.yml`) and
writes new ones — so only run it when the user explicitly invokes this
command, and walk through every step below in order rather than skipping
ahead.

Candidate collector name from the command argument: $ARGUMENTS

## 0. Confirm this is a scaffolded exporter, and detect its I/O flavor

Refuse to guess at a repository that was never scaffolded by this plugin.
Confirm `internal/collector/` and a `cmd/*/main.go` both exist; if either is
missing, stop and point the user at `/new-prometheus-exporter` instead.

Detect the flavor from what actually lives in `internal/collector/` — never
ask the user something you can check yourself:

| Found | Flavor | Why |
|---|---|---|
| `internal/collector/client.go` (defines `NewClient`) | **http** | The HTTP flavor's injectable `Client` boundary |
| `internal/collector/execute.go` (defines `var Execute`) | **cli** | The CLI flavor's injectable command-execution boundary |
| Neither, or somehow both | — | **Ask the user** which flavor this repo is. Don't guess: the wrong flavor produces a collector with the wrong factory signature and wires it against the wrong shared self-instrumentation. |

Everything below has two columns, **http** and **cli**, for exactly these two
v0.1 flavors.

## 1. Read this repo's real values

A scaffolded repo has no `@@VAR@@` sentinels left — every value below is read
from real code, not substituted from a template:

| Value | How to read it |
|---|---|
| `NAMESPACE` | The literal in `cmd/*/main.go`'s `const namespace = "<literal>"` |
| `MODULE_PATH` | The `module <path>` line in `go.mod` |
| `EXPORTER_NAME` | The single subdirectory name under `cmd/` |
| (http only) the existing base-URL default | Any existing `--collector.<x>.target` flag's `.Default("<literal>")` in `cmd/*/main.go` — the new collector's own target flag should default to this same value unless the user says this collector really talks to a different base URL |

## 2. Collect the new collector's identity

**Name.** Use $ARGUMENTS as the candidate if given, otherwise ask. Validate
before deriving anything else from it or touching a single file:

- reject if empty, contains `/`, contains `..`, contains any whitespace, or
  starts with a leading `.` (same hard-reject shape as
  `/new-prometheus-exporter`'s `EXPORTER_NAME` check);
- **additionally reject if it is not a valid Go identifier**
  (`^[A-Za-z_][A-Za-z0-9_]*$`) — unlike `EXPORTER_NAME`, this name is spliced
  directly into Go identifiers (`<name>Data`, `<name>GetMetrics`, ...) in step
  3, so a shape a directory name tolerates (say, a leading digit) would still
  break compilation here.
- Non-blocking suggestion: lowercase `snake_case`, matching the existing
  collector-naming convention (`example`, `http_client_requests`/
  `command_exec`) — not a hard rule.

**Idempotent refusal.** Before writing anything, check:

```sh
[ -e internal/collector/<name>.go ] || [ -e internal/collector/<name>_test.go ]
grep -q 'register("<name>"' cmd/*/main.go
```

If either is true, **stop and refuse**: tell the user a collector named
`<name>` already exists (naming the colliding file/registration) and do not
overwrite or double-register it. Pick a different name, or this is the wrong
command if the goal is to *change* an existing collector.

**Derive `<Name>`** (PascalCase) from `<name>` mechanically: uppercase the
first letter and the first letter following each underscore, then drop the
underscores — `queue` → `Queue`, `job_queue` → `JobQueue`. The lowercase
`<name>` form (underscores intact) is used verbatim as the registry string,
the flag name, and the file name; `<Name>` is used only inside Go identifiers.

**Ask the data source:**

| Flavor | Meaning | Example |
|---|---|---|
| http | The endpoint **path** this collector fetches (the base URL is shared — see step 1) | `/api/queue` |
| cli | The **command and its arguments**, as separate tokens (not one shell string — `exec.CommandContext` never goes through a shell) | command `queue-cli`, args `stats` |

**Ask the target metrics**: name(s), labels (if any), and help text for each.
Remind the user (and yourself, when writing step 3's code):

- Metric names and label **keys** must be **static** — a plain string
  literal, or `prometheus.BuildFQName(ns, sub, name)` with string-literal
  arguments — never computed. `make docs-check`
  (`internal/collector/docs_check_test.go`) statically extracts metrics at
  exactly this precision; anything else is invisible to it or, worse, flagged
  as an unresolvable warning.
- Ask what a **healthy-but-empty** scrape looks like for this data (e.g. "the
  queue can legitimately be empty"). This decides whether you need an
  always-emitted summary gauge alongside a per-item one — see step 3's
  collector-authoring rule.

## 3. Materialize the collector file

Read the flavor's template directly — do **not** run `scaffold.sh` against
this repository: it copies a whole tree and expects an empty (or
`--force`-wiped) destination, which would clobber this already-customized
repo's `go.mod`/`Makefile`/`README.md`/etc. wholesale. A single new file is a
plain adaptation, not a re-scaffold.

- http: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/http/collector.go.tmpl`
- cli: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/cli/collector.go.tmpl`

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
| `"@@NAMESPACE@@_..."` metric name literals | the user's chosen static metric names (already real, e.g. `demo_items` in this repo — never a leftover `@@...@@`) |
| `@@MODULE_PATH@@` in the import line | the real module path from step 1 |
| `@@DATA_SOURCE_PATH@@` (http) | the endpoint path from step 2 |
| `"@@DATA_SOURCE@@"` (cli, inside `<name>Data`'s `Execute(ctx, ...)` call) | the command from step 2, as its own string, followed by each arg as its **own** additional string literal — `Execute(ctx, "queue-cli", "stats")`, never `Execute(ctx, "queue-cli stats")` |

Do **not** blindly find-and-replace `example` through the whole file text —
that would also mangle prose. Only the identifiers/literals above move
mechanically. Separately, **rewrite the doc comments**: drop the template's
"this is a placeholder... replace it when adapting this collector" framing —
that's no longer true, this collector already targets its real source — and
write real documentation of what it actually does. Keep comments that explain
a durable invariant of this exporter as-is (why `Collect` logs-and-returns
zero metrics on error, why `StatusTracker` treats that as failure, why a
duplicate label set breaks `Gather` for the whole scrape): those stay true for
every collector, not just the one being replaced. Within such a kept comment,
any embedded `@@…@@` sentinel or `collector="example"` illustration must still
be updated to the real namespace / new collector name — the "why" prose stays;
the concrete example values get updated.

**Adapt the shape to the user's real metrics**, not just the field count the
template happens to ship:

- Keep the five-piece shape — `<name>Data` (I/O only) → `parse<Name>` (pure)
  → `<name>GetMetrics` (glue) → `Describe`/`Collect` — regardless of how many
  fields or metrics you end up with.
- **Collector-authoring rule** (non-negotiable): on a successful scrape,
  always emit every metric, with zero *values* when there's nothing to
  report — never zero metrics. The shared `StatusTracker` counts emitted
  metrics per scrape and reports `success=0` for the collector when a
  `Collect` call sends nothing at all, indistinguishable from a real failure.
  If any of this collector's metrics has variable labels and can legitimately
  have zero entries on a healthy scrape (an empty queue, an empty list, ...),
  keep (or add) a fixed-shape, always-emitted gauge alongside it — exactly
  what the template's `items`/`entries` field already demonstrates — so a
  "nothing to report" scrape still sends at least one metric.
- More or fewer than the template's two metrics, and any number of labels,
  are all fine — adapt the struct fields, `*prometheus.Desc` fields, and
  `Collect` body freely to match what step 2 asked for.

## 4. Materialize the full test triad + fixture

Read the flavor's test template(s):

- http: `.../code/http/collector_test.go.tmpl` → write `internal/collector/<name>_test.go`
- cli: `.../code/cli/collector_test.go.tmpl` **and** `.../code/cli/parser_test.go.tmpl` → merge both into one `internal/collector/<name>_test.go`. (The shipped repo keeps these split only because the *first* collector's files are generically named `collector_test.go`/`parser_test.go`; your new collector already has a unique name, so one file is simpler and matches the http flavor's own convention.) Both templates declare `package collector` and have overlapping imports (`"os"`, `"testing"`, etc.); the merge must keep **one** `package collector` line and a **single deduplicated import block** — a literal concatenation would cause a duplicate-package/duplicate-import compile error.

Apply the same identifier renames as step 3 (whichever of that table's rows
actually occur in the test template — the endpoint-path/command rows won't,
since the test stubs I/O via `httptest`/an `Execute` swap instead of calling
the real target). Then **drop these declarations from the copy** — they are
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

Reuse `statusTrackerSuccessMetric` (already in scope, package-wide) in your
own `Test<Name>Collector_StatusTracker*` tests instead of redeclaring it.

General rule if a future template edit adds more shared declarations: any
top-level `func Test...`/`const .../var ...` in the test template whose name
does **not** contain `Example`/`example` is testing shared per-flavor
infrastructure, not the starter collector itself — never copy it into a
second collector's test file. If one slips through anyway, `go build`/
`make test` reports "redeclared in this block" — that error always means
exactly this, not a mystery to debug from scratch.

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
  metric families by name and, within a family, by label value — write the
  expected block in that order (it is deterministic, not incidental).

Add a `testdata/<name>.{json,txt}` fixture (http: JSON matching your struct;
cli: whatever `parse<Name>` expects) with realistic, anonymized sample data
(see this repo's own `CONTRIBUTING.md`, "Test Data").

## 5. Register the collector

Both markers already exist verbatim in `cmd/*/main.go` (they survive
scaffolding for exactly this purpose). Insert **after the last existing line**
of each block — never replace the marker comment itself, and never re-declare
`log`, which the closures below capture by reference:

**http** — after the last existing flag line under `// @@CLIENT_INIT@@`:

```go
<name>Target := kingpin.Flag("collector.<name>.target", "Base URL the <name> collector scrapes.").Default("<base URL from step 1>").String()
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-request timeout for the <name> collector.").Default("5s").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	return collector.New<Name>Collector(log, collector.NewClient(*<name>Target, *<name>Timeout))
}, true)
```

**cli** — after the last existing flag line under `// @@CLIENT_INIT@@`:

```go
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-command timeout for the <name> collector.").Default("5s").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	return collector.New<Name>Collector(log, *<name>Timeout)
}, true)
```

`register()` auto-declares the negatable `--[no-]collector.<name>` flag
(defaulting to enabled) — nothing else to wire for that.

This insertion point is anchor-based (last line of each marker's existing
block), so it works the same way regardless of how many collectors already
exist — it is never specific to "the second collector".

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

The names/labels here **must exactly match** what step 3's code emits — this
is what `make docs-check` verifies (fails the build on a documented metric
the code can't produce; only warns on the reverse). Every row's Type should
reflect what step 3 actually constructed (`Gauge`/`Counter`/`Histogram`/
`Summary`).

Optional, not gated by any automated check but cheap and worth doing:
add `<name>` to `docs/configuration.md`'s "Available collectors" table and,
if you added a `--collector.<name>.*` flag, its own flags table too — keeps
that reference from going stale.

## 7. Propose a business alert

Open `monitoring/prometheus/alerts.yml`. Insert a new, real (uncommented)
block immediately before the existing:

```
      # ──────────────────────────────────────────────────────────────────
      # EXAMPLE — business alert (commented out: not loaded by Prometheus)
      # ──────────────────────────────────────────────────────────────────
```

— leave that shipped teaching comment in place; don't delete it. Use the same
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
concrete, round-number default thresholds — same spirit as the shipped
commented example's `100`/`500` — noting they're defaults to adjust per
deployment, not something to leave unexamined. PromQL must reference only
metrics that step 3 actually emits — no other metric name is acceptable here.
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
if step 3 produces something step 6 doesn't document — either mismatch means
go back and fix steps 3/6 against each other, not silence the check.

For extra confidence before handing this back, `make lint`/`make vet` (fast)
and the full `make check` (vet + lint + test + vuln + actionlint + zizmor +
`deadcode` + docs-check) are worth running too — `deadcode` in particular
would catch a new collector file that never made it into step 5's registry.

## 9. What's next

- Run the built binary against the real target and confirm the new metric(s)
  with `curl -s http://localhost:<port>/metrics | grep <metric_name>` — this
  repo's own `CONTRIBUTING.md` Definition of Done, steps 5-8.
- Repeat this whole command, one collector at a time, for the rest of the
  architecture phase's collector list.
- Commit with `feat(collector): add <name> collector` (see `CONTRIBUTING.md`'s
  commit-message convention).
