# Multi-instance target model

**Status:** design approved 2026-07-23 · v0.5.0. Builds on the v0.4.0 YAML
configuration layer, which exists precisely so N instances with per-instance
credentials can be declared somewhere a kingpin flag surface cannot reach.

## 1. Goal

Two deliverables that share one configuration schema.

**A. Per-target credentials for the existing `multi` model.** Today a
multi-target exporter carries a single global `http_client_config:`, so it
cannot probe two targets that authenticate differently. A `modules:` section,
shaped like the Blackbox exporter's, lets each named module carry its own
authentication and TLS. A request selects one with `/probe?target=...&module=...`.

**B. A third target model, `multi-instance`.** One process watches a list of
machines declared in the configuration file, each identified by a label, each
refreshed by its own background poller, all served through a single `/metrics`
that Prometheus scrapes as one target. This is the model an exporter needs when
its data refreshes more slowly than Prometheus's staleness window (see §4).

The two are one mechanism seen from two sides. A `multi` module and a
`multi-instance` instance both reduce to the same thing: a named bundle of
authentication, TLS and labels. `multi` binds that bundle to a target
per request; `multi-instance` binds it to an address at boot. Designing
`instances:` without reusing the `modules:` schema would ship two redundant
YAML shapes.

### Non-goals

- **SIGHUP reload.** Reloading the instance list into a running process, while
  its pollers are mid-flight, is a concurrency problem worth its own version.
  It is deferred to v0.6.0. v0.5.0 validates the whole configuration once, at
  boot, fail-fast.
