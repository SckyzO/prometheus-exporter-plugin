# Gap report: this plugin against four official exporters

Produced 2026-08-01 for the re-sync epic. Feeds `re-sync.md` §8, whose shape and
verdict vocabulary it follows. **Verdicts here are proposals.** Nothing is
applied until the maintainer rules on each one.

## What was read

Four cold clones, `--depth 1 --branch <tag>`, in scratch space, read-only, all
four `git status` clean at the end (§1.3 discipline):

| Reference | Tag | License |
|---|---|---|
| `prometheus/node_exporter` | `v1.12.1` | Apache-2.0 |
| `prometheus/blackbox_exporter` | `v0.28.0` | Apache-2.0 |
| `prometheus/snmp_exporter` | `v0.30.1` | Apache-2.0 |
| `prometheus-community/ipmi_exporter` | `v1.10.1` | MIT |

Read in four parallel tranches, one per domain, then fused here. Every claim is
sourced to `file:line` on both sides.

## The three headline results

**1. `re-sync.md` §4.6 is correct, and the wart it records is real.** This was
the first draft's headline, asserting the opposite, and an adversarial review
killed it. The reasoning is preserved here because the trap is worth inheriting.

`execute()` does set `success = 0` for both `ErrNoData` and a real error, the
only difference being the log level (`node_exporter/collector/collector.go:164-174`).
That is true, and it is not the point. **`ErrNoData` does not mean "legitimately
empty"; it means "the data source is absent"** — every one of its ~40 use sites
is an `os.ErrNotExist` mapping (`bonding_linux.go:61-63`,
`thermal_zone_linux.go:75-77`, `mdadm_linux.go:127-129`, `conntrack_linux.go:149`).

A collector that is *legitimately empty* takes a different path entirely: it
iterates an empty result and returns `nil`. `readBondingStats` returns an empty
map with a nil error when `bonding_masters` exists but is empty
(`bonding_linux.go:74-102`); `Update` then runs its loop zero times and returns
`nil` at `:71`; `execute()` takes the `else` branch and emits **`success = 1`
with zero metrics**. Same shape at `mdadm_linux.go:232-249` and
`thermal_zone_linux.go:82-90`.

So the `Update(ch) error` contract does exactly what §4.6 says: it lets a
collector **assert** success instead of leaving the tracker to **infer** failure
from a zero count. For that same collector this plugin reports
`collector_success=0` (`status_tracker.go.tmpl:102-104`). The gap is real and
§4.6 needs no correction.

**2. The real divergence is the opposite one, and it is a false negative.** A
collector that emits some of its series and then fails reports
`collector_success=1` here, because `StatusTracker` has only the metric count as
a signal (`status_tracker.go.tmpl:102-104`). node_exporter reads the returned
error, not the count, so it reports the failure while keeping the already-emitted
metrics (`conntrack_linux.go:107-125` emits before it can fail;
`collector.go:160-176` reads `err`). The plugin's own doctrine, "on a
successful-but-empty scrape always emit metrics with zero values"
(`collector-pattern.md:179-199`), actively widens this blind spot.

**3. A shipped reference names a metric the code cannot emit.** All four
references register `versioncollector.NewCollector("<name>")`, exposing
`<name>_build_info` with the ldflags-injected version
(`node_exporter.go:147`, `blackbox_exporter/main.go:69`,
`snmp_exporter/main.go:221`, `ipmi_exporter/main.go:140`). This plugin registers
`collectors.NewBuildInfoCollector()`, which emits `go_build_info`
(`mains/single/main.go.tmpl:202` and the two sibling mains).
`project-scaffold.md:339` nonetheless tells the reader that
"`@@EXPORTER_NAME@@_build_info` gives Prometheus itself a way to query the
running version". Nothing emits that metric.
`dashboards-and-alerts.md:256-258` says `go_build_info` and is correct, so the
two references contradict each other. `make docs-check` cannot see either file.

## Unresolved conflict between two tranches

**Concurrency ceiling and instrumentation on `/metrics`.** Two tranches reached
opposite verdicts on the same evidence, and this report does not pick a winner.

- Against: one reference of four does it, and it is the one whose scrape is
  uniquely expensive across ~90 kernel collectors. blackbox, snmp and ipmi all
  serve `/metrics` with a bare handler. `StatusTracker` already answers "is a
  collector slow or failing" per collector.
