# Re-sync: reference → template mapping

> This is the one file under `docs/` — besides the design spec and the
> implementation plan — that names the production exporter this plugin's
> templates were derived from. It is deliberately excluded from
> `test/zero-source-grep.sh`'s scan (see that script's exclude set, and the
> root `CLAUDE.md`'s "Zero-source-mention rule" and "Re-sync rule", both of
> which point here by name instead of naming anything themselves). Every
> other shipped file — `SKILL.md`, `references/`, `assets/`, `commands/`,
> `agents/`, the root `README.md`/`CLAUDE.md` — must stay generic and must
> never name the source: the knowledge they teach stands on `prometheus.io`'s
> own authority, not on "this was copied from a specific project."

## 1. The reference

- **Repository:** `slurm_exporter`, a production Prometheus exporter for the
  Slurm workload manager (module path `github.com/sckyzo/slurm_exporter`),
  read throughout this plugin's v0.1 build at
  `~/Dev/work/apps_repo/exporters/slurm_exporter/slurm_exporter/` —
  **read-only**, never modified, never committed to. Its `git status` stayed
  clean through all 23 implementation tasks (verified again at the end of
  Task 23).
- **License:** GPL-3.0. This matters operationally: the plugin's own
  `LICENSE` (Apache-2.0) and the `licenses/LICENSE-apache-2.0.txt` template
  were **not** copied from the reference — they come from
  `prometheus/client_golang`'s vendored Apache-2.0 text, a dependency both
  projects already share.
- **Maintainer handle:** `SckyzO` — the same person maintains both
  repositories. It legitimately appears in *this* plugin's own
  `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
  `README.md`, and root `CLAUDE.md` (self-attribution, not a leak). The stock
  Apache-2.0 `LICENSE` keeps its bracketed appendix placeholder unfilled per
  convention, so the handle does not appear there. It must never appear under `skills/`,
  `commands/`, `agents/`, or `assets/` — checked by
  `test/zero-source-grep.sh`'s HANDLE-GREP (blocking: exit 1 on a match) — and
  templates always attribute the *generated* exporter to `@@OWNER@@`, a
  placeholder for whoever runs `/new-prometheus-exporter`, never to this
  handle.
- **Why derive from a real repository at all:** design spec §11 states the
  constraint plainly — templates are derived from the real files, never
  reproduced from memory, so they inherit real, load-bearing decisions (a
  documented CVE dependency bump, an exact `exporter-toolkit` call shape,
  a real container digest) instead of a plausible-looking guess.

## 2. Source → template mapping

Legend: **[D]** derived (a generalized copy of a real reference file) ·
**[N]** new (no reference equivalent — built from Prometheus principles,
context7 research, or plugin-specific tooling).

### 2.1 Flavor-agnostic core (mirror-layout final paths, Task 4)

| Reference | Template | Origin | Transform |
|---|---|---|---|
| `cmd/slurm_exporter/main.go` (280 l.) | `assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl` | [D] | The hardcoded 15-collector map became the lazy `register()` closure seam + `// @@CLIENT_INIT@@`/`// @@COLLECTOR_REGISTRY@@` markers (§4.2); all Slurm-only flags/collectors stripped; `server.Shutdown()` added for real (§4.7 — the reference's own signal handling never actually drained the HTTP server); `promhttp.ContinueOnError` added (§4.7); the exposed-bind startup warning added (§4.12) |
| `internal/collector/status.go` (82 l.) | `assets/internal/collector/status_tracker.go.tmpl` | [D] | `slurm_exporter_collector_*` → `@@NAMESPACE@@_exporter_collector_*`; made count-based, not panic-only (§4.6) |
| `internal/logger/logger.go` (144 l.) | `assets/internal/logger/logger.go.tmpl` | [D] | Logic byte-identical; package doc comment added (lint fix — the file had zero Slurm references to begin with) |
| `go.mod` / `go.sum` | `assets/go.mod.tmpl` / `assets/go.sum` | [D] | Module path → `@@MODULE_PATH@@`; dependency versions copied verbatim, not re-resolved, to preserve the reference's own `golang.org/x/crypto` CVE bump; `testify` dropped (§4.10) |
| — | `assets/internal/collector/docs_check_test.go.tmpl` | [N] | No reference equivalent — the reference's own docs are hand-maintained and unchecked (§4.8) |

