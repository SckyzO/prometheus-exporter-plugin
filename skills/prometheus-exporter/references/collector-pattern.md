# The collector pattern: mockable I/O, five pieces, and the test triad

Every collector this scaffold produces, in either shipped flavor, follows
the same shape. This document is the concrete implementation of the
principle `exporter-architecture.md` names at design time (the I/O boundary
is a mockable dependency) and the naming/typing rules
`prometheus-principles.md` states. This file is about the *code structure*
those rules live inside. Everything below matches
`code/http/collector.go.tmpl`, `code/cli/collector.go.tmpl`, their
`collector_test.go.tmpl` companions, and
`internal/collector/status_tracker.go.tmpl` as shipped. Read those alongside
this document, not instead of it.

## The mockable I/O boundary, in three flavors

The one piece of a collector that touches the outside world is swapped out
in tests; nothing else needs to be. Three flavors, one principle:

**HTTP (default, shipped).** An injectable `*Client`
(`internal/collector/client.go`), constructed with a base URL and a timeout:

```go
func NewClient(target string, timeout time.Duration) *Client
func (c *Client) Fetch(ctx context.Context, path string) ([]byte, error)
```

A collector holds a `*Client` and calls `client.Fetch(ctx, path)`. A test
points `NewClient` at an `httptest.Server` instead of a real target: no
conditional, no test-only code path inside `Client` itself, just a different
base URL.

`client.go` also exports `NewClientWithConfig(target string, timeout
time.Duration, httpCfg promconfig.HTTPClientConfig) (*Client, error)`, which
builds a `*Client` whose transport carries the authentication and TLS
declared in `--config.file`'s `http_client_config:` section. The rule for
which to call is the presence of that section, not a preference: with an
`http_client_config:` section, call `NewClientWithConfig`; without one, keep
calling `NewClient`, because its transport is what every existing deployment
already runs, and `NewClientWithConfig` would build a client with different
transport defaults (keep-alives, HTTP/2) even with no authentication
configured. A multi-target probe's wiring uses a different pair for the same
job, `NewHTTPClient`/`NewClientFor`, so the shared transport is built once
across every target instead of once per probe; see `client.go`'s own doc
comments for why building one per probe would defeat connection reuse.

**CLI (shipped).** A package-level function variable
(`internal/collector/execute.go`):

```go
var Execute = func(ctx context.Context, name string, args ...string) ([]byte, error) {
	// exec.CommandContext(ctx, name, args...) under the hood
}
```

A collector calls the package-level `Execute(ctx, "@@DATA_SOURCE@@")`
directly. There is no per-collector client value to construct or inject. A
test saves the current `Execute`, reassigns the package var to a stub that
returns fixture bytes, and restores the original via `defer` immediately
after saving it, so one test's stub never leaks into another's. This is a
deliberate exception to "prefer an injected value over a package var": there
is no live binary to run in CI, and swapping the var is what makes the
collector testable without one.

**Database sources are out of scope for this plugin**, not a future flavor.
See `exporter-architecture.md`'s data-source non-goal note for the reasoning
and the pointer to `postgres_exporter`/`mysqld_exporter`/ `sql_exporter`.

The flavor is chosen once, at the architecture step
(`exporter-architecture.md`), and materialized by **directory selection**:
`/prometheus-exporter:new-prometheus-exporter --flavor http|cli` copies
exactly one `code/<flavor>/` subtree into `internal/collector/`. There is no
`if flavor == "cli"` branching inside a shared file to keep the two flavors
in sync; the flavor you didn't choose is simply absent from the generated
repository.

One consequence worth naming explicitly: HTTP's target is both a
scaffold-time default *and* a runtime override
(`--collector.example.target`, backed by `client_init.frag`'s
`kingpin.Flag(...).Default("@@DATA_SOURCE@@")`), while CLI's target (which
binary or command to run) is baked in at scaffold time only (`Execute(ctx,
"@@DATA_SOURCE@@")`, a fixed literal, no corresponding flag). A CLI
collector that genuinely needs to run a different binary per deployment
would need its own flag added by hand; the scaffold doesn't generate one,
because "which binary" is a much rarer runtime knob than "which host" is for
an HTTP target.

## The five pieces

Every collector, in either flavor, is these five pieces plus
`Describe`/`Collect`. Only the first varies by flavor. The other four are
identical in shape whether they sit on top of an HTTP client or a CLI
`Execute` call.

1. **`<name>Data(ctx)`**: the collector's only I/O. HTTP:
   `c.exampleData(ctx)` calls `c.client.Fetch(ctx, path)`. CLI:
   `c.exampleData(ctx)` wraps the call in its own `context.WithTimeout` and
   calls the package `Execute`. Nothing else in the collector touches the
   network, a subprocess, or a database.