- For: the exposure is real for `single` and `multi-instance`, where `/metrics`
  triggers the full collector set, and node_exporter is the only reference doing
  synchronous local collection at scale, so the evidence is thin in count but
  directly on point in kind.

Both agree on the awkward part: node_exporter's `--web.max-requests` defaults to
**40**, not unlimited (`node_exporter.go:192-195`). Matching it changes behavior
for already-deployed exporters. Defaulting to 0 matches this plugin's existing
posture but ships an unexercised ceiling, the exact risk
`2026-07-28-config-reload-and-concurrency-design.md:614-617` names.

Maintainer's call.

---

## §8.2 Collector shape and scrape-error semantics

| Gap | Official | This plugin | Seen in | Verdict |
|---|---|---|---|---|
| A legitimately empty scrape is a success | the collector returns `nil` and `execute()` emits `success=1` with zero metrics (`bonding_linux.go:67-71` + `collector.go:171-176`). `ErrNoData` is the *separate*, source-absent case. ipmi agrees: zero metrics, `ipmi_up 1` (`collector_dcmi.go:56-63`) | zero metrics means `collector_success=0` (`status_tracker.go.tmpl:102-104`) | node v1.12.1, ipmi v1.10.1 | **adopted** |
| Partial emission then failure | error return is the signal, independent of metric count (`collector.go:160-176`) | count is the only signal, so half-then-fail reads as success (`status_tracker.go.tmpl:102-104`) | node v1.12.1, ipmi v1.10.1 | **adopted** |
| Central per-collector log policy | `execute()` owns it for the whole fleet: Error / Debug / Debug-with-duration (`collector.go:164-174`) | `StatusTracker` logs panics only (`status_tracker.go.tmpl:93`); the zero-metric path is silent | node v1.12.1, ipmi v1.10.1 | **adopted** |
| Collectors run sequentially | node parallelises per collector (`collector.go:146-156`). snmp has a worker pool but `--snmp.module-concurrency` **defaults to 1** (`main.go:50`), so it is sequential out of the box too; ipmi is sequential | sequential (`status_tracker.go.tmpl:75-111`), bounded only on the probe path | node v1.12.1 (the only one parallel by default) | **adopted (document only)** |
| Panic isolation | **no `recover()` in any of the four**, non-test code | per-collector recover, rest of the scrape survives (`status_tracker.go.tmpl:89-98`) | absent from all four | **already covered — plugin better** |
| `collect[]` / `exclude[]` per-request filtering | node builds a filtered handler per request (`node_exporter.go:79-120`) | absent | node v1.12.1 only | **rejected** |

**Why, on the ones that matter.** The two collector-shape rows are the **same
gap seen from both sides**, and both are fixed by the same change. Today the
tracker infers an outcome from a metric count, which is wrong in both
directions: a legitimately empty collector reads as failed (false positive), and
a collector that emits half its series then fails reads as healthy (false
negative). The count is a proxy for a signal the collector never gets to send.
The false negative is the more dangerous of the two, and this plugin's own
doctrine — always emit at least one metric — actively widens it.

The central log policy is *adopted* separately because it is the cheapest real
improvement here and it is the missing half of `StatusTracker`'s own promise: it
claims to expose every collector's health uniformly, yet says nothing about the
most common failure it detects.

**Cost.** Partial-emit touches the collector seam itself, which every collector
under `internal/collector/` implements and which `StatusTracker.Add`,
`register()`, `internal/probe`'s `Factory` and `internal/instance`'s
`Factory.New` all consume. Two-phase rule, mandatory: the new shape lands
beside the existing `prometheus.Collector` one, or every previously scaffolded
exporter stops compiling. The log policy is purely additive inside
`StatusTracker.Collect`: no signature change, no collector change, no two-phase.

---

## §8.3 Naming, labels, self-instrumentation

