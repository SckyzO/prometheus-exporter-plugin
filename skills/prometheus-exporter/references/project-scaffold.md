# The project scaffold: layout, registry, and the running exporter

This is step 2 of the workflow: what `/new-prometheus-exporter` actually
produces once the architecture decision (`exporter-architecture.md`) and the
collector pattern (`collector-pattern.md`) are applied to real files. Three
pieces: a `cmd/` entry point, an `internal/collector/` package holding every
collector plus the shared `StatusTracker`, and an `internal/logger/` package
both depend on. Everything below matches `cmd/@@EXPORTER_NAME@@/main.go.tmpl`,
`internal/collector/status_tracker.go.tmpl`, and `internal/logger/logger.go.tmpl`
as shipped. Read those alongside this document, not instead of it. What gets
built and tested against this layout is `makefile-and-tooling.md`'s subject;
what happens to it at a tagged release is `cicd-and-release.md`'s.

## Repository layout

```
config.example.yml      # commented example for --config.file, never loaded by default
cmd/@@EXPORTER_NAME@@/
  main.go               # entry point: flags, registry, HTTP server, shutdown
internal/config/
  config.go             # --config.file: loads it, validates it, renders it back to args
internal/collector/
  status_tracker.go     # shared health-metric wrapper (flavor-agnostic)
  docs_check_test.go    # make docs-check's implementation (flavor-agnostic)
  client.go / execute.go   # the flavor's mockable I/O boundary (collector-pattern.md)
  collector.go           # the bundled example collector, five pieces
  ...                    # one file pair per collector /add-collector adds later
internal/logger/
  logger.go              # thin log/slog wrapper
internal/instance/
  instance.go            # multi-instance seam: the Registry (Prepare/Commit) the multi-instance main drives at boot and on reload
internal/reload/
  reload.go              # SIGHUP / POST /-/reload mechanism, shared by multi and multi-instance; absent on single (exporter-architecture.md)
```

Neither `internal/collector` nor `internal/logger` is Prometheus-specific by
virtue of being a package: nothing about the package boundary itself knows
this is an exporter. The Prometheus-facing behavior all lives in what these
packages construct and how `main` wires them together, covered below.

### The logger

`internal/logger` wraps `log/slog` behind a `*Logger` type (`*slog.Logger`
embedded) so every collector and `main` share one dependency instead of each
reaching for the standard library directly. Collectors take a
`*logger.Logger` parameter, never a global logger. Two constructors,
`NewTextLogger`/`NewJSONLogger`, both driven by `--log.level`/`--log.format`;
a handful of go-kit/log-style compatibility methods (`Log`, `With`,
`WithTimeout`, `WithCommand`) exist so a collector can derive a
scoped/contextualized logger without every call site rebuilding one from
scratch. `WithContext` is a documented no-op (slog resolves attributes from
values handed to it directly, not from a `context.Context`), kept only for
call sites that still expect that shape.

## The registry: registration-driven, lazily invoked

`main.go` never hardcodes a list of collector constructors to call:

```go
type registryEntry struct {
	name    string
	enabled *bool
	newFn   func() prometheus.Collector
}

var registry []registryEntry

func register(name string, newFn func() prometheus.Collector, enabledByDefault bool) {
	enabled := kingpin.Flag("collector."+name, "Enable the "+name+" collector.").
		Default(strconv.FormatBool(enabledByDefault)).Bool()
	registry = append(registry, registryEntry{name: name, enabled: enabled, newFn: newFn})
}
```

Every collector (the bundled `example` one, everything `/add-collector`
inserts afterward) is exactly one `register(name, newFn, enabledByDefault)`
call. There is no central switch statement or if-chain that grows with every
new collector; adding one means adding a line at a fixed insertion point
(below), never touching the loop that walks the registry.

### Why `newFn` is a closure invoked later, not immediately