2. **`parse<Name>(b []byte)`**: pure. No I/O, no logging, no side effects:
   every input maps deterministically to an output, which is what makes it
   unit-testable with a plain byte fixture and nothing else. The CLI
   flavor's `parseExample` additionally rejects a duplicate key as a parse
   error rather than silently overwriting or double-emitting it. See "Two
   metrics, one label set" below for why that has to happen here and not
   later.
3. **`<name>GetMetrics(ctx)`**: the glue between the two pieces above: calls
   `<name>Data`, then `parse<Name>` on the result. Identical shape
   regardless of flavor.
4. **`<Name>Collector`**: a struct holding its `*prometheus.Desc` fields
   (never a raw metric value), a `*logger.Logger`, and whatever the flavor
   needs (`client *Client` for HTTP, `timeout time.Duration` for CLI).
5. **`New<Name>Collector(...)`**: the constructor. HTTP:
   `NewExampleCollector(ctx context.Context, log *logger.Logger, client
   *Client)`. CLI: `NewExampleCollector(ctx context.Context, log
   *logger.Logger, timeout time.Duration)`. `ctx` arrives here, not at
   `Collect`, because `prometheus.Collector.Collect(ch)` takes no context at
   all: the constructor is the only channel available to hand one in. In a
   single-target exporter that context is `context.Background()` (no
   deadline, exactly as before); in a multi-target probe it is the probe's
   own deadline. Builds every `*prometheus.Desc` once, here, not per scrape.

### Describe and Collect

`Describe` sends exactly the fixed set of descriptors built in the
constructor: "constant regardless of scrape outcome, which is what makes
`prometheus.DescribeByCollect` unnecessary here," as the template's own
comment puts it. `DescribeByCollect` exists in `client_golang` for a
collector whose metric *set* genuinely varies by scrape outcome; this
pattern's descriptor set never does, so it doesn't need it.

`Collect` calls `<name>GetMetrics`, then either logs and returns (error
path) or emits one `prometheus.MustNewConstMetric` per value (success path).
See `prometheus-principles.md`'s note on why `MustNewConstMetric` and not
direct instrumentation. That is the entire contract, and it is worth stating
precisely because both branches have a rule attached.

### The error contract

On error, log and return: nothing is sent on the channel:

```go
stats, err := c.exampleGetMetrics(context.Background())
if err != nil {
	c.log.Error("Failed to get example metrics", "err", err)
	return
}
```

Zero metrics sent from one `Collect` call is not a neutral outcome: it is
exactly what the shared `StatusTracker`
(`internal/collector/status_tracker.go`) treats as a failed scrape.
`StatusTracker` wraps every collector registered in `main.go`'s registry (so
a panic or a broken descriptor in one collector can't take a whole scrape
down, and so every collector's health is exposed uniformly) and its
`Collect` method buffers each wrapped collector's output on a private
channel, counts what came out, and only then forwards it:

```go
if len(collected) == 0 {
	succeeded = 0
}
```

A panic is still caught separately via `defer`/`recover` in the same pass,
but the count check is what makes an *ordinary, non-panicking* "log the
error and return" collector register as a failure too. Before this became
count-based, `StatusTracker` only flipped `success` to `0` on a recovered
panic, so a collector that simply logged and returned on error was reported
`success=1` with zero metrics published, silently indistinguishable from a
healthy, empty scrape.
`<namespace>_exporter_collector_success{collector="example"}` is the metric
this produces; both directions of the contract
(`_StatusTrackerSuccess`/`_StatusTrackerFailure` in the HTTP flavor's test
file) are pinned down as regression tests specifically because this bug
existed once.

### The flip side: never zero metrics on success

A successful scrape that happens to have nothing to report is a different
outcome from a failed one, and the two must not look the same to
`StatusTracker`. **Always emit your metrics on a successful scrape, with
zero *values* when there's nothing to report, never zero metrics.** The CLI
flavor's `entries` gauge exists precisely to satisfy this: it is
unconditionally emitted, valued at `len(metrics)`, even when that's `0`:

```go
ch <- prometheus.MustNewConstMetric(c.entries, prometheus.GaugeValue, float64(len(metrics)))
for _, m := range metrics {
	ch <- prometheus.MustNewConstMetric(c.value, prometheus.GaugeValue, m.Value, m.Key)
}
```

The per-key `value` gauge legitimately emits nothing when `metrics` is
empty. That's fine, because `entries` already satisfied the rule for this
scrape regardless. A collector whose only metric is a per-item one (nothing
shaped like `entries`) needs a fixed-shape, always-emitted metric of its
own, or a genuinely empty successful scrape becomes indistinguishable from a
failed one. This is a case worth designing for explicitly, not an edge case
to notice after the fact.

