# Tranche A — Hardening (v0.1.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove — in the golden test and CI — the three shipped-but-unexercised template families (`Dockerfile.minimal`, the compose files, the GoReleaser config), fix the residual `master`→`main` branch assumptions, and give the container image a canonical CycloneDX SBOM. No new user-facing features.

**Architecture:** Every change lands in the *plugin's* templates (`skills/prometheus-exporter/assets/`) and its golden harness (`test/golden-smoke.sh`), so each fix ships to every future scaffolded exporter and is proven by the same golden matrix that already gates the plugin. Nothing here changes what `/new-prometheus-exporter` asks the user; it changes what the generated repo ships and what the golden verifies.

**Tech Stack:** POSIX sh (golden harness + scaffold), Go templates via `@@VAR@@` sentinels, GoReleaser, syft (already the archive-SBOM tool), Docker/Podman, Make.

## Global Constraints

Every task's requirements implicitly include this section. Copied from the plugin's own `CLAUDE.md` and the v0.1 plan.

- **Zero-source gate (hard).** No shipped file may name the production reference exporter or the maintainer's real handle. Run `test/zero-source-grep.sh` before every commit; it must pass. `docs/` is exempt (this plan lives there).
- **No AI/automation attribution in any git artifact.** Plain Conventional Commits with a scope (`fix(golden):`, `fix(templates):`, `feat(templates):`, `docs(templates):`). No `Co-authored-by`, no "Generated with…", no `claude.ai`/session trailers. Commit with `git -c commit.gpgsign=false`.
- **Container-first with graceful skip.** Every new golden check reuses the harness's existing container-engine detection (native tool → `docker run` → `podman` → explicit `SKIP` with a logged reason). A check that cannot run must print why it skipped — never a silent pass (no-silent-caps rule).
- **[G]/[S] discipline.** Only the generic shape is templated; anything exporter-specific stays a `@@VAR@@` or a documented fill-in. No concrete non-generic value baked into a shipped template.
- **Two-phase for contract changes.** The image-SBOM change (Task 4) is *additive*: it adds a CycloneDX artifact and keeps the existing BuildKit SPDX attestation. Nothing load-bearing is removed.
- **English for every shipped artifact** (templates, docs templates, the golden harness). This plan file may stay as-is.
- **Pinned-version invariant.** The golden validates the GoReleaser config against the *same* GoReleaser version the generated exporter is expected to run. That version lives in exactly one place in the harness (`GORELEASER_VERSION`), with a comment tying it to the template's own pin.
- **Evidence before assertion.** A task is not done until the golden cell that exercises it has actually been run and shown green. Every task ends by running the relevant `test/golden-smoke.sh` invocation and pasting real output.