`register()` itself must run *before* `kingpin.Parse()`. Like every other
kingpin flag declaration, the `--[no-]collector.<name>` flag it declares is
only visible to kingpin if `Flag()` runs ahead of `Parse()`. But `newFn` is
not called at that point; it is stored in `registry` and invoked exactly once,
later, only for collectors the parsed flags actually enable:

```go
tracker := collector.NewStatusTracker(log)
for _, e := range registry {
	if *e.enabled {
		tracker.Add(e.name, e.newFn())
		log.Info("Collector enabled", "collector", e.name)
	} else {
		log.Info("Collector disabled", "collector", e.name)
	}
}
```

This split exists because a collector's constructor typically needs values
that don't exist yet when `register()` runs: the shared `*logger.Logger`
(built only after `--log.level`/`--log.format` are parsed) and, for the HTTP
flavor, a `*Client` built from a `--collector.<name>.target` flag's *parsed*
value. Go closures capture variables by reference, not by value, so the
closure passed as `newFn` can safely reference `log` or a flag variable that
is still nil/zero at the moment `register()` runs, provided nothing calls the
closure before `main()` finishes assigning them. `main()`'s own ordering
guarantees that; nothing about `register()` itself would, on its own.

### The three seam markers

Both the initial scaffold and every later `/add-collector` insert their flag
declarations, client construction, and `register()` calls at three fixed,
literal comment markers inside `main()`. `// @@CLIENT_INIT@@` and
`// @@COLLECTOR_REGISTRY@@` sit textually *before* `kingpin.Parse()`, exactly
like before; `// @@CLIENT_BUILD@@` sits right after it, still before the
logger is built:

```go
func main() {
	var log *logger.Logger

	// @@CLIENT_INIT@@

	// @@COLLECTOR_REGISTRY@@

	kingpin.Version(version.Print("@@EXPORTER_NAME@@"))
	kingpin.MustParse(kingpin.CommandLine.Parse(...))

	// @@CLIENT_BUILD@@

	...
```

`// @@CLIENT_INIT@@` is where a flavor's per-collector flags are declared:
HTTP's bundled example contributes a target flag, a timeout flag, and a
`var exampleClient *collector.Client` (assigned later, at
`// @@CLIENT_BUILD@@`); CLI's contributes only a timeout, because its target
is a fixed command baked in at scaffold time rather than a runtime flag
(`collector-pattern.md` explains why the two flavors differ here).
`// @@CLIENT_BUILD@@` is where the client is actually built, once flags are
parsed and the configuration file has been loaded, so it can honor an
operator's `http_client_config:` section. Both flavors fill it: HTTP builds
`exampleClient` there, while CLI, having no outbound request to authenticate,
uses it to refuse an `http_client_config:` section rather than accept a
setting it would silently drop.
`// @@COLLECTOR_REGISTRY@@` is where the matching `register(...)` call lands,
its closure capturing whatever the other two markers declared and built:

```go
// HTTP flavor
exampleTarget := kingpin.Flag("collector.example.target", "...").Default("@@DATA_SOURCE@@").String()
exampleTimeout := kingpin.Flag("collector.example.timeout", "...").Default("5s").Duration()
// Declared here, assigned at // @@CLIENT_BUILD@@ once flags are parsed.
var exampleClient *collector.Client
...
register("example", func() prometheus.Collector {
	return collector.NewExampleCollector(context.Background(), log, exampleClient)
}, true)
...
// at // @@CLIENT_BUILD@@, after kingpin.MustParse:

// collector.Limiters (limiter.go) is the single, shared LimiterSet every
// collector's client_build wiring consults, one Limiter per distinct
// --collector.<name>.target address. Guarded on nil so a second collector's
// own client_build.frag (scaffolded, or appended later by /add-collector)
// reuses the same set instead of replacing it.
if collector.Limiters == nil {
	collector.Limiters = collector.NewLimiterSet(*maxRequestsPerTarget)
}

// A limiter with no bound on its own wait would be exactly the silent-
// queueing failure mode a concurrency ceiling exists to prevent: refuse at
// boot, naming the collector, once a ceiling is actually configured.
if *maxRequestsPerTarget > 0 && *exampleTimeout <= 0 {
	fmt.Fprintln(os.Stderr, fmt.Errorf("collector %q: a positive --collector.example.timeout is required when --exporter.max-requests-per-target is set, got %v (the limiter wait would otherwise be unbounded)", "example", *exampleTimeout))
	stop()
	os.Exit(1)
}

if cfg.HTTPClientConfig != nil {
	exampleClient, err = collector.NewClientWithConfig(*exampleTarget, *exampleTimeout, *cfg.HTTPClientConfig)
	...
} else {
	exampleClient = collector.NewClient(*exampleTarget, *exampleTimeout)
}
// A nil limiter (the default ceiling of 0) leaves this a no-op.
exampleClient = exampleClient.WithLimiter(collector.Limiters.For(*exampleTarget))
```

