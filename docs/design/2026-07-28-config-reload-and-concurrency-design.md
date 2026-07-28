# Configuration reload, and a per-target concurrency ceiling

**Status:** design approved 2026-07-28 · v0.7.0. Delivers the two reload
items opened in [`ROADMAP.md`](../../ROADMAP.md)'s v0.7 section, with their
scope corrected by §3 below, plus the per-instance concurrency ceiling that
the same section of the roadmap left unscoped. The project journal, listed
in the same section, is explicitly out (§4.2).

## 1. Goal

A `multi` or `multi-instance` exporter is driven by a configuration file it
reads exactly once, at startup. Every change to that file, adding a machine
to `instances:`, pointing an instance at a different module, rotating a
secret written inline, costs a process restart.

A restart is not free under `multi-instance`. Every watched machine's cache
dies with the process, and the cache is the whole point of the model: a
target refreshed every fifteen minutes serves fifteen minutes of stale data
from memory precisely so the scrape never waits. Restarting therefore blanks
every instance's series until each background poller has completed its first
refresh, which is up to one full refresh interval per instance.

Reloading on `SIGHUP` and on `POST /-/reload`, applying the new
configuration atomically and keeping the old one when the new one fails, is
what the ecosystem does. `blackbox_exporter` and `snmp_exporter` both do it;
Prometheus itself does it, gated behind `--web.enable-lifecycle` for the HTTP
route. An exporter driven by a configuration file that cannot reload is the
exception.

The second, smaller goal: bound how many requests this exporter has in
flight against one machine at a time. Under `multi-instance` every collector
is a background poller owning its own goroutine and its own ticker, and
nothing today caps how many of them hit the same machine at once.

## 2. Background: what ships today

Six facts decide everything below, all of them already shipped.

**The configuration file is read once, at boot, and never again.** Each
main calls `config.Load(configPath)` then `cfg.Validate(...)`, then hands
the result to `kingpin` as synthetic arguments
(`mains/multi-instance/main.go.tmpl:99-112`, and the equivalent block in
`mains/multi/main.go.tmpl`). Nothing re-reads the path afterwards.

**The `flags:` section is resolved by rendering it back into command-line
arguments.** `internal/config/config.go.tmpl:9-15` documents why: `kingpin`
applies a flag's default only when that flag is absent from the parsed
arguments, so writing values into flags after `Parse()` would ADD to the
default of a repeatable flag instead of replacing it. The consequence for
this design is that `flags:` is parsed exactly once per process and cannot
be re-applied without re-running the whole parse.

**`multi` resolves credentials per request, from an immutable table.**
`probe.Handler` holds `modules`, `defaultClient` and `credentialed`, all set
once in `NewHandler` (`internal/probe/probe.go.tmpl:74-114`) and read by
`selectFactories` on every probe (`:153-211`).