| Gap | Official | This plugin | Seen in | Verdict |
|---|---|---|---|---|
| `<name>_build_info` | `versioncollector.NewCollector("<name>")` in all four | `collectors.NewBuildInfoCollector()`, emits `go_build_info` (`mains/single/main.go.tmpl:202`) | **all four** | **adopted** |
| `project-scaffold.md:339` names a metric nothing emits | n/a | claims `@@EXPORTER_NAME@@_build_info`; `dashboards-and-alerts.md:256` says `go_build_info` | n/a | **adopted (doc)** |
| `probe_timeout_seconds` documented inconsistently | blackbox emits two probe meta-gauges (`prober/handler.go:78-85`) | code emits three (`probe.go.tmpl:369-371`); `prometheus-principles.md:87,94-95` says "these two only"; shipped `metrics.md` lists two | blackbox v0.28.0 | **already covered (metric) / adopted (doc)** |
| The `<x>_info` pattern is not taught | used by all four (node ~20 times; snmp `EnumAsInfo`; `ipmi_bmc_info`; blackbox `probe_tls_version_info`) | the OpenMetrics `info` *type* is named once (`prometheus-principles.md:214`); the pattern is never taught | **all four** | **adopted** |
| Handler instrumentation + inbound ceiling | node only (`node_exporter.go:159,165-167,192-195`) | neither | node v1.12.1 | **conflict, see above** |
| Operator-facing cardinality note in the generated repo | node's README (`README.md:180,187-193`) | the generated repo ships a contributor checklist item (`CONTRIBUTING.md.tmpl:178-180`); the depth is in `prometheus-principles.md:164-198`, which **never reaches the generated repo** — `scaffold.sh` copies nothing from `references/` | node v1.12.1 | **already covered** |

**Plugin better, recorded as such.** A bare `type` label is forbidden here
(`prometheus-principles.md:172`) and `ipmi_exporter` uses exactly that on two
metrics (`collector_ipmi.go:31-42`). `make docs-check` mechanically verifies
that no documented metric is unemittable; no reference has an equivalent, and
ipmi's `docs/metrics.md` is hand-maintained prose. Self-instrumentation
registers through the same seam as any other collector, so it lands on the
served registry; snmp uses `promauto` into the global registry and gets away
with it only because it never builds a custom one (`snmp_exporter/main.go:60-75,312`).
`RequestWait` pre-touches both `outcome` values at init so neither series
vanishes (`limiter.go.tmpl:47-58`); no reference does this for any `*Vec`.

**Cost.** `<name>_build_info` is purely additive alongside `go_build_info`: one
line in each of three mains, one import, zero new dependencies,
`prometheus/common` already direct in `go.mod.tmpl:10` and the Makefile already
injects the ldflags (`Makefile.tmpl:33-41`). Adopting it also makes
`project-scaffold.md:339` true rather than needing a doc-only retraction.

---

## §8.4 The `/probe` contract, modules, configuration structure

| Gap | Official | This plugin | Seen in | Verdict |
|---|---|---|---|---|
| Validate-and-exit mode | `--config.check` (`blackbox_exporter/main.go:53,106-109`), `--dry-run` (`snmp_exporter/main.go:49,243-246`) | all the validation exists but only on the path to binding the listener (`mains/multi/main.go.tmpl:119-134`) | blackbox v0.28.0, snmp v0.30.1 | **adopted** |
| A refused probe produces no exporter-side signal | `blackbox_module_unknown_total`; `snmp_request_errors_total` on every 400 *in the `/snmp` handler* (`snmp main.go:99,106,116,123,149,158`) | the allowlist 403 (`probe.go.tmpl:321-323`) and the unknown-module error (`:234`) are silent, no log and no metric. The no-credentials guard on the same 400 branch *does* log (`:264-265`) | blackbox v0.28.0, snmp v0.30.1 | **adopted** |
| Repeated `?target=` silently resolves to the first | snmp rejects it: `len(query["target"]) != 1` → 400 (`snmp_exporter/main.go:97-126`) | `Query().Get("target")` (`probe.go.tmpl:313`); `?target=a&target=b` probes `a` and returns 200 | snmp v0.30.1 only | **adopted** |
| `/config` endpoint | blackbox and snmp both YAML-dump the running config with no endpoint-specific auth (`blackbox main.go:280-291`, `snmp main.go:375-385`); both sit behind `web.ListenAndServe`, so `--web.config.file` covers them exactly as it covers every other route | absent | blackbox v0.28.0, snmp v0.30.1 | **rejected** |
| `?debug=true`, probe history, `/logs` | blackbox only (`prober/handler.go:136-140,247-267`; `main.go:226-278`) | absent | blackbox v0.28.0 | **rejected** |
| Per-scrape module concurrency | `--snmp.module-concurrency` (`snmp_exporter/main.go:50,214-216`) | sequential, bounded by a shared deadline (`probe.go.tmpl:334-339`) | snmp v0.30.1 only | **rejected** |
| Checksum short-circuit on unchanged reload | blackbox SHA-256s first (`config/config.go:125-138`) | full parse every time (`reload.go.tmpl:192-231`) | blackbox v0.28.0 | **rejected** |
| `--config.file` repeatable + glob | snmp glob-expands repeatable paths and merges them (`config/config.go:41-61`) | one path | snmp v0.30.1 only | **rejected** |
| `Module` defaults mechanism | three seed a default before decoding (blackbox `config.go:412-413`, snmp `config.go:141-142`, ipmi `config.go:192-193`); node has no module config at all | `Module` has two keys, both with meaningful zero values | blackbox, snmp, ipmi | **already covered** |