`NewClientWithConfig(target string, timeout time.Duration, httpCfg
promconfig.HTTPClientConfig) (*Client, error)` sits beside `NewClient` in
`client.go`, never replacing it: with an `http_client_config:` section, the
wiring above calls it; without one, it keeps calling `NewClient`, because that
transport is what every existing deployment already runs.

`--exporter.max-requests-per-target` (default `0`, unlimited) is what
`maxRequestsPerTarget` above holds; it is absent on `multi` (a `/probe`
handler builds a client per caller-controlled request, so there is no fixed
key space to index a ceiling by) and present on `single` and
`multi-instance`. What it actually bounds differs by build: on `single`
with the HTTP flavor, one ceiling per distinct `--collector.<name>.target`
address, via the `LimiterSet` above; on `single` with the CLI flavor, one
ceiling for the whole process (`collector.CommandLimiter`, a plain
assignment, since CLI has no per-target `Client` to index by, only the one
shared command-execution boundary every collector calls through); on
`multi-instance`, one ceiling per watched *instance* (`instance.Handle`
owns its own `Limiter`), not per physical address, so two instances naming
the same machine are bounded independently. A request that waits for a slot
is recorded by `collector.RequestWait` (below), never silent.

All three markers survive the substitution that fills them: the scaffolding
mechanism inserts each flavor's snippet immediately *after* the marker line
without consuming it, specifically so the same three markers are still
present, unchanged, for `/add-collector` to insert the next collector at
later. A generated repository's `main.go` therefore keeps all three comments
even after several collectors have been added. They are structural, not
leftover scaffolding residue.

## Auto flags: `--[no-]collector.<name>`

`register()`'s `kingpin.Flag(...).Default(strconv.FormatBool(enabledByDefault)).Bool()`
is what gives every collector its own negatable boolean flag for free:
kingpin's own boolean-flag convention accepts both `--collector.foo` and
`--no-collector.foo` for any flag declared this way, so nothing beyond passing
`enabledByDefault` is needed to support disabling a normally-on collector, or
opting a normally-off one in. The bundled `example` collector and both
flavors' self-instrumentation collector (below) are registered with
`enabledByDefault: true`; a collector that's expensive against its target or
only relevant to some deployments is registered with `false` instead, and
nothing else about the mechanism changes.

## Self-instrumentation is just another registry entry

Each flavor times its own I/O boundary with a package-level
`*prometheus.HistogramVec`, labeled only by `outcome` (`success`/`error`):
HTTP's `RequestDuration` (`internal/collector/client.go`, observed inside
`Client.Fetch`) and CLI's `CommandDuration` (`internal/collector/execute.go`,
observed inside `Execute`). Both are built with plain
`prometheus.NewHistogramVec`, never `promauto`'s auto-registering variant:
`promauto` targets `prometheus.DefaultRegisterer`, the process-wide global
registry, but `main.go` builds its own `prometheus.NewRegistry()` instead
(below), so a `promauto`-built metric would simply never reach `/metrics`
here.

Since a `*prometheus.HistogramVec` already implements `prometheus.Collector`,
it needs no separate registration mechanism. It is wired into `main.go`
through the exact same `register(...)` call as any real collector:

