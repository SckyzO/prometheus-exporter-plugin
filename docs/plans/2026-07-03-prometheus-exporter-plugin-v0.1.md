# Prometheus Exporter Plugin — v0.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v0.1 MVP of the `prometheus-exporter` Claude Code plugin: a self-contained plugin that scaffolds and hardens production-grade Go Prometheus exporters (skill + `/new-prometheus-exporter` + `/add-collector` + `exporter-reviewer`), supporting the **HTTP** and **CLI** I/O flavors, with health+business alerting, a health Grafana dashboard, a non-lying metrics-docs check, and a golden smoke test wired into the plugin's own CI.

**Architecture:** A Claude Code plugin repo that *is its own marketplace*. Knowledge lives in `skills/prometheus-exporter/` (SKILL.md router + 10 reference docs). Artifacts live in `skills/prometheus-exporter/assets/` as `@@VAR@@`-delimited templates materialized by a dependency-free `scaffold.sh` (sh + sed only). I/O flavor is chosen by **directory selection** (`code/http/` vs `code/cli/`), never by in-file conditionals. Templates are **derived from a real reference exporter, then corrected and de-identified** — never reproduced from memory. Three executable components (2 commands + 1 subagent) drive the templates. A golden smoke test scaffolds throwaway exporters per flavor and proves `make build` + `make check` + `make docs-check` stay green.

**Tech Stack:** Go 1.26; `prometheus/client_golang`, `prometheus/exporter-toolkit`, `prometheus/common`, `alecthomas/kingpin/v2`; GoReleaser (cosign keyless, CycloneDX SBOM, `dockers_v2`); golangci-lint v2; container-first Makefile (docker/podman/native); POSIX `sh`+`sed` for scaffolding; Claude Code plugin format (`.claude-plugin/`, `commands/`, `agents/`, `skills/`).

---

## Global Constraints

Every task's requirements implicitly include this section. Values are verbatim from the design spec (`docs/design/2026-07-02-prometheus-exporter-plugin-design.md`).

- **Reference exporter (derivation source, never shipped, never named in artifacts):** `~/Dev/work/apps_repo/exporters/slurm_exporter/slurm_exporter/`. Read the real files; do **not** reproduce templates from memory (spec §11).
- **HARD gate — SLURM-GREP (the source PROJECT is never named):** `grep -rin slurm . --exclude-dir=docs --exclude-dir=.git --exclude-dir=.superpowers --exclude-dir=test` must return **0**. The taught knowledge and templates stand on official Prometheus authority (`prometheus.io`), never on "distilled from <source project>" — so the source project is never named in any shipped file. `docs/design/` + `docs/plans/` are creation-history (this plan lives there) and are the only places it may appear. (Use `--exclude-dir=docs`, NOT `| grep -v '/docs/'` — GNU grep emits bare `docs/…` paths without a leading slash, so the pipe filter silently fails. RTK may wrap `grep` unreliably — use `command grep` if results look wrong.)
- **Ownership in templates — always `@@OWNER@@`:** the generated exporter's owner/maintainer is the third party who runs `/new-prometheus-exporter`, represented by `@@OWNER@@` in scaffold templates — **never a hardcoded real handle**. This (not any secrecy rule) is the reason a real maintainer handle does not appear under `assets/`.
- **Light hygiene — HANDLE-GREP (non-blocking, decided 2026-07-03):** `grep -rin sckyzo skills/ commands/ agents/` should be **0** — there is simply no reason for the maintainer's handle to appear in generic knowledge/templates, so it stays absent naturally. This is a hygiene check, **not a hard gate**: the maintainer openly authors the plugin, and `SckyzO` legitimately appears in the plugin's own manifest / LICENSE / README / root CLAUDE.md.
- **Auto-portance:** the plugin depends on **no** personal `CLAUDE.md`/profile. OSS engineering principles are extracted and de-personalized inside the plugin (spec §7bis).
- **Templating:** delimiter `@@VAR@@`. Substitution by `scaffold.sh` (`sh`+`sed` only) — **zero runtime dependency** beyond sh/sed. No brace template engine (collides with GoReleaser `{{ }}`, Actions `${{ }}`, Docker `${ }`). Flavor = directory selection, **no in-file conditionals**. A generated repo must contain **no residual `@@…@@`**.
- **Container-first:** all dev tooling runs in a pinned `*-tools` image; auto-detect `docker` → `podman` → native fallback with an "unpinned versions" warning + `NATIVE=1` escape hatch.
- **Release host-agnostic:** SemVer, git `v*` tags, Keep-a-Changelog CHANGELOG, Conventional Commits, ldflags `version.*`, GoReleaser runs locally without any forge. The GitHub layer (`.github/`) is **opt-out** via `@@FORGE@@` (`github` | `none`).
- **English** for every shipped artifact (SKILL, references, templates, commands, agents, README, root CLAUDE.md). French is allowed only in `docs/design/` and `docs/plans/` (maintainer working language).
- **context7-first** for any library/framework/tool/API/CLI documentation (Prometheus conventions, client_golang, GoReleaser, cookiecutter/scaffold, Claude Code plugin format). Web only if context7 lacks it.
- **No AI/automation attribution in any git artifact** (no `Co-authored-by: Claude`, no "Generated with", no `claude.ai` link). Commits are Conventional Commits, signed off manually as needed; run with `git -c commit.gpgsign=false` if signing is not configured.
- **Default license** Apache-2.0 (Prometheus/node_exporter norm); user is offered a choice at scaffold time.
- **v0.1 flavors = HTTP (default) + CLI.** DB flavor, `/generate-dashboard`, and cache/background variants are **v0.2** — out of scope here. `main.go` implements **single-target**; multi-target is *documented* in the architecture reference, not implemented.

### Deliberate spec deviations (surfaced, not silent)

1. **No `execute.go` in `code/common/`.** Spec §4 lists `execute.go.tmpl` under both `common/` and `cli/`, which would clash and couple a CLI concern into the shared layer. Resolution: `var Execute` + exec-timing self-instrumentation lives **only** in `code/cli/`; the HTTP flavor's request-timing instrumentation lives in `code/http/client.go`. `code/common/` stays flavor-agnostic.
2. **Flavor seam via uniform factory + markers.** `main.go` (common) is flavor-agnostic and calls flavor-provided collector constructors at two sentinel markers (`// @@CLIENT_INIT@@`, `// @@COLLECTOR_REGISTRY@@`). This is the contract both the initial scaffold and `/add-collector` use to insert collectors deterministically (defined in Task 4).

---

## File Structure (created in this plan)

```
prometheus-exporter-plugin/
  .claude-plugin/{plugin.json, marketplace.json}           # T1
  CLAUDE.md README.md ROADMAP.md TODO.md CHANGELOG.md LICENSE .gitignore   # T1/T2
  docs/design/…                                            # exists (spec)
  docs/plans/2026-07-03-…-v0.1.md                          # this file
  docs/design/re-sync.md                                   # T23
  commands/{new-prometheus-exporter.md, add-collector.md}  # T15/T16
  agents/exporter-reviewer.md                              # T17
  skills/prometheus-exporter/
    SKILL.md                                               # T18
    references/*.md   (10 files)                           # T19/T20/T21
    assets/
      scaffold.sh                                          # T3
      code/common/{go.mod.tmpl, main.go.tmpl, status_tracker.go.tmpl, logger.go.tmpl}   # T4
      code/http/{client.go.tmpl, collector.go.tmpl, collector_test.go.tmpl, wiring.go.tmpl}   # T5
      code/cli/{execute.go.tmpl, collector.go.tmpl, collector_test.go.tmpl, parser_test.go.tmpl, wiring.go.tmpl}   # T8
      build/{Makefile.tmpl, .golangci.yml, scripts/docker/tools/{Dockerfile.tmpl, goreport.sh, deps-report.sh}}   # T6
      docs/{README.md.tmpl, CONTRIBUTING.md.tmpl, SECURITY.md.tmpl, CHANGELOG.md.tmpl, docs/{configuration,development,release-process,validation-checklist}.md.tmpl}   # T10
      code/common/docs_check_test.go.tmpl                  # T11
      monitoring/prometheus/{alerts.yml.tmpl, rules.yml.tmpl} + grafana/health-dashboard.json.tmpl + README.md.tmpl   # T12
      packaging/{Dockerfile.tmpl, Dockerfile.minimal.tmpl, docker-compose.yml.tmpl, docker-compose.minimal.yml.tmpl, .dockerignore, systemd.service.tmpl}   # T13
      release/{.goreleaser.yaml.tmpl, .goreleaser.dev.yaml.tmpl, github/…}   # T14
      licenses/{LICENSE-apache-2.0.txt, LICENSE-mit.txt, LICENSE-gpl-3.0.txt, LICENSE-bsd-3.txt}   # T14
      github/{ISSUE_TEMPLATE/*.yml, pull_request_template.md}   # T14
  test/golden-smoke.sh                                     # T7 (grown through T22)
  .github/workflows/plugin-ci.yml                          # T22
```