**Why, on the ones that matter.** Validate-and-exit is *adopted* because the
value is a CI gate before restarting a live exporter, every validation function
already exists and is already run at boot, and this is a flag plus an early
return, not new logic. The refused-probe signal is *adopted* because a 400 shows
up as `up == 0` for one Prometheus target but nothing aggregates it, so "a reload
deleted module `prod` and 400 scrape configs still name it" is invisible from
the exporter's own metrics; the 403 case is worse, since the allowlist is this
plugin's own hardening lever and a silently-rejected re-IP'd target has no signal
at all. Repeated `?target=` is *adopted* because a duplicated `__param_target`
from a mis-written relabel rule currently yields a **green scrape describing the
wrong machine**, which is the one failure mode monitoring cannot self-detect.

`/config`, `?debug=true` and `/logs` are all *rejected* on the same ground, and
it is a disclosure argument, not an authentication one: `/probe` already refuses
to put module names in a response body because a module name is topology, which
environments and tenants this exporter holds credentials for
(`probe.go.tmpl:258-262`, decided in
`2026-07-27-multi-target-module-credentials-design.md:106-109`). An
unauthenticated `/config` publishes the whole module table and contradicts that
rule from the other side. blackbox is a hand-driven testing tool whose landing
page is meant to be clicked; a scaffolded exporter is not.

**`--config.file` glob is *rejected*, not already covered.** The first draft
claimed it had been deferred in writing, citing
`2026-07-21-yaml-config-layer-design.md:496-497`. That note asks whether
`--config.file` should accept a **directory of fragments**, which is a different
question from snmp's repeatable-glob-and-merge; the word "glob" appears nowhere
in that document. So the honest verdict is a fresh rejection: snmp's merge
semantics are not obviously right either, since a later file's `modules:` map
merges key-by-key with no report of which file won a given key. The
directory-of-fragments question stays open where it was left.

**Plugin better, recorded as such.** Module-to-collector names are validated at
boot **and again on every reload** (`mains/multi/main.go.tmpl:299-337`);
blackbox's equivalent typo, `prober: htpp`, reloads successfully and breaks every
subsequent probe. A collector-construction failure is a 500, explicitly never
`probe_success 0`, so a configuration fault does not blame the target
(`probe.go.tmpl:346-351`); blackbox folds the same failure into `probe_success 0`
(`prober/http.go:458-462`). `probe_timeout_seconds` is emitted; no reference has
it. An http/https floor plus an optional `--probe.target-allowlist` validate the
target; **no reference validates `target` beyond non-empty at the request layer**
(`blackbox handler.go:87-91`, `ipmi main.go:60-61`, `snmp main.go:98`) —
blackbox's in-prober `url.Parse` is a format check that yields `probe_success 0`,
not a refusal. And this is the only one of the four with a test driving
concurrent `/probe` traffic against a concurrent reload
(`probe_test.go.tmpl:638-670,736-780`).

One superiority claim from the first draft is withdrawn: "no reference rebuilds
clients on reload" is literally true but hollow, because blackbox builds a client
*per probe* (`prober/http.go:458`) and so has no stale-client problem to solve.
This plugin's build-once-plus-`CloseIdleConnections` is a connection-pooling
advantage, not a correctness one.

**Cost.** Validate-and-exit and the refused-probe counter change no HTTP
contract. The counter must carry an outcome-only label: a module or target label
would reintroduce the topology leak and unbounded cardinality. Repeated
`?target=` **does change the contract**: a request that returns 200 today returns
400. In practice only a scrape config already probing the wrong target is
affected, but it is a behavioral change on already-scaffolded exporters and
belongs in a CHANGELOG rather than slipped in.