```go
register("http_client_requests", func() prometheus.Collector { return collector.RequestDuration }, true)
register("http_client_request_wait", func() prometheus.Collector { return collector.RequestWait }, true)
// or, CLI flavor:
register("command_exec", func() prometheus.Collector { return collector.CommandDuration }, true)
register("command_exec_wait", func() prometheus.Collector { return collector.RequestWait }, true)
```

From the flag/`StatusTracker` point of view there is nothing special about
self-instrumentation: it gets a `--[no-]collector.http_client_requests` (or
`command_exec`) flag exactly like `example` does, and is wrapped by the same
`StatusTracker` as every other entry (below). There is no separate
"register the I/O timing metric" hook function distinct from this: timing
self-instrumentation is a collector, full stop, registered the same way any
other one is. A cache layer sitting in front of a collector's `*Data` call is
a v0.2 variant not shipped today (`collector-pattern.md`'s "Collector
variants" section); when it lands, it would follow the same pattern (its own metric,
wired through `register(...)`) rather than introduce a new mechanism
alongside this one.

`collector.RequestWait` (`http_client_request_wait` / `command_exec_wait`,
same underlying histogram either flavor) is the second self-instrumentation
metric alongside the duration one: it records how long a request or command
waited for a slot from `--exporter.max-requests-per-target`'s ceiling before
running, which is what makes queuing visible in `/metrics` instead of just
quietly lengthening scrape times. It reaches `/metrics` on `single` through
this same `register(...)` call; `multi` and `multi-instance` each hardcode
their own `reg.MustRegister(collector.RequestWait)` beside their own
`RequestDuration` line instead, since neither one runs `main.go`'s
registration-driven registry loop this file describes.

## StatusTracker: one collector wrapping every collector

```go
tracker := collector.NewStatusTracker(log)
for _, e := range registry {
	if *e.enabled {
		tracker.Add(e.name, e.newFn())
	}
}
reg.MustRegister(tracker)
```

Every enabled collector (real or self-instrumentation) is added to a single
`StatusTracker`, and only the tracker itself is ever registered on `reg`. Two
problems this solves at once: several collectors independently emitting the
same status-metric descriptor would panic Prometheus's own duplicate-registration
check, and a panic inside any one collector's `Collect` would otherwise take
the whole scrape down with it. `StatusTracker`'s own `Collect` recovers from a
panic per inner collector and buffers each one's output on a private channel
so it can count what came out before forwarding it: a collector that returns
normally but sends nothing is exactly as much a failure as one that panics,
both surfaced as
`@@NAMESPACE@@_exporter_collector_success{collector="<name>"} == 0`. The full
mechanics and the error-contract rationale live in `collector-pattern.md`;
this document is only about *where* the tracker sits in `main.go`, between
the registry loop and the custom registry below.

## A custom registry, not the global one

```go
reg := prometheus.NewRegistry()
reg.MustRegister(collectors.NewBuildInfoCollector())
if !*disableExporterMetrics {
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
}
...
reg.MustRegister(tracker)
```

`prometheus.NewRegistry()` (never `prometheus.DefaultRegisterer`) avoids two
things at once: global mutable state shared with anything else the process
happens to link in, and a third-party dependency that calls `promauto` at its
own package-init time silently adding metrics this exporter never asked to
expose. Build info is always registered (cheap, and universally useful:
`@@EXPORTER_NAME@@_build_info` gives Prometheus itself a way to query the
running version); Go runtime and process metrics are gated behind
`--web.disable-exporter-metrics` (off by default), for deployments where
something else already scrapes a dedicated Go-runtime exporter and duplicate
`go_*`/`process_*` series would just be noise.

## exporter-toolkit: the web flags and TLS/Basic Auth

```go
toolkitFlags = webflag.AddFlags(kingpin.CommandLine, ":@@DEFAULT_PORT@@")
...
web.ListenAndServe(server, toolkitFlags, log.Logger)
```