- **Per-instance flag overrides.** An instance declares its identity, address,
  module reference and extra labels. Everything else (timeouts, intervals,
  which collectors are enabled) stays global. Kingpin parses the flag surface
  exactly once (v0.4.0's central invariant), so a per-instance flag override
  would need a second resolution mechanism with its own type conversion and
  validation. No confirmed consumer needs it; YAGNI. Opening one later is
  additive.
- **`cli`-flavor multi-instance.** `--target-model multi-instance` requires
  `--flavor http`, refused fail-fast on `cli`, the same pairing rule
  `--target-model multi` already enforces. Per-instance authentication is the
  core of the model and only has meaning over HTTP.
- **Synchronous collectors under multi-instance.** See §7. The model's promise
  ("`/metrics` answers fast even when machines are down") only holds when every
  collector reads from a background cache. A synchronous collector is refused.
- **Configurable instance-label name at runtime.** The label name is fixed at
  scaffold time by `scaffold.sh --instance-label` (default `target`), baked
  into the generated code. A runtime knob would let a config edit rename every
  series at once and would make `docs/metrics.md` unverifiable by
  `make docs-check`.

## 2. Background: three target models

`--target-model` already selects between two runtimes; v0.5.0 adds a third.

| Model | Targets | Who chooses the target | `--config.file` |
|---|---|---|---|
| `single` | one, fixed at scaffold time | the author, hard-coded | optional |
| `multi` | one per request | Prometheus, via `?target=` | optional |
| `multi-instance` | many, listed in the config file | the exporter, at boot | **required** |

`scaffold.sh` keeps only the selected `mains/<target-model>/main.go.tmpl` and
removes the rest (`scaffold.sh:268-276`), so a `single` or `multi` scaffold
receives no multi-instance code at all.

**The `multi` credential gap.** `mains/multi/main.go.tmpl` builds one
`probe.NamedFactory` list (`:138-140`), and the http wiring builds one
`*http.Client` from the single global `http_client_config:` shared by every
target (`code/http/wiring/probe_factory.frag`). Two targets needing different
credentials cannot both be probed. The v0.4.0 YAML layer is what finally makes
this fixable: credentials now have a place to live, keyed by name.

**Why `?target=` cannot host multi-instance.** A background poller must know its
target at startup to begin polling; `?target=` supplies the target only per
request. This is the same asymmetry `/add-collector` already encodes by
refusing `--variant background` on a multi-target scaffold
(`commands/add-collector.md:191-195`). Multi-instance is the mirror image:
background is not just allowed, it is mandatory (§7).

## 3. Configuration schema

One shared section, `modules:`, plus one model-specific section, `instances:`.

```yaml
# Existing v4 sections stay valid and unchanged.
flags:
  log.level: debug

# NEW: named credential/TLS bundles, Blackbox-shaped. Each module optionally
# narrows the collector set and carries its own outbound HTTP client config.
modules:
  default:
    http_client_config:
      basic_auth: { username: monitor, password_file: /etc/exporter/default.pass }
  privileged:
    collectors: [example]
    http_client_config:
      tls_config: { ca_file: /etc/ssl/internal-ca.pem }

# NEW (multi-instance only): the machines this process watches. Each references
# a module by name; it never carries inline credentials.
instances:
  - { name: library-a, address: https://a.example.net, labels: { site: paris } }
  - { name: library-b, address: https://b.example.net, module: privileged }
```

**Rules.**

1. **A module is a named bundle** of an optional `collectors:` subset and an
   optional `http_client_config:` (the same `promconfig.HTTPClientConfig` the
   v0.4.0 layer already parses and validates). Nothing a flag can express lives
   in `http_client_config:`; a `basic_auth` was never flag-expressible.
2. **`collectors:` is consulted only under `multi`.** There it selects the probe
   subset, the job `--probe.module` does today. Under `multi-instance`,
   collector enablement is global (the `--collector.<name>` flags), so an
   instance always runs the globally enabled set and a module's `collectors:`
   key would be a second source for the same decision. It is therefore refused
   at boot under `multi-instance`, not silently ignored; a module used there
   contributes only its `http_client_config:`.
3. **Fallback is by replacement, not by merge.** An instance that names a module
   takes that module's client config whole. There is no field-level merge with
   a global block, because a merge produces combinations nobody wrote and no
   error message can explain.
4. **v0.4.0 compatibility.** When no `modules:` section is present, a top-level
   `http_client_config:` is treated as the `default` module. Every v0.4.0
   config keeps working verbatim.
5. **An instance references a module, never inline auth.** Omitting `module:`
   means the `default` module. This keeps the "no value has two sources" rule
   from v0.4.0 intact.
6. **`single` refuses `modules:` and `instances:` at boot.** A single-target
   exporter has one target; a module or instance list is meaningless there, and
   ignoring it silently would mask a misconfiguration. Same fail-fast posture as
   `--flavor cli` rejecting `http_client_config:` in v0.4.0.
7. **`multi-instance` requires `--config.file`.** Without it there are no
   instances to watch. This is the one place multi-instance departs from
   v0.4.0's "an absent file changes nothing"; it is a new target model, so no
   existing scaffold's behaviour moves.

### The `--probe.module` flag collision

`mains/multi/main.go.tmpl:96-99` declares `--probe.module`
(`<name>:<collector>,...`), which expresses collector subsets: the same thing a
module's `collectors:` key now expresses. Two-phase rule:

- The flag stays intact and functional (no existing v0.3 deployment breaks).
- Supplying both `--probe.module` and a `modules:` section is refused at boot
  with a clear message; there is no silent precedence.
- The flag is documented as deprecated, for removal in a later version.

## 4. Why multi-instance exists: the staleness window

The motivating constraint is not "slow targets". Prometheus assigns a value to a
timestamp from the newest sample within a lookback period that defaults to five
minutes (Prometheus docs, *Querying basics > Staleness*). A datum you only want
to refresh every fifteen minutes, or every six hours, cannot be obtained by
lengthening `scrape_interval`: the series would be queryable for five minutes
per cycle and invisible the rest of the time.

It must instead be **re-served from a cache on every scrape**, at scrape
cadence, while the real refresh runs on its own slower schedule. That is the
poller-plus-cache model, and `?target=` cannot host it (a poller needs its
target at startup). This reasoning generalises past any one device: any
application API whose call is expensive, any batch whose state only changes
hourly, any inventory polled once a night.

This argument replaces the "slow, unpaginated endpoints" framing in the ROADMAP
and in the TS4500 design's §3, whose own `honor_timestamps` section already
states the staleness reasoning correctly but buries it.

## 5. Boot sequence: `mains/multi-instance/main.go.tmpl`

Reuses the multi preamble verbatim: `config.Load` -> `Validate` ->
`kingpin.Parse` over rendered arguments (`mains/multi/main.go.tmpl:104-123`).
Then:

1. **Validate instances, fail-fast.** At least one instance; non-empty and
   unique names; addresses that parse as http/https; each referenced module
   resolves; each module's `http_client_config` validates through `promconfig`;
   no instance label name collides with the identifying label or with a label a
   collector already emits.
2. **One `*http.Client` per instance, built once before the loop.** Same reason
   as the `/probe` fragment: connection reuse, and an unreadable CA or secret
   file is a configuration fault that must stop the process at boot rather than
   surface on the first scrape.
3. **For each instance, for each enabled factory:** call
   `f.New(inst.Address, inst.ClientConfig)`, which returns a background
   collector (poller plus cache) already bound to that instance's transport;
   call its `Start(ctx)`, add it to the shared shutdown-wait slice, add it to a
   per-instance `StatusTracker`, and register that tracker against
   `prometheus.WrapRegistererWith(labels, reg)` where `labels` carries the
   identifying label plus the instance's extra labels. The factory is the
   `internal/instance` seam, not `probe.NamedFactory` (see §9).
4. `/metrics`, `/healthz`, `/`. No `/probe`.

**Collector flags stay.** The `multi-instance` main keeps the
`--collector.<name>` toggles, using the same two markers the http flavor already
splices: `@@CLIENT_INIT@@` before Parse to declare each flag, `@@PROBE_FACTORIES@@`
after Parse to build. The generic README promises this toggle on every scaffold
(`README.md.tmpl:23`); dropping it on one target model would be a gratuitous
inconsistency.

**Shared shutdown budget.** The single/multi mains wait for background
collectors to stop with a `time.After(5 * time.Second)` **per collector**
(`mains/single/main.go.tmpl:267-273`). With N instances x M background
collectors, that worst-cases at N*M*5s. The multi-instance main shares one 5s
budget across all of them.

## 6. Instance label and cardinality

The identifying label (default `target`, fixed by `scaffold.sh --instance-label`)
is applied by `WrapRegistererWith` to **every** series the instance emits,
health metrics included:
`<ns>_exporter_collector_success{collector="example", target="library-a"}`.

Verified in source: `WrapRegistererWith` adds the labels as `ConstLabels`
(`prometheus/wrap.go:26-46`), and `ConstLabels` are part of a `Desc`'s identity,
so two instances registering the same collector never collide. `Gather` collects
one goroutine per registered collector (`prometheus/registry.go:430-467`), so
fanning the same collector across N instances scrapes them concurrently for
free.

This deliberately goes against `WrapRegistererWith`'s own doc guidance, which
warns against using it to put fixed labels on *all* exposed metrics and points
to "target labels, not static scraped labels". That is the acknowledged price of
the model, and it is exactly why the `?target=` model was rejected for this use
case. The generated docs state it plainly rather than hiding it.

## 7. Failure model

Two levels, sharply separated.

- **Configuration error -> fail-fast at boot.** Non-unique names, an address
  that does not parse, an unresolved module reference, an unreadable CA or
  secret file. Clear error, no silent default. This is the TS4500 design's §4.4,
  generalised.
- **An instance goes down -> runtime, isolated.** Its
  `collector_success{target=...}` reads 0 and it exposes the age of its last
  snapshot; the other instances are unaffected. This reconstructs, explicitly,
  the per-target health that Prometheus no longer supplies for free: with one
  scrape target, `up` only reports that the exporter process is alive, not that
  any given machine is reachable.

## 8. Background collector mandate

Multi-instance serves N machines through one `/metrics`. A **synchronous**
collector fetches its target at scrape time, and `Gather` waits for every
collector, so one slow or dead machine would stall the whole `/metrics`
response, reintroducing exactly the coupling the model exists to remove. A
**background** collector (poller plus cache; `Collect` only reads the cache,
`Start(ctx)`/`Done()` at `code/http/variants/background_collector.go.tmpl:119,140`)
keeps the promise that `/metrics` answers in milliseconds regardless of target
state.

Therefore, on a multi-instance scaffold:

- The starter collector is the background variant.
- `/add-collector` **refuses** the synchronous variant with a clear message,
  the mirror of its existing refusal of the background variant on `multi`
  (`commands/add-collector.md:191-195`).

## 9. Architecture: mirror the `NamedFactory` pattern with a background seam

The multi-target epic introduced
`probe.NamedFactory{Name, New func(ctx, target, timeout) (prometheus.Collector, error)}`,
whose `New` builds a **synchronous** collector: the probe re-scrapes its target
on every request, so no goroutine and no cache are involved. `multi-instance`
mandates the opposite (§8): a **background** collector, whose constructor takes
a refresh interval, must be `Start(ctx)`-ed, and must be waited on via `Done()`
at shutdown. That lifecycle does not fit through the synchronous `New` signature
(`timeout` is not `interval`; there is nowhere to hand back the `Start`/`Done`
handle), and widening the probe seam to carry it would make the same seam mean
two incompatible things.

So `multi-instance` gets its own seam, `internal/instance`, that mirrors the
`NamedFactory` pattern rather than reusing the type:

```go
package instance

type BackgroundCollector interface {
	prometheus.Collector
	Start(context.Context)
	Done() <-chan struct{}
}

type Factory struct {
	Name    string
	Enabled *bool // the --[no-]collector.<name> toggle, kept per §5
	New     func(addr string, hcfg *promconfig.HTTPClientConfig) (BackgroundCollector, error)
}
```

`New` builds the instance's `*collector.Client` (honouring the module's
`http_client_config`, or the default transport when absent) and the background
collector around it; it may fail on an unreadable CA or secret file, which fails
the boot. `*ExampleCollector`, the background variant already shipped
(`code/http/variants/background_collector.go.tmpl`), satisfies
`BackgroundCollector` structurally, so no collector or test template changes.