---

## §8.5 Mutating and operational endpoints, CLI-wrapper shape

| Gap | Official | This plugin | Seen in | Verdict |
|---|---|---|---|---|
| Secrets on a spawned process's command line | ipmi writes credentials through a `0600` FIFO with a crypto-random name and passes `--config-file <pipe>` (`freeipmi/freeipmi.go:92-99,126-148,161`) | nothing addresses it; `security-and-hardening.md:38-41` names the `Execute` boundary only to forbid *reporting* a credential | ipmi v1.10.1 | **adopted (doc)** |
| `/` answers 200 for any unmatched path | toolkit's landing page 404s a non-prefix path (`exporter-toolkit@v0.17.1/web/landing_page.go:127-131`), so node and snmp 404 a typo. blackbox and ipmi write their own HTML and have the same catch-all defect as this plugin | unconditional 200 + landing HTML (`mains/single/main.go.tmpl:229-232`) | node v1.12.1, snmp v0.30.1 | **adopted** |
| Startup warning when running as root | node warns if `user.Current().Uid == "0"` (`node_exporter.go:219-221`) | two startup posture warnings exist, neither checks the effective user | node v1.12.1 only | **adopted** |
| `/-/reload` ungated | all three that have it register it unconditionally on an unauthenticated port | behind `--web.enable-lifecycle`, default false (`mains/multi/main.go.tmpl:61-64,256-262`) | blackbox, snmp, ipmi | **rejected — plugin better** |
| pprof on the exporter port | three of four blank-import `net/http/pprof` | absent everywhere | node, blackbox, snmp | **rejected — plugin better** |
| `/healthz` vs `/-/healthy` | blackbox and snmp use `/-/healthy`; node and ipmi have no health endpoint | `/healthz`, rationale at `project-scaffold.md:374-378` | split 2/2 | **rejected** |
| Timer-driven auto-reload | blackbox only, opt-in, default off (`main.go:55-56,162-171`) | SIGHUP and `POST /-/reload` only | blackbox v0.28.0 | **rejected** |
| `--web.route-prefix` / `--web.telemetry-path` | route-prefix: blackbox only; telemetry-path: node and snmp | all paths hardcoded | 1/4 and 2/4 | **rejected** |

**Why, on the ones that matter.** Secrets-in-argv is *adopted* as documentation
only: the shipped CLI template is safe by construction, a fixed command with no
arguments (`code/cli/collector.go.tmpl:36`), but it is explicitly a starting
point, and the first thing anyone wrapping a real CLI does is add authentication
arguments. The one reference that faced this problem solved it deliberately, and
this plugin's security reference discusses the very same call site while being
silent on argv. The root warning is *adopted* as the same category as the
existing exposed-bind warning: visible, non-fatal, no default changes — and it is
more relevant here than in node_exporter, because the CLI flavor is the one that
invites `sudo`-style escalation, the pattern ipmi documents at
`docs/privileges.md:19-29`.

`/-/reload` gating and the pprof omission are both *rejected*, meaning **this
plugin is right and the majority of the references are wrong**. A generated
exporter is unauthenticated by default, which is precisely why
`warnIfExposedAndUnauthenticated` exists; shipping an ungated mutating endpoint
would be the one change that degrades the posture of an operator who configured
nothing. `/debug/pprof/heap` is a memory dump of a process that, on the `multi`
models, holds credentials, and `profile?seconds=60` is a free 60-second CPU tax
for anyone who can reach the port. Both belong in §4 as numbered deliberate
deviations.

**Plugin better, recorded as such.** **No reference drains its HTTP server.** All
four build a bare `&http.Server{}` and never call `Shutdown` on it
(`blackbox main.go:293`, `snmp main.go:387`, `ipmi main.go:177`,
`node_exporter.go:246`); node installs no signal handler at all, snmp and ipmi
handle SIGHUP only and never SIGTERM, and blackbox catches SIGTERM only to log
and return, abandoning in-flight probes. This plugin drains under a 5s budget in
all three mains. Its SIGHUP handler ends with `signal.Ignore(syscall.SIGHUP)`
rather than `signal.Stop`, so a SIGHUP arriving mid-drain is discarded instead of
killing the process at exit code 129. Reload is fail-closed and
prepare-then-commit; its outcome gauges are the *same pair* blackbox exposes
(`blackbox config/config.go:100-110`), which snmp, ipmi and node do not.