`webflag.AddFlags` declares `--web.listen-address` (defaulted to
`:@@DEFAULT_PORT@@`) and `--web.config.file`; `web.ListenAndServe` is what
makes the latter meaningful: pointed at a YAML file in Prometheus's own
TLS/Basic-Auth web-config format, it serves the exporter over HTTPS and/or
behind a password with no application code of this exporter's own involved.
`prometheus/exporter-toolkit` is the one dependency in this stack not indexed
by context7 at the time these references were written; its exact API here is
verified against the real, building `main.go.tmpl` (whose golden test
scaffolds and builds a fresh repository from it) and the pinned version in
`go.mod`, not against fetched documentation. Re-check the pinned
`exporter-toolkit` version's `AddFlags`/`ListenAndServe` signatures directly
before changing this file, since a major bump could change either.

## Endpoints

| Endpoint | Registered via | Behavior |
|---|---|---|
| `/metrics` | `promhttp.HandlerFor(reg, promhttp.HandlerOpts{...})` | OpenMetrics-enabled scrape endpoint |
| `/healthz` | `http.HandleFunc` | Always `200 OK` while the process is up |
| `/` | `http.HandleFunc` | Landing page linking to `/metrics` |

`/healthz` deliberately answers independently of whether the thing this
exporter monitors is reachable: it tells an orchestrator "the exporter
process itself is alive", not "the data source is up". That second question
is what `@@NAMESPACE@@_exporter_collector_success` is for instead; wiring
`/healthz` to depend on any collector's success would conflate two failure
modes an operator needs to tell apart (restart the exporter process, versus
go investigate the actual target).

### `ContinueOnError`: why one collector's failure can't 500 the whole scrape

```go
http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{
	EnableOpenMetrics: true,
	ErrorHandling:     promhttp.ContinueOnError,
}))
```

`client_golang`'s own default `HandlerOpts` is `HTTPErrorOnError`: any error
`Gather()` hits, anywhere, in any one collector, turns the *entire*
`/metrics` response into an HTTP error, discarding every other collector's
metrics along with the failing one's. That default directly contradicts what
`StatusTracker` exists to promise (one collector's trouble stays visible and
contained, never blanks out its neighbors): a `Gather`-level error
attributable to just one collector (two `MustNewConstMetric` calls colliding
on the same descriptor and label set is the concrete way `collector-pattern.md`
shows this happening) would still fail the whole scrape at the HTTP layer
even though `StatusTracker` handled it gracefully everywhere else.
`ContinueOnError` is the deliberate deviation that closes that gap: it serves
every metric family that gathered cleanly and only falls back to an HTTP
error if *nothing* could be gathered at all, the same idiom multi-collector
exporters like node_exporter use.

## Signal-aware shutdown

```go
ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
defer stop()

server := &http.Server{ReadHeaderTimeout: 5 * time.Second}

go func() {
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdownCtx)
}()

if err := web.ListenAndServe(server, toolkitFlags, log.Logger); err != nil && !errors.Is(err, http.ErrServerClosed) {
	stop()
	os.Exit(1)
}
```