Consequences:

- **The probe seam is untouched.** `multi` (`?target=`) keeps
  `probe.NamedFactory` verbatim; volet A adds module-credential selection to it
  (§1A) without changing its synchronous lifecycle. Zero regression risk to the
  shipped `multi` runtime.
- **Collectors are untouched.** `multi-instance` ships the existing background
  variant as its starter (§8, §10); `NewExampleCollector(log, client, interval)`
  and `NewClientWithConfig(target, timeout, hc)` already exist. No template
  edits.
- **`/add-collector` gains a multi-instance branch** that appends an
  `instance.Factory` (background only), the mirror of its existing multi branch.
  It is a third wiring shape, the honest cost of two genuinely different
  collector lifecycles.

## 10. Scaffold surface

- New `--target-model multi-instance` value (http only; reject `cli` fail-fast,
  mirroring `scaffold.sh:191-192`).
- New `mains/multi-instance/main.go.tmpl`.
- New `scaffold.sh --instance-label` variable, default `target`.
- `internal/config` learns to parse `modules:` and `instances:`.
- `--config.file` required at boot under multi-instance.
- `/new-prometheus-exporter` and `/design-exporter` carry the third value
  through their existing `--target-model` handling
  (`commands/new-prometheus-exporter.md:40-48,111-175`).

