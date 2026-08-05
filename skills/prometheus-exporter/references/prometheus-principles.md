# Prometheus conventions: naming, types, labels, OpenMetrics

Everything in this document is sourced from the current `prometheus.io`
documentation, fetched via context7, not from memory, which drifts as
conventions evolve between Prometheus releases. Two pages carry most of the
rules below: [Metric and label naming](https://prometheus.io/docs/practices/naming/)
and [Writing exporters](https://prometheus.io/docs/instrumenting/writing_exporters/).
Anything drawn from elsewhere is cited inline. Re-run the same context7
lookups before relying on this document for a detail it doesn't cover, or
if enough time has passed that the conventions might have moved.

This document teaches the *rules*. Where the scaffold's own templates apply
them (sometimes exactly, sometimes with a documented, deliberate deviation)
is called out explicitly, because a reference that only stated the ideal
without checking it against the shipped code would be exactly the kind of
doc `make docs-check` (`docs-and-governance.md`) exists to catch lying.

## Naming

**Structure**: `namespace_subsystem_name_unit`. `namespace` is a single-word
prefix for the whole exporter (often the exporter or target's own name);
`subsystem` groups metrics belonging to one component when an exporter has
several; `unit`, when the metric has a physical dimension, is a base-unit
suffix (below). Metric names "should have a single-word application prefix
relevant to the metric's domain, often the application name itself," and
"must refer to a single unit and quantity" ([naming](https://prometheus.io/docs/practices/naming/)).
The scaffold's own metrics follow this: `<namespace>_exporter_collector_success`
reads as namespace + subsystem (`exporter`) + name (`collector_success`); a
bare `<namespace>_healthy` (the bundled HTTP-flavor example) has no
subsystem and no unit suffix because "healthy" is a boolean flag, not a
physical quantity.

**Counters end in `_total`.** [Writing exporters](https://prometheus.io/docs/instrumenting/writing_exporters/)
reserves the `_total` suffix for counters specifically (alongside `_sum`,
`_count`, and `_bucket`, reserved for the parts of a Summary or Histogram;
don't reuse any of the four for something that isn't one). OpenMetrics 1.0
made `_total` mandatory on every counter; [OpenMetrics 2.0 relaxes this to a
recommendation](https://prometheus.io/docs/guides/open_metrics_2_0_migration/)
for OpenTelemetry interoperability. Keep using it anyway, since it is still
what every existing Prometheus convention, dashboard, and human reader
expects a counter to look like.

**Base units, not display units.** Use `seconds` not milliseconds,
`bytes` not kilobytes, `ratio` (a plain 0-1 value) not a percentage: "use
base units... and let graphing tools handle conversions"
([naming](https://prometheus.io/docs/practices/naming/)). The scaffold's own
self-instrumentation follows this exactly:
`<namespace>_exporter_request_duration_seconds` and
`<namespace>_exporter_command_duration_seconds` are both seconds, both
`float64`, never milliseconds. Not every metric needs a unit suffix. Only
one with an actual physical dimension does. The bundled example's
`<namespace>_items` needs no unit suffix because a bare count is already
unambiguous without one; a suffix only earns its place when the number
means nothing without it, the way a raw `42` does for a duration until
`_seconds` says what it's 42 *of*.

**The unit lives in the name, never in a label.** A metric's unit is fixed
at instrumentation time and belongs in the name as a suffix or infix; it is
not a dimension a label should carry: OpenMetrics' own `UNIT` metadata is
expected to be "a suffix or infix of the MetricFamily name," and a
MetricFamily whose unit is neither is explicitly flagged as discouraged
([OpenMetrics spec](https://prometheus.io/docs/specs/om/open_metrics_spec_2_0/)).
The mirror-image rule from [writing exporters](https://prometheus.io/docs/instrumenting/writing_exporters/)
covers the other direction: "metric names should not include labels." Don't
bake a label's dimension into the name either (`http_requests_get_total`
instead of `http_requests_total{method="get"}`), except when separate
metrics are genuinely the better model. The next section is how to tell.

### Deciding between a separate name and a label value

The exception above is the single most re-litigated question when a
collector is written, so it gets a procedure rather than a judgment call.
Work the three steps in order and stop at the first one that answers.

**Step 1: apply the official rule of thumb, and keep its hedge.** [Naming
practices](https://prometheus.io/docs/practices/naming/) puts it this way,
verbatim:

> As a rule of thumb, either the `sum()` or the `avg()` over all dimensions
> of a given metric should be meaningful (though not necessarily useful). If
> it is not meaningful, split the data up into multiple metrics.

Its own worked example is queue capacity: several queues' capacities under
one metric is good, mixing a queue's capacity with its current element count
is not. Note "**rule of thumb**" and "**though not necessarily useful**".
This is a heuristic that the same documentation then carves an exception
into, so it is a strong first indication and not a decision procedure.
Treating it as one is the trap, in both directions:

- A meaningful `sum()` does **not** oblige you to use a label. Read/write is
  the standing counter-example, and Step 2 settles it the other way.
- A meaningless `sum()` does **not** oblige you to split, either. Step 2 has
  the counter-example for that as well, and it is a case that arises
  specifically in exporters.

**Step 2: check whether the official guidance already names the case.**
Three families are addressed outright, and deriving any of them from Step 1
alone gets at least one wrong. All three are from [writing
exporters](https://prometheus.io/docs/instrumenting/writing_exporters/):

- **Read/write and send/receive: separate metrics.** Verbatim: "Read/write
  and send/receive are best as separate metrics, rather than as a label. This
  is usually because you care about only one of them at a time, and it is
  easier to use them that way." Step 1 alone would have allowed a
  `direction` label here, since bytes read plus bytes written is a
  meaningful sum. Note the guidance's own hedges, "best as" and "usually":
  this is a strong default, not a prohibition.
- **Fundamentally tabular data: one metric, despite a meaningless `sum()`.**
  This is the exception that stops Step 1 being a decision procedure, and it
  is introduced as arising "with exporters" specifically. Verbatim: "There is
  one other case that comes up with exporters, and that's where the data is
  fundamentally tabular and doing otherwise would require users to do regexes
  on metric names to be usable. Consider the voltage sensors on your
  motherboard, while doing math across them is meaningless, it makes sense to
  have them in one metric rather than having one metric per sensor." So a
  per-sensor, per-slot or per-device dimension over readings of the same
  unit stays **one metric with a label**, even though summing across it is
  nonsense.
- **Mixed units: always separate.** The same passage draws the boundary of
  the tabular case: "All values within a metric should (almost) always have
  the same unit, for example consider if fan speeds were mixed in with the
  voltages, and you had no way to automatically separate them." This is what
  actually refuses a temperature and a humidity under one name behind a
  `sensor_type` label: not that adding them is meaningless, which the
  voltage case shows is survivable, but that they are different units.

**Step 3: when none of that settles it, look at what an official exporter in
the same domain already does, before concluding.** Prefer context7 for the
lookup; fall back to a cold, read-only clone at a release tag when it does
not cover the exporter. The convention an established exporter shipped is
stronger evidence than a fresh derivation, because dashboards and alerts in
the wild are already written against it.

A worked example, since it shows Steps 1 and 2 pulling against each other:
for tape drives, `node_exporter` exposes `node_tape_read_bytes_total` and
`node_tape_written_bytes_total` as separate names with no `direction` label,
alongside `node_tape_reads_completed_total` and
`node_tape_writes_completed_total`. The pair is not even symmetrical in
wording (`read` against `written`), which is a good hint that these are two
distinct measurements rather than two values of one dimension. Its per-device
dimension, meanwhile, is a plain `device` label on each of them: tabular data,
Step 2's second family.

Two further points, both of which stand on their own:

- **Cardinality is still a reason to split**, and it is the reason `writing
  exporters` gives for its own exception to "metric names should not include
  the labels that they're exported with": that exception is "when you're
  exporting the same data with different labels via multiple metrics", which
  for direct instrumentation "should only come up when exporting a single
  metric with all the labels would have too high a cardinality". If one
  labeled metric would multiply out past what the cardinality budget can
  carry (`exporter-architecture.md`), separate metrics are the answer
  regardless of what Steps 1 to 3 concluded.
- **A unit is never a label** (see the rule directly above), so a
  `unit="bytes"`/`unit="seconds"` dimension is not an option this procedure
  can ever arrive at. Step 2's third family is the same rule seen from the
  other side.

**Record the answer, once.** These arbitrations are made per exporter, not
per collector: `/prometheus-exporter:design-exporter` works them out and
writes them into the project journal next to the shared label vocabulary, so
that `/prometheus-exporter:add-collector` inherits them instead of asking
again for every collector. A decision that lives only in the conversation
that produced it will be re-litigated, and re-litigated differently.

**No dynamic metric names, static label keys.** [Writing exporters](https://prometheus.io/docs/instrumenting/writing_exporters/)
is direct about this: "metric names should not be procedurally generated"
outside of a custom collector's own internals. Label *keys* are held to the
same standard: they are part of a metric's identity, fixed at
instrumentation time, and label *values* are the only part meant to vary
per scrape. This scaffold doesn't just state the rule, it enforces it
mechanically: `make docs-check` (`internal/collector/docs_check_test.go`)
statically resolves every metric name and label-key list from source via
`go/ast`, and only recognizes a name built from a string literal or a
`prometheus.BuildFQName(ns, sub, name)` call whose three arguments are
themselves literals. A computed name is invisible to that check and reported
as an explicit warning rather than silently skipped, which is itself a
second, independent reason (beyond the Prometheus convention) to never
compute one.

### Deliberate exception: `probe_success` / `probe_duration_seconds`

Multi-target scaffolds (`--target-model multi`, `internal/probe/probe.go`)
emit these two gauges **without** the `namespace_subsystem_name` prefix this
document otherwise requires. This is intentional, not an oversight: every
multi-target exporter in the ecosystem (Blackbox, SNMP) emits `probe_success`
and `probe_duration_seconds` exactly like this (no application prefix), and
every multi-target dashboard/alert in the wild queries those exact bare
names ([Prometheus's own multi-target exporter guide](https://prometheus.io/docs/guides/multi-target-exporter/)
shows the same convention). Matching the ecosystem here outweighs this
scaffold's own namespace-prefix convention, for these two metrics only.
Nothing else either model emits gets this exception, and it is called out
again at its declaration site in `internal/probe/probe.go` itself.

## Types

**Counter**: monotonically increasing, resets to zero only on process
restart, named with `_total`. **Gauge**: an arbitrary value that can go up or
down. **Histogram**: client-side bucketed observations, exposing `_bucket`,
`_sum`, and `_count` series that can be aggregated across instances and have
quantiles computed at query time. A Summary computes quantiles client-side
instead: cheaper to query, but its quantiles cannot be meaningfully averaged
across instances; this scaffold ships no Summary, and Histogram is the
better default whenever aggregation across replicas matters.

**Prefer `MustNewConstMetric` over direct instrumentation inside a
collector.** [Writing exporters](https://prometheus.io/docs/instrumenting/writing_exporters/)
is explicit: "avoid direct instrumentation that updates metrics on each
scrape. Instead, create new metrics each time" with `MustNewConstMetric` (or
the equivalent in another client library): "this prevents race conditions
and ensures that disappearing label values are not exported." Every business
metric this scaffold's collectors emit follows this: `Collect` builds a
fresh `prometheus.MustNewConstMetric` per value, every call, from whatever
`<name>GetMetrics` just returned. Nothing is updated in place or retained
between scrapes (`collector-pattern.md` covers the full shape). The same doc
carves out the one exception this scaffold also relies on: "direct
instrumentation is acceptable for metrics about the exporter's own
operation, like bytes transferred," which is exactly what `RequestDuration`
(`internal/collector/client.go`) and `CommandDuration`
(`internal/collector/execute.go`) are: plain, package-level
`prometheus.HistogramVec` values that every `Fetch`/`Execute` call observes
into directly, not per-scrape const metrics.

**The "const-Gauge for everything" pattern, and its limit.** Every business
metric the bundled `example` collector emits, `items`, `healthy` (HTTP
flavor), `example`, `example_entries` (CLI flavor), is sent as a
`prometheus.GaugeValue`, regardless of whether its own semantics are closer
to a running total. That default is a reasonable one for a collector that
*polls a snapshot* of external state on every scrape (which is what a
request- or command-driven collector, by construction, always does). There
is no notion of "since process start" to accumulate, only "what does the
target report right now." It stops being correct the moment your own target
exposes a genuine monotonic counter (requests served since its own process
started, for instance): forcing that through a Gauge throws away
`rate()`/`increase()`'s built-in counter-reset detection in PromQL, and
pairing a Gauge with a `_total` name is simply wrong regardless. If your
data source hands you a real counter, emit it as
`prometheus.CounterValue` with a `_total` name. Don't default to Gauge out
of habit.

The shared `StatusTracker` (`internal/collector/status_tracker.go`) makes
the opposite, and correct, choice for its own two metrics, and is worth
reading precisely because it looks like the same pattern but isn't:
`<namespace>_exporter_collector_success` and
`<namespace>_exporter_collector_duration_seconds` are both Gauges too, but
here Gauge is the *right* type, not a default reached for out of convenience.
[Prometheus's own instrumentation guidance](https://prometheus.io/docs/practices/instrumentation/)
carves out exactly this case: "export a gauge for collection duration in
seconds... this is an exception where duration can be a gauge, similar to
batch job durations." A success flag that can legitimately flip from 0 back
to 1 on the next scrape could never be a Counter (which must never decrease
in a way that isn't a reset); a last-scrape duration has the same
"batch job" shape. The trade-off to know: a Gauge only ever tells you the
*last* scrape's outcome or duration, no distribution, no percentile, no
history. When a distribution across many calls is actually what you want,
reach for a Histogram instead, exactly as this scaffold's own
`RequestDuration`/`CommandDuration` already do for per-request/per-command
timing.

### Two counter traps a target can hand you

Field experience rather than prometheus.io guidance, except where cited: both
come from the source, so no type choice on this side fixes them.

**A per-device counter is exposed per device, never pre-summed.** The
temptation, when a target reports N devices each with its own counter, is to
add them up and expose the total, because the total is usually the number
people ask for. Do not: the sum is only monotonic while N is, so removing a
device drops it, and `rate()` reads any drop as a counter reset and credits
the whole post-drop value as new activity. Decommissioning a device then
produces a spike in a graph of work done.

[Writing exporters](https://prometheus.io/docs/instrumenting/writing_exporters/)
rules out the shape independently of that artifact, for a `label="total"`
series and for an unlabeled one alike. On what each costs: *"The former breaks
for people who do a `sum()` over your metric, and the latter breaks sum and is
quite difficult to work with."* And on what to do instead: *"Never do either of
these, rely on Prometheus aggregation instead."*

The aggregation that replaces it has a required order, and getting it backwards
reintroduces exactly the artifact above. [Querying
functions](https://prometheus.io/docs/prometheus/latest/querying/functions/) is
explicit: *"always take a `rate()` first, then aggregate."* `sum(rate(x[5m]))`
over per-device counters does not spike when a device goes away, because the
departed series simply stops contributing; `rate(sum(x)[5m:])` does. So expose
the per-device counter, labeled, and put the ordering rule in the metric's own
help text or in `docs/metrics.md` where whoever writes the query will meet it.

**A source counter that saturates is a floor, not a measurement.** Some targets
hold a counter at its type's ceiling instead of wrapping (65535 on a uint16,
255 on a byte, whatever the target's own documentation states) rather than
letting it roll over. Once pinned, every scrape reports the same value,
`rate()` reads zero, and the metric looks calm precisely when the underlying
quantity is at its worst. The tell is a value sitting exactly at a type
boundary, unchanged across scrapes.

The consequence reaches past the metric, into the rules written over it. An
average over a saturating counter is biased low and can never exceed the
ceiling, however bad the true values are: a device pinned at the maximum
representable value still raises the fleet mean, but it raises it toward a
number that understates reality by an unknown margin, so a threshold placed
above the ceiling can never fire on that average. (A `sum()` is not bounded the
same way, since several saturated devices add past the ceiling; the bias
downward remains.)

Say it in the metric's help text, with the ceiling: *"Reported by the device
and saturates at 65535; a value at that ceiling is a lower bound, not a
count."* Then alert on reaching the ceiling (`>= 65535`, not `== 65535`, so a
target that clamps slightly differently or a later model that widens the type
still trips it) rather than on a rate or an average of it, and see
`dashboards-and-alerts.md` before writing a rule that aggregates one.

## Low-cardinality labels

Label values must come from a small, bounded set known in advance: never
an identifier, a raw timestamp, an email address, or anything else whose
distinct-value count scales with your data instead of with your metric
schema. ["Prometheus performance almost always comes down to one thing:
label cardinality"](https://prometheus.io/docs/practices/the_zen/); labels
multiply across each other, so two labels with a hundred values each is
already ten thousand series for one metric. [Writing exporters](https://prometheus.io/docs/instrumenting/writing_exporters/)
adds two narrower rules on top: avoid a generic label name like `type`, and
avoid names that collide with common infrastructure labels applied
externally by Prometheus's own relabeling (`region`, `zone`, `cluster`,
`service`, `environment`) since a scrape-time label with the same name as
one added later at the Prometheus-server level silently shadows it. `le` and
`quantile` are reserved for Histogram buckets and Summary quantiles
specifically and should not be reused for anything else.

A `multi-instance` build (`exporter-architecture.md`) has a label-collision
hazard of its own, applied at registration time rather than by Prometheus's
scrape-time relabeling: every series a watched instance emits carries an
identifying label (`--instance-label`, default `target`) plus that
instance's own `labels:` from the configuration file, both folded in as
`ConstLabels` via `prometheus.WrapRegistererWith`. An instance's `labels:`
may not reuse the identifying label, or a label a collector already emits
(`internal/config/config.go`'s `ResolveInstances` refuses either at boot),
and every instance must declare the same set of label keys, since two
collectors sharing a metric name but differing in label-key dimension is an
opaque registration-time panic, not a graceful degradation.

Cardinality is controlled the same way at runtime as it is at design time
(`exporter-architecture.md`'s budget): a flag. `--[no-]collector.<name>`
removes an entire collector's series; a narrower `--collector.<name>.<x>`
flag (the bundled example ships `.timeout` and `.target`, neither
cardinality-related, but the same flag shape) is where a label-reduction
toggle belongs once a real collector needs one. See
`exporter-architecture.md`'s cardinality-budget section for when to add one.

## OpenMetrics

The scaffold's `/metrics` endpoint enables the [OpenMetrics](https://prometheus.io/docs/specs/om/open_metrics_spec/)
exposition format, not just the classic Prometheus text format:

```go
http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{
	EnableOpenMetrics: true,
	ErrorHandling:     promhttp.ContinueOnError,
}))
```

`promhttp.HandlerFor` content-negotiates on the request's `Accept` header:
a scraper that asks for `application/openmetrics-text` gets it (including
its `# EOF` terminator and richer type set: `gaugehistogram`, `stateset`,
`info`, alongside the familiar counter/gauge/histogram/summary), and
anything else gets the classic text format. Nothing about a collector's own
code needs to change to support this: `EnableOpenMetrics` is a handler-level
switch, not a per-metric one.

`ErrorHandling: promhttp.ContinueOnError` is a related, separate decision
worth understanding alongside it: without it, one collector's `Gather` error
(two `MustNewConstMetric` calls colliding on an identical label set, say)
would fail the *entire* `/metrics` response with an HTTP error, discarding
every other collector's metrics along with the broken one. `ContinueOnError`
serves every metric family that gathered cleanly and only falls back to an
HTTP error if nothing could be gathered at all, the same idiom
multi-collector exporters like `node_exporter` use, and the reason the
per-collector `StatusTracker` (`collector-pattern.md`) can promise that one
collector's failure doesn't take the others down with it.

## Self-instrumentation naming

An exporter's metrics about its *own* operation (request timing, per-collector
success, scrape duration) need a naming convention too, and Prometheus
reserves two prefixes for this purpose: "the prefixes `process_` and
`scrape_` are reserved, but can be extended with exporter-specific prefixes,
such as `jmx_scrape_duration_seconds`"
([writing exporters](https://prometheus.io/docs/instrumenting/writing_exporters/)).
That guidance's own example takes the `<namespace>_scrape_*` shape: extend
the reserved word with your own prefix in front of it.

This scaffold's self-instrumentation takes a different, equally valid path:
`<namespace>_exporter_*` (`<namespace>_exporter_collector_success`,
`<namespace>_exporter_collector_duration_seconds`,
`<namespace>_exporter_request_duration_seconds` /
`<namespace>_exporter_command_duration_seconds`). It never touches the
literal words `process_` or `scrape_` at all, reserved or not. The
non-collision rule the guidance is actually protecting (don't let your own
exporter-internal metric collide with one Prometheus or another exporter
convention might use) holds either way. Recognize both shapes as compliant
when you see them in the wild; don't read `_exporter_` as a required
convention or `_scrape_` as the only correct one.

## Checklist

- [ ] Metric names follow `namespace_subsystem_name_unit`; counters end in
      `_total`; base units only (`_seconds`, `_bytes`, `_ratio`).
- [ ] No unit encoded as a label value; no label dimension baked into the
      metric name instead of an actual label.
- [ ] Every name-vs-label choice went through the three-step procedure, not
      the `sum()`/`avg()` rule of thumb alone, which is a hedged heuristic
      with a named tabular-data exception rather than a decision procedure;
      the outcome is recorded on the journal's `Name-vs-label arbitrations:`
      line rather than left in the conversation that decided it.
- [ ] Metric names and label keys are static: a literal or a
      `BuildFQName(literal, literal, literal)` call, never computed.
- [ ] A per-device counter is exposed per device, never pre-summed into a
      total the exporter computes: `rate()` reads the drop from a shrinking
      population as a counter reset, and aggregation belongs in PromQL,
      `rate()` first and `sum()` after.
- [ ] A source counter that can saturate says so in its help text, with the
      ceiling value, because a value at the ceiling is a lower bound rather
      than a count and an average over it is biased low without bound.
- [ ] Type matches semantics: Counter only for genuine monotonic totals,
      Histogram for distributions you'll aggregate or want percentiles from,
      Gauge for a snapshot or a last-scrape outcome/duration.
- [ ] Every label's value set is small and known in advance; no identifiers,
      timestamps, or free text.
- [ ] Self-instrumentation is named so it cannot collide with a target
      collector's own metrics: `<namespace>_exporter_*` or
      `<namespace>_scrape_*`, either is fine, but not a bare `process_*` /
      `scrape_*`.
