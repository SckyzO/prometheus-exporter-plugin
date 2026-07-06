# Background-refresh collector variant — Design

**Status:** proposed (v0.2 epic, unreleased)
**Supersedes/relates:** the `code/variants/` placeholder named in
`2026-07-02-prometheus-exporter-plugin-design.md` and `ROADMAP.md`.

## Goal

Let the plugin scaffold a collector that fetches its data in a **background
goroutine on a fixed interval** and serves the **last cached result** on every
Prometheus scrape, so that a slow or expensive backend is never on the scrape's
critical path. A scrape must **never block** on the backend, regardless of how
slow the backend is.

## Driving case

An exporter for the **IBM TS4500** tape library. Its REST/CLI interface is
slow (seconds per call). Hitting it on every scrape would (a) make scrapes
block and risk exceeding Prometheus's `scrape_timeout`, and (b) hammer a device
that is not built for high-frequency polling. The background variant decouples
scrape cadence from fetch cadence entirely.

## Provenance — two real exporters studied

Both of the maintainer's existing exporters cache, but with **two different
patterns**. This distinction is load-bearing and is the reason this epic
templates one and not the other.

- **`slurm_exporter` → `sacct_efficiency`** = **proactive background refresh**.
  A goroutine (`Start(ctx)` + `time.NewTicker`) refreshes the cache on its own
  clock; `Collect()` only ever reads the cache. `main.go` derives a
  `signal.NotifyContext` and waits ≤5s on the collector's `Done()` channel at
  shutdown. **Scrapes never block.** ← this is the pattern we template.
- **`infiniband_exporter`** = **lazy TTL cache** (`ibnetdiscover.go:126`:
  `fresh := time.Since(refresh) < ttl`). The scrape that finds the cache stale
  runs the fetch **synchronously, inline**, and waits for it. No goroutine, no
  ticker, no `signal.NotifyContext` anywhere in the repo. This is the "lazy
  cache" pattern — it reduces backend load but a scrape **can still block** on
  the fetch at TTL expiry. **Out of scope for this epic** (see Non-goals).

**Invariant** across both (the load-bearing elements the template must keep):
a stored "last populated at" timestamp compared against an interval to gate
serve-cached-vs-refetch; a lock-guarded shared cache; an operator-configurable
interval flag with a sane non-zero default; **selective per-collector** opt-in
(both exporters mix cached and fully-synchronous collectors); a failed fetch is
logged and non-fatal, retried on the next trigger.

**Divergent** (resolved here in favor of the background/`sacct_efficiency`
shape, because the driving case demands "no scrape ever blocks"): push
goroutine vs. pull-on-scrape; a `Start()`/`Done()` lifecycle vs. none;
`signal.NotifyContext` wiring vs. none; **fail-open** (serve stale, the
freshness gauge stalling is the alarm) vs. infiniband's fail-closed
(drop the series); `sync.RWMutex` vs. `sync.Mutex`.

## The pattern, concretely (the shape the template ships)

A background collector is the standard five-piece collector plus a refresh
loop and a cache:

- **`New<Name>Collector(...)` stays pure** — it builds the `*prometheus.Desc`
  fields and the struct and starts **nothing**. Keeps the collector
  constructible in tests with no goroutine running.
- **`Start(ctx context.Context)`** is a separate method `main.go` calls once,
  after construction. It spawns one goroutine that:
  - runs one `c.refresh(ctx)` immediately (so the cache begins filling as soon
    as the process starts — the fetch is **not** awaited by `Start`'s caller,
    so process startup is never blocked by a slow first fetch), then
  - enters `ticker := time.NewTicker(c.interval)` /
    `for { select { case <-ticker.C: c.refresh(ctx); case <-ctx.Done(): return } }`,
  - with `defer close(c.done)` so the completion channel closes exactly when
    the loop returns.
- **`Done() <-chan struct{}`** returns that channel for the shutdown wait.
- **`sync.RWMutex`** guards `cached []prometheus.Metric` and
  `lastRefresh time.Time`.
- **`refresh(ctx)`** does the one slow I/O call (the only flavor-specific
  line — see Decision 2), parses it, builds the metric slice, then under
  `Lock()` replaces `cached` and stamps `lastRefresh`. On error it **logs and
  returns**, leaving the previous cache and timestamp untouched (**fail-open**).
- **`Collect(ch)`** takes `RLock()`, replays every metric in `cached`, and
  **always** emits the freshness gauge (see Decision 4). It never calls the
  backend and is O(cached-size), non-blocking.

## Design decisions (locked)

