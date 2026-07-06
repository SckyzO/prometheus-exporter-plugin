# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-07-06

Hardening tranche: prove the shipped-but-unexercised release artifacts in the
golden test, standardize on `main`, and give the container image a canonical
CycloneDX SBOM. No user-facing feature changes.

### Added

- **`make sbom-image`** — generates a CycloneDX SBOM for the container image
  via syft, so the image carries a canonical CycloneDX bill of materials
  matching the release archives. The BuildKit-native SPDX attestation is
  retained as a supplementary embedded layer.
- Golden-test coverage for three previously-unexercised templates: the
  distroless `Dockerfile.minimal` build, `docker compose config` validation
  of both compose files, and `goreleaser check` (pinned to the same
  GoReleaser version the release workflow uses).

### Changed

- The default branch is `main` throughout the release runbook and the
  dev-release workflow trigger (previously `master`).
- SBOM documentation across the templates and references now describes the
  supply-chain artifacts accurately: CycloneDX for archives and image, plus
  the supplementary SPDX buildx attestation on the image.

## [0.1.0] - 2026-07-05

Initial release: an end-to-end plugin for creating and hardening Go
Prometheus exporters, from architecture decision through a releasable,
monitored repository.

### Added

- **`prometheus-exporter` skill** — a router (`SKILL.md`) covering the full
  lifecycle (architecture design, scaffolding, per-collector development,
  hardening, release/observability, audit) plus 10 reference documents:
  architecture, official Prometheus conventions (naming/types/labels/
  OpenMetrics, context7-anchored), the collector pattern, project layout,
  container-first tooling, host-agnostic CI/release, packaging, security,
  dashboards/alerting, and docs/governance. Every reference separates
  generic guidance from exporter-specific fill-ins.
- **`/new-prometheus-exporter <name>`** — scaffolds a complete, buildable,
  git-initialized exporter repository from an already-decided architecture:
  choice of **HTTP** (default) or **CLI** I/O flavor, a license (Apache-2.0,
  MIT, GPL-3.0, or BSD-3-Clause; Apache-2.0 by default), and an optional
  GitHub Actions layer. Refuses to overwrite a non-empty target directory
  and proves the result with a real `make build` + `make check`.
- **`/add-collector <name>`** — adds one new collector, its full test triad,
  registry wiring, a `docs/metrics.md` update, and a proposed tiered business
  alert to an existing scaffolded exporter. Idempotent: refuses to add a
  collector that already exists.
- **`exporter-reviewer` subagent** — a self-sufficient, read-only audit of
  the exporter-specific delta: Definition of Done, Prometheus naming/type/
  label conventions, the five-piece collector pattern, per-collector test
  coverage, cardinality, secret exposure in metrics, and docs/alerts
  lockstep with the code. Runs alongside `/code-review` and
  `pr-review-toolkit` when installed, but depends on neither.
- **Two I/O flavors, HTTP and CLI**, sharing one flavor-agnostic core:
  registry-driven collector wiring with auto-generated
  `--[no-]collector.<name>` flags, a count-based health tracker exposed as
  `<namespace>_exporter_collector_success`/`..._duration_seconds`,
  exporter-toolkit web flags (TLS/Basic Auth via `--web.config.file`), a
  startup warning when serving unauthenticated on a non-loopback address,
  and signal-aware graceful shutdown.
- **A container-first Makefile**: every dev-tooling target (`build`, `test`,
  `race`, `vet`, `lint`, `vuln`, `check`, `report`, and more) runs inside a
  pinned tools image by default, auto-detecting Docker or Podman, with a
  documented native fallback (`NATIVE=1`) for contributors without a
  container engine.
- **Host-agnostic release tooling**: SemVer tags, a Keep-a-Changelog
  `CHANGELOG.md`, Conventional Commits, and a GoReleaser configuration
  (multi-arch builds, CycloneDX SBOM, keyless cosign signing, dual-variant
  container images) that all work with no forge at all. The GitHub Actions
  layer — CI, release, dev-release, `govulncheck`, Trivy, Scorecard,
  Dependabot, CODEOWNERS, issue/PR templates — is an explicit **opt-out**
  (`--forge none` omits it entirely; the repository stays versioned and
  locally releasable either way).
- **`monitoring/` shipped with every scaffolded exporter**: Prometheus
  health alerts (exporter down, collectors failing, abnormal scrape
  duration) plus a commented business-alert example, a NaN-guarded
  recording rule, and a health dashboard for Grafana — all validated
  against the exporter's own real metrics, never an invented one.
- **`make docs-check`**: a generated test that statically extracts every
  metric name and label the code can actually produce and fails the build
  if `docs/metrics.md` documents one that doesn't exist — the metrics
  reference cannot drift from the code without the build catching it.
- **Hardened packaging**: a standard Dockerfile (dedicated non-root user)
  and a distroless-minimal variant, both building from source; a hardened
  Docker Compose stack (`no-new-privileges`, dropped capabilities,
  read-only root, `tmpfs`); and an optional systemd unit.
- **A golden smoke test and this plugin's own CI**: `test/golden-smoke.sh
  --all` scaffolds all four `{http,cli} × {none,github}` combinations and
  proves each one builds, gates clean, validates its PromQL, and catches an
  injected metrics-doc lie; `.github/workflows/plugin-ci.yml` runs it,
  `claude plugin validate .`, and the zero-source-mention grep on every
  push and pull request.
- Plugin skeleton: the plugin manifest and self-hosted marketplace
  (`.claude-plugin/`), and root governance (`CLAUDE.md`, `README.md`,
  `ROADMAP.md`, `TODO.md`, `LICENSE`).