---

# Milestone 0 — Plugin skeleton (provable: `claude plugin validate .` passes)

### Task 1: Plugin manifest, marketplace, git init

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `.gitignore`

**Interfaces:**
- Produces: a validatable plugin root that later tasks add components to. `plugin.json` `name` = `prometheus-exporter`.

- [ ] **Step 1: Confirm repo + git**

Run: `cd ~/Dev/work/apps_repo/exporters/prometheus-exporter-plugin && git status`
Expected: a git repo (init already done per spec §3). If not: `git init`.

- [ ] **Step 2: Write `.claude-plugin/plugin.json`**

Verify the current schema with the `claude-code-guide` agent or context7 (`code.claude.com/docs` plugins) before writing. `name` + `description` are required; include optional metadata.

```json
{
  "name": "prometheus-exporter",
  "version": "0.1.0",
  "description": "Scaffold and harden production-grade Go Prometheus exporters: architecture-first design, collector pattern with mockable I/O, container-first tooling, host-agnostic releases, health+business alerting, and a non-lying metrics-docs check.",
  "author": { "name": "SckyzO" },
  "license": "Apache-2.0",
  "keywords": ["prometheus", "exporter", "observability", "metrics", "grafana", "golang", "scaffold"],
  "homepage": "",
  "repository": ""
}
```

