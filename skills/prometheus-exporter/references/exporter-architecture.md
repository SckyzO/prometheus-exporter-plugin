# Exporter architecture: the design phase before any code

This is step 0 of the workflow: a design pass that runs *before* the first
line of Go is written and before `/new-prometheus-exporter` is invoked. It
produces four decisions (the data source, the single- vs. multi-target
model, the I/O flavor, and the collector list with its cardinality budget)
that everything downstream (the scaffold, the per-collector loop, the
alerting) is built from. Getting this phase right is cheaper than
re-architecting a repository that already builds.

This document teaches the decision process itself. The concrete shape a
collector's code takes once the flavor is chosen is `collector-pattern.md`;
the repository layout the scaffold produces is `project-scaffold.md`; the
Prometheus-specific naming and typing rules that apply once metrics exist are
`prometheus-principles.md`.

## 1. Choosing a data source

The data source is an architecture decision, not a technical default. Pick in
this order of preference, falling through only when the option above is
genuinely unavailable:

1. **REST/API.** A structured, versioned HTTP interface is the easiest
   boundary to mock (an `httptest.Server` stands in for the real thing) and
   the easiest to reason about (a documented request/response shape,
   typically JSON). This is the default flavor for a reason: most modern
   targets expose one.
2. **gRPC.** Prefer it over a REST API when the target's *primary*, best
   maintained interface is gRPC rather than a REST facade bolted on
   afterward. A typed, generated client is just as mockable as an HTTP one
   (swap the generated client for a fake implementing the same generated
   interface). This scaffold does not ship a dedicated `grpc` flavor today:
   a gRPC-backed collector adapts the HTTP flavor's injectable-client shape
   (`collector-pattern.md`) using a generated stub in place of `net/http`,
   rather than picking a flavor directory that does not exist yet.
3. **CLI (last resort).** Wrapping a command-line tool is the least
   preferred option: output formats are rarely versioned, rarely
   machine-readable by design, and change without notice between tool
   releases. It is the right call only when a target's *only* interface is a
   CLI binary, commonly a legacy system whose API surface predates its
   monitoring needs. This scaffold ships a `cli` flavor precisely because
   that situation is common enough to deserve first-class support, not
   because CLI wrapping is the recommended starting point.

**Database targets are out of scope for this plugin: a deliberate
non-goal, not a deferred feature.** When a target's only interface is its
own database, reach for a purpose-built tool instead of this scaffold: the
database engine itself is already well served by `postgres_exporter` or
`mysqld_exporter`, and arbitrary SQL-to-metrics is served by the
config-driven `sql_exporter` (a YAML mapping from query to metric, no Go to
write at all). This scaffold exists for programs that have **no existing
exporter**, reached through their own HTTP API, gRPC, or CLI. A database
schema was rarely designed as a stable public contract, and the tools above
already cover that ground better than a hand-rolled collector would.

context7 is one of several grounding inputs, used in the ladder's
preference order (local spec first, then docs, then context7). Whichever
rung you land on, use context7 against the **target's own**
documentation before writing a collector against it: its actual endpoints,
payload shapes, authentication, and pagination, not a remembered or assumed
shape. This is separate from, and happens before, the context7 lookup against
`prometheus.io` in step 1 of the workflow (`prometheus-principles.md`), which
verifies Prometheus's own conventions instead of the target's API. See
`discovery-inputs.md` for the full input ladder and per-source extraction
method.

## 2. Single-target vs. multi-target

Prometheus documents two distinct exporter shapes:

- **Single-target**: the exporter runs alongside (or embedded in) the one
  thing it monitors and always reports on that one target. This is what
  every collector this scaffold ships assumes: `main.go`'s registry, flags,
  and `/metrics` endpoint all describe exactly one target.