### Two metrics, one label set, breaks the whole scrape

`Registry.Gather` rejects a scrape outright if two `MustNewConstMetric`
calls share both a descriptor and an identical label set, not just for the
offending collector, for the whole `/metrics` response, unless
`promhttp.ContinueOnError` is set (`prometheus-principles.md`'s OpenMetrics
section covers why this scaffold sets it). This is exactly why the CLI
flavor's `parseExample` rejects a duplicate key as a parse error instead of
letting it reach `Collect`: two entries sharing a key would produce two
`MustNewConstMetric` calls against the same `value` descriptor with an
identical `key` label, a `Gather`-time failure, discovered at scrape time
instead of parse time. Rejecting it in the pure parser keeps the failure
inside this collector's own already-documented fail-closed contract (parse
error → `Collect` logs and emits nothing) instead of surfacing downstream as
a registry-wide error. Adapting this parser for a real source that can
legitimately repeat a key means aggregating or deduplicating before
returning, or adding a further label to disambiguate: never letting two
`ConstMetric`s reach the same label set.

## The test triad (plus the StatusTracker pair)

Four tests, per collector, are the baseline:

1. **Parser test** (`TestParse<Name>`): a fixture from `testdata/` in,
   asserting the parsed struct/slice out, plus malformed input, and (CLI) a
   duplicate-key input, each asserted to return an error rather than panic.
   The HTTP flavor's version is a sub-test inside `TestParseExample`; the
   CLI flavor ships it as its own `parser_test.go.tmpl` file. Either
   placement is fine, the coverage is what matters.
2. **`_Collect`**: the full five-piece path exercised through a real
   `prometheus.NewRegistry()` and `Register`, then `testutil.GatherAndCount`
   for the metric count and `testutil.CollectAndCompare` against an exact
   expected exposition-format string. HTTP stands up an `httptest.Server`;
   CLI swaps `Execute` for a stub returning a fixture.
3. **`_Describe`**: locks the descriptor count at an exact number (two, for
   the bundled example, in both flavors) so a future edit that silently adds
   or drops a metric is caught here, not downstream.
4. **`_ErrorHandling`**: every way the I/O → parse pipeline can fail (HTTP:
   a `500` response, and an unreachable server; CLI: `Execute` returning an
   error, `Execute` succeeding with unparseable output, and a duplicate-key
   input) asserted to yield exactly zero metrics and no panic.

The shipped templates go one step further and also lock down the
`StatusTracker` contract itself, not just the raw registry count: HTTP's
`_StatusTrackerSuccess`/`_StatusTrackerFailure` pair, and CLI's
`_StatusTrackerSuccessOnEmptyOutput`, wrap the collector in a real
`StatusTracker` and assert `<namespace>_exporter_collector_success` reads
`1` or `0` as expected. These aren't a required fifth test to write for
every new collector by hand (they exist in the shared pattern already proven
correct), but they're worth understanding, because they're the tests that
would catch a regression in `StatusTracker`'s own counting logic, not just
in your collector.

## Fixtures

Fixtures live in `internal/collector/testdata/` (the bundled examples:
`testdata/example.json` for HTTP, `testdata/example.txt` for CLI), Go's
`testdata` convention, ignored by the toolchain outside test runs, not
`test_data`. Every fixture must be **anonymized** before it's committed:
real hostnames become `host1`/`example.internal`, real usernames become
`user1`/`alice`/`bob`, real account or tenant names become `team_a`/`org_b`,
and anything else identifying gets a placeholder that preserves the
fixture's shape (field count, rough magnitude) without preserving its
content. Never commit a fixture copy-pasted straight from a production
system.

## Performance checklist