On systemd, the distinguishing claim is narrower than it first looks. **Three of
four ship a unit** — `node_exporter/examples/systemd/node_exporter.service`,
`snmp_exporter/examples/systemd/snmp_exporter.service`,
`ipmi_exporter/contrib/rpm/systemd/prometheus-ipmi-exporter.service` — and all
three already run under a dedicated user. What none of them carries is a single
sandboxing directive; this plugin's unit sets `NoNewPrivileges=true` active by
default plus a commented hardening block
(`systemd/@@EXPORTER_NAME@@.service.tmpl:61,69-80`).

**Cost.** The root warning is log-only. The `/` catch-all fix **changes shipped
default behavior**, `GET /anything` going from 200 to 404; nothing sane depends on
the old behavior but it belongs in a CHANGELOG. If the fix is switching to
`web.NewLandingPage`, note two consequences: the landing HTML changes visibly,
and `LandingConfig.Profiling` **must be set explicitly to a non-`"true"` value**,
or the page advertises `debug/pprof/heap` and `debug/pprof/profile` links
(`landing_page.go:107-109`) pointing at routes this plugin does not register —
which would undo the pprof rejection above through the back door.

---

## Deliberate deviations this report proposes for §4

Every *rejected* verdict above is a place where this plugin diverges on purpose
and should be recorded as a numbered deviation, so the next re-sync inherits the
reasoning instead of re-litigating it:

1. `/-/reload` gated behind `--web.enable-lifecycle` while three of four
   references ship it ungated.
2. No `net/http/pprof` on the exporter port, against three of four references.
3. No `/config`, `?debug=true`, probe history or `/logs`: a module name is
   topology, and the rule already applied to `/probe` response bodies applies
   from the other side too.
4. `/healthz` rather than `/-/healthy`, on split precedent, for the orchestrator
   that actually consumes it.
5. No per-request `collect[]` / `exclude[]` filtering: a node_exporter
   affordance for 60+ collectors, incompatible with the built-once registry the
   `register()` seam is designed around.

## Settled by the review pass

Three items the first draft could not determine turned out to be cheaply
determinable:

- **`golden-smoke.sh` has no 405 assertion.** The only occurrence of "405" is a
  comment at `:1002`. The 405-on-GET behaviour is covered by the unit test
  (`reload_test.go.tmpl:454-457`) and nowhere else.
- **`multi-instance` does have its own reload block**, guarded at `:1303`, with
  its own assertion 1 at `:1355`. The first draft only found the `multi` one.
- **`promconfig.NewClientFromConfig` does re-read CA and client-cert files**
  (`prometheus/common@v0.70.1/config/http_config.go:320,806,1427`), so
  `probe.go.tmpl:46-49`'s comment is accurate.

## What genuinely could not be determined

- Whether node_exporter's `success = 0` on `ErrNoData` — the *source-absent*
  case, not the empty one — is intentional or vestigial. The clones are shallow,
  so there is no blame history. It is the more interesting question now that the
  empty case is known to be handled separately: treating an absent source as a
  scrape failure is a debatable choice this plugin need not copy along with the
  rest of the shape.
- Whether the pprof omission here is a judgement or an absence. No trace in
  `security-and-hardening.md`, `SECURITY.md.tmpl`, or the reload design doc. The
  verdict stands either way, but a maintainer re-syncing could plausibly add
  pprof as "ecosystem parity" without realising it is a disclosure surface.
- Whether the `<x>_info` omission is a scope decision or an oversight. §4's
  twenty deviations do not mention info metrics.

## How this document was produced, and what that cost

Four parallel reading tranches, one per domain, fused into this report, then
handed to an adversarial reviewer that had not written any of it, with
instructions to break the headline claims and every universal negative first.

That pass was not a formality. It killed the original headline result outright:
the first draft asserted that `re-sync.md` §4.6 rested on a false premise, and
it was the draft that was wrong, having collapsed node_exporter's *source-absent*
and *legitimately-empty* paths into one. It also falsified three "the plugin does
it better" claims — the systemd unit, the reload gauges, and the client rebuild —
each disprovable by a single counter-example, and each of which would otherwise
have been recorded in §4 as a deliberate deviation resting on a false comparison.

The pattern is worth keeping: **the flattering claims and the universal negatives
were the least reliable parts of the draft**, precisely because nobody had an
incentive to challenge them.