### 2.2 HTTP flavor (`code/http/`) — entirely new (Task 5)

The reference has no HTTP collector: every Slurm collector wraps a CLI. Built
from `references/collector-pattern.md`'s five-piece principle plus
`prometheus/client_golang` itself (context7-verified custom `Collector`,
`NewDesc`, `MustNewConstMetric`, `httptest`), not derived from any reference
file: `client.go.tmpl`, `collector.go.tmpl`, `collector_test.go.tmpl`,
`wiring/{client_init,registry}.frag`, `metrics.md.tmpl`,
`testdata/example.json` — all **[N]**.

### 2.3 CLI flavor (`code/cli/`, Task 8)

| Reference | Template | Origin | Transform |
|---|---|---|---|
| `internal/collector/execute.go` (135 l.) | `assets/code/cli/execute.go.tmpl` | [D] | `var Execute` kept mockable; signature changed to `func(ctx, name, args...)` (ctx replaces the logger parameter — `Execute` never logs, callers do); timeout moved from a package-level `commandTimeout`/`SetCommandTimeout` pair to a per-collector `time.Duration` |
| `internal/collector/cpus.go` (88 l., the simplest single-command collector) | `assets/code/cli/collector.go.tmpl` | [D] (structural shape only) | Slurm `sinfo` parsing replaced by a generic `key value` line parser; duplicate-key rejection added fail-closed (fix pass) |
| `internal/collector/cpus_test.go` + `cpus_collector_test.go` | `assets/code/cli/{parser_test.go,collector_test.go}.tmpl` | [D] (structural shape only) | Same fixture-driven triad shape; fixture replaced with anonymous `foo 1`/`bar 2` data |
| — | `assets/code/cli/wiring/{client_init,registry}.frag`, `metrics.md.tmpl` | [N] | No reference equivalent — the wiring-frag mechanism is plugin-specific (§4.4) |

### 2.4 Container-first tooling (Task 6)

| Reference | Template | Origin | Transform |
|---|---|---|---|
| `Makefile` | `assets/Makefile.tmpl` | [D] | **The 4 corrections — §3.** |
| `.golangci.yml` | `assets/.golangci.yml` | [D] | De-identified; `@@MODULE_PATH@@` substituted into `goimports.local-prefixes`; `gosec.excludes: [G304]` narrowed from global to test-files-only (§4.11) |
| `scripts/docker/tools/Dockerfile` | `assets/scripts/docker/tools/Dockerfile.tmpl` | [D] | Same `golang:1.26.4-alpine` digest pin; `git config --system --add safe.directory '*'` added (§4 — needed once a scaffolded repo has a real `.git`) |
| `scripts/docker/tools/{goreport.sh,deps-report.sh}` | same names under `assets/scripts/docker/tools/` | [D] | One string fix each (`slurm_exporter-tools` → `@@EXPORTER_NAME@@-tools`); otherwise byte-identical |

### 2.5 Operator docs (Task 10)

| Reference | Template | Origin | Transform |
|---|---|---|---|
| `README.md` | `assets/README.md.tmpl` | [D] | Restructured with a Security & supply-chain section; cosign recipe points at GHCR only (§4.17) |
| `CONTRIBUTING.md` | `assets/CONTRIBUTING.md.tmpl` | [D] | Definition of Done gains a `make docs-check` step; static-metric-name and anonymization rules added |
| `SECURITY.md` | `assets/SECURITY.md.tmpl` | [D] | De-personalized; the direct source for `references/security-and-hardening.md`'s universal rules |
| `CHANGELOG.md` | `assets/CHANGELOG.md.tmpl` | [D] | Keep-a-Changelog skeleton only |
| `docs/configuration.md` | `assets/docs/configuration.md.tmpl` | [D] | exporter-toolkit sections kept; Slurm flags replaced by the example collector's |
| `docs/development.md` | `assets/docs/development.md.tmpl` | [D] | Make-targets table kept in lockstep with the real `Makefile.tmpl` |
| `docs/release-process.md` | `assets/docs/release-process.md.tmpl` | [D] | tag → GoReleaser → RC → CI flow kept; the reference's `master`-only branch naming was carried over and not yet reconciled with `main` (open concern, §4.19) |
| `docs/validation-checklist.md` | `assets/docs/validation-checklist.md.tmpl` | [D] | Command/Expected/If-fails structure kept |
| `docs/metrics.md`, `docs/metrics-examples.md` | *(not templated)* | [N] | Generated per-flavor at scaffold time (`code/{http,cli}/metrics.md.tmpl`) and enforced live by `make docs-check` instead of hand-maintained (§4.9) |
| `docs/roadmap.md` | *(dropped)* | — | Superseded by the plugin's own root `ROADMAP.md` — plugin governance, not exporter governance (design spec §7) |