## 11. Prometheus configuration

**single** and **multi** are unchanged. The two contrasts worth stating:

**multi** now relabels a module alongside the target (credentials live in the
module, so differing-credential targets carry differing `module` labels):

```yaml
  - job_name: 'myexporter-probe'
    metrics_path: /probe
    file_sd_configs: [{ files: ['targets/*.yml'] }]   # each entry carries a `module` label
    relabel_configs:
      - { source_labels: [__address__],    target_label: __param_target }
      - { source_labels: [module],         target_label: __param_module }
      - { source_labels: [__param_target], target_label: instance }
      - { target_label: __address__, replacement: 'exporter-host:PORT' }
```

**multi-instance** is scraped like single: one target, no relabeling. The N
machines appear only as the `target="..."` label the exporter applies itself.
`scrape_timeout` must cover the process, not N live fetches, because
`/metrics` reads caches.

```yaml
  - job_name: 'myexporter'
    static_configs: [{ targets: ['exporter-host:PORT'] }]
```

## 12. `monitoring/` changes

The shipped rules assume a single target: `ExporterCollectorFailing` names
`{{ $labels.collector }}` without an instance (`alerts.yml.tmpl:92-98`), and the
recording rule aggregates `sum by (job)` (`rules.yml.tmpl:36-39`), which would
drown one failing machine among N healthy ones. A multi-instance scaffold ships
rules aggregated `by (job, target)` and carrying the instance label in alert
summaries. This is a scaffold-time divergence, not a runtime toggle.

## 13. Test matrix

`golden-smoke` gains one cell: http / none / multi-instance, taking the matrix
from five containerised cells to six. The multi credential volet (A) is covered
inside the existing http-multi cell, adding no cell.

## 14. Documentation corrections carried by the epic

- **`ROADMAP.md` v0.5**: rejustify the model by the five-minute staleness
  window (§4), not by "slow targets". The argument generalises to any
  application API, not only tape libraries.
- **`commands/design-exporter.md:76-78`**: the line calling multi-target
  "documented follow-up work, not something this command produces" has been
  false since v0.3. Architecture decision 2 becomes a three-value choice.

## 15. Deferred / open

- **SIGHUP reload** -> v0.6.0, with the poller-vs-reload race as its risk-1.
- **`multi-instance` on `cli`** -> not planned; opening it later is additive,
  not breaking.
- **Per-instance flag overrides** -> not planned; YAGNI until a consumer needs
  one.