1. **Per-collector, selected at `/add-collector` time — not a scaffold-wide
   axis.** `scaffold.sh`'s only axis stays `--flavor`. Background-ness is a
   property of an individual collector, proven by both studied exporters
   mixing synchronous and cached collectors in one binary. `/add-collector`
   gains a background branch (a `--variant background` argument or an early
   "is this backend slow/expensive enough to refresh in the background?"
   question); the default stays the synchronous collector, byte-for-byte
   unchanged.

2. **Both flavors (http + cli).** The refresh machinery is I/O-agnostic; the
   only flavor-specific part is the single fetch call inside `refresh()` —
   http calls the injected `*Client`, cli calls the package-level `Execute`.
   Two template files (one per flavor), same structure.

3. **`main.go.tmpl` gains a generic, dormant `Done()` seam** — shipped by
   every `/new`, populated only when a background collector is added:

   ```go
   // near the top of main(), alongside the existing signal.NotifyContext:
   type backgroundCollector interface{ Done() <-chan struct{} }
   var backgroundCollectors []backgroundCollector

   // ...after web.ListenAndServe returns and "Server stopped" is logged:
   for _, bc := range backgroundCollectors {
       select {
       case <-bc.Done():
       case <-time.After(5 * time.Second):
           log.Warn("a background collector did not stop within 5s; exiting anyway")
       }
   }
   ```

   The `for … range` over the (possibly empty) slice **uses** the variable, so
   a synchronous-only exporter still compiles with the seam dormant. This is
   the symmetric completion of the graceful-shutdown path that already ships
   unconditionally (`signal.NotifyContext` + `server.Shutdown`), and it is the
   *registry / extension-point* shape (populate a list) rather than a
   core-editing-per-collector shape — so a background collector's wiring is
   purely additive at the existing `// @@COLLECTOR_REGISTRY@@` marker, never a
   second structural edit elsewhere in `main.go`. No collector name is
   hardcoded (an improvement over the reference's single `sacctDone`).

   The background collector's registry snippet (spliced by `/add-collector`)
   constructs eagerly, starts, and enrolls in the seam:

   ```go
   <name>Coll := collector.New<Name>Collector(log, /* flavor deps */, *<name>Interval)
   <name>Coll.Start(ctx)
   backgroundCollectors = append(backgroundCollectors, <name>Coll)
   register("<name>", func() prometheus.Collector { return <name>Coll }, true)
   ```

   (`ctx` is the existing `signal.NotifyContext` value already in scope.)

4. **Always-emit, to satisfy the count-based `StatusTracker`.** This plugin's
   `StatusTracker` reports `success=0` when a `Collect` call emits **zero**
   metrics (a stricter, deliberate improvement over the reference's
   panic-only tracker). A verbatim port of the reference's
   `if !lastRefresh.IsZero()` guard would therefore misreport the startup
   window (before the first refresh completes) as a failed scrape. So the
   background `Collect()` emits the freshness gauge **unconditionally** — value
   `0` before the first successful refresh, the real Unix timestamp after. The
   gauge alone guarantees ≥1 metric per scrape, so `StatusTracker` reads the
   collector as alive; the gauge's value (`0` = epoch = "ancient") makes the
   standard freshness alert fire until real data lands. This cleanly separates
   the two orthogonal signals: **`StatusTracker` success** = "did `Collect`
   run", **freshness gauge** = "is the data current". They are not the same
   question and must not be conflated.

5. **Fail-open on refresh error.** A failed background fetch keeps the previous
   cache and lets the freshness gauge stall — that stall is the intended
   staleness alarm. (Rejecting infiniband's fail-closed: here we already hold
   good cached data and serving it beats dropping the series.)

6. **Freshness gauge** `<namespace>_<name>_last_refresh_timestamp_seconds`,
   a `GaugeValue` of the last successful refresh's Unix time. Help text carries
   the runbook verbatim: *"Alert if time() - this > 2 × the collector's
   configured interval."* This is the **only** correct staleness signal — the
   `StatusTracker` duration metric times the cheap cache-read `Collect`, not
   the background fetch, and must not be used for freshness.

7. **Interval flag** `--collector.<name>.interval`, a `Duration`, drives the
   ticker. **No lookback flag** — lookback is a `sacct`-specific accounting
   window, not a general concept. Default: **1 minute** (see Open questions —
   flagged for maintainer confirmation). The scrape never blocks regardless of
   the interval, so the interval trades data freshness against backend load
   only.

## Template surface (files)

**New (plugin assets):**
- `skills/prometheus-exporter/assets/code/http/variants/background_collector.go.tmpl`
- `skills/prometheus-exporter/assets/code/http/variants/background_collector_test.go.tmpl`
- `skills/prometheus-exporter/assets/code/cli/variants/background_collector.go.tmpl`
- `skills/prometheus-exporter/assets/code/cli/variants/background_collector_test.go.tmpl`

These live under `code/<flavor>/variants/` so that `/add-collector` can read
them from the plugin tree (exactly as it reads `code/<flavor>/collector.go.tmpl`
today, `add-collector.md` §3), while **never** shipping into a scaffolded repo.

**Modified:**
- `skills/prometheus-exporter/assets/scaffold.sh` — after the flavor-selection
  move, `rm -rf "$dst/internal/collector/variants"`, mirroring the existing
  `wiring/` staging removal. This keeps `/new` output byte-identical to today
  (the variant templates are consumed only by `/add-collector`, never emitted).
- `skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl` — add
  the generic dormant `Done()` seam of Decision 3. Additive; synchronous-only
  exporters are behaviorally unchanged.
- `commands/add-collector.md` — a background branch: read the
  `variants/background_collector.go.tmpl` (and its test) instead of the
  synchronous template, apply the same identifier renames plus the interval
  flag, and use the `Start(ctx)` + `append(backgroundCollectors, …)` registry
  snippet (Decision 3) instead of the plain deferred `register(...)`.

**Explicitly NOT modified:** the synchronous `code/<flavor>/collector.go.tmpl`
and the default `/new` path — both stay byte-for-byte as they are.

## Testing

- **The variant test template ships the lifecycle unit tests** (mirroring the
  reference's `TestSacctEfficiencyCollector_*`): `Done()` closes on `ctx`
  cancel within a bound; a refresh error keeps the previous cache; `Collect`
  serves cached data without calling the backend; the first scrape (before any
  refresh) emits the freshness gauge with value `0` and drives
  `StatusTracker` `success=1`. These are the real coverage for the goroutine
  behavior.
- **Golden smoke** (`test/golden-smoke.sh`): extend the existing http/none
  `/add-collector` sub-check to also add a **background** collector via the new
  branch and re-run `make build` + `make docs-check`, proving the background
  template compiles, wires, and documents cleanly end-to-end under the harness.
- **`make race`** in the scaffolded repo covers the mutex/goroutine for the
  added background collector (the template's own tests run under `-race`).
- **Out of scope:** a live-binary start-and-SIGTERM test in golden — the
  harness never runs the compiled binary today; the shipped lifecycle unit
  tests cover shutdown behavior instead. Noted as a possible fast-follow.
- **docs-check:** the background collector's metrics (including the freshness
  gauge) are documented in `docs/metrics.md`, same discipline as any collector.

## Non-goals (this epic)

- **The lazy TTL cache variant** (the `infiniband_exporter` shape). It is a
  legitimate, simpler pattern (no goroutine, no shutdown coordination) but it
  does not deliver the "scrape never blocks" guarantee the driving case needs.
  Explicit fast-follow if a use case appears; it would reuse most of this
  epic's cache + freshness + always-emit core.
- **Auto-selecting the background variant from the `/design-exporter` brief.**
  A future tie-in (a slow-backend target could be flagged in the brief's
  `## Architecture decisions`), not built here.
- **A live-binary signal test in the golden harness.**

## Open questions / decisions to confirm

1. **Default interval (Decision 7).** Proposed **1m**: fresh enough for most
   backends, and because the scrape never blocks, this is purely one backend
   call per minute regardless of scrape frequency. Both studied exporters
   happen to default to `5m`; a TS4500-class backend may well want `5m` too.
   Easily overridden per-collector; flagged for the maintainer to set the
   default they prefer. **Not a backward-compatibility concern** (new feature,
   no existing users).
2. **`--variant background` argument vs. an interactive question in
   `/add-collector`.** A flag is scriptable and explicit; a question is
   discoverable and matches the command's existing conversational step 2.
   Leaning flag-with-question-fallback; final call at plan time.
3. **Dormant seam as "dead code" (Decision 3).** The empty
   `backgroundCollectors` slice + no-op wait loop in a purely-synchronous
   exporter is dormant infrastructure, justified as the completion of the
   already-unconditional shutdown path and as the preferred extension-point
   shape. Flagged in case the maintainer would rather have `/add-collector`
   splice the whole seam in on the first background collector (costs two more
   `main.go` markers and a structural edit; rejected here as more fragile).