- **Multi-target**: the exporter itself queries *N* other instances over the
  network and is queried, per-target, via a `/probe` endpoint carrying a
  `target` (and often `module`) query parameter: Prometheus's own
  [multi-target exporter pattern](https://prometheus.io/docs/guides/multi-target-exporter/).
  The canonical example is the Blackbox exporter: a `scrape_configs` entry
  points `metrics_path: /probe` at the exporter's own address, with
  `params: {module: [http_2xx], target: [some-host]}`, and relabeling turns
  the probed target into the resulting series' `instance` label. The
  exporter process itself is not "the thing being monitored." It is a
  fan-out proxy in front of however many real targets Prometheus asks it to
  probe. A multi-target exporter can also authenticate per target: declaring
  a `modules:` section in its configuration file and having the scrape
  config name one with `&module=` lets one target's credentials differ from
  another's. Without that section every target authenticates the same way,
  or not at all, which is the right answer when one credential covers all
  of them.

This is a structural fork, not a later refinement: it dictates the shape of
`main.go` (a `/probe` handler that builds a fresh set of collectors per
request, scoped to the `target` parameter, instead of a fixed registry built
once at startup) and changes what "a collector" even means (per-request
constructed, not process-lifetime).

**Multi-target is scaffolded, opt-in, via `--target-model multi` (http flavor
only).** If your target is one of many identical instances Prometheus should
poll on demand (a fleet of identical network devices, a protocol prober,
anything shaped like the Blackbox exporter), `/new-prometheus-exporter
--target-model multi` produces a `/probe?target=…` handler
(`internal/probe/`) holding an ordered slice of named factories, one per
collector, instead of the fixed registry the default `single` model builds
once at startup. On every request the handler builds a fresh registry scoped
to that one target and gathers whichever factories the request selects.
`multi` requires `--flavor http`: there is no `cli` multi-target, since the
`cli` flavor has no network target to vary.

Each probe runs under a real deadline,
`min(--probe.timeout, X-Prometheus-Scrape-Timeout-Seconds - --probe.timeout-offset)`
(`--probe.timeout` defaults to `5s`, `--probe.timeout-offset` to `0.5s`),
which reaches every scoped collector through its own constructor, because
`prometheus.Collector.Collect(ch)` takes no context at all: the constructor
is the only channel available to hand one in. The shared `StatusTracker`
collects every scoped collector sequentially, so a probe costs the SUM of
its collectors' durations, not the slowest one alone; the deadline above is
what keeps that sum bounded instead of letting a probe run long after
Prometheus gave up on it. `--probe.module` selects a subset of collectors
per probe (`/probe?target=…&module=…`, repeatable and comma-separated,
named modules combine); an absent `module` runs every registered collector,
so an existing scrape config that only sets `target` keeps working
untouched. `/add-collector` understands both models: it appends a
`probe.NamedFactory` at the multi-target scaffold's own marker the same way
it appends a `register(...)` call at the single-target one (see
`project-scaffold.md`). Decide the model now, because retrofitting it onto
an already-scaffolded single-target `main.go` later touches the entry point,
the registry, and every collector's constructor signature at once.

Multi-target's own self-metrics, `probe_success`, `probe_duration_seconds`,
and `probe_timeout_seconds`, are a deliberate, documented exception to this
scaffold's usual `namespace_subsystem_name` metric-naming rule. See
`prometheus-principles.md`'s naming-exception note.

## 3. The mockable I/O boundary: choosing a flavor

Whatever the source, one principle survives the choice: **the I/O boundary is
an injectable dependency**, not a call made directly from a collector. That
is what makes a collector testable without a live target in CI. The concrete
shape of that dependency is what this scaffold calls a *flavor*:

| Flavor | Boundary | Status |
|---|---|---|
| `http` (default) | An injectable `*Client` wrapping `net/http`, pointed at a base URL; swapped for an `httptest.Server` in tests | Shipped |
| `cli` | A package-level `var Execute` function variable wrapping `exec.CommandContext`; reassigned to a stub in tests | Shipped |

The full mechanics of each boundary (exact types, the five-piece collector
shape built on top of it, the test triad) are `collector-pattern.md`'s
subject, not this one. What belongs at the architecture stage is just the
choice itself, made once, up front: **the flavor follows from the source**
(step 1), not the other way around. A REST/API source picks `http`; a
CLI-only legacy source picks `cli`. A database-only source has no flavor to
pick here at all. See the non-goal note in step 1: reach for
`postgres_exporter`/`mysqld_exporter`/`sql_exporter` instead of this
scaffold.

Mechanically, the flavor is selected by **directory**, not by a conditional
inside a shared file: `/new-prometheus-exporter` copies the one
`code/<flavor>/` template subtree that matches your choice into
`internal/collector/`, and the other flavor's templates are never present in
the generated repository at all. There is no `if flavor == "cli"` branch
anywhere in the shipped code to keep in sync. The unused flavor simply isn't
there.

## 4. Collector decomposition

Decompose the target into **one collector per resource** before scaffolding,
not one collector that tries to report everything. Each collector this
scaffold produces:

- is wrapped independently by the shared `StatusTracker`, so one collector's
  failure is visible (`<namespace>_exporter_collector_success{collector="x"}
  == 0`) and does not blank out any other collector's metrics for that
  scrape;
- gets its own `--[no-]collector.<name>` flag, so an expensive or
  irrelevant-to-you resource can be switched off without touching code;
- gets its own focused test triad (`collector-pattern.md`) instead of one
  sprawling test file covering unrelated concerns.

For each collector, also decide whether its backend is slow or expensive
enough (seconds per call, a rate limit, or a device not built for
high-frequency polling, the kind of backend a scrape should never wait on)
to warrant refreshing on a fixed background interval instead of
synchronously on every scrape. This is `/add-collector`'s
`--variant background`. See `collector-pattern.md` for the shape once the
collector list reaches this one. Most collectors do not need it; a fast,
cheap REST endpoint or CLI call should stay synchronous, the simpler
default.

A resource that genuinely needs several independent fetches (a `/health`
endpoint and a `/stats` endpoint that change on unrelated schedules, say)
is usually two collectors, not one collector with two `*Data` methods, each
one only as large as the one thing it reports on.

## 5. The cardinality budget

Before writing a parser, decide, per collector:

- **Which labels** it will attach to each metric, and where each label's
  value actually comes from.
- **How many series** that produces in the worst realistic case: the
  Cartesian product of every label's distinct value count, per metric, summed
  across the collector's metrics.
- **What flag**, if any, caps that number before it becomes a problem.

Worked example, anchored to the bundled `example` collector's CLI-flavor
shape (`internal/collector/collector.go`): it emits
`<namespace>_example{key="..."}`, one series per distinct key the data source
reports, plus `<namespace>_example_entries` (no labels, always exactly one
series). The `key` label is safe *in that fixture* because the source's own
key-space is small and fixed (three keys in `testdata/example.txt`): the
budget for this metric is "however many distinct keys the real target can
ever report," and that number must be checked against the real target, not
assumed from the fixture. A label whose values are unbounded or
user-supplied (a request ID, a raw email, a timestamp) is not a cardinality
budget that can be stated at all. See `prometheus-principles.md`'s
low-cardinality-label rule before choosing one.

Once a real collector's label choice turns out to be expensive at scale, the
lever is a flag, decided now rather than discovered later: a boolean that
omits the highest-cardinality label entirely (collapsing per-item series into
one aggregate series), or a flag that limits which values populate a label
(an allow-list or a size cap). Document the flag in `docs/configuration.md`
next to the collector's other flags, the same way the bundled `example`
collector documents `--collector.example.timeout` and
`--collector.example.target`, neither of which is a cardinality-reduction
flag itself, since the example's own single `key` label doesn't need one, but
the pattern (a `--collector.<name>.<setting>` flag, documented, defaulted
sensibly) is the one to reuse.

## 6. Candidate business alerts per collector

For every collector on the list, ask one question before moving on: *what
functional condition, if this collector's own metrics showed it, should page
or warn someone?* Not "is the exporter up" (that alert is generic and ships
for free with every scaffold; see `dashboards-and-alerts.md`) but something
specific to what this collector actually measures: a resource approaching
saturation, a queue depth that stopped draining, an error rate crossing a
threshold, a value that should never realistically be zero going to zero.

Write these down now, even as a one-line note per collector ("alert if
saturation exceeds N%", "alert if lag exceeds N seconds"), without wiring the
PromQL yet. `/add-collector` proposes a concrete alert, following the
two-tier `warning`/`critical` plus `for:` pattern documented in
`dashboards-and-alerts.md`, at the point each collector is actually
materialized; having the candidate list now means that step is confirming a
decision already made, not inventing one under time pressure once the metric
exists.

## Output of this phase

Before `/new-prometheus-exporter` runs, this phase should have produced:

- [ ] **Data source** chosen, in preference order (REST/API, gRPC, or CLI
      as a last resort, a database-only target is out of scope; see step 1),
      confirmed against the target's own docs via context7.
- [ ] **Single- vs. multi-target** decided, and if multi-target, confirmed
      that the flavor is (or will be) `http`, since `--target-model multi`
      requires it.
- [ ] **I/O flavor** chosen (`http` or `cli`), following directly from the
      data source.
- [ ] **Collector list**, one resource per collector, in the order
      `/add-collector` will work through them.
- [ ] **Background-refresh candidates** flagged, per collector, if any
      backend is slow/expensive enough that a scrape should never wait on
      it directly.
- [ ] **Cardinality budget** per collector: labels, worst-case series count,
      and any reduction flag needed.
- [ ] **Candidate business alert(s)** per collector, even as a one-line note.

These seven items are the inputs the rest of the workflow consumes: the
scaffold takes the flavor and license; the per-collector loop takes the
collector list; the release/observability step takes the alert candidates.

When produced via `/design-exporter`, these seven items are serialized into
an architecture brief (`./exporter-design-brief.md`) that
`/new-prometheus-exporter` consumes; see `discovery-inputs.md` for the
format.