On `SIGTERM`/`SIGINT`, the goroutine above calls `server.Shutdown`, which
stops accepting new connections and waits up to 5 seconds for in-flight ones
to drain instead of leaving the process to a bare `kill`. `ReadHeaderTimeout`
on the `http.Server` itself is a separate, always-on mitigation
(Slowloris-style slow-header attacks, flagged by `gosec`'s G112) unrelated to
shutdown, worth knowing it's there for the same "the server config isn't
just the happy path" reason. `ListenAndServe` returning `http.ErrServerClosed`
is the *expected* outcome of a graceful shutdown, so it's explicitly excluded
from the branch that calls `os.Exit(1)`; any other error calls `stop()` first
(releasing the signal handler explicitly, since `os.Exit` bypasses every
deferred call including the `defer stop()` above it) before exiting
non-zero.

This same `ctx` is the hook the background-refresh collector variant
(`collector-pattern.md`'s "Collector variants" section) derives its own
cancellation from, rather than each such collector inventing its own signal
handling independently.

## What this scaffold does not do

Everything above describes the **single-target** model, `single`, still the
default and unchanged: one exporter process, one fixed target, a registry
built once at startup, every collector's constructor assuming that same one
target for the process's whole lifetime.

`--target-model multi` (http flavor only, there is no `cli` multi-target) is
one of two other models `/new-prometheus-exporter` can scaffold. Instead of
this file's registration-driven registry, it ships `internal/probe/` and a
`/probe?target=…` handler that builds a fresh registry and collector set,
scoped to whatever `target=` the caller supplies, once per request,
Prometheus's own multi-target exporter pattern (see `exporter-architecture.md`
§2 for why this is a structural fork decided *before* scaffolding, not
retrofitted onto this `main.go` afterward). `/add-collector` handles it:
against a multi-target scaffold it appends a factory at
`// @@PROBE_FACTORIES@@` instead of a `register(...)` call.

Each factory in that slice has the shape
`func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error)`.
`hc` is resolved per request, from the module the request named (or the
top-level `http_client_config:`, or nil), but built only once, at boot in
`main`, and shared by every collector: nothing about handling one more probe
rebuilds it.

`--target-model multi-instance` (http flavor only, and `--config.file` is
required at runtime) is the third. Instead of a registry built once for one
target, or a handler that builds one fresh per request, it ships
`internal/instance/` and an `instance.Registry` that boot and every later
reload both drive through the same two calls: `Prepare(instances)` builds
whatever a new instance list needs (a `Factory.New(h)` call, one per
instance per enabled collector, against that instance's own `Handle`) and
mutates nothing, so it can fail before anything already running is touched;
`Commit(ctx, plan)` `Start(ctx)`s each new collector, wraps its
`StatusTracker` in `prometheus.WrapRegistererWith(labels, reg)`, where
`labels` carries the identifying label (`--instance-label`, default
`target`) plus that instance's own `labels:` from its configuration entry,
and cannot fail. Boot is `Prepare` against an empty live set followed by
`Commit`, the exact same two calls a `SIGHUP` or `POST /-/reload` makes,
which is what lets this path be exercised by every start, not only when an
operator reloads. There is no `/probe` here: every instance is already
resolved by the time the process finishes booting, so the one `/metrics`
endpoint answers for all of them from whatever each instance's background
pollers have already cached (`collector-pattern.md`'s "Collector variants"
section covers why every collector on this model must be the background
variant). `/add-collector` handles this model too: against a multi-instance
scaffold it appends a factory at `// @@INSTANCE_FACTORIES@@` instead of a
`register(...)` call.

The three models are mutually exclusive per scaffold: a generated repository
has exactly one `main.go`, and exactly one of this file's registry, the
`/probe` handler, or the multi-instance boot-time loop, never more than one.

## Checklist

- [ ] Every collector (bundled example, self-instrumentation, anything
      `/add-collector` adds later) is exactly one `register(name, newFn,
      enabledByDefault)` call at `// @@COLLECTOR_REGISTRY@@`, with its flags
      (if any) declared at `// @@CLIENT_INIT@@` and, for the http flavor, its
      client built at `// @@CLIENT_BUILD@@`; all markers left intact.
- [ ] `newFn`'s closure references `log`/flag variables safely: it is never
      invoked before `kingpin.Parse()` and the logger's construction, both of
      which happen once, later in `main()`.
- [ ] Every collector, including self-instrumentation, is wrapped by the one
      shared `StatusTracker`, never registered on `reg` directly.
- [ ] `reg` is `prometheus.NewRegistry()`, never the global
      `prometheus.DefaultRegisterer`.
- [ ] `/metrics` keeps `ErrorHandling: promhttp.ContinueOnError`. Removing it
      would let one collector's `Gather`-time error fail the entire scrape.
- [ ] Shutdown stays signal-aware: `signal.NotifyContext` plus a bounded
      `server.Shutdown`, not a bare process exit on `SIGTERM`.