**`multi-instance` builds one client per instance per collector.**
`code/http/wiring/instance_factory.frag:10-22` calls
`collector.NewClientWithConfig(addr, *exampleTimeout, *hcfg)` inside the
factory closure, which the instance loop
(`mains/multi-instance/main.go.tmpl:162-186`) runs once per instance per
enabled collector. Each call reaches `promconfig.NewClientFromConfig`, which
mints a fresh `http.Transport` and caches nothing. Fifteen collectors across
five instances is seventy-five transports and seventy-five connection pools,
against the explicit advice of the comment on `NewHTTPClient`
(`code/http/client.go.tmpl:63-71`: "Build it ONCE and share it across
targets").

**Collectors are collected sequentially.** `StatusTracker.Collect`
(`internal/collector/status_tracker.go.tmpl:74-111`) iterates its entries one
at a time. Synchronous collectors therefore never issue concurrent requests
to a target, under any target model. The only outbound concurrency in a
scaffolded exporter comes from background pollers, each of which owns a
goroutine and a ticker (`code/http/variants/background_collector.go.tmpl:119-134`)
and runs entirely outside that serialization.

**Background is mandatory under `multi-instance` and refused under `multi`.**
`commands/add-collector.md:105` refuses `--variant background` on a
multi-target scaffold; `:113` states that every collector under
`multi-instance` is a background poller by construction. So poller
concurrency exists under `multi-instance` and under `single` with the
background variant, and does not exist at all under `multi`.

## 3. What a reload actually buys, and what it does not

The roadmap justifies this work with credential rotation: "Since v0.5 a
single exporter can hold several credential sets, and rotating one currently
costs a restart and therefore a gap in the series." That is **false for
every secret held in a file**, and the correction narrows the scope.

In the pinned `github.com/prometheus/common v0.70.1`:

- `FileSecret.Fetch` (`config/http_config.go:805-811`) performs an
  `os.ReadFile` on every call, and `basicAuthRoundTripper.RoundTrip` calls
  it per request (`:926`). The same `SecretReader` indirection backs
  `bearer_token_file` and `authorization.credentials_file`.
- `tlsRoundTripper.RoundTrip` (`:1575-1588`) hashes the CA, certificate and
  key on every request and rebuilds its inner round tripper when the hash
  changes.

So `password_file`, `bearer_token_file`, `authorization.credentials_file`,
`ca_file`, `cert_file` and `key_file` are already hot: rewriting the file on
disk takes effect on the next request, with no reload, no restart and no gap.
This mirrors what `exporter-toolkit` already does for `--web.config.file` on
the inbound side.

What is left for a reload to deliver:

| Change | Already hot | Needs reload |
|---|---|---|
| Contents of any `*_file` secret or TLS material | yes | no |
| A secret written inline (`password:`, `bearer_token:`) | no (`InlineSecret.Immutable()` is true) | yes |
| `proxy_url`, `insecure_skip_verify`, `server_name`, `follow_redirects` | no | yes |
| A module added, removed, or edited | no | yes |
| An instance added, removed, re-addressed, re-labelled, or re-pointed at another module | no | **yes, and nothing else covers it** |
| The `flags:` section | no | impossible by construction (§2) |

The last row of the "needs reload" column is the real payload: the shape of
the configuration, not the secrets inside it. That is what sets the scope in
§4.

## 4. Scope

### 4.1 In

- Reload under **`multi`** and **`multi-instance`**: `SIGHUP` always, and
  `POST /-/reload` behind `--web.enable-lifecycle`.
- A per-target concurrency ceiling under **`multi-instance`** and
  **`single`**, opt-in, defaulting to unlimited.
- The refactor that makes both possible: one shared transport per watched
  machine, swappable in place.

### 4.2 Out, and why

**Reload under `single`.** Its file holds `flags:`, which cannot be
reloaded, and `http_client_config:`, whose file-backed parts are already hot
per §3. What remains is inline secrets and a handful of transport booleans.
The documentation says so and points at `password_file` instead.

**Reloading `flags:`.** Impossible by construction (§2). A reload that finds
this section changed refuses the whole reload rather than applying half of
it (§6.3).

**A concurrency ceiling under `multi`.** There are no background pollers
there (§2), and `StatusTracker` already serializes a probe's collectors, so
a ceiling inside one probe would be a no-op. Bounding concurrent probes of
the same target would need a map keyed by the `target` query parameter, and
`/probe` is allow-any by default: the key space would be caller-controlled
and unbounded. Refused on both counts.

**A per-instance ceiling in `instances:`.** The "no per-instance override"
rule locked in the v0.5 design is not reopened. A homogeneous fleet needs one
number.

**The project journal.** Listed under v0.7 in the roadmap, unrelated to this
work, moved out to its own session.

**Reintroducing `/add-collector`'s in-place migrations.** The v0.6 decision
stands: a repository scaffolded before this change is detected, refused, and
told to rescaffold. The migration harness remains the prerequisite, after
1.0.

## 5. Operator surface

### 5.1 Signals and endpoint

| Trigger | Behaviour |
|---|---|
| `SIGHUP` | Always active. Registered through a dedicated `signal.Notify` channel, never through the existing `signal.NotifyContext`, which must keep cancelling the process context on `SIGTERM` and `SIGINT` only. |
| `POST /-/reload` | Registered only when `--web.enable-lifecycle` is set. Default `false`. |
| `GET /-/reload` | `405 Method Not Allowed`. |
| `POST /-/reload`, flag unset | `404 Not Found`, as Prometheus does. |
| Reload succeeded | `200`, body `reload succeeded`. |
| Reload failed | `500`, body is the error. The previous configuration stays in force. |

**Why the endpoint is gated when `blackbox_exporter` and `snmp_exporter` do
not gate theirs.** A scaffolded `multi` exporter is allow-any and
unauthenticated by default; `warnIfExposedAndUnauthenticated` exists because
that is the ecosystem default this plugin follows. Shipping every generated
exporter an unauthenticated **mutating** endpoint would be the only change in
this release that degrades the default posture of a user who configured
nothing. `--web.config.file` covers the route once it is set, but it is not
set by default. `SIGHUP` already requires being on the machine, so it needs
no gate. Prometheus itself takes exactly this position.

### 5.2 Metrics

Three new metrics, in the `<namespace>_exporter_` family that already carries
`collector_success` and `request_duration_seconds`:

```
@@NAMESPACE@@_exporter_config_last_reload_successful                # 1 or 0
@@NAMESPACE@@_exporter_config_last_reload_success_timestamp_seconds
@@NAMESPACE@@_exporter_request_wait_seconds                         # histogram
```

The first two mirror the ecosystem's own naming and are set on every reload
attempt, successful or not. They ship with an alerting rule in `monitoring/`
(`ConfigReloadFailed`, firing on
`..._config_last_reload_successful == 0`) and an entry in `docs/metrics.md`,
which puts them under `make docs-check`.

The third is the concurrency ceiling's observability, discussed in §8.

### 5.3 What a reload never does

Change anything derived from a flag. `--web.listen-address`,
`--log.level`, `--probe.target-allowlist`, `--probe.timeout`,
`--collector.<name>.*` and `--exporter.max-requests-per-target` are all
resolved once. A reload that finds `flags:` changed refuses, naming the keys:

```
reload refused: flags section changed (log.level, web.listen-address);
these are applied once at startup, restart to apply them
```

## 6. The common layer: `internal/reload`

A new package beside `internal/probe` and `internal/instance`, selected by
`scaffold.sh` for the `multi` and `multi-instance` target models only. It
owns the mechanism; each main owns the policy.

```go
type Reloader struct{ ... }

func New(log *logger.Logger, path string, boot *config.Config,
         apply func(*config.Config) error) *Reloader

func (r *Reloader) Run(ctx context.Context) // consumes SIGHUP and HTTP requests
func (r *Reloader) Handler() http.Handler   // POST /-/reload
```

### 6.1 Serialization

A single goroutine consumes a `chan chan error`, the pattern Prometheus uses
for the same problem. A `SIGHUP` arriving during a `POST /-/reload` waits its
turn, and the HTTP handler receives the error of **its own** reload, so its
status code cannot report someone else's outcome.

### 6.2 Prepare, then commit

`apply` is split in two, and the split is what makes atomicity real rather
than asserted:

**Prepare** may fail, and mutates nothing: re-read the path,
`yaml.UnmarshalStrict`, compare `flags:` against the boot snapshot, run the
target model's own validation, resolve the modules, and **build every new
`*http.Client`**. Building a transport is the step that fails on an
unreadable CA or an unreadable secret file, and it must fail before anything
is swapped. Without this split, a bad CA on the third instance would leave the
process half reconfigured.

**Commit** cannot fail: atomic stores, `Register`/`Unregister` on names
prepare already proved unique, and goroutine starts.

### 6.3 Fail closed

Any error in prepare leaves the running configuration untouched, sets
`config_last_reload_successful` to 0, and logs at `Error`. The success
timestamp is only advanced by a successful commit.

## 7. Per-target-model policy

### 7.1 `multi`: swapping the module table

The three fields a reload changes are grouped into one immutable value behind
an atomic pointer:

```go
type handlerConfig struct {
    modules       map[string]Module
    defaultClient *http.Client
    credentialed  []string
}

type Handler struct {
    log        *logger.Logger
    factories  []NamedFactory
    allowlist  []string      // flag: fixed at startup
    maxTimeout, timeoutOffset time.Duration
    cfg        atomic.Pointer[handlerConfig]
}
```

`selectFactories` loads the pointer once at its top and works on that
snapshot for the rest of the request. A probe in flight finishes against a
coherent table; the next one sees the new one.

**Why an atomic pointer rather than the `sync.RWMutex` the roadmap named.**
`/probe` is the hot path: it reads this table on every request and never
writes it. A pointer to an immutable value costs no lock on that path, and it
makes "a reader observes a half-replaced table" impossible by construction
rather than by discipline.

Prepare additionally runs `probe.ValidateModules(factories, modules)`: a
module naming an unknown collector fails a reload exactly as it fails a boot.

Commit stores the new pointer, then calls `CloseIdleConnections()` on every
replaced `*http.Client`. Without it, the old transports hold their idle
sockets until `IdleConnTimeout`. It is safe to call immediately: the method
closes idle connections only, never one a probe still has in flight.

### 7.2 `multi-instance`: a shared transport, and a poller diff

#### 7.2.1 Separating what is shared from what is not

```go
// internal/collector: one per watched machine, shared by its collectors.
type Transport struct{ hc atomic.Pointer[http.Client] }
func (t *Transport) Set(hc *http.Client)

// internal/collector: one per collector, and tiny.
type Client struct {
    tr      *Transport    // SHARED
    baseURL string
    timeout time.Duration // this collector's own
    limiter *Limiter      // SHARED, nil means unlimited
}
```

One `Transport.Set` reaches all fifteen of an instance's collectors at once,
and no collector signature changes.

The per-collector timeout is preserved by moving it off
`http.Client.Timeout`, which cannot differ between collectors sharing a
transport, and onto a `context.WithTimeout` applied inside `Fetch`. This
matters concretely: `/add-collector` declares a `--collector.<name>.timeout`
per collector, and a slow endpoint may legitimately need a value orders of
magnitude larger than its siblings'.

**Non-regression.** `NewClient(target, timeout)`, the constructor used by
every shipped collector test and by every repository scaffolded before this
change, keeps building its own private `http.Client{Timeout: timeout}` and
leaves `Client.timeout` at zero. Exactly one timeout mechanism per
construction path, and the old path is untouched.

The shared path, by contrast, carries no `http.Client.Timeout` at all, so a
collector reaching it with no deadline would hang its poller forever. That
makes a non-positive timeout a boot-time configuration error rather than a
defensive nicety, and `ClientFor` reports it:

```go
func (h *Handle) ClientFor(timeout time.Duration) (*collector.Client, error)
```

#### 7.2.2 The handle

```go
// instance.Handle is everything the process keeps about ONE watched machine.
type Handle struct {
    Name    string
    Address string                 // immutable: a changed address rebuilds the Handle
    tr      *collector.Transport
    limiter *collector.Limiter
    labels  prometheus.Labels      // remembered: needed to unregister
    tracker *collector.StatusTracker
    cancel  context.CancelFunc     // per instance, child of the process context
    bgs     []interface{ Done() <-chan struct{} }
}
```

The factory seam changes shape:

```go
New func(h *Handle) (BackgroundCollector, error)
```

and `instance_factory.frag` stops building a transport, asking the handle for
a client instead:

```go
New: func(h *instance.Handle) (instance.BackgroundCollector, error) {
    c, err := h.ClientFor(*exampleTimeout)
    if err != nil {
        return nil, err
    }
    return collector.NewExampleCollector(log, c, *exampleInterval), nil
},
```

The v0.4 design kept this error return as an extension point despite having
no caller that could fail. It now has one, on both paths that matter: a
non-positive timeout fails the boot, and it fails a reload's prepare phase
before anything is swapped.

This is a seam signature change. Under the v0.6 no-migrations policy it is
handled by detection and refusal, not rewriting: `/add-collector` recognises
the older shape and tells the operator to rescaffold.

#### 7.2.3 The diff

Identity is the instance **name**, which validation already proves unique.
Three properties are then compared independently, because each has a
different cost:

| Changed | Commit action | Cache |
|---|---|---|
| nothing | nothing | kept |
| module or credentials, compared as the **resolved** `HTTPClientConfig`, not the module name | `h.tr.Set(new)`, then `CloseIdleConnections()` on the old | **kept** |
| labels | unregister through a wrapper built with the **old** labels, re-register the same `tracker` with the new ones | **kept** |
| address | treated as a removal plus an addition under the same name | dropped |
| instance added or removed | build and `Start(instanceCtx)`, or `cancel()` and unregister | n/a |

Two consequences worth stating explicitly.

**Comparing resolved content, not the module name**, means renaming a module
without changing what it holds restarts nothing, while editing a module's
contents under the same name does swap the transport. That is the case that
matters for rotating a secret written inline.

**Labels can change without touching the poller** only because
`WrapRegistererWith` applies its `ConstLabels` inside the wrapper, at
`Collect` time: the collector's cache holds metrics carrying bare `Desc`s and
knows nothing about instance labels. Unregistering requires a wrapper built
with the previous labels, which is why `Handle` remembers them.

A single instance can hit both the label case and the module case in one
reload. Order is labels first, then transport; neither blocks.

#### 7.2.4 Draining

Unregistering is synchronous at commit, so a removed instance's series
disappear from the very next scrape. Waiting for its goroutines to exit
happens in a separate goroutine under the same shared five second budget the
shutdown path already uses (`mains/multi-instance/main.go.tmpl:229-237`),
logging a warning if it is exceeded. A reload therefore never blocks behind a
poller stuck in a long request, and a lingering poller is harmless: it is
unreferenced, unregistered, and exits when its cancelled context surfaces.

## 8. The concurrency ceiling

```go
// internal/collector
type Limiter struct{ slots chan struct{} }

func NewLimiter(limit int) *Limiter // limit <= 0 returns nil
func (l *Limiter) Acquire(ctx context.Context) (release func(), err error)
```

A `nil` `*Limiter` is a pass-through, so the unlimited default costs one nil
check and no allocation.

`Acquire` honours the context:

```go
select {
case l.slots <- struct{}{}:
    return func() { <-l.slots }, nil
case <-ctx.Done():
    return nil, ctx.Err()
}
```

The wait must therefore be bounded by the collector's own
`--collector.<name>.timeout`. This is the property that keeps a ceiling from
degrading silently: a starved poller fails its refresh, logs, keeps its previous
cache, and its freshness gauge stops advancing. Without a deadline on the wait it
would instead sit in the queue while `time.Ticker` silently dropped its ticks,
and the effective refresh interval would drift with nothing reporting it.

**Corrected during implementation.** This section originally claimed the wait was
charged against the collector's budget "never in addition to it". That was only
true on the shared-transport path. On every wired construction
(`NewClient`, `NewClientWithConfig`, `NewClientFor`) the deadline lives on
`http.Client.Timeout`, which starts at `Do`, after the wait has already happened,
so the wait was unbounded. Reproduced at five times the configured budget. The
`Client` now carries an explicit acquire budget, populated by every constructor,
that bounds the wait itself. The honest bound is therefore **at most twice the
configured timeout** on the wired paths (the wait, then the request) and exactly
once on the shared-transport path, where a single context deadline covers both.

**Where the semaphore lives, and why there is no index of targets.** Under
`multi-instance` the `Limiter` belongs to the `Handle`: one machine, one set
of tokens, shared by its collectors because they share the handle. An
instance added by a reload builds its own. Under `single` there is no handle
and each collector carries its own `--collector.<name>.target`, so grouping
by address is done in `main.go` through a small `LimiterSet` whose
`For(target)` is called at startup only, over the finite and immutable set of
target flags. No caller-controlled key ever reaches either structure.

An index pre-populated at startup and shared across models was considered and
rejected: an instance added by a reload would have no entry, and its ceiling
would silently not apply.

Flag: `--exporter.max-requests-per-target`, default `0`, meaning unlimited.
The default does not move, following the same posture as
`--probe.target-allowlist`, whose empty value means allow-any. A non-zero
default would make the starvation scenario the out-of-the-box behaviour
rather than a deliberate choice, and the model has never been measured under
concurrent load.

Observability is one histogram, `@@NAMESPACE@@_exporter_request_wait_seconds`,
unlabelled, registered on the root registry beside `RequestDuration`, which
carries no instance label either. It answers "are requests queueing"; the
per-collector freshness gauge already shipped with the background variant
answers "which one is starving". Together they cover the failure mode.

## 9. Consumers to update

| File | Change |
|---|---|
| `commands/add-collector.md` | The multi-instance fragment follows `New(h *instance.Handle)`. The seam-shape detector gains a fourth shape: a v0.5 or v0.6 repository is refused with a rescaffold pointer. |
| `skills/prometheus-exporter/assets/scaffold.sh` | `internal/reload/` is selected the way `internal/probe/` and `internal/instance/` already are: present under `multi` and `multi-instance`, removed under `single`. |
| `commands/design-exporter.md` | A new sub-question, conditioned on the target model: "does your target tolerate concurrent requests?", asked only for `multi-instance`, or for `single` with at least one background collector. The answer goes in the brief and is applied by `/new-prometheus-exporter`, the same three-piece shape the v0.5 credential-convention question uses. |
| `references/exporter-architecture.md` | Reload in the three-model comparison. |
| `references/packaging-and-ops.md` | `SIGHUP`, `ExecReload=/bin/kill -HUP $MAINPID` in the systemd unit, `--web.enable-lifecycle`. |
| `references/security-and-hardening.md` | Why the HTTP route is closed by default. |
| `references/dashboards-and-alerts.md` | The `ConfigReloadFailed` rule. |
| `references/collector-pattern.md` | The context-carried timeout in the background variant. |
| `references/docs-and-governance.md` | The three new metrics in `docs/metrics.md`. |
| `assets/SECURITY.md.tmpl` | The mutating endpoint, its closed default, and that `--web.config.file` covers it once set. |

## 10. Proving it

### 10.1 Go unit tests

- `internal/reload`: serialization (a `SIGHUP` arriving during a `POST`
  waits, and each caller gets its own error), an unreadable or invalid file
  leaves the previous configuration in force and drives the gauge to 0, a
  changed `flags:` section is refused with the differing keys named, and the
  HTTP handler's status reflects its own reload.
- `internal/probe`: the table swaps while a probe is in flight and that probe
  keeps a coherent snapshot; a module naming an unknown collector is refused.
- `internal/instance`: each of the five diff cases, each asserting on both
  the cache (kept or dropped) and the registration.
- `internal/collector`: the `Limiter` respects its ceiling, is cancellable
  through its context, and passes through at limit 0; `Transport.Set`
  concurrent with `Fetch`.

`go test -race` is mandatory: it is the only layer that can catch a
regression in `Transport.Set` or in the diff.

### 10.2 Golden smoke, cells `http-multi` and `http-multi-instance`

1. Start without the flag, `POST /-/reload` returns **404**. Proves the
   closed default.
2. Restart with `--web.enable-lifecycle`, rewrite the file to add an
   instance or a module, reload: **200**,
   `config_last_reload_successful 1`, **and the new instance appears in
   `/metrics`**.
3. Write a broken file, reload: **500**, gauge **0**, **and the previous
   instances are still served**.
4. Change `flags:`, reload: **500**, and the message names the key.

Step 3 is the one that proves atomicity, and steps 2 and 3 exist because of
the v0.4 lesson: `config.example.yml` survived nine task reviews because the
golden checked that the file **existed**, never that it **loaded**. The
equivalent trap here is checking that `/-/reload` answers without ever
checking that it changed anything.

### 10.3 Unchanged gates

`test/zero-source-grep.sh`, `claude plugin validate .`, and `make check`
inside every golden cell.

## 11. Implementation tranches

One plan, four tranches, the first of which changes no observable behaviour.
This is the two-phase rule applied at the level where it has meaning: the new
mechanism lands first, with every existing caller still on the old path.

1. **`Transport`, `Client`, `Limiter` in `internal/collector`.** Pure
   refactor. The existing collector tests are the non-regression proof, and
   the golden matrix must stay green with no template rewiring yet.
2. **`internal/reload` plus `multi` wiring.** The common layer, validated on
   the simpler of the two models.
3. **`Handle` and the `multi-instance` diff.** The hard half.
4. **Documentation, references, `/design-exporter`, `monitoring/`, and the
   golden assertions.**

## 12. Risks

**The seam change is load-bearing.** `instance.Factory.New` changes shape,
and the v0.5 epic's most instructive defect was exactly this class: changing
`probe.NewHandler` from six to seven parameters broke a consumer nobody
re-audited. Every consumer of the instance seam has to be enumerated and
checked, not assumed: `instance_factory.frag`, both mains,
`commands/add-collector.md`, and the golden second-collector snippet.

**The shared transport changes connection behaviour under `multi-instance`.**
Seventy-five pools become five. That is the intent, but it means an instance's
collectors now contend for one pool's `MaxIdleConnsPerHost`, whose `net/http`
default is 2.

**Resolved during implementation: this does not bite.** `prometheus/common`'s
own transport constructor (`config/http_config.go:652-664` in v0.70.1) sets
`MaxIdleConns: 20000` and `MaxIdleConnsPerHost: 1000`, citing golang/go#13801,
and every path in this scaffold that shares a client reaches it through
`NewClientFromConfig`. The only construction bypassing it is `NewClient`, whose
transport is private to one collector and therefore uncontended. No deliberate
override is required.

**A ceiling that is never set is a ceiling that is never exercised.** With
the default at 0, only the unit tests cover the non-trivial path. The golden
cells should run one configuration with a non-zero ceiling so the wiring is
proven end to end, not only the pass-through.