**Grounding facts (from the current tree — verify, don't trust blindly):**
- `test/golden-smoke.sh` matrix = `{http,cli} × {none,github}`; `--all` runs all four; a single cell is `--flavor <http|cli> --forge <github|none>`. Per cell it already runs: `scaffold.sh` → grep-clean → `make build` → `make check` → `promtool check rules` → docs-check lie round-trip → `docker build -f Dockerfile …` → (http/none only) an `/add-collector` mechanical sub-check.
- The standard Dockerfile build uses a `docker → podman → SKIP` cascade; `promtool` uses `native → docker run prom/prometheus → podman → SKIP`. **Reuse whichever helper/idiom already implements these — do not invent a second detection mechanism.**
- Templates: `assets/Dockerfile.minimal.tmpl`, `assets/docker-compose.yml.tmpl`, `assets/docker-compose.minimal.yml.tmpl`, `assets/.goreleaser.yaml.tmpl`, `assets/Makefile.tmpl`, `assets/docs/release-process.md.tmpl`, `assets/.github/workflows/dev-release.yml.tmpl`.
- `.goreleaser.yaml.tmpl` already has `sboms: [{artifacts: archive, …cyclonedx-json…}]` (archives → CycloneDX via syft). Container images currently get only the BuildKit-native `sbom: "true"` attestation inside each `dockers_v2` entry (SPDX). **GoReleaser cannot catalog its own container images via the `sboms:` block** (documented limitation; valid `artifacts:` values never include `image`) — so a CycloneDX image SBOM must come from a separate syft invocation, not a goreleaser config toggle.
- `.goreleaser.yaml` ships in **both** forge modes (release is host-agnostic); only `.github/` is gated by `--forge`. So `goreleaser check` is runnable in all four cells.

---

## Task 1: `master` → `main` residuals

**Files:**
- Modify: `skills/prometheus-exporter/assets/docs/release-process.md.tmpl` (four literal `master` branch commands, ~L26, ~L265, ~L332, ~L354)
- Modify: `skills/prometheus-exporter/assets/.github/workflows/dev-release.yml.tmpl` (trigger, ~L11)
- Modify: `test/golden-smoke.sh` (add a regression assertion)

**Interfaces:**
- Produces: nothing consumed by later tasks. Independent.

- [ ] **Step 1: Add the failing golden assertion first.** In `test/golden-smoke.sh`, after the scaffold+grep block of a cell, assert the generated `docs/release-process.md` contains no `git checkout master` and no `--base master`, and (github forge only) that `.github/workflows/dev-release.yml` triggers on `main`. Model the failure message on the existing residual-`@@VAR@@` assertion. Keep it engine-free (pure grep).

- [ ] **Step 2: Run it to confirm it fails.** `sh test/golden-smoke.sh --flavor http --forge github` → expect FAIL on the new assertion (the template still says `master`).

- [ ] **Step 3: Fix the template prose.** In `release-process.md.tmpl`, change the four `master` occurrences that are *branch* commands (`git checkout master && git pull` ×3, `gh pr create --base master …` ×1) to `main`. Leave any `master` that is part of an upstream URL untouched (there is none in this file, but do not blanket-replace).

- [ ] **Step 4: Fix the dev-release trigger.** In `dev-release.yml.tmpl`, change the push-branches trigger from `- master` to the peer workflows' form `branches: [main, master]` (support both default-branch names, matching `ci`/`govulncheck`/`scorecard`).

- [ ] **Step 5: Re-run to green.** `sh test/golden-smoke.sh --flavor http --forge github` → the new assertion PASSes; the cell still ends green overall. Run `test/zero-source-grep.sh` (must pass).

- [ ] **Step 6: Commit.** `git -c commit.gpgsign=false commit -am "fix(templates): use main as the default branch in release runbook and dev-release trigger"`

---

## Task 2: golden coverage for `Dockerfile.minimal` and the compose files

**Files:**
- Modify: `test/golden-smoke.sh` (add checks after the existing standard-Dockerfile build)

**Interfaces:**
- Consumes: the cell's already-scaffolded `test/_work/<cell>` repo and its detected container engine.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Add the minimal-image build.** Immediately after the existing `docker build -f Dockerfile …` block, add an analogous build of `Dockerfile.minimal` (`… build -f Dockerfile.minimal -t "golden-smoke-min-$flavor-$forge:latest" .`), reusing the *same* container-engine variable/cascade the standard build already resolved — no second detection. If that build is SKIPped, this one skips identically (log the reason).

- [ ] **Step 2: Add the compose config validation.** After the image builds, validate both compose files parse: `<engine> compose -f docker-compose.yml config -q` and `… -f docker-compose.minimal.yml config -q`. Cascade `docker compose` → `podman compose`/`podman-compose` → SKIP-with-reason. `config -q` needs no env (the templates ship defaults), exits non-zero on a malformed file.

- [ ] **Step 3: Run one cell.** `sh test/golden-smoke.sh --flavor http --forge none` → expect PASS, with new lines showing the minimal build and both compose validations (or explicit SKIPs if no engine).

- [ ] **Step 4: Run the full matrix.** `sh test/golden-smoke.sh --all` → 4/4 green.

- [ ] **Step 5: Commit.** `git -c commit.gpgsign=false commit -am "test(golden): build Dockerfile.minimal and validate compose files"`

---

## Task 3: golden coverage for the GoReleaser config (`goreleaser check`)

**Files:**
- Modify: `test/golden-smoke.sh` (add a `GORELEASER_VERSION` constant near the top and a `goreleaser check` step)

**Interfaces:**
- Consumes: the scaffolded repo's `.goreleaser.yaml` (present in all cells).
- Produces: `GORELEASER_VERSION` — a single harness-level constant later maintainers keep in sync with the template's own pin.

- [ ] **Step 1: Discover the template's pinned GoReleaser version.** Read where `assets/.github/workflows/release.yml.tmpl` (or the release-process doc / Makefile) pins GoReleaser. Record that exact version. This is the version the golden must check against.

- [ ] **Step 2: Add the constant.** Near the top of `test/golden-smoke.sh`, define `GORELEASER_VERSION=<that version>` with a comment: `# keep in sync with the goreleaser version pinned in assets/.github/workflows/release.yml.tmpl`.

- [ ] **Step 3: Add the check step.** After the compose validation, run `goreleaser check` against the scaffolded config, container-first: `goreleaser` native → `docker run --rm -v "$PWD":/w -w /w goreleaser/goreleaser:${GORELEASER_VERSION} check` → SKIP-with-reason. Run it from the scaffolded repo's root so it finds `.goreleaser.yaml`. A schema error must fail the cell.

- [ ] **Step 4: Run one cell.** `sh test/golden-smoke.sh --flavor cli --forge none` → expect PASS with a `goreleaser check` PASS/SKIP line.

- [ ] **Step 5: Run the full matrix.** `sh test/golden-smoke.sh --all` → 4/4 green.

- [ ] **Step 6: Commit.** `git -c commit.gpgsign=false commit -am "test(golden): validate the GoReleaser config with goreleaser check"`

---

## Task 4: canonical CycloneDX SBOM for the container image

The user's decision: make the project's SBOM story **uniform CycloneDX** across archives *and* image. GoReleaser can't SBOM its own images, so add a syft step. This is additive — the existing BuildKit SPDX attestation stays as a supplementary registry-native layer, now documented as such rather than implied to be the canonical SBOM.

**Files:**
- Modify: `skills/prometheus-exporter/assets/Makefile.tmpl` (new `sbom-image` target)
- Modify: `skills/prometheus-exporter/assets/docs/release-process.md.tmpl` and/or the supply-chain header wherever it enumerates SBOM artifacts (make the two layers accurate: archives = CycloneDX via GoReleaser/syft; image = CycloneDX via `make sbom-image`; plus a BuildKit SPDX attestation noted as supplementary)
- Modify: `test/golden-smoke.sh` (prove the image SBOM after the standard image build)

**Interfaces:**
- Consumes: the standard image the golden already builds (`golden-smoke-$flavor-$forge:latest`).
- Produces: a `make sbom-image IMAGE=<ref>` target emitting a CycloneDX-JSON file; nothing later depends on it.

- [ ] **Step 1: Add the `sbom-image` Makefile target.** In `Makefile.tmpl`, add a target that runs syft on a built image and writes CycloneDX JSON, e.g. `sbom-image: ## Generate a CycloneDX SBOM for the container image` running `syft "$(IMAGE):$(TAG)" -o cyclonedx-json > @@EXPORTER_NAME@@.image.cdx.json` (native syft against the local docker daemon — what a real maintainer runs after `make docker-build`). Keep it container-first-consistent with the file's other targets; document the `IMAGE`/`TAG` vars next to the existing docker targets. Do **not** hardcode a concrete image name — use the file's existing image/tag variables.

- [ ] **Step 2: Update the SBOM documentation to stop implying one uniform source.** Wherever the release/supply-chain prose lists SBOMs (the "supply-chain" header and/or `release-process.md.tmpl`), state plainly: archives get a CycloneDX SBOM (GoReleaser + syft), the container image gets a CycloneDX SBOM via `make sbom-image` (syft), and the image additionally carries a BuildKit-native SPDX attestation from `dockers_v2 … sbom:"true"` as a supplementary registry layer. No wording may claim CycloneDX is produced for the image *by GoReleaser* (it can't be).

- [ ] **Step 3: Add the failing golden proof.** In `test/golden-smoke.sh`, after the standard `docker build`, prove a CycloneDX image SBOM can be produced: if `syft` is native → run `make sbom-image IMAGE=golden-smoke-$flavor-$forge TAG=latest` and assert the output file exists and contains `"bomFormat": "CycloneDX"`; elif an engine is available → `docker save` the image to a tar and `docker run --rm -v …:/w anchore/syft:<pinned> docker-archive:/w/img.tar -o cyclonedx-json` and assert the same marker; else SKIP-with-reason. Add `SYFT_VERSION=<pinned>` alongside `GORELEASER_VERSION`. Run it before Step 1's target exists to confirm it FAILs (target missing).

- [ ] **Step 4: Run one cell to green.** `sh test/golden-smoke.sh --flavor http --forge none` → the SBOM proof PASSes (or SKIPs explicitly with no engine).

- [ ] **Step 5: Run the full matrix + zero-source gate.** `sh test/golden-smoke.sh --all` → 4/4 green. `test/zero-source-grep.sh` → pass.

- [ ] **Step 6: Commit.** `git -c commit.gpgsign=false commit -am "feat(templates): canonical CycloneDX SBOM for the container image via make sbom-image"`

---

## Self-Review (run before dispatching Task 1)

- **Spec coverage:** golden now exercises Dockerfile.minimal (T2), compose (T2), goreleaser (T3); master→main fixed + regression-locked (T1); image gets CycloneDX SBOM (T4). All five carried-over debts covered.
- **Placeholder scan:** the only deliberately-unresolved value is the pinned GoReleaser/syft versions (Task 3/4 Step 1 discovers them) — a discovery step, not a placeholder.
- **Consistency:** `GORELEASER_VERSION` (T3) and `SYFT_VERSION` (T4) are both single-source harness constants with a sync comment; no second container-engine detector is introduced (all new checks reuse the existing cascade).
- **Blast radius:** Tasks 1 and 4 change shipped templates (every future exporter); both are gated by the golden and the zero-source grep. Task 4 is additive (SPDX attestation retained).
