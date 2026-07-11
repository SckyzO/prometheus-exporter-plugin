# Multi-target scaffold — `/probe?target=` runtime

**Status:** design approved 2026-07-10 · sub-project 3b of the v0.3.0
"multi-target + live-probe" epic. Sub-project 3a (live-probe, discovery rung 4)
landed first and is out of scope here. Together 3a + 3b were tagged v0.3.0.

## 1. Goal

Let `/new-prometheus-exporter` scaffold a **multi-target** exporter — one that
probes *N* remote instances on demand via a `/probe?target=` endpoint — in
addition to the single-target exporter it produces today. This is Prometheus's
own [multi-target exporter pattern](https://prometheus.io/docs/guides/multi-target-exporter/):
the exporter is a fan-out proxy (like Blackbox / SNMP / IPMI exporters), not a
sidecar reporting on one fixed target.

The choice is a new `scaffold.sh` flag `--target-model <single|multi>`,
**defaulting to `single`**. A single-target scaffold is **behaviourally
unchanged**; the one structural change is a pure refactor — the startup
security helpers move to `security.go` (§3.1), same package, same behaviour,
now unit-tested. The golden matrix proves the single tree still builds and
passes `make check` identically.

### Non-goals

- **`cli`-flavor multi-target.** `multi` requires `--flavor http`; the pairing
  `--target-model multi --flavor cli` is rejected at scaffold time. The CLI
  flavor has no network target to vary (`NewExampleCollector(log, *timeout)`),
  and every ecosystem multi-target exporter is a network prober.
- **A `module` query parameter.** Blackbox/SNMP use `module` to pick a probe
  profile; this scaffold's collectors are already toggled by
  `--collector.<name>` flags, so a second selection axis is redundant for v0.3.0.
- **`/add-collector` multi-awareness.** Adding a collector to a multi-target
  exporter is a documented follow-up (see §3.6), the same "documented
  follow-up" treatment multi-target itself carried until now.
- **A `target` label on `RequestDuration`.** Per-target request timing is
  unbounded cardinality — the exact failure mode the multi-target pattern
  exists to avoid. `RequestDuration` stays outcome-labelled only.

## 2. Background — the current single-target-only scaffold

`exporter-architecture.md` §2 and `project-scaffold.md`'s "What this scaffold
does not do" both state the fork explicitly today: *"This scaffold produces
single-target exporters only … wiring `/probe`, per-request collector
construction, and the `target`/`module` parameters is documented follow-up
work."* `SKILL.md:44-47` and `discovery-inputs.md:170` carry the same
"documented follow-up" wording. This sub-project ships the follow-up as an
opt-in scaffold mode, and updates that wording from "not implemented" to
"opt-in via `--target-model multi`".

The runtime seam is already multi-target-ready in one crucial place:
`NewClient(target string, timeout)` (`code/http/client.go.tmpl:55`) takes the
target as a parameter. The Client layer needs **no change** — the entire fork
lives in `main.go` and a new `internal/probe/` package.

## 3. Design

### 3.1 Two entry-point models, selected at scaffold time

The fork is structural (a `/probe` handler that builds a fresh collector set
per request vs. a fixed registry built once), so it is resolved by selecting
one of two `main.go` templates — mirroring the existing `code/<flavor>/`
selection mechanism `scaffold.sh` already implements (move the chosen subtree
to its final path, `rm -rf` the staging tree):

```
assets/mains/single/main.go.tmpl   <- today's cmd/<name>/main.go, moved verbatim
assets/mains/multi/main.go.tmpl    <- new: /probe + /metrics + /healthz
```

`scaffold.sh --target-model <model>` moves `mains/<model>/main.go.tmpl` to
`cmd/@@EXPORTER_NAME@@/main.go`, then `rm -rf assets/mains/`. Default `single`
reproduces the current tree exactly.

**Shared, extracted, tested.** The startup security helpers `isLoopbackHost`
and `warnIfExposedAndUnauthenticated` (today inline in `main.go`) move to a new
`cmd/@@EXPORTER_NAME@@/security.go.tmpl` — same `package main`, shipped by
**both** models, and now unit-testable via `security_test.go.tmpl`. This is the
DRY seam that keeps the two `main.go` models from duplicating the ~40 lines of
exposure-warning logic.

### 3.2 The `/probe` handler (`internal/probe/`, multi-only)

A new package `internal/probe/` ships **only** in multi mode (single-mode
scaffolds `rm -rf internal/probe`, exactly as `--forge none` drops `.github`).
Placing the handler in its own package — not `package main` — is what makes the
SSRF-relevant logic testable in isolation, the same rationale as 3a's backbone
living outside `assets/`.

```go
// probe.Factory builds the per-target collector set. One line per collector;
// the multi main.go fills it at the // @@PROBE_FACTORIES@@ marker from the
// flavor's probe_factory.frag.
type Factory func(target string, timeout time.Duration) prometheus.Collector

type Handler struct {
    log       *logger.Logger
    factory   Factory
    allowlist []string      // empty => allow-any (see §3.4)
    timeout   time.Duration // --collector.example.timeout, the upper bound
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    target := r.URL.Query().Get("target")
    // 1. floor: must parse as an http/https URL (non-negotiable, always on)
    // 2. allowlist: 403 unless allowed (allowlist empty => allow-any)
    // 3. reg := prometheus.NewRegistry()          // fresh, per request
    // 4. timeout := clampScrapeTimeout(r, h.timeout) // §3.5
    // 5. tracker := collector.NewStatusTracker(h.log)
    //    tracker.Add("example", h.factory(target, timeout))
    //    reg.MustRegister(tracker)
    // 6. reg.MustRegister(probeSuccess, probeDuration) // per-request gauges
    // 7. set probeDuration; probeSuccess=1 iff every scoped collector's
    //    tracker success is 1; then promhttp.HandlerFor(reg,…).ServeHTTP
}
```

`StatusTracker` (`status_tracker.go.tmpl`) is **stateless across scrapes** (no
mutex, `NewStatusTracker(log)` + `Add`), so it is reused verbatim inside the
per-request registry — no change to that file.

### 3.3 Metric split — self-instrumentation on `/metrics`, targets on `/probe`

The multi main.go serves **both** endpoints (Blackbox parity):

- **`/metrics`** — the process-lifetime registry, unchanged: build info,
  Go/process collectors, and `RequestDuration`. This is the exporter watching
  *itself* (aggregate request timing, memory), scraped independently of any
  target.
- **`/probe?target=…`** — a fresh registry per request, exposing only that
  probe's series: `probe_success`, `probe_duration_seconds`, and the scoped
  collectors' own metrics.
- **`/healthz`** — unchanged (200 while the server is up).
- **`/`** — landing page links to both `/metrics` and a `/probe?target=…`
  example.

`probe_success` (gauge, 0/1) = 1 iff every collector constructed for this probe
reported a successful scrape (via its `StatusTracker` success signal);
`probe_duration_seconds` (gauge) = wall-clock of the whole probe. Both are
**un-namespaced** (§3.7).

### 3.4 SSRF posture — allow-any default + shipped allowlist + startup WARN

A `/probe?target=` endpoint is an SSRF primitive by construction: whoever
reaches it makes the exporter issue a request to an arbitrary host. The default
follows the ecosystem (Blackbox, SNMP, IPMI all accept any target by default
and rely on network isolation — verified against snmp_exporter's `/snmp` and
the Blackbox multi-target guide), which is also exactly the project's OSS
security philosophy: *don't deviate from the expected default behaviour, warn
at startup in an exposed posture, ship the hardening as an optional config key,
document the risk.*

- **Default = allow-any.** With no allowlist configured, `/probe` accepts any
  target that clears the floor. This is what makes the exporter work
  out-of-the-box with service discovery (a static allowlist fights dynamic SD —
  the very reason the ecosystem defaults to allow-any).
- **`--probe.target-allowlist` (repeatable, shipped, empty by default)** — the
  opt-in hardening lever. When non-empty, a target's host must match an entry
  or the probe returns `403`. Not dead code: it is the documented one-flag
  hardening path, like the project's "optional, commented-by-default config
  keys" pattern.
- **Startup WARN when the allowlist is empty:** one visible, non-fatal line —
  *"/probe accepts any target; anyone who can reach this exporter can make it
  issue requests to arbitrary hosts; set --probe.target-allowlist to restrict."*
  Never refuses to start (same rule as `warnIfExposedAndUnauthenticated`).
- **Non-negotiable floor (always on, not disableable):** the target must parse
  as an `http`/`https` URL. `file://`, `gopher://`, and a bare hostname without
  scheme are rejected `400`. This bounds the SSRF surface to HTTP even in
  allow-any mode.

Testable security property (anti-lie analog to 3a's redaction test): *a target
that fails the floor is never fetched, and a target absent from a non-empty
allowlist returns 403 without a fetch.*

### 3.5 Scrape-timeout propagation

Prometheus sends `X-Prometheus-Scrape-Timeout-Seconds` on every scrape. The
handler uses `min(header, --collector.example.timeout)` as the per-request
`Client` timeout, so a probe never outruns Prometheus's own deadline and never
exceeds the operator's configured ceiling. This needs **no change to
`collector.go.tmpl`** — the timeout is carried by `NewClient(target, timeout)`,
which the factory already builds per request.

### 3.6 Flavor wiring — the multi-only factory frag

Single mode's wiring is unchanged: `code/http/wiring/{client_init,registry}.frag`
inject `--collector.example.target`/`.timeout` flags and a `register(...)` call.

Multi mode needs different wiring, because in multi there is **no fixed
`--collector.example.target` flag** (the target comes from the query param) and
collectors are built per request, not `register()`-ed once. A new multi-only
frag supplies the factory:

```
assets/code/http/wiring/probe_factory.frag   (multi-only)
```
```go
factory := func(target string, timeout time.Duration) prometheus.Collector {
    return collector.NewExampleCollector(log, collector.NewClient(target, timeout))
}
```

`scaffold.sh` injects `probe_factory.frag` at the multi main.go's
`// @@PROBE_FACTORIES@@` marker (and `client_init.frag`'s `--collector.example.timeout`
flag, minus the `.target` flag) using the same anchored `sed r` mechanism as
today's two markers. The single main.go has no `// @@PROBE_FACTORIES@@` marker;
the multi main.go has no `// @@COLLECTOR_REGISTRY@@` for the example collector's
per-target build (it keeps one only for the self-instrumentation
`http_client_requests` collector on `/metrics`).

**`/add-collector` stays single-only for 3b.** Run against a multi-target
scaffold it refuses cleanly with a message pointing at the manual procedure;
the scaffold's own `docs/` explain adding a collector by hand (one factory line
at `// @@PROBE_FACTORIES@@`). Teaching `/add-collector` to detect the model and
insert a factory vs. a `register()` is a separate follow-up — it would double
3b's surface for an exporter shape that is almost always single-collector.

### 3.7 Metric naming — `probe_success` / `probe_duration_seconds` un-namespaced

Every multi-target exporter in the ecosystem (Blackbox, SNMP) emits
`probe_success` and `probe_duration_seconds` **without** an application prefix,
and every multi-target dashboard/alert in the wild queries those exact names
(confirmed against the Prometheus multi-target guide's own metric output). The
scaffold matches the ecosystem here, which means a **deliberate, documented
exception** to `prometheus-principles.md`'s `namespace_subsystem_name` rule.
The exception is commented at the metric declarations and noted in
`prometheus-principles.md` / `exporter-architecture.md`. Nothing enforces the
namespace rule mechanically — `docs_check_test` checks that documented names
match code, not that they carry the namespace — so `make docs-check` stays
green as long as the scaffold's `metrics.md` documents these two names.

## 4. Files touched

### New (assets — shipped into scaffolds)
1. `assets/mains/single/main.go.tmpl` — today's
   `cmd/@@EXPORTER_NAME@@/main.go.tmpl`, moved verbatim (git-move; content
   unchanged except the security helpers extracted per #3).
2. `assets/mains/multi/main.go.tmpl` — new multi entry point (§3.1-3.5): `/probe`
   + `/metrics` + `/healthz` + `/`, `--probe.target-allowlist` flag, startup
   WARN, `// @@PROBE_FACTORIES@@` marker.
3. `assets/cmd/@@EXPORTER_NAME@@/security.go.tmpl` — extracted `isLoopbackHost`
   + `warnIfExposedAndUnauthenticated`, shipped by both models.
4. `assets/cmd/@@EXPORTER_NAME@@/security_test.go.tmpl` — unit test for the
   extracted helpers (fills a current coverage gap).
5. `assets/internal/probe/probe.go.tmpl` — the `Handler`/`Factory`, allowlist +
   floor validation, `probe_success`/`probe_duration_seconds`, timeout clamp.
   Multi-only (single-mode `rm -rf internal/probe`).
6. `assets/internal/probe/probe_test.go.tmpl` — the security unit test (§3.4
   testable property) + timeout-clamp test.
7. `assets/code/http/wiring/probe_factory.frag` — multi-only factory snippet
   (§3.6).

### Modified (assets)
8. `assets/scaffold.sh` — `--target-model <single|multi>` flag (default
   `single`); main-model selection + `rm -rf mains/`; multi⇒http validation;
   conditional `rm -rf internal/probe` in single; `// @@PROBE_FACTORIES@@`
   marker injection + residual-sentinel exemption for it.
9. `assets/docs/configuration.md.tmpl` — document `--probe.target-allowlist`,
   the SSRF posture, and the `/probe` endpoint (multi only; conditional prose).
10. `assets/SECURITY.md.tmpl` — SSRF section for multi-target exporters.
11. `assets/README.md.tmpl` — `/probe` usage + `scrape_configs` relabeling
    example (multi only).
12. `assets/code/http/metrics.md.tmpl` — document `probe_success` /
    `probe_duration_seconds` (multi) so `make docs-check` stays truthful.

### Modified (plugin knowledge — never shipped)
13. `skills/prometheus-exporter/references/exporter-architecture.md` §2 —
    "single-target only / documented follow-up" → "opt-in `--target-model multi`
    (http only)"; the naming exception (§3.7).
14. `skills/prometheus-exporter/references/project-scaffold.md` — "What this
    scaffold does not do" updated; describe the two-model seam.
15. `skills/prometheus-exporter/references/prometheus-principles.md` — record
    the `probe_success` naming exception.
16. `skills/prometheus-exporter/references/discovery-inputs.md:170` — brief's
    Target-model line: drop "(documented follow-up)".
17. `skills/prometheus-exporter/SKILL.md:44-47` — multi-target now scaffolded
    (opt-in), not "documented follow-up".
18. `commands/new-prometheus-exporter.md` — offer `--target-model`; refuse
    `multi`+`cli`; pass it to `scaffold.sh`.
19. `commands/add-collector.md` — refuse cleanly on a multi-target scaffold,
    pointing at the manual procedure.
20. `ROADMAP.md:52` — "Advanced multi-target support" → basic multi-target
    shipped; note `/add-collector` multi + `module` as remaining.
21. `CHANGELOG.md` — `[Unreleased]` `### Added` entry.

### New (plugin tests — never shipped)
22. `test/scaffold_test.sh` (or a new `scaffold_multitarget_test.sh`) — assert
    single is unchanged (diff-nul against a known tree), multi ships
    `internal/probe` + `/probe`, single does not; multi+cli rejected.
23. `test/golden-smoke.sh` — new `http × multi` cell: scaffold → `make build` +
    `make check` + `promtool check metrics` on a captured `/probe` sample.

## 5. Testing strategy

Two non-regressions get failing-first tests: **single is unchanged** and **the
SSRF floor/allowlist bites**.

- **Single unchanged behaviour:** a scaffold_test assertion that
  `--target-model single` (and the default, no-flag) produce a tree with no
  `internal/probe`, no `/probe` in `main.go`, `security.go` present, and the
  helpers absent from `main.go`. The golden matrix's existing `http` cells
  already build/check the single tree; adding the multi cell must not perturb
  them. (Strict byte-for-byte parity does not hold — the security-helper
  extraction is a deliberate refactor — so the guard is behavioural + layout,
  not a diff against the old tree.)
- **SSRF floor (unit, `internal/probe`):** a target of `file:///etc/passwd`
  and a bare `localhost:9100` (no scheme) → handler returns `400`, and the
  factory is **never invoked** (a recording fake factory asserts zero calls).
  RED first: without the floor check the fake factory is called.
- **Allowlist (unit):** allowlist `["node1"]`; `target=http://node2:9100` →
  `403`, factory not called; `target=http://node1:9100` → `200`. Empty
  allowlist ⇒ any http target reaches the factory.
- **Timeout clamp (unit):** header `X-Prometheus-Scrape-Timeout-Seconds: 30`
  with `--collector.example.timeout=5s` ⇒ effective `5s`; header `2` ⇒ `2s`.
- **security_test.go (unit):** `isLoopbackHost` truth table +
  `warnIfExposedAndUnauthenticated` emits/suppresses correctly — the coverage
  the extraction newly enables.
- **Golden-smoke `http × multi`:** the scaffolded multi exporter builds, passes
  `make check`, and its `/probe?target=<httptest>` output passes
  `promtool check metrics`, with `probe_success`/`probe_duration_seconds`
  present.

## 6. Non-regression guarantees

- `--target-model single` (and the flag's absence) reproduce today's
  single-target behaviour; the only tree change is the security-helper refactor
  (§3.1, covered by `security_test.go`). The golden `http`/`cli` ×
  `none`/`github` matrix still builds and checks identically, and the new multi
  cell is additive.
- `NewClient`, `collector.go.tmpl`, `status_tracker.go.tmpl`, `execute.go.tmpl`
  are **untouched** — no scaffolded single-target exporter changes at runtime.
- The CLI flavor is untouched and cannot enter multi mode (rejected at scaffold
  time), so no cli scaffold is affected.
- `test/zero-source-grep.sh` runs before every commit; all new shipped surfaces
  stay free of the reference project's name and the maintainer's handle.

## 7. Open questions / assumptions

- **`probe_success` aggregation:** defined as "1 iff every scoped collector
  succeeded". For the single bundled `example` collector this is unambiguous;
  the plan pins the exact `StatusTracker`→handler success signal (the tracker
  today emits success as a metric — the handler either reads it back from the
  gathered families or the factory returns a small status the handler
  aggregates). Bias: a partial failure yields `probe_success 0`.
- **Landing-page `/probe` example** uses a placeholder target
  (`http://localhost:9100`); harmless, purely illustrative.
- **Allowlist match semantics** (host exact-match vs. host:port vs. suffix) is
  pinned in the plan; default proposal: match on URL host (port-insensitive),
  the least-surprising for a fleet of `host:9100` targets.

## 8. Out of scope

`/add-collector` multi-awareness, a `module` parameter, cli multi-target, and a
per-target `RequestDuration` label — all deferred (§1 Non-goals), filed on the
ROADMAP as the remaining multi-target work after v0.3.0.