### 2.6 Observability (Task 12)

| Reference | Template | Origin | Transform |
|---|---|---|---|
| `monitoring/prometheus/alerts.yml` | `assets/monitoring/prometheus/alerts.yml.tmpl` | [D] | Only the two `StatusTracker` metrics plus `up` are active (common to both flavors); the flavor-specific business alert ships as a *commented* example — an uncommented one would lie for whichever flavor doesn't emit that metric |
| `monitoring/prometheus/rules.yml` | `assets/monitoring/prometheus/rules.yml.tmpl` | [D] | The reference's `rate(counter)/(rate(counter)>0)` shape is kept as a *commented* example; the one active rule uses a gauge-based guard instead, since gauges are the only metric common to both flavors |
| `monitoring/grafana/dashboards/08-slurm-health.json` + `09-slurm-exporter-perf.json` | `assets/monitoring/grafana/health-dashboard.json.tmpl` | [D] | Merged into one health dashboard; every Slurm-specific panel dropped; `by (job, instance)` aggregation added (fix pass, multi-target triage) |
| `monitoring/README.md` | `assets/monitoring/README.md.tmpl` | [D] | Prometheus-core/Grafana-extension boundary language kept |

### 2.7 Packaging (Task 13)

| Reference | Template | Origin | Transform |
|---|---|---|---|
| `Dockerfile` | `assets/Dockerfile.tmpl` | [D] (mechanism changed) | Reference is single-stage, COPY-only (expects a binary pre-staged externally); template is **multi-stage, builds from source** — deliberate deviation, §4.16 |
| `Dockerfile.minimal` | `assets/Dockerfile.minimal.tmpl` | [D] (mechanism changed) | Same deviation; runtime base changed `cc-debian12` → `distroless/static` (the binary is already fully static) |
| `docker/docker-compose.yml` / `docker-compose.minimal.yml` | `assets/docker-compose.yml.tmpl` / `docker-compose.minimal.yml.tmpl` | [D] | Same 4 hardening directives kept; Slurm volume mounts dropped; distinct `container_name` per variant (fix pass) |
| `.dockerignore` | `assets/.dockerignore` | [D] (content inverted) | The reference's list *excludes* `cmd/`/`internal/`/`go.mod` (correct for a COPY-only build); the template's from-source build needs the opposite — it keeps those and excludes build output instead |
| `systemd/slurm_exporter.service` | `assets/systemd/@@EXPORTER_NAME@@.service.tmpl` | [D] (hardening added) | The reference ships **zero** hardening directives; the template adds `NoNewPrivileges=true` active by default plus a large commented block (`ProtectSystem`, etc.) |

### 2.8 Release & host-agnostic CI (Task 14)