- **Indexed lookup over a linear scan.** The CLI parser's own duplicate-key
  guard is the concrete example already in the templates: a
  `map[string]struct{}` built once while scanning (`seen :=
  make(map[string]struct{})`, checked with `if _, dup := seen[key]; dup`)
  turns "have I seen this key before" into an O(1) lookup per line instead
  of an O(n²) re-scan of everything parsed so far. Reach for the same shape
  (a `map` keyed by whatever you'd otherwise scan for) any time a parser or
  collector needs to check "have I seen this before" across more than a
  handful of items.
- **Merge before adding a new call.** Before wiring a new request or command
  into an existing collector, check whether it can be merged with one that's
  already there (same endpoint or command, a different field of the same
  response) instead of doubling the I/O.
- **Cache what doesn't change every scrape.** If the underlying data changes
  far less often than your scrape interval, that's a caching opportunity,
  not a caching requirement. See "Variants" below for the shape this takes
  once you need it.
- **Bound anything you retain across scrapes.** Neither shipped flavor
  retains state between calls to `Collect`. Every scrape re-fetches and
  re-parses from scratch, so there's nothing to bound today. The moment a
  collector starts keeping something around between scrapes (a cache value,
  a history), size that structure explicitly (a fixed-size ring buffer, a
  single last-good value, never an ever-growing slice) rather than letting
  it grow with process uptime. This is exactly the discipline the
  background-refresh variant below needs, and exactly why it doesn't just
  accumulate every observation it's ever made.
- **Make an expensive collector opt-in.** A collector whose `<name>Data`
  call is genuinely costly for the target belongs behind a
  `--collector.<name>` that defaults to disabled, not a hope that nobody
  enables it on a busy target.

## Collector variants (beyond the synchronous default)

The synchronous collector above is the default. One variant beyond it ships
today, and one is still planned.

- **Background refresh (shipped).** Add it with
  `/prometheus-exporter:add-collector --variant background`; its template is
  `background_collector.go.tmpl` (per flavor, under
  `code/<flavor>/variants/`). A goroutine plus a ticker plus a
  `context.Context` refresh a cached value on their own schedule, decoupled
  from Prometheus's own scrape timing entirely, so a scrape never waits on a
  slow or expensive backend. On a refresh error it keeps the last-good value
  rather than blanking a working cache because one refresh attempt failed,
  and it always emits a `<namespace>_<name>_last_refresh_timestamp_seconds`
  freshness gauge (`0` before the first successful refresh) so a consumer
  can tell how stale the served value is. This is also where the
  signal-aware shutdown `main.go` already wires for the whole process
  (`project-scaffold.md`) becomes relevant to a single collector's own
  goroutine, not just the HTTP server's: the collector's `Done()` plugs into
  `main.go`'s `backgroundCollectors` wait seam.
- **Cache (v0.2 fast-follow, not shipped today).** A shared, TTL-guarded
  cache sitting in front of `<name>Data` (RWMutex-protected, a `time.Time`
  freshness stamp), so several scrapes inside one TTL window reuse a single
  fetch instead of hitting the target every time, the simpler pattern that
  refetches inline when stale, without a goroutine, and so does not give the
  background variant's "scrape never blocks" guarantee. Same five-piece
  shape underneath; `<name>Data` consults the cache before doing real I/O.
  Not materialized as a template yet: don't go looking for `cache.go.tmpl`
  in this scaffold's assets today; it lands per the roadmap.

On a `multi-instance` build (`exporter-architecture.md`), background refresh
is not one option among several: every collector must be this variant,
because multi-instance's own `main` never calls a collector per scrape at
all. `instance.Registry.Commit` `Start`s one `instance.BackgroundCollector`
per instance per collector, at boot and again on every later reload that
adds an instance, and every scrape after that just reads whatever each
poller has already cached. The variant's own constructor signature reflects
the same split as that seam: `NewExampleCollector(log, client, interval)`
(`background_collector.go.tmpl`) takes no `ctx` at all, unlike the
synchronous constructor above, because a background collector's cancellation
context does not arrive at construction, it arrives at `Start(ctx)`, called
separately by `Registry.Commit`, not by `main` itself. `internal/instance`'s
`Factory.New`, `func(h *instance.Handle) (BackgroundCollector, error)`,
matches that shape exactly: no `ctx` parameter either. `h` is the one
watched machine's `Handle`, built once by `Registry.Prepare` and shared by
every collector watching it (the transport and the concurrency ceiling both
live there, not on the collector); a collector gets its own `*Client` from
it via `h.ClientFor(timeout)`, which refuses a non-positive timeout rather
than leaving a poller with no deadline at all, failing `Prepare` (at boot)
or a reload's prepare phase, never `Collect`. On shutdown, every instance's
every collector's `Done()` is drained under one shared five-second budget,
not one per collector: with N instances and M collectors that is N x M
goroutines to wait on, and a per-collector budget would multiply the wait by
that count instead of bounding it once.

## Checklist

- [ ] The one I/O call sits behind the flavor's mockable boundary (`Client`
      for HTTP, `Execute` for CLI). Nothing else in the collector touches
      the network, a subprocess, or a database directly.
- [ ] `parse<Name>` is pure: no I/O, no logging, deterministic on its input
      alone.
- [ ] `Describe` sends a fixed descriptor set; `Collect` emits
      `MustNewConstMetric` values or, on error, logs and returns zero
      metrics.
- [ ] A successful-but-empty scrape still emits every metric, with zero
      values, never zero metrics.
- [ ] No two `MustNewConstMetric` calls in one `Collect` can share both a
      descriptor and an identical label set; a parser that could produce
      that must reject or deduplicate first.
- [ ] The test triad exists and is green: parser fixture, `_Collect`,
      `_Describe`, `_ErrorHandling`.
- [ ] Every fixture under `testdata/` is anonymized before it's committed.