Note: the author is the real handle `SckyzO` (maintainer decision — the plugin's own manifest is exempt from HANDLE-GREP; see Global Constraints). Do **not** use the `@@OWNER@@` scaffold sentinel here — this is the shipped manifest, not a template. Leave `homepage`/`repository` empty until the repo is pushed, then fill with the real URL.

- [ ] **Step 3: Write `.claude-plugin/marketplace.json` (self-marketplace)**

Verify schema first (context7 / claude-code-guide). The repo lists itself as the single plugin, source = this repo.

```json
{
  "name": "prometheus-exporter-marketplace",
  "owner": { "name": "SckyzO" },
  "plugins": [
    { "name": "prometheus-exporter", "source": "./", "description": "Scaffold and harden production-grade Go Prometheus exporters." }
  ]
}
```

- [ ] **Step 4: Write `.gitignore`** (plugin repo hygiene)

```gitignore
# scratch / throwaway scaffolds produced by the golden smoke test
/tmp/
/test/_work/
*.log
.DS_Store
```

- [ ] **Step 5: Validate**

Run: `claude plugin validate .`
Expected: PASS (no errors). If `claude` CLI is unavailable in the exec environment, note it and defer this check to the golden CI (Task 22) — but attempt it.

- [ ] **Step 6: Commit**

```bash
git -c commit.gpgsign=false add .claude-plugin .gitignore
git -c commit.gpgsign=false commit -m "feat(plugin): add manifest and self-marketplace skeleton"
```

---

### Task 2: Root governance files

**Files:**
- Create: `CLAUDE.md`, `README.md`, `ROADMAP.md`, `TODO.md`, `CHANGELOG.md`, `LICENSE`

**Interfaces:**
- Consumes: nothing. Produces: contribution rules the rest of the plugin repo follows (dogfooding).

- [ ] **Step 1: Write root `CLAUDE.md`** (governance of the plugin itself, de-personalized — spec §7)

Content (English), each as a short section: Conventional Commits with scope; **English for all shipped artifacts**; no dead code; two-phase rule for risky refactors; the **[G]/[S] discipline** (templates keep only Generic; Specific becomes `@@VAR@@` or a fill-in hole); how to test the plugin (`claude plugin validate .`, `claude --plugin-dir .`, `/reload-plugins`); the **zero-source-mention rule** with its grep (`grep -rin -e slurm -e sckyzo` excluding `docs/` == 0); and a **generic** re-sync rule: *"re-derive templates from a production reference exporter when practices evolve — never name a specific source in shipped artifacts; the concrete source→template mapping lives only in `docs/design/re-sync.md`."* Do **not** name the reference exporter here.

- [ ] **Step 2: Write `ROADMAP.md`** (verbatim milestones from spec §7)

v0.1 (MVP): skill + arch phase + `/new-prometheus-exporter` + `/add-collector` + `exporter-reviewer`; flavors **HTTP+CLI**; `monitoring/` = health Prometheus alerts + health Grafana dashboard; `make docs-check`; generated repo `make build`+`make check` green; plugin CI + golden test. → v0.2: DB flavor, `/generate-dashboard` (business, design-led), cache/background variants, advanced multi-target. → v1.0: marketplace polish + full docs.

- [ ] **Step 3: Write `TODO.md`** — an operational backlog pointer that references this plan file as the source of truth and lists the milestone checkboxes at a coarse grain.

- [ ] **Step 4: Write `CHANGELOG.md`** (Keep-a-Changelog) with an `## [Unreleased]` section and an `### Added` bullet for the skeleton.

- [ ] **Step 5: Write `LICENSE`** — Apache-2.0 full text (the plugin's own license). Fetch the canonical text (from the reference repo's `LICENSE` **only if it is Apache-2.0**, else from an authoritative copy). This is the plugin's license, unrelated to the scaffold `licenses/` set (Task 14).

- [ ] **Step 6: Write `README.md`** — plugin positioning (first *exporter-creation* plugin), install/dev loop, and a **"Distribution & install"** section: `/plugin marketplace add <owner/repo>` → `/plugin install prometheus-exporter@<mkt>`; version pinning via git `v*` tag; team share via shared `settings.json`; a trust note (installing a plugin runs code). **No source mention.**

- [ ] **Step 7: Grep gate + commit**

Run SLURM-GREP: `grep -rin slurm . --include='*.md' --include='*.json' | grep -v '/docs/'`
Expected: empty. (These root files legitimately carry `SckyzO` — README install path, CLAUDE.md author — so HANDLE-GREP is scoped to `skills/ commands/ agents/`, not the root; do **not** grep `sckyzo` here.)
```bash
git -c commit.gpgsign=false add CLAUDE.md README.md ROADMAP.md TODO.md CHANGELOG.md LICENSE
git -c commit.gpgsign=false commit -m "docs(plugin): add root governance (CLAUDE, README, ROADMAP, TODO, CHANGELOG, LICENSE)"
```

---

# Milestone 1 — Templating engine (provable: `scaffold.sh` unit test green)

### Task 3: `scaffold.sh` + shell test harness

**Files:**
- Create: `skills/prometheus-exporter/assets/scaffold.sh`
- Create: `test/scaffold_test.sh` (unit test for the engine)
- Create: `test/fixtures/mini-template/` (tiny fixture template used only by the test)

**Interfaces:**
- Produces: `scaffold.sh` with this contract, relied on by Tasks 7/9/15/16/22:
  - Usage: `scaffold.sh --src <assets-dir> --dst <target-dir> --flavor <http|cli> --forge <github|none> --var KEY=VALUE [--var …]`
  - Behavior: copy `--src` tree to `--dst`; select `code/<flavor>/` (drop other `code/<flavor>` dirs, keep `code/common/`); if `--forge none`, omit `release/github/` and top-level `github/`; substitute every `@@KEY@@` in file **contents**; rename path components containing `@@KEY@@`; strip the `.tmpl` suffix; place the chosen `LICENSE` from `licenses/`; **fail loudly** if any `@@…@@` remains after substitution; **refuse** a non-empty `--dst` unless `--force`.

- [ ] **Step 1: Write the failing test `test/scaffold_test.sh`**

```sh
#!/bin/sh
# Unit test for scaffold.sh — no Go, no network, sh+sed only.
set -eu
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sh "$root/skills/prometheus-exporter/assets/scaffold.sh" \
  --src "$here/fixtures/mini-template" \
  --dst "$work/out" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter \
  --var NAMESPACE=redis \
  --var OWNER=acme

fail() { echo "FAIL: $1" >&2; exit 1; }

# path rename applied
[ -f "$work/out/cmd/redis_exporter/main.go" ] || fail "path @@EXPORTER_NAME@@ not renamed"
# content substitution applied
grep -q 'namespace = "redis"' "$work/out/cmd/redis_exporter/main.go" || fail "@@NAMESPACE@@ not substituted"
# flavor selection: http kept, cli dropped
[ -f "$work/out/code/client.go" ] || fail "http flavor file missing"
[ ! -d "$work/out/code/cli" ] || fail "cli flavor dir should be dropped"
# forge none: github dir dropped
[ ! -d "$work/out/github" ] || fail "forge=none should drop github/"
# no residual sentinels anywhere
if grep -rn '@@[A-Z_]*@@' "$work/out"; then fail "residual @@VAR@@ left"; fi
# .tmpl suffix stripped
if find "$work/out" -name '*.tmpl' | grep -q .; then fail ".tmpl suffix not stripped"; fi
echo "PASS"
```

- [ ] **Step 2: Create the fixture template** `test/fixtures/mini-template/` mirroring the real layout in miniature:
  - `cmd/@@EXPORTER_NAME@@/main.go.tmpl` containing `const namespace = "@@NAMESPACE@@"` and `// owner: @@OWNER@@`
  - `code/common/keep.txt.tmpl` → `owner=@@OWNER@@`
  - `code/http/client.go.tmpl` → `package client // @@NAMESPACE@@`
  - `code/cli/execute.go.tmpl` → `package cli`
  - `github/keep.txt` → `forge-only`
  - `licenses/LICENSE-apache-2.0.txt` → `Apache placeholder`

- [ ] **Step 3: Run the test to see it fail**

Run: `sh test/scaffold_test.sh`
Expected: FAIL (scaffold.sh does not exist yet).

- [ ] **Step 4: Write `scaffold.sh`** (POSIX sh; sed for substitution; no engine)

Key implementation points (write real, working code):
- Parse `--src/--dst/--flavor/--forge/--force` and repeatable `--var KEY=VALUE` into a temp sed script (`s/@@KEY@@/VALUE/g` per var, escaping `/&\` in values).
- Refuse non-empty `--dst` unless `--force`.
- `cp -R "$src/." "$dst"`; then in `$dst`: remove `code/<other-flavors>` keeping `code/common` and `code/<flavor>`; if `--forge none`, `rm -rf release/github github`.
- Move the selected `code/<flavor>/*` up so collectors land in the module (decide final layout: flavor files go to `internal/collector/`; `code/common` files go to their real destinations — encode this mapping in the script as explicit `mv` rules, not guesswork). For the mini fixture, the test only checks `code/client.go` exists, so the script's generic rule is "flatten `code/<flavor>/` into `code/` and remove the flavor dir"; the **real** destination mapping (`internal/collector/`, `cmd/`, root) is added in Task 4 once the real layout exists. Keep Task 3 mapping generic enough to pass the fixture; refine in Task 4.
- Substitute contents: `find "$dst" -type f` → `sed -f $sedscript -i` (portable: write to temp then move).
- Rename paths: loop over paths containing `@@`, compute substituted name, `mv`.
- Strip `.tmpl`: `find … -name '*.tmpl'` → `mv` to basename without suffix.
- Place license: `mv licenses/LICENSE-<@@LICENSE@@-lowercased>.txt LICENSE` when a `LICENSE`/`@@LICENSE@@` var is present (guard: only if `licenses/` exists and var set); then `rm -rf licenses`.
- Final guard: `if grep -rn '@@[A-Z_]*@@' "$dst"; then echo "residual sentinel" >&2; exit 3; fi`.

- [ ] **Step 5: Run the test to see it pass**

Run: `sh test/scaffold_test.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -c commit.gpgsign=false add skills/prometheus-exporter/assets/scaffold.sh test/scaffold_test.sh test/fixtures
git -c commit.gpgsign=false commit -m "feat(scaffold): add dependency-free @@VAR@@ templating engine with unit test"
```

---

# Milestone 2 — Minimal HTTP exporter that builds (provable: golden HTTP build green)

### Task 4: `code/common/` templates (flavor-agnostic core)

**Files (create):**
- `skills/prometheus-exporter/assets/code/common/go.mod.tmpl`
- `skills/prometheus-exporter/assets/code/common/main.go.tmpl`
- `skills/prometheus-exporter/assets/code/common/status_tracker.go.tmpl`
- `skills/prometheus-exporter/assets/code/common/logger.go.tmpl`
- Refine `scaffold.sh` destination mapping for the real layout.

**Interfaces (the flavor seam — consumed by Tasks 5, 8, 16):**
- `main.go` defines and exposes:
  - `func register(name string, newFn func() prometheus.Collector, enabledByDefault bool)` — a **lazy constructor** (collectors are built after kingpin `Parse()`, else flag pointers read zero); appends a `registryEntry` and auto-creates `--[no-]collector.<name>` (kingpin negation), wraps with StatusTracker. (No `type Collector` alias — use `prometheus.Collector` directly.)
  - Marker `// @@CLIENT_INIT@@` — where flavor client construction is inserted (HTTP: `client := newClient(cfg)`; CLI: nothing).
  - Marker `// @@COLLECTOR_REGISTRY@@` — where `register("<name>", func() prometheus.Collector { return New<Name>Collector(deps…) }, true)` lines are inserted by scaffold/`add-collector` (closure wraps the factory so construction happens post-`Parse()`).
  - `const namespace = "@@NAMESPACE@@"`.
- Flavor collector constructor signatures the seam expects:
  - HTTP: `func New<Name>Collector(logger *Logger, client *Client) prometheus.Collector`
  - CLI: `func New<Name>Collector(logger *Logger) prometheus.Collector`

**Derive from (read in full; do NOT reproduce from memory):**
- `cmd/slurm_exporter/main.go` (280 l.) → `main.go.tmpl`
- `internal/collector/status.go` (82 l.) → `status_tracker.go.tmpl`
- `internal/logger/logger.go` (144 l.) → `logger.go.tmpl`
- `go.mod` → `go.mod.tmpl`

**Transform:**
- `go.mod.tmpl`: `module @@MODULE_PATH@@`; keep `go 1.26.x`; keep the dep set (`client_golang`, `exporter-toolkit`, `common`, `kingpin/v2`) with the **exact versions from the reference `go.mod`**. **context7-verify** `webflag.AddFlags` / `web.ListenAndServe` signatures against the pinned `exporter-toolkit` version (spec §12 open item) and adjust `main.go.tmpl` to match.
- `main.go.tmpl`: keep [G] — registry map-driven, auto flags, StatusTracker wrapping, exporter-toolkit web flags, endpoints `/metrics` (OpenMetrics) `/healthz` `/`, signal-aware shutdown. Exec/request-timing self-instrumentation and cache metrics are **flavor/variant-owned, NOT in common** (HTTP wires request timing in `client.go`; CLI wires `RegisterExecMetrics` in `execute.go`; cache = v0.2). Replace the hardcoded collector registrations with the two markers above + the `register()` helper. Replace `slurm`/binary specifics with `@@NAMESPACE@@`/`@@EXPORTER_NAME@@`/`@@DEFAULT_PORT@@`. Remove Slurm-only flags (`--slurm.bin-path`, feature-set, sacct). Keep `--command.timeout` only in the CLI wiring (move out of common if CLI-specific).
- `status_tracker.go.tmpl`, `logger.go.tmpl`: pure [G]; only rename package/import paths to `@@MODULE_PATH@@`; strip any Slurm comment.
- **de-identify:** SLURM-GREP the four generated files → 0.
- **Asset layout = mirror the final repo tree (REVISED from concern-grouping — decision 2026-07-04).** Common templates live at their FINAL repo-relative paths under `assets/`: `assets/go.mod.tmpl`, `assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl`, `assets/internal/collector/status_tracker.go.tmpl`, `assets/internal/logger/logger.go.tmpl`. `scaffold.sh` does **NO** per-file/per-concern mapping table (avoids the central-hardcoded-list anti-pattern). The ONLY staging exception is flavor selection: change `scaffold.sh`'s flavor-flatten so `code/<flavor>/*` lands in `internal/collector/` (not `code/`), then `rm -rf code/`. Update `test/scaffold_test.sh` fixture + assertions to match (common files at final paths; flavor asserts `internal/collector/client.go`); keep both suites green. All later concern dirs (`build/`, `packaging/`, `docs/`, `monitoring/`, `release/`) follow the same rule in their tasks: template sits at its final repo-relative path under `assets/`, no mapping.

- [ ] **Step 1: Read the four source files in full.**
- [ ] **Step 2: Write the four `.tmpl` files** applying the transform.
- [ ] **Step 3: context7-verify exporter-toolkit web API**, adjust `main.go.tmpl`.
- [ ] **Step 4: Refine `scaffold.sh` destination mapping**; keep `test/scaffold_test.sh` green (`sh test/scaffold_test.sh` → PASS).
- [ ] **Step 5: Materialize-and-grep check** — scaffold HTTP into a temp dir with the current (incomplete) asset tree and assert the four files land at the right paths and are grep-clean:

Run:
```bash
tmp=$(mktemp -d); sh skills/prometheus-exporter/assets/scaffold.sh --src skills/prometheus-exporter/assets --dst "$tmp/x" --flavor http --forge none --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo_exporter --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=Apache-2.0 --force 2>/dev/null; ls "$tmp/x/cmd/demo_exporter/main.go" "$tmp/x/internal/logger/logger.go"; grep -rin -e slurm -e sckyzo "$tmp/x" || echo "GREP CLEAN"
```
Expected: files listed; `GREP CLEAN`. (Full compile happens in Task 7.)
- [ ] **Step 6: Commit** `feat(templates): add flavor-agnostic core (main/registry/status/logger/go.mod)`.

---

### Task 5: `code/http/` templates (default flavor — new code, principle-derived)

**Files (create):**
- `skills/prometheus-exporter/assets/code/http/client.go.tmpl`
- `skills/prometheus-exporter/assets/code/http/wiring.go.tmpl`
- `skills/prometheus-exporter/assets/code/http/collector.go.tmpl`
- `skills/prometheus-exporter/assets/code/http/collector_test.go.tmpl`

**Interfaces:**
- Consumes: the seam from Task 4 (`register`, markers, `namespace`, `*Logger`).
- Produces: `type Client struct{…}`; `func newClient(baseURL string, timeout time.Duration) *Client`; `func (c *Client) fetch(ctx, path string) ([]byte, error)` with request-timing self-instrumentation; `func NewExampleCollector(logger *Logger, client *Client) prometheus.Collector`; `wiring.go` fills `// @@CLIENT_INIT@@` and `// @@COLLECTOR_REGISTRY@@` for the initial example collector.

**Basis:** HTTP flavor is **new** (the reference exporter has no HTTP collector). Build it from the collector-pattern principle (5 pieces) + `prometheus/client_golang` (context7: custom Collector, `NewDesc`, `MustNewConstMetric`, `NewRegistry`/`Gather`, `httptest`). Keep the **exact 5-piece + error contract** so both flavors teach the same shape.

- [ ] **Step 1: Write `client.go.tmpl`** — injectable HTTP boundary: a `Client` wrapping `*http.Client` + base URL; `fetch(ctx, path)` doing the request, recording duration/outcome via a package `prometheus.Histogram`/counter (self-instrumentation `@@NAMESPACE@@_exporter_request_duration_seconds`). The seam for tests is the `*http.Client.Transport` (swappable) or a base URL pointing at an `httptest.Server`.
- [ ] **Step 2: Write `collector.go.tmpl`** — the example collector, 5 pieces exactly:
  - `exampleData(ctx) ([]byte, error)` → `client.fetch(ctx, "@@DATA_SOURCE_PATH@@")` (I/O)
  - `parseExample(b []byte) (exampleStats, error)` → **pure**, decode `{"items": <int>, "healthy": <bool>}` (documented placeholder shape to replace)
  - `exampleGetMetrics(ctx) (exampleStats, error)` → glue
  - `ExampleCollector struct{ items, healthy *prometheus.Desc; … }`
  - `NewExampleCollector(logger, client)`; `Describe`; `Collect` → on error: `log + return` (0 metrics → StatusTracker marks failed).
- [ ] **Step 3: Write the failing triad `collector_test.go.tmpl`** — `TestParseExample` (fixture bytes), `TestExampleCollector_Collect` (httptest.Server returns fixture → `NewRegistry`+`Gather` → assert 2 metrics), `TestExampleCollector_Describe` (exact desc count), `TestExampleCollector_ErrorHandling` (server 500 / closed → `Collect` yields 0 metrics, no panic). Include a `testdata/example.json` fixture template.
- [ ] **Step 4: Write `wiring.go.tmpl`** — provides the two-marker fill: in `main.go` the scaffold inserts `client := newClient(cfg.dataSource, cfg.timeout)` at `// @@CLIENT_INIT@@` and `register("example", func() prometheus.Collector { return NewExampleCollector(logger, client) }, true)` at `// @@COLLECTOR_REGISTRY@@`. Implement insertion as sed-marker replacement rules that `scaffold.sh` applies for HTTP flavor (marker → flavor snippet file), keeping "no in-file conditionals".
- [ ] **Step 5: Materialize + grep check** (compile deferred to Task 7): scaffold HTTP, assert `internal/collector/collector.go` + `_test.go` + `client.go` present, markers filled, grep-clean.
- [ ] **Step 6: Commit** `feat(templates): add HTTP flavor (client, example collector, test triad, wiring)`.

---

### Task 6: `build/` templates (container-first Makefile, corrected)

**Files (create):**
- `skills/prometheus-exporter/assets/build/Makefile.tmpl`
- `skills/prometheus-exporter/assets/build/.golangci.yml`
- `skills/prometheus-exporter/assets/build/scripts/docker/tools/Dockerfile.tmpl`
- `skills/prometheus-exporter/assets/build/scripts/docker/tools/{goreport.sh, deps-report.sh}`

**Derive from:** `Makefile`, `.golangci.yml`, `scripts/docker/tools/{Dockerfile,goreport.sh,deps-report.sh}`.

**Transform — keep [G], apply the §6.4 corrections (the template is the *corrected* version):**
1. **Containerize `build`** too (reference leaves it on host Go → makes the "docker only" claim false). Now `build`, `test`, `race`, `vet`, `lint`, `vuln`, `check`, `report`, `report-deps` all run via `IN_TOOLS`.
2. **Delete the `setup` target** (host Go install via `wget|tar` — contradicts container-first, security/maintenance liability).
3. **Single Go-version source of truth** = the tools image Dockerfile (remove the stale host `GO_VERSION ?= 1.22.2` fallback).
4. **Document the `lint`/`report` overlap** in a comment (gofmt/vet/ineffassign/misspell covered by both; distinct goals: gate vs grade).
- Engine detection: `CONTAINER_ENGINE ?=` auto (docker → podman → none); native fallback with an "unpinned versions" warning banner + `NATIVE=1` escape hatch.
- Substitute `@@EXPORTER_NAME@@`, `@@MODULE_PATH@@`, ldflags `version.*` package path. Remove Slurm targets (`docker-build-minimal` stays generic; drop slurm-client mount specifics). Strip the stale `23.11` comment.
- `.golangci.yml`: v2 (default none + explicit enable) — copy as-is, de-identify.

- [ ] **Step 1: Read the four source files in full.**
- [ ] **Step 2: Write `Makefile.tmpl`** with the four corrections; verify no `setup` target, no host `GO_VERSION` fallback, `build` uses `IN_TOOLS`.
- [ ] **Step 3: Write `.golangci.yml`, `Dockerfile.tmpl`, `goreport.sh`, `deps-report.sh`** (de-identified).
- [ ] **Step 4: Grep-clean check** on the four files.
- [ ] **Step 5: Commit** `feat(templates): add corrected container-first Makefile and tools image`.

---

### Task 7: Golden smoke test v1 — HTTP flavor builds and gates

**Files:**
- Create: `test/golden-smoke.sh` (grown in Tasks 9/22)

**Interfaces:**
- Produces: `golden-smoke.sh --flavor <f> --forge <forge>` that scaffolds a throwaway exporter into `test/_work/<f>/` and runs `make build` + `make check`.

- [ ] **Step 1: Write `test/golden-smoke.sh`** — for the given flavor: pick real `@@VAR@@` values (`EXPORTER_NAME=demo_exporter`, `NAMESPACE=demo`, `MODULE_PATH=example.com/demo_exporter`, `DATA_SOURCE`/`DATA_SOURCE_PATH`, `DEFAULT_PORT=9999`, `OWNER=acme`, `LICENSE=Apache-2.0`, `FORGE`), invoke `scaffold.sh`, then run `make build` then `make check` in the generated dir. Assert both succeed; assert `grep -rin -e slurm -e sckyzo test/_work` == 0; assert no residual `@@`.
- [ ] **Step 2: Run it for HTTP**

Run: `sh test/golden-smoke.sh --flavor http --forge none`
Expected: scaffold OK → `make build` PASS → `make check` PASS → grep clean. (This is the first real Go compile; fix any template gaps in Tasks 4/5/6 until green — likely: import paths, unused hooks, `go.mod` deps, exporter-toolkit signature.)
- [ ] **Step 3: Iterate to green.** Any failure is a template bug in T4/T5/T6 — fix at the source template, not in `_work`.
- [ ] **Step 4: Commit** `test(golden): scaffold + build + check green for HTTP flavor`.

---

# Milestone 3 — CLI flavor (provable: golden CLI build green)

### Task 8: `code/cli/` templates (derived from the reference)

**Files (create):**
- `skills/prometheus-exporter/assets/code/cli/execute.go.tmpl`
- `skills/prometheus-exporter/assets/code/cli/wiring.go.tmpl`
- `skills/prometheus-exporter/assets/code/cli/collector.go.tmpl`
- `skills/prometheus-exporter/assets/code/cli/collector_test.go.tmpl`
- `skills/prometheus-exporter/assets/code/cli/parser_test.go.tmpl`

**Interfaces:**
- Produces: package `var Execute = func(ctx, name string, args …string) ([]byte, error)` (mockable) + `RegisterExecMetrics`; `NewExampleCollector(logger *Logger) prometheus.Collector`; `wiring.go` fills the markers (CLI `// @@CLIENT_INIT@@` = empty; registry line uses no client).

**Derive from (read in full):**
- `internal/collector/execute.go` (135 l.) → `execute.go.tmpl` (`var Execute` + `RegisterExecMetrics` + `--command.timeout` handling)
- `internal/collector/cpus.go` (88 l., simplest single-command collector) → `collector.go.tmpl` (structural shape only)
- `internal/collector/cpus_test.go` + `internal/collector/cpus_collector_test.go` → `collector_test.go.tmpl` + `parser_test.go.tmpl` (the triad)

**Transform:**
- Keep the 5-piece shape + error contract identical to HTTP. Replace Slurm parsing with a **generic** parser: `parseExample(b) ([]kv, error)` splitting `key<whitespace>value` lines → gauge `@@NAMESPACE@@_example{key=…}`. `exampleData(ctx)` → `Execute(ctx, "@@DATA_SOURCE@@", "@@DATA_SOURCE_ARGS@@"…)`.
- **Anonymize fixtures:** `testdata/example.txt` = generic `key value` lines, no Slurm output.
- de-identify all five files → grep 0.
- **Wiring = two frag files** `code/cli/wiring/{client_init.frag, registry.frag}` (same mechanism as HTTP; scaffold injects at the `main.go` markers — see the progress-ledger "Wiring MECHANISM" standing decision). CLI `client_init.frag` = empty (or a `--command.timeout` flag decl); `registry.frag` = `register("example", func() prometheus.Collector { return NewExampleCollector(logger) }, true)`. Register the CLI exec-timing self-instrumentation metric as a collector via the same seam (plain `prometheus.New*`, NOT promauto).

- [ ] **Step 1: Read the source files in full.**
- [ ] **Step 2: Write the five `.tmpl` files + `testdata/example.txt`.**
- [ ] **Step 3: Grep-clean check** on all files.
- [ ] **Step 4: Commit** `feat(templates): add CLI flavor (var Execute, example collector, triad, wiring)`.

---

### Task 9: Golden smoke test — CLI flavor

- [ ] **Step 1: Run golden for CLI**

Run: `sh test/golden-smoke.sh --flavor cli --forge none`
Expected: scaffold OK → `make build` PASS → `make check` PASS → grep clean.
- [ ] **Step 2: Iterate to green** (fix CLI templates at source).
- [ ] **Step 3: Run BOTH flavors** to confirm no regression:
Run: `sh test/golden-smoke.sh --flavor http --forge none && sh test/golden-smoke.sh --flavor cli --forge none`
Expected: both PASS.
- [ ] **Step 4: Commit** `test(golden): scaffold + build + check green for CLI flavor`.

---

# Milestone 4 — Docs discipline + non-lying metrics check

### Task 10: `docs/` templates (README + governance + operator docs)

**Files (create):**
- `assets/docs/README.md.tmpl`, `assets/docs/CONTRIBUTING.md.tmpl`, `assets/docs/SECURITY.md.tmpl`, `assets/docs/CHANGELOG.md.tmpl`
- `assets/docs/docs/{configuration,development,release-process,validation-checklist}.md.tmpl`

**Derive from:** `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `docs/{configuration,development,release-process,validation-checklist}.md`.

**Transform (spec §6.8 split):**
- **Templated** (strong [G] structure): `development.md` (identical make targets), `release-process.md` (tag→GoReleaser→RC→CI flow), `validation-checklist.md` (Command/Expected/If-fails structure), `configuration.md` (exporter-toolkit common sections). Substitute `@@VAR@@`; strip Slurm examples; replace with the HTTP/CLI example collector.
- `CONTRIBUTING.md.tmpl` = **Definition of Done**: build → non-decreasing test coverage → lint 0 → **`make docs-check`** → test target → workload → metric validation → logs → CI-local; new-collector rules; anonymization rule; Common Pitfalls; **English-for-public** rule; contributor tone ("I'm not closing the PR…").
- `README.md.tmpl`: structured, with a **Security & supply chain** section (cosign/SBOM/distroless recipes). **No source mention.**
- `metrics.md`/`metrics-examples.md` are **generated**, not templated (Task 11).

- [ ] **Step 1: Read the source docs in full.**
- [ ] **Step 2: Write the templated docs**, de-identified.
- [ ] **Step 3: Grep-clean check** across `assets/docs/`.
- [ ] **Step 4: Commit** `feat(templates): add operator docs and Definition-of-Done governance`.

---

### Task 11: `make docs-check` — metrics docs cannot lie

**Files (create):**
- `skills/prometheus-exporter/assets/code/common/docs_check_test.go.tmpl`
- Add a `docs-check` target to `build/Makefile.tmpl`
- Add `docs/metrics.md` generation to the scaffold flow (stub + regenerate)

**Interfaces:**
- Produces: a Go test that builds the real registry (all collectors, clients/Execute mocked), `Gather()`s, and cross-checks `docs/metrics.md`: **fails** if any metric/label named in `metrics.md` is absent from the code; **warns** (option: fails) on code metrics missing from docs.

- [ ] **Step 1: Write the failing test** `docs_check_test.go.tmpl` — `TestDocsCheck`: construct all registered collectors via the registry with mocked I/O, `prometheus.NewRegistry()` + `Gather()`, collect the set of metric names + label keys; parse `docs/metrics.md` (fenced metric names / a simple table); assert `documented ⊆ emitted`; report undocumented as warnings.
- [ ] **Step 2: Add `docs-check` Make target** (runs this test via `IN_TOOLS`) and fold it into `check`.
- [ ] **Step 3: Prove it catches a lie** — in a scaffolded `_work` repo, add a fake metric line to `docs/metrics.md`, run `make docs-check`, expect FAIL; remove it, expect PASS. Encode this as an assertion in `golden-smoke.sh` (inject-lie → expect non-zero → revert → expect zero).
- [ ] **Step 4: Generate `docs/metrics.md`** at scaffold: the example collector's metrics documented truthfully (so a fresh repo is green). Wire a `make docs-generate`-style helper or capture `/metrics` in the golden test; keep `metrics.md` truthful for the example.
- [ ] **Step 5: Run golden (both flavors) with docs-check**

Run: `sh test/golden-smoke.sh --flavor http --forge none && sh test/golden-smoke.sh --flavor cli --forge none`
Expected: `make check` (now including `docs-check`) PASS; lie-injection sub-check FAILs as expected then reverts to PASS.
- [ ] **Step 6: Commit** `feat(templates): add non-lying make docs-check with golden lie-injection assertion`.

---

# Milestone 5 — Observability shipped with the exporter

### Task 12: `monitoring/` templates (alerts + rules + health dashboard)

**Files (create):**
- `assets/monitoring/prometheus/alerts.yml.tmpl`
- `assets/monitoring/prometheus/rules.yml.tmpl`
- `assets/monitoring/grafana/health-dashboard.json.tmpl`
- `assets/monitoring/README.md.tmpl`

**Derive from:** `monitoring/prometheus/alerts.yml`, `monitoring/prometheus/rules.yml`, `monitoring/grafana/dashboards/08-slurm-health.json` + `09-slurm-exporter-perf.json` (health + exporter-perf), `monitoring/README.md`.

**Transform (spec §6.9):**
- `alerts.yml.tmpl` — **health** (generic, from self-instrumentation): `up == 0`, `@@NAMESPACE@@_exporter_collector_success == 0`, abnormal scrape duration. Plus a **business** exemplar alert on the example collector's metric (to teach the pattern). Two tiers `severity: warning|critical` with `for:`; portable labels (`severity`, `component`) — no team/runbook/dashboard hardcoded.
- `rules.yml.tmpl` — a recording rule with the **anti-NaN guard** (`… / (rate(...) > 0)`), generalized from the reference's ratio rule.
- `health-dashboard.json.tmpl` — templatable because self-instrumentation is identical across exporters; parameterize `namespace`/`job` via `@@NAMESPACE@@` and a Grafana `$job` variable. Strip all Slurm panels; keep exporter-health + scrape panels only.
- **PromQL validated against existing metrics** (same anti-lie bar as docs-check): every metric referenced must exist in the example's emitted set.

- [ ] **Step 1: Read the source monitoring files in full.**
- [ ] **Step 2: Write the four templates**, de-identified, PromQL referencing only `@@NAMESPACE@@_*` metrics the example emits + standard `up`.
- [ ] **Step 3: Validate with promtool** (via `IN_TOOLS` or a `promtool` in the tools image): in a scaffolded `_work` repo, `promtool check rules monitoring/prometheus/rules.yml` and `promtool check config`/`check rules` on `alerts.yml`. Add this to `golden-smoke.sh`.
- [ ] **Step 4: Grep-clean check** across `assets/monitoring/`.
- [ ] **Step 5: Commit** `feat(templates): add health+business alerting, recording rules, health dashboard`.

---

# Milestone 6 — Packaging + host-agnostic release

### Task 13: `packaging/` templates

**Files (create):**
- `assets/packaging/Dockerfile.tmpl`, `assets/packaging/Dockerfile.minimal.tmpl`
- `assets/packaging/docker-compose.yml.tmpl`, `assets/packaging/docker-compose.minimal.yml.tmpl`
- `assets/packaging/.dockerignore`, `assets/packaging/systemd.service.tmpl`

**Derive from:** `Dockerfile`, `Dockerfile.minimal`, `docker/docker-compose.yml`, `docker/docker-compose.minimal.yml`, `.dockerignore`, `systemd/slurm_exporter.service`.

**Transform (spec §6.6):**
- `Dockerfile.tmpl`: generic minimal base + dedicated non-root user; **remove Slurm-client install/mount**; run `@@EXPORTER_NAME@@` on `@@DEFAULT_PORT@@`.
- `Dockerfile.minimal.tmpl`: distroless nonroot; the app is self-contained (no external client mount for HTTP; CLI flavor documents mounting its target CLI).
- compose: hardened (`no-new-privileges`, `cap_drop: ALL`, `read_only`, `tmpfs`); substitute image/port; strip Slurm volumes.
- `systemd.service.tmpl`: dedicated user, `Restart=on-failure`, commented hardening; substitute `@@EXPORTER_NAME@@`/`@@DEFAULT_PORT@@`.

- [ ] **Step 1: Read the six source files in full.**
- [ ] **Step 2: Write the six templates**, de-identified.
- [ ] **Step 3: Build check** — in a scaffolded `_work` repo (HTTP): `docker build -f Dockerfile .` (or `make docker-build`) succeeds; if no engine, skip with a logged note. Add a guarded build to `golden-smoke.sh`.
- [ ] **Step 4: Grep-clean check.**
- [ ] **Step 5: Commit** `feat(templates): add hardened Docker (dual), compose, systemd packaging`.

---

### Task 14: `release/` (GoReleaser always + GitHub opt-out) + licenses + forge conditional

**Files (create):**
- `assets/release/.goreleaser.yaml.tmpl`, `assets/release/.goreleaser.dev.yaml.tmpl`
- `assets/release/github/workflows/{ci,release,dev-release,govulncheck,trivy-scan,scorecard}.yml.tmpl`
- `assets/release/github/{dependabot.yml.tmpl, CODEOWNERS.tmpl}`
- `assets/github/ISSUE_TEMPLATE/{bug_report,feature_request,question}.yml`, `assets/github/pull_request_template.md`
- `assets/licenses/{LICENSE-apache-2.0.txt, LICENSE-mit.txt, LICENSE-gpl-3.0.txt, LICENSE-bsd-3.txt}`

**Derive from:** `.goreleaser.yaml`, `.goreleaser.dev.yaml`, `.github/workflows/{ci,release,dev-release,govulncheck,trivy-scan,scorecard}.yml`, `.github/{dependabot.yml,CODEOWNERS,ISSUE_TEMPLATE/*,pull_request_template.md}`. (Ignore Slurm-only extras: docker-cleanup, dockerhub-readme, docker-refresh, goreportcard, FUNDING.)

**Transform (spec §6.5, host-agnostic):**
- `.goreleaser.yaml.tmpl` (**always emitted**): multi-OS/arch CGO off, checksums, **SBOM CycloneDX**, **cosign keyless**, `dockers_v2` multi-arch dual-variant, floating tags gated `Prerelease==""`. Substitute image/owner/binary. context7-verify `dockers_v2` schema against pinned GoReleaser.
- GitHub workflows (**conditional `@@FORGE@@ == github`**, placed under `release/github/`): actions **pinned by SHA**, least-privilege; de-identify.
- `scaffold.sh` already drops `release/github/` + `github/` when `--forge none` (Task 3). On `--forge github`, these are moved to `.github/`. Add/verify that mapping.
- `licenses/`: full canonical text of the four licenses.

- [ ] **Step 1: Read the source release/workflow/license files in full.**
- [ ] **Step 2: Write the GoReleaser templates + workflows + issue/PR templates + dependabot/CODEOWNERS + the four license texts.**
- [ ] **Step 3: Forge matrix check in `golden-smoke.sh`:** scaffold HTTP with `--forge none` → assert **no `.github/`**, GoReleaser present; scaffold HTTP with `--forge github` → assert `.github/workflows/` present. Both grep-clean.
- [ ] **Step 4: GoReleaser check** — in a `_work` repo: `goreleaser check` (config validity) via `IN_TOOLS`/host; if unavailable, log-skip.
- [ ] **Step 5: Commit** `feat(templates): add host-agnostic GoReleaser, opt-out GitHub layer, license set`.

---

# Milestone 7 — Executable components (commands + subagent)

### Task 15: `commands/new-prometheus-exporter.md`

**Files:** Create `commands/new-prometheus-exporter.md`.

**Content (command prompt, spec §8.1):** an ordered procedure that (0) **requires the architecture phase** (§6.0) done → captures I/O flavor + collector list + single/multi-target; (1) collects/derives the variables (§5) **including `@@FORGE@@`**; (1b) **offers the license** with a simple one-line explanation each, **default Apache-2.0** (Apache-2.0 permissive+patent grant / MIT minimal / GPL-3.0 strong copyleft / BSD-3 permissive); (2) invokes `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/scaffold.sh` with the chosen flavor/forge/vars; (3) `git init` + first Conventional Commit; (4) runs `make build` + `make check` to **prove** it; (5) points to `/add-collector`. **Refuses** a non-empty target dir. Frontmatter: `description`, `argument-hint: <name>`.

- [ ] **Step 1: Verify command frontmatter schema** (context7 / claude-code-guide).
- [ ] **Step 2: Write the command** referencing `${CLAUDE_PLUGIN_ROOT}` and the arch-phase gate; English; no source mention.
- [ ] **Step 3: Manual dry-run check** — load plugin (`claude --plugin-dir .`), run the command against a temp target, confirm it scaffolds a building repo (this reuses the golden path). If interactive run isn't possible in-harness, assert the command text invokes `scaffold.sh` with all required flags and the arch gate.
- [ ] **Step 4: Grep-clean + commit** `feat(command): add /new-prometheus-exporter scaffolder`.

---

### Task 16: `commands/add-collector.md`

**Files:** Create `commands/add-collector.md`.

**Content (spec §8.2):** (1) detect the repo's I/O flavor (or ask); (2) ask collector name + source/endpoint + target metrics; (3) materialize `code/<flavor>/collector.go.tmpl` + `collector_test.go.tmpl` (**full triad**) via `scaffold.sh` into `internal/collector/`; (4) register in the map-driven registry at `// @@COLLECTOR_REGISTRY@@` + add `--[no-]collector.<name>` (via the `register()` seam from Task 4); (5) **propose business alerts** (§6.9 tiered pattern) for the new metrics in `monitoring/prometheus/alerts.yml`; (6) remind `docs/metrics.md` lockstep + run `make test` + `make docs-check`. **Idempotent:** refuse if the collector already exists.

- [ ] **Step 1: Write the command** using the Task 4 seam (markers + `register`) and `scaffold.sh` for a single-collector materialization.
- [ ] **Step 2: Integration check** — in a scaffolded `_work` HTTP repo, run the add-collector procedure's `scaffold.sh` invocation for a second collector `queue`, insert at the marker, then `make test` + `make docs-check`. Expected: green, two collectors registered, idempotent refusal on re-run. Add this as a golden sub-check.
- [ ] **Step 3: Grep-clean + commit** `feat(command): add /add-collector with triad, registry wiring, business-alert proposal`.

---

### Task 17: `agents/exporter-reviewer.md`

**Files:** Create `agents/exporter-reviewer.md`.

**Content (spec §8.3):** a **self-sufficient** subagent auditing the **exporter delta only** — Definition of Done, Prometheus naming/types/labels, [G]/[S] separation, cardinality flags present, **test triad present per collector**, self-instrumentation wired, **no secret in any metric/label**, docs in lockstep (`make docs-check`), health alert rules present. It explicitly does **not** duplicate generic review and does **not** call other reviewers (auto-portance). Frontmatter: `name`, `description`, restricted `tools` (read + Bash for `make check`/`make docs-check`), `model`.

- [ ] **Step 1: Verify agent frontmatter schema** (context7 / claude-code-guide).
- [ ] **Step 2: Write the agent** with an actionable checklist output; English; no source mention.
- [ ] **Step 3: Smoke check** — dispatch the agent (or assert its prompt) against a scaffolded `_work` repo; confirm it reports the DoD/convention checklist and flags a deliberately-introduced gap (e.g., an undocumented metric).
- [ ] **Step 4: Grep-clean + commit** `feat(agent): add self-sufficient exporter-reviewer`.

---

# Milestone 8 — The skill (knowledge + workflow)

### Task 18: `SKILL.md` router

**Files:** Create `skills/prometheus-exporter/SKILL.md`.

**Content (spec §9):** frontmatter (`name: prometheus-exporter`, `description` with triggers "create/scaffold/harden/audit a Prometheus exporter"); the encoded workflow steps 0–6 (0 architecture-design/API-first → 1 context7-first Prometheus conventions → 2 `/new-prometheus-exporter` → 3 per-collector loop `/add-collector` → 4 hardening `make check`+`docs-check` → 5 release/CI+docs+observability → 6 audit: `exporter-reviewer` always + `/code-review`/`pr-review-toolkit` **if present**, optional); a checklist (one task per step); the [G]/[S] discipline; context7-first rule; pointers to the 10 references.

- [ ] **Step 1: Verify SKILL.md frontmatter schema** (context7 / claude-code-guide).
- [ ] **Step 2: Write SKILL.md** as a router (no deep content — that lives in references). English; no source mention.
- [ ] **Step 3: `claude plugin validate .`** → PASS (skill now discoverable).
- [ ] **Step 4: Grep-clean + commit** `feat(skill): add prometheus-exporter SKILL router with encoded workflow`.

---

### Task 19: References group A — architecture, principles, collector pattern

**Files:** Create `skills/prometheus-exporter/references/{exporter-architecture.md, prometheus-principles.md, collector-pattern.md}`.

- [ ] **Step 1: `exporter-architecture.md`** (§6.0) — ÉTAPE 0: source choice order **REST/API > gRPC > DB > CLI (last resort)**, context7-on-target-API; single vs **multi-target** (`/probe?target=`, documented not implemented in v0.1); mockable I/O boundary → flavor; collector decomposition + cardinality budget; candidate business alerts per collector.
- [ ] **Step 2: `prometheus-principles.md`** (§6.1) — **context7-first** (`prometheus.io` Writing Exporters + naming): `namespace_subsystem_unit`, `_total`/`_seconds`/`_bytes`, no unit in labels; Gauge/Counter/Histogram + explicit note on the "const-Gauge for everything" pattern and its limits; low-cardinality labels; cardinality via flags; OpenMetrics; `_exporter_*` self-instrumentation; `process_`/`scrape_` reserved-but-extensible.
- [ ] **Step 3: `collector-pattern.md`** (§6.2) — the mockable I/O boundary in **3 flavors** (HTTP default / DB / CLI) as *principle*; the **5 pieces** + `Describe`/`Collect` (error → log+return, 0 metrics → StatusTracker); the **test triad** (parser fixture / `_Collect` / `_Describe` / `_ErrorHandling`); anonymized fixtures; perf checklist (indexed structures, bounded queues); note cache/background as v0.2 variants.
- [ ] **Step 4: Grep-clean + commit** `docs(skill): add architecture, principles, collector-pattern references`.

---

### Task 20: References group B — scaffold, tooling, release

**Files:** Create `references/{project-scaffold.md, makefile-and-tooling.md, cicd-and-release.md}`.

- [ ] **Step 1: `project-scaffold.md`** (§6.3) — `cmd/` + `internal/collector/` + `internal/logger/`; map-driven registry; auto `--[no-]collector.<name>` (kingpin negation, opt-in via disabledByDefault); StatusTracker wrapping (`recover()` per collector); exec/cache metric hooks; custom registry; BuildInfo/Go/Process gated; exporter-toolkit web flags; endpoints `/metrics` `/healthz` `/`; signal-aware shutdown. Reference the seam markers from Task 4.
- [ ] **Step 2: `makefile-and-tooling.md`** (§6.4) — container-first, engine detection, native fallback + `NATIVE=1`; the target list; **the four corrections** framed as *lessons* (build must be containerized to honor the claim; no host-Go install target; single Go-version source; document lint/report overlap). Explains the *why*; the template (Task 6) is the artifact.
- [ ] **Step 3: `cicd-and-release.md`** (§6.5) — universal versioning (SemVer/tags/CHANGELOG/Conventional Commits/ldflags); GoReleaser (SBOM/cosign/`dockers_v2`/gated floating tags) **local-capable**; the **opt-out** GitHub layer via `@@FORGE@@`; local-release path when `none`; SHA-pinned least-privilege actions.
- [ ] **Step 4: Grep-clean + commit** `docs(skill): add scaffold, tooling, cicd-release references`.

---

### Task 21: References group C — packaging, security, observability, docs

**Files:** Create `references/{packaging-and-ops.md, security-and-hardening.md, dashboards-and-alerts.md, docs-and-governance.md}`.

- [ ] **Step 1: `packaging-and-ops.md`** (§6.6) — Dockerfile (non-root) vs minimal (distroless nonroot); hardened compose; systemd; `.dockerignore`.
- [ ] **Step 2: `security-and-hardening.md`** (§6.7, **de-personalized**) — never expose secrets in metrics/labels (passwords/tokens/keys/cert paths/passphrases) via the public `/metrics`; conservatism on defaults (breaking change documented); startup warnings in exposed config; optional hardening (`--web.config.file` TLS/BasicAuth); supply-chain pointers to §6.5/§6.6.
- [ ] **Step 3: `dashboards-and-alerts.md`** (§6.9) — boundary "alerting = Prometheus core; dashboards = Grafana extension"; health+business alerting; tiered `severity` + `for` + portable labels; recording rules + anti-NaN guard; PromQL validated against existing metrics; health dashboard templatable (v0.1); business dashboard via `/generate-dashboard` **design-led RED/USE** (v0.2, forward-reference only).
- [ ] **Step 4: `docs-and-governance.md`** (§6.8) — template-vs-generated split; docs in lockstep with `/metrics`; **`make docs-check`** (docs ⊆ code); `CONTRIBUTING.md` = Definition of Done; SECURITY/CHANGELOG (operator impact per entry).
- [ ] **Step 5: `claude plugin validate .`** → PASS; grep-clean; **commit** `docs(skill): add packaging, security, observability, docs-governance references`.

---

# Milestone 9 — Plugin CI, golden gate, dogfooding

### Task 22: Full golden smoke test + plugin CI workflow

**Files:**
- Finalize `test/golden-smoke.sh` (all flavors × forge matrix + all sub-checks)
- Create `.github/workflows/plugin-ci.yml` (the plugin's **own** CI)

**Interfaces:**
- Produces: a single `make -C . golden` / `sh test/golden-smoke.sh --all` entry the CI calls.

- [ ] **Step 1: Finalize `golden-smoke.sh --all`** — matrix over `{http,cli} × {none,github}`: scaffold → `make build` → `make check` (incl. `docs-check`) → promtool rules check → docs-lie injection sub-check → forge presence assertion → `grep -rin -e slurm -e sckyzo test/_work` == 0 → no residual `@@`. Log any skipped step (missing engine/goreleaser) explicitly — never silently pass.
- [ ] **Step 2: Write `.github/workflows/plugin-ci.yml`** — on push/PR: `claude plugin validate .` (if CLI available in CI, else a JSON schema lint), the **zero-source grep** over the tree excluding `docs/`, and `sh test/golden-smoke.sh --all`. SHA-pinned actions, least-privilege `permissions:`.
- [ ] **Step 3: Run the full golden locally**

Run: `sh test/golden-smoke.sh --all`
Expected: every matrix cell PASS; grep clean; lie-injection behaves; skips (if any) logged.
- [ ] **Step 4: Repo-wide zero-source gate (two scoped checks)**

Run SLURM-GREP: `grep -rin slurm . --exclude-dir=docs --exclude-dir=.git --exclude-dir=.superpowers --exclude-dir=test` → Expected: empty.
Run HANDLE-GREP: `grep -rin sckyzo skills/ commands/ agents/` → Expected: empty. (Manifest/LICENSE/README/CLAUDE.md root exempt — see Global Constraints.)
- [ ] **Step 5: Commit** `test(ci): add full golden matrix and plugin CI (validate + zero-source grep + golden)`.

---

### Task 23: `re-sync.md`, dogfood release, final self-review

**Files:**
- Create `docs/design/re-sync.md` (grep-excluded — may name the source)
- Update `CHANGELOG.md`; tag `v0.1.0`

- [ ] **Step 1: Write `docs/design/re-sync.md`** — the concrete source→template mapping (per Task list), the four Makefile corrections, deliberate deviations (execute.go placement, factory seam), and the re-derivation procedure. This is the only shipped-repo file (besides this plan/spec) allowed to name the source.
- [ ] **Step 2: Success-criteria pass (spec §10)** — verify each bullet: HTTP+CLI build+check green; arch phase present + API-first; license chosen (default Apache-2.0); 10 references present; `docs-check` green; `monitoring/` health+business + recording rules + health dashboard, PromQL valid; `scaffold.sh` sh/sed-only, no residual `@@`; reviewer actionable; `claude plugin validate` passes; auto-portance (no personal CLAUDE.md dependency); **zero-source grep == 0**; `--forge none` omits `.github/` yet stays versioned/releasable; nothing committed to the reference repo. Fix any gap inline.
- [ ] **Step 3: Update `CHANGELOG.md`** — move Unreleased → `## [0.1.0] - 2026-07-03`, list features (skill, 2 commands, agent, HTTP+CLI flavors, monitoring, docs-check, golden CI).
- [ ] **Step 4: Dogfood tag**

```bash
git -c commit.gpgsign=false add -A
git -c commit.gpgsign=false commit -m "chore(release): prepare v0.1.0"
git tag v0.1.0
```
- [ ] **Step 5: Final validate + grep**

Run: `claude plugin validate .` → Expected: PASS.
Run SLURM-GREP: `grep -rin slurm . --exclude-dir=docs --exclude-dir=.git --exclude-dir=.superpowers --exclude-dir=test` → Expected: empty.
Run HANDLE-GREP: `grep -rin sckyzo skills/ commands/ agents/` → Expected: empty.

---

## Self-Review (run after the plan is written)

**Spec coverage** — mapping design §→task:
- §2 principles (arch-first/auto-portance/container-first/host-agnostic): T4/T6/T14/T19/T20, Global Constraints.
- §3 4 v0.1 components: skill T18–T21, `/new` T15, `/add-collector` T16, reviewer T17.
- §4 structure: File Structure map + per-task Files.
- §5/§5bis variables + `@@VAR@@`/scaffold: T3 (engine), used throughout.
- §6.0–6.9 references: T19 (6.0/6.1/6.2), T20 (6.3/6.4/6.5), T21 (6.6/6.7/6.8/6.9).
- §6.4 Makefile corrections: T6.
- §6.8 docs-check: T11. §6.9 monitoring: T12.
- §7 governance + dogfooding: T2, T23. §7bis universal/personal frontier: T2/T21/T10 (CONTRIBUTING).
- §8.1–8.3: T15/T16/T17. §8.4 `/generate-dashboard`: **v0.2 — intentionally out of scope** (ROADMAP), forward-referenced in T21.
- §9 workflow: T18. §10 success criteria: T23. §11 golden/CI/re-sync: T7/T9/T11/T22/T23. §12 exporter-toolkit re-verify: T4 step 3.

**Deferred to v0.2 (not gaps):** DB flavor, `/generate-dashboard`, cache/background variants (`code/variants/`), advanced multi-target `main.go`.

**Placeholder scan:** none — derivation tasks give exact source paths + transforms + validation; new-code tasks give full code or precise structure + tests. `@@OWNER@@` in T1 is an intentional real placeholder (the plugin's own manifest), flagged for fill at publish.

**Type/interface consistency:** the flavor seam (`register`, `// @@CLIENT_INIT@@`, `// @@COLLECTOR_REGISTRY@@`, `NewExampleCollector(logger[, client])`) is defined once in T4 and consumed identically in T5/T8/T16.