| Reference | Template | Origin | Transform |
|---|---|---|---|
| `.goreleaser.yaml` | `assets/.goreleaser.yaml.tmpl` | [D] | Version bumped to the then-current GoReleaser release (§4.19); `sboms.args` made explicit (§4.18 — a real reference bug, fixed, not just a style choice); `extra_files` added (the reference's `dockers_v2` assumes a pre-staged binary; this Dockerfile builds from source); registry narrowed to GHCR only (§4.17); `tolower` wraps `@@OWNER@@`/project name (case-sensitivity guard) |
| `.goreleaser.dev.yaml` | `assets/.goreleaser.dev.yaml.tmpl` | [D] | Near-direct; snapshot-only, no Docker/signing/SBOM, matching the reference's own dev/prod split |
| `.github/workflows/ci.yml` | `assets/.github/workflows/ci.yml.tmpl` | [D] (simplified) | The reference re-implements lint/test as bespoke steps even though its own `make check` exists; the template collapses to `make check` + `make race`, with no `actions/setup-go` at all (fully containerized) |
| `.github/workflows/release.yml` | `assets/.github/workflows/release.yml.tmpl` | [D] | `make check` gate added ahead of release; Docker Hub login dropped |
| `.github/workflows/dev-release.yml` | `assets/.github/workflows/dev-release.yml.tmpl` | [D] | Near-direct |
| `.github/workflows/govulncheck.yml` | `assets/.github/workflows/govulncheck.yml.tmpl` | [D] | Calls `make vuln` (containerized) instead of a raw host `go install .../govulncheck@latest` |
| `.github/workflows/trivy-scan.yml` | `assets/.github/workflows/trivy-scan.yml.tmpl` | [D] (simplified) | The reference's "stage a binary in a `golang:alpine` container" step is dropped — this Dockerfile builds from source, so `build-push-action` needs nothing else |
| `.github/workflows/scorecard.yml` | `assets/.github/workflows/scorecard.yml.tmpl` | [D] | Near-direct |
| `.github/{dependabot.yml,CODEOWNERS}` | `assets/.github/{dependabot.yml,CODEOWNERS}.tmpl` | [D] | The `stretchr` dependabot group dropped (no testify, §4.10); timezone de-personalized to UTC |
| `.github/ISSUE_TEMPLATE/*`, `pull_request_template.md` | same names under `assets/.github/` | [D] | Bodies rewritten to be data-source-generic instead of Slurm-specific |
| `.github/workflows/{docker-cleanup,dockerhub-readme,docker-refresh,goreportcard}.yml`, `.github/FUNDING.yml` | *(dropped)* | — | Slurm-specific extras (a second registry's maintenance, funding links) with no generic equivalent; `make report` already covers the offline goreportcard use case |
| — | `assets/licenses/{LICENSE-apache-2.0,LICENSE-mit,LICENSE-gpl-3.0,LICENSE-bsd-3}.txt` | [N] | **Not** sourced from the reference, whose own `LICENSE` is GPL-3.0 only — Apache-2.0 from `client_golang`'s vendored copy, the other three from their canonical SPDX/GNU texts |

### 2.9 Everything else — new, not file-derived

No reference equivalent exists for any of these; they are plugin-specific
tooling, or knowledge synthesized from the design spec plus the already-derived
templates above:

- **`skills/prometheus-exporter/assets/scaffold.sh`** — the `@@VAR@@`/`sh`+`sed`
  templating engine itself (design spec §5bis), informed by context7 research
  into `cookiecutter` and `hay-kot/scaffold`, both of which need per-file
  escaping or custom delimiters to survive this asset tree's own legitimate
  `{{ }}` (GoReleaser), `${{ }}` (GitHub Actions), and `${ }` (Docker/compose)
  syntax — the reason for a brace-free sentinel instead of a template engine.
- **`.claude-plugin/{plugin.json,marketplace.json}`**, root
  `CLAUDE.md`/`README.md`/`ROADMAP.md`/`TODO.md`/`CHANGELOG.md`/`LICENSE` —
  this plugin's **own** governance, not the generated exporter's. De-personalized
  from the maintainer's private engineering principles (design spec §7bis's
  ENCODÉ/EXCLU split) — never copied from the reference's own root files, which
  govern a different repository, for different maintainers and audiences.
- **`commands/new-prometheus-exporter.md`, `commands/add-collector.md`,
  `agents/exporter-reviewer.md`, `skills/prometheus-exporter/SKILL.md`** — the
  four executable/routing components. They consume the templates in §2.1–2.8
  (e.g. `add-collector.md` reads `code/<flavor>/collector.go.tmpl` directly and
  knows the exact identifiers to rename) but are workflow logic, not derived
  text.
- **`skills/prometheus-exporter/references/*.md`** (10 files) — written by
  reading the *already-derived templates* directly (`main.go.tmpl`,
  `Makefile.tmpl`, `.goreleaser.yaml.tmpl`, etc. — confirmed per-file in every
  Task 19–21 report), not by re-reading the reference repository a second
  time. **This matters for re-derivation (§6):** refresh `assets/` from the
  reference first, then refresh `references/*.md` to match the *updated
  templates* — never point a references rewrite at the reference repository
  directly, or the references layer and the templates layer can silently
  diverge.
- **`internal/collector/docs_check_test.go.tmpl`** (`make docs-check`) — no
  reference equivalent; the reference's own `docs/metrics.md` is hand-maintained
  and unchecked (§4.8, §4.9).
- **`test/*.sh`** (scaffold unit tests, the golden smoke matrix, the zero-source
  grep) and **`.github/workflows/plugin-ci.yml`** — this plugin's own
  test/CI harness, never shipped inside a generated exporter.

## 3. The four Makefile corrections

`assets/Makefile.tmpl` is not a straight de-identified copy of the reference's
`Makefile`. Design spec §6.4 and the v0.1 plan (Task 6) call for four
deliberate corrections on top of the derivation.
`references/makefile-and-tooling.md` teaches these as generic, checkable
properties of any container-first Makefile — "four things worth checking" —
without naming the reference.

| # | Correction | Reference behavior (before) | Template behavior (after) |
|---|---|---|---|
| 1 | **`build` containerized too** | `build` ran `CGO_ENABLED=0 go build` directly on the host, while `test`/`vet`/`lint`/`race`/`vuln` all went through `$(IN_TOOLS)` — silently contradicting the reference's own header comment ("no Go toolchain needed") | `build` now runs through the identical `$(IN_TOOLS)` wrapper as every other tooling target |
| 2 | **`setup` target deleted** | A `setup` target ran `wget \| tar` to install a host-local Go toolchain under `./go/`, contradicting container-first and carrying an ongoing supply-chain/maintenance cost | Deleted entirely, along with its now-dead `GOPATH`/`GOPATH_ENV`/`GOFILES` variables (confirmed unused by anything else via grep, not assumed) |
| 3 | **Single Go-version source of truth** | `GO_VERSION ?= $(if $(GO_INSTALLED_VERSION),...,1.22.2)` — a host-side fallback that could silently drift from whatever the tools image actually pins | Removed; the version lives in exactly one place, `scripts/docker/tools/Dockerfile`'s `FROM golang:1.26.4-alpine@sha256:...`, matching `go.mod.tmpl`'s `toolchain go1.26.4` |
| 4 | **`lint`/`report` overlap documented** | No comment; a reader could mistake the overlap (gofmt/vet/ineffassign/misspell covered by both `lint` and `report`) for redundancy | A comment directly above `report` explains the distinct purposes: `lint` (part of `check`) is a pass/fail **gate**; `report` is a goreportcard-style **grade**, tolerant of a few findings as long as the average stays ≥ B |

## 4. Deliberate deviations

Compiled from `progress.md`'s "Standing decisions" and the individual task
reports/fix passes. Numbered for cross-reference from §2's tables.

1. **No `execute.go` in the common core.** `var Execute` and its exec-timing
   self-instrumentation live only in `code/cli/` — keeping it in the
   flavor-agnostic core would couple a CLI-only concern into a layer both
   flavors share. HTTP's own request-timing lives in `code/http/client.go`
   instead. (Task 4/8; spec deviation #1)
2. **Flavor seam = a lazy `register()` closure, not a plain value.** kingpin
   flags must be declared before `kingpin.Parse()` runs, but a collector
   factory needs a `*Logger` (and, for HTTP, a client) built only *after*
   `Parse()` — an eagerly-evaluated collector value would silently bake in
   the wrong log level or target the instant a user overrides either flag.
   `register(name string, newFn func() prometheus.Collector, enabledByDefault bool)`
   defers construction to a fixed, non-templated loop after `Parse()`. (Task 4)
3. **Two marker comments, not a mapping table.** `// @@CLIENT_INIT@@` and
   `// @@COLLECTOR_REGISTRY@@`, both narrowly exempted from `scaffold.sh`'s
   residual-sentinel guard (an exact two-string exception, not a growing
   list), both anchored (`^[[:blank:]]*// @@MARKER@@[[:blank:]]*$`) so
   `register()`'s own doc-comment prose mention of a marker is never mistaken
   for an injection point. (Task 4/5)
4. **Wiring = per-flavor `.frag` files, not one shared `wiring.go.tmpl`.**
   `code/<flavor>/wiring/{client_init.frag,registry.frag}`, spliced into
   `main.go` by an anchored `sed ... r frag`, then deleted. A `.frag` is a
   bare statement/closure body meant to be spliced mid-function, not a
   standalone compilable Go file — this supersedes the plan doc's original,
   pre-implementation description of a single `wiring.go.tmpl`. (Task 5)
5. **Self-instrumentation is exposed by registering it through the same
   seam**, not via a separate `RegisterExecMetrics`/`RegisterCacheMetrics`
   hook. `RequestDuration` (http) / `CommandDuration` (cli) are plain,
   non-`promauto` `*prometheus.HistogramVec` values, registered exactly like
   any other collector: `register("http_client_requests", func() prometheus.Collector { return collector.RequestDuration }, true)`.
   This is also a bug fix: the first implementation's `promauto` version
   registered into `prometheus.DefaultRegisterer`, which this exporter's
   custom, actually-served registry never reads. (Task 5 fix pass, Task 8)
6. **`StatusTracker` is count-based, not panic-only.**
   `_exporter_collector_success{collector}=0` iff the wrapped `Collect` call
   emits **zero metrics** — not only on a `recover()`'d panic — closing a real
   gap where a collector could silently emit nothing and still report
   success. Paired with a hard collector-authoring rule taught in
   `collector-pattern.md`: on a successful-but-empty scrape, always emit
   metrics with zero *values*, never zero metrics. A documented, deferred-to-v0.2
   wart: a collector that legitimately has zero series to report reads as a
   false-positive failure — the gold-standard fix (node_exporter-style
   `Update(ch) error` collectors) is noted as future work, not done here.
   (Task 5 fix pass)
7. **`promhttp.ContinueOnError` on the `/metrics` handler.** The implicit
   default (`HTTPErrorOnError`) means one collector's `Gather` error (e.g. a
   duplicate label set) 500s the *entire* scrape, discarding every other
   collector's otherwise-good metrics — defeating `StatusTracker`'s whole
   purpose at the HTTP layer. Also motivated the graceful `server.Shutdown()`
   goroutine added to `main.go.tmpl`: the reference's own signal handling only
   ever cancelled a background collector's context, never actually drained
   the HTTP server on SIGTERM. (Task 4/8 fix pass)
8. **`make docs-check` is a `go/ast` source-extraction test, not a
   construct-and-`Gather()` test.** Constructing collectors with mocked I/O
   and calling `Describe` is not actually flavor-agnostic here, since
   `NewExampleCollector`'s signature differs per flavor — a shared test file
   can't call it directly without either duplicating the check per flavor or
   maintaining a second, hand-kept "list my collectors" helper that can
   silently drift from `main.go`'s real registry. Source-extraction has zero
   drift risk, at the cost of one documented limitation: a metric's name and
   labels must be static — a literal, or `prometheus.BuildFQName` with
   literal arguments — already a Prometheus best practice independent of
   this tool. (Task 11)
9. **`docs/metrics.md` is two static per-flavor templates, not one shared
   file or a `make docs-generate` helper.** A single common template cannot
   be simultaneously truthful for both flavors, since their example
   collector's metric names differ — exactly the lie `docs-check` exists to
   prevent. (Task 11)
10. **Test library is `client_golang/prometheus/testutil` plus stdlib
    `testing`, not `testify`.** The reference's tests use
    `testify/assert`+`require` throughout; the collector-triad tests here use
    `testutil.CollectAndCompare`/`GatherAndCount` instead — already a
    dependency, idiomatic for collectors — letting `go.mod.tmpl` drop
    `testify` entirely (verified empirically that this does not affect the
    resolved, CVE-safe `golang.org/x/crypto` version either way). (Task 4
    fix pass, standing decision)
11. **`gosec`'s G304 exclusion is scoped to test files only, not global.**
    The first-pass `.golangci.yml` carried a linter-wide
    `settings.gosec.excludes: [G304]`, silencing unsafe-file-inclusion
    warnings even in real, non-test collector code; narrowed to rely on the
    pre-existing `_test\.go` path-scoped exclusion instead, which already
    covered the intended (test fixture) case on its own. (Task 21 fix pass)
12. **An exposed-bind startup warning is implemented, not just documented as
    a principle.** `warnIfExposedAndUnauthenticated` in `main.go.tmpl` logs
    once, non-fatally, if any `--web.listen-address` binds a non-loopback
    host while `--web.config.file` is unset. Design §6.7 asked for this; the
    first reference-derivation pass documented it in
    `security-and-hardening.md` as a principle only, and a fix pass wired it
    for real. (Task 21 fix pass)
13. **Asset layout mirrors the final repo tree**, not a concern-grouped
    staging layout (`build/`, `packaging/`, `docs/` as top-level *staging*
    folders that get redistributed at scaffold time). Every template sits at
    its own final repo-relative path under `assets/` — e.g.
    `assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl`, not
    `assets/build/cmd/.../main.go.tmpl` — so `scaffold.sh` has no per-file or
    per-concern mapping table to keep in sync. The only staging exception is
    flavor selection: `code/<flavor>/*` flattens into `internal/collector/`.
    This revises the v0.1 plan doc's original, pre-implementation
    concern-grouped `File Structure` section, intentionally left un-edited as
    creation history. (Task 4, decided 2026-07-04)
14. **`@@VAR@@` plus a dependency-free `scaffold.sh` (`sh`+`sed` only), not a
    brace-based template engine.** Verified via context7 against
    `cookiecutter` (Jinja `{{}}`) and `hay-kot/scaffold` (Go `text/template`)
    — both need per-file escaping or custom delimiters to survive this asset
    tree's own legitimate `{{ }}`/`${{ }}`/`${ }` syntax. (design spec §5bis)
15. **`--forge`/`--flavor` are directory selections, never literal template
    text.** No `@@IO_FLAVOR@@`/`@@FORGE@@` content-substitution variable
    exists anywhere — flavor and forge are "directory selection, never
    conditionals inside a file," by design (design spec §5bis).
16. **Dockerfiles build from source (multi-stage), not COPY-only.** The
    reference's `Dockerfile`/`Dockerfile.minimal` expect a binary pre-staged
    in the build context, by GoReleaser's `dockers_v2` or a host `go build`
    step — appropriate for a repository whose release tooling is already
    wired. A freshly scaffolded repository has neither yet; a self-contained
    multi-stage build means `docker build .` works immediately, with zero
    preconditions. Knock-on effect: `Makefile.tmpl`'s `docker-build` recipe
    dropped the reference's host `go build`+`--platform` pre-staging step,
    since a from-source Dockerfile makes that step dead computation, not
    just dead code. (Task 13)
17. **GHCR only by default, not also Docker Hub.** A freshly scaffolded
    repository's `@@OWNER@@` has no Docker Hub credentials by construction;
    wiring a second registry unconditionally would make the release
    workflow's Docker Hub login step the first thing that fails for most
    users. Documented as an explicit default, with the how-to-add-a-second-registry
    path left in both the GoReleaser config's own comment and the README.
    (Task 14)
18. **`sboms.args` set explicitly to CycloneDX.** The reference's own comment
    claims "SBOM (CycloneDX) per archive," but its actual config has no
    `args:` override, so — per GoReleaser's documented default — it silently
    emits SPDX instead. This is a **correction of a real reference bug**
    (a doc/config mismatch), not a stylistic deviation: the template sets
    `args: ["$artifact", "--output", "cyclonedx-json=$document"]` explicitly,
    so it actually delivers on the CycloneDX claim design §6.5 makes.
    (Task 14)
19. **GoReleaser pinned to the release current at authorship time (2.16.0),
    not the reference's own historical pin (2.15.4).** The reference's pin
    was reacting to a `dockers_v2` layout change specific to *its* upgrade
    history (its own commit `f90288b`); carrying that exact number forward
    would import a stale, situational pin rather than a re-verified current
    one. A re-sync should re-check the current release again, not carry
    either number forward indefinitely. (Task 14)
20. **Root governance is written from scratch, not copied.** `CLAUDE.md`,
    `README.md`, `ROADMAP.md`, `TODO.md` are de-personalized from the
    maintainer's own private engineering principles (design spec §7bis's
    ENCODÉ/EXCLU split) — never copied from the reference's own root files,
    which govern a different repository, for a different audience of
    contributors. (Task 2)

## 5. Version pins inherited from the reference (re-verify at next re-sync)

| Pin | Value at v0.1 | Source in the reference | Note for the next re-sync |
|---|---|---|---|
| Go toolchain | `1.26.5` (`golang:1.26.5-alpine@sha256:3ad57304ad93bbec8548a0437ad9e06a455660655d9af011d58b993f6f615648`) | `scripts/docker/tools/Dockerfile`, `go.mod`'s `toolchain` directive | Re-verify the digest resolves live (`docker pull`) before reusing; don't copy a digest without pulling it |
| `prometheus/client_golang` | v1.23.2 | `go.mod` | — |
| `prometheus/exporter-toolkit` | v0.16.0 | `go.mod` | Not context7-indexed — re-verify `webflag.AddFlags`/`web.ListenAndServe`/`web.FlagConfig` field names against the tagged source directly if this version changes, not from memory |
| `prometheus/common` | v0.68.1 | `go.mod` | — |
| `alecthomas/kingpin/v2` | v2.4.0 | `go.mod` | — |
| `golang.org/x/crypto` | v0.52.0 | `go.mod` (a deliberate CVE bump in the reference's own history) | Copied verbatim, not re-resolved, specifically to preserve this fix — verify the reference hasn't bumped further since |
| GoReleaser | 2.16.0 (current at authorship, deliberately not the reference's own 2.15.4 pin — see §4.19) | context7 + a live GitHub release check, not the reference | Re-check the current release again; carry neither number forward blindly |
| GitHub Actions (`checkout`, `setup-go`, `golangci-lint-action`, `goreleaser-action`, `cosign-installer`, `sbom-action`, `setup-qemu-action`, `setup-buildx-action`, `build-push-action`, `trivy-action`, `scorecard-action`, `upload-artifact`, `codeql-action`) | SHA-pinned to specific tags | reference `.github/workflows/*.yml` | Every pin was re-verified live via `git ls-remote --tags <action-repo>` at authorship time (Tasks 14 and 22) — SHA pins go stale; re-verify again, don't trust a carried-forward SHA |

## 6. Re-derivation procedure

When practices in a new or updated reference exporter diverge enough from
what's taught here to be worth folding in:

1. **Point at a real, buildable reference.** Same constraint as the original
   build (design spec §11): read the real files, never reconstruct templates
   from memory or from this document's prose alone.
2. **Re-diff file-by-file against §2's tables**, one concern at a time (core
   → flavor → tooling → docs → monitoring → packaging → release), the same
   order the v0.1 plan used. For each reference file that changed: re-read it
   in full, re-apply the same [G]/[S] split (design spec §2 — only the
   generic shape survives; anything specific becomes a `@@VAR@@` or an
   explicit fill-in hole), and re-run `test/zero-source-grep.sh` before
   committing.
3. **Re-apply §3's corrections and §4's deviations on top of the new copy.**
   Don't assume a newer reference has fixed the same issues on its own — e.g.
   re-check whether `build` is still containerized, whether a `setup`-shaped
   target crept back in, whether `sboms.args` still matches its own doc
   comment.
4. **Refresh `references/*.md` from the *updated templates*, not from the
   reference a second time** (see §2.9's closing note) — the references layer
   documents this plugin's own shipped code, one level removed from the
   reference. Pointing a references rewrite at the reference directly risks
   the references layer and the templates layer silently diverging from each
   other.
5. **Re-verify every version pin in §5 live** — GoReleaser's current release,
   each GitHub Action's SHA against `git ls-remote`, the Go toolchain digest,
   `exporter-toolkit`'s call shapes (not context7-indexed; re-read the tagged
   source directly, it is not safe to assume its API is stable across minor
   versions).
6. **Re-run the golden matrix and the gates:**
   `sh test/golden-smoke.sh --all` (all four `{http,cli}×{none,github}` cells
   green, including the `docs-check` lie-injection round-trip and
   `promtool check rules`), then `sh test/zero-source-grep.sh` and
   `claude plugin validate .`.
7. **Record what changed and why, appended here** — extend §2/§4/§5 rather
   than silently overwriting them; a future maintainer re-deriving a third
   time needs the history of *why* each deviation exists, not only its
   current state.
8. **Confirm the reference stays untouched.** `git status` in the reference's
   own working tree must be clean before and after this whole process — this
   plugin only ever reads it.

## 7. Cross-references

- Root `CLAUDE.md`'s "Re-sync rule" and "Zero-source-mention rule" sections
  both point here by name instead of naming anything themselves — this file
  is the concrete counterpart to those two generically-worded rules.
- `test/zero-source-grep.sh` excludes `docs/` (hence this file) from its
  SLURM-GREP scan; it is not exempt from anything else — the mapping and
  version pins recorded here are still expected to be *accurate*, just not
  *absent* from a search.
- Design spec §11 ("Fidélité + correction des templates") and the v0.1 plan's
  "Global Constraints" section are the original authority for the derivation
  discipline this file exists to satisfy.
