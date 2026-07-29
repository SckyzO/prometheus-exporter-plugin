# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] - 2026-07-29

### Added

- **Configuration reload for `multi` and `multi-instance`.** `SIGHUP`
  (always active) and `POST /-/reload` (behind `--web.enable-lifecycle`,
  default `false`, which is Prometheus's own posture for a mutating
  endpoint rather than `blackbox_exporter`'s and `snmp_exporter`'s, both
  of which expose theirs ungated) both re-read
  `--config.file` and apply it atomically. Everything that can fail,
  parsing, a changed `flags:` section, an unresolved module, an unreadable
  secret, runs before anything is mutated: a failed reload leaves the
  running configuration untouched, drives
  `..._exporter_config_last_reload_successful` to `0`, and logs the
  failure at error; a successful one sets that gauge back to `1` and
  advances `..._exporter_config_last_reload_success_timestamp_seconds`.
  Reload does not ship for `single`: its file holds only a `flags:`
  section (unreloadable for the reason below) and an
  `http_client_config:` whose file-backed secrets and TLS material
  (`password_file`, `bearer_token_file`, `authorization.credentials_file`,
  `ca_file`, `cert_file`, `key_file`) `prometheus/common` already re-reads
  from disk on every outbound request with no reload involved; a
  `single` build's documentation points at those `_file` variants instead.
- **A changed `flags:` section refuses the whole reload.** `flags:` is
  rendered into command-line arguments exactly once, at startup, so a
  running process cannot adopt a new value for one. Rather than apply the
  rest of a file and leave the process describing neither configuration,
  a reload that finds this section changed refuses outright, naming every
  changed key, and keeps running what it had.
- **On `multi-instance`, a reload cannot change the SET of label KEYS an
  instance carries.** A Prometheus registry never releases a metric
  family's label-name dimension once registered, so re-registering one
  under a different label key set (a label added, removed, or renamed
  across every instance; a labelled instance replaced by an unlabelled
  one) would panic. This is refused instead, with an error naming what
  moved and asking for a restart. A label VALUE change is unaffected and
  keeps reloading with no restart.
- **A per-target concurrency ceiling**
  (`--exporter.max-requests-per-target`, `multi-instance` and `single`,
  opt-in, default `0` meaning unlimited): bounds how many requests this
  exporter has in flight against one watched machine at a time, so a slow
  collector's background poller cannot starve its siblings polling the
  same instance. `..._exporter_request_wait_seconds` records how long a
  request waited for a slot; it is always registered on every HTTP-flavor
  target model and reports a permanent zero when no ceiling is
  configured. Not offered on `multi`: it has no background pollers, and
  `/probe`'s caller-controlled `target=` rules out a pre-populated
  limiter index.

### Changed

- **One shared, swappable transport per watched machine**
  (`multi-instance`) or per module (`multi`), replacing a transport built
  fresh on every use. This is what makes both the reload and the
  concurrency ceiling above possible without a connection-pool explosion.
- **`instance.Factory.New` takes a `*instance.Handle`, not an address and a
  client config.** Affects repositories scaffolded with `--target-model
  multi-instance`. The signature moves from
  `func(addr string, hcfg *promconfig.HTTPClientConfig) (BackgroundCollector, error)`
  to `func(h *instance.Handle) (BackgroundCollector, error)`: the Handle
  owns the transport every collector of that machine now shares, built once
  per machine so a reload can swap it underneath them without restarting
  any poller. `/add-collector` detects the older, pre-Handle shape and
  refuses to append to it rather than generate code that will not compile;
  the supported route for a repository on that shape is to rescaffold with
  `/new-prometheus-exporter` and port collector bodies across, the same
  no-migration posture v0.6.0 already applies to `/add-collector`'s other
  seam checks.
- **The systemd unit's `ExecReload` is now per-target-model.** A
  single-target scaffold no longer ships it active: `single` installs no
  SIGHUP handler, so an active `ExecReload` there would let `systemctl
  reload` deliver SIGHUP's OS default (terminate the process) instead of
  the harmless `Job type reload is not applicable` refusal it gave before
  this exporter had any reload mechanism at all. `multi` and
  `multi-instance` keep it active: they install `internal/reload`'s own
  SIGHUP handler.

## [0.6.0] - 2026-07-28

### Changed

- **`multi-instance` is taught, not just shipped.** The target model landed in
  v0.5.0 but appeared in none of the reference documents and not in the
  skill's own step 0, so a session learning from `references/` alone still
  believed there were two target models and could not discover the third when
  making an architecture decision. The architecture reference now compares
  three models instead of forking on two, and the scaffold, collector,
  discovery and Prometheus-conventions references each cover what the model
  changes for them: the background-collector mandate, the shared shutdown
  budget, the per-instance identifying label and the labels an instance may
  not reuse. The argument for the model is stated where it belongs: it exists
  for Prometheus's five-minute staleness window, not for slow targets, and it
  generalises to any application API, batch job or nightly inventory that
  cannot be scraped live.

### Removed

- **`--probe.module`.** Deprecated in v0.5.0 in favour of the configuration
  file's `modules:` section, removed here under the two-phase rule announced
  at deprecation. Modules now come from `modules:` and nowhere else; the
  mutual-exclusion refusal between the flag and `modules:` is gone with it,
  since there is no longer a second source to conflict with. The refusal of a
  `modules:` section alongside a top-level `http_client_config:` is unrelated
  and stays.
- **`/add-collector`'s in-place seam migrations.** The command no longer
  rewrites an older repository's `internal/probe/` and `cmd/*/main.go` to
  the current shape. It detects an outdated seam, stops, and points at
  rescaffolding with `/new-prometheus-exporter` and porting the collector
  bodies across, which is a smaller operation than an automated rewrite no
  gate in this plugin can verify. Appending into an outdated seam is still
  refused, so nothing silently produces code that will not compile.

  This is a pre-1.0 decision. Migration was the only part of this plugin that
  writes into a repository somebody else owns, the only part with no test
  harness, and it cost about 19k tokens on every invocation, more than any
  other component. With no released version yet carrying a user, it was
  maintained for nobody. Migrations become an obligation after 1.0, and a
  migration harness is the prerequisite for bringing them back.

## [0.5.0] - 2026-07-28

### Added

- **A third target model, `multi-instance`** (`--target-model multi-instance`,
  http flavor only): one process watches a fixed list of machines declared in
  `--config.file`, each polled in the background on its own schedule and
  re-served from a cache on every scrape, so the scrape itself never waits on
  a live fetch. `--config.file` is required for this target model (the one
  place multi-instance departs from the "absent file changes nothing" rule);
  single-target and multi-target builds are unchanged.
- **`modules:` and `instances:` configuration schema.** `modules:` names
  reusable `http_client_config:` bundles; `instances:` lists the machines a
  multi-instance exporter watches, each with a `name`, an `address`, an
  optional `module`, and optional extra `labels`. A plain v0.4.0 config file
  (no `modules:`/`instances:`) keeps working unchanged.
- **`scaffold.sh --instance-label`** (default `target`): the identifying
  label a multi-instance scaffold applies to every series of every watched
  instance, fixed at scaffold time rather than a runtime flag.
- **Per-target credentials for the `multi` target model.** A `/probe` request
  selects credentials by name with `?module=`, so one multi-target exporter
  can probe targets that authenticate differently. Credentials resolve in a
  fixed order (the unique selected module carrying them, then a `default`
  module, then the top-level `http_client_config:`) and never combine:
  selecting two credential-bearing modules returns 400, and so does a probe
  that resolves no credentials against a configuration that declares some.
  The same mechanism expresses both ecosystem conventions, a module as a
  complete bundle or credentials as an independent axis, so the choice lives
  in the configuration file rather than in code.

### Changed

- **`probe.Factory` gains a fourth `hc *http.Client` parameter.** Affects
  repositories scaffolded with `--target-model multi`; `/add-collector`
  detects the older shape and migrates it, diff first. No flag is renamed and
  no URL changes. Per-collector HTTP clients collapse into one client per
  module, built once at boot.

### Deprecated

- **`--probe.module`.** Superseded by the configuration file's `modules:`
  section, which can also carry credentials. Both at once is refused at boot.
  Removal no earlier than v0.6.0.

## [0.4.0] - 2026-07-22

### Changed

- **Breaking (multi-target only):** `--collector.example.timeout` is renamed
  `--probe.timeout`. The old name never configured the `example` collector: it
  bounded every probe. With one collector the two were the same thing, so the lie
  was invisible. `/add-collector` migrates a v0.3.0 scaffold and shows the diff
  first.

### Added

- Multi-target exporters hold more than one collector. `/add-collector` now works
  on a `--target-model multi` scaffold instead of refusing and handing over a
  manual procedure.
- `/probe?target=...&module=...` selects a subset of an exporter's collectors. The
  parameter is repeatable and comma-separated, and named modules combine, as in
  the SNMP exporter. An absent `module` runs every collector, so an existing
  scrape config keeps working.
- `--probe.timeout-offset` (default `0.5s`) is subtracted from Prometheus's
  scrape timeout so a probe answers before Prometheus abandons the scrape.
- `probe_timeout_seconds` is exported alongside `probe_success` and
  `probe_duration_seconds`.
- **Optional YAML configuration file** (`--config.file`): every scaffolded
  exporter can load a `flags:` section (any flag the binary declares,
  addressable by name) and an `http_client_config:` section (basic auth,
  bearer token, TLS/client certs) for the authentication no flag surface can
  express. `http_client_config:` is honored by the HTTP flavor only; the CLI
  flavor refuses to start if it is set, since it runs a local command and has
  nothing to authenticate against. Precedence is command-line flag, then the
  file, then environment, then the flag's own built-in default. A binary
  started without `--config.file` is unchanged: the flag defaults to empty
  and nothing is read.

- A scaffolded exporter's dependency floor moves: `golang.org/x/text` to
  v0.39.0, and `golang.org/x/sync` to v0.21.0 as a transitive requirement of
  it. `go.yaml.in/yaml/v2` also moves from the indirect block to the direct
  one, which it earned when `internal/config` started importing it.

  No released version of this plugin ever generated an exporter affected by
  GO-2026-5970, the advisory the `x/text` bump closes. Reaching the
  vulnerable code requires calling `NewClientFromConfig`, which nothing
  imported before the configuration layer above. That call and the bump that
  closes it both land in this release, so there is nothing to upgrade away
  from and no reason to rebuild an exporter generated from v0.3.0 or earlier.

### Fixed

- Collectors now run under a context that can actually be cancelled. `Collect`
  minted its own `context.Background()`, so the context threaded through the
  collector's I/O carried no deadline and cancellation was plumbed and then
  thrown away. In a multi-target probe this meant a hanging target ran until its
  HTTP client timeout with nothing able to interrupt it. Single-target behavior
  is unchanged: it passes `context.Background()` explicitly, which is exactly the
  value `Collect` minted for itself.

## [0.3.0] - 2026-07-11

### Added

- **Live-target probe (discovery rung 4)** — `/design-exporter` can now ground
  a design by probing a *running* instance of the target: an HTTP `GET` against
  its description surface (`/openapi.json`, `/metrics`, …) or a CLI
  `--help`/`--version`/sample invocation. Opt-in and consent-gated (the exact
  command is shown and confirmed before running); every capture passes through
  a deterministic secret-redaction backbone
  (`skills/prometheus-exporter/scripts/probe-target.sh`, `bash`, outside
  `assets/` so no scaffold ships it) before any of it reaches the brief. It
  **supplements** the discovery walk — confirming and filling gaps in the
  higher rungs, surfacing contradictions as open questions — and the default
  walk (local spec > docs > context7 > dialogue) is unchanged when no live
  instance is offered.
- **Multi-target scaffolding** (`--target-model multi`, http flavor only):
  `/new-prometheus-exporter` can now scaffold a Prometheus multi-target
  (`/probe?target=…`) exporter — a fresh registry and collector set per
  request scoped to the target, `probe_success`/`probe_duration_seconds`,
  a `--probe.target-allowlist` hardening flag with a startup warning when
  empty, and an always-on http/https target floor. Single-target remains
  the default and is unchanged.

### Security

- Pinned the scaffold's Go toolchain to **1.26.5**, which carries the fix for
  GO-2026-5856 (Encrypted Client Hello privacy leak in `crypto/tls`). Every
  scaffolded exporter reaches `crypto/tls` through `web.ListenAndServe`, so this
  keeps their `make check` (govulncheck) clean.

## [0.2.0] - 2026-07-08

### Added

- **`/generate-dashboard [name]`** — generates 1..N business Grafana dashboards
  for an already-scaffolded exporter from its own `docs/metrics.md`, via a
  RED/USE design dialogue on top of a deterministic backbone
  (`skills/prometheus-exporter/scripts/generate-dashboard.sh`, `bash`+`jq`,
  container-first). Emits **exportable** JSON (`__inputs`/`__requires`,
  `${DS_PROMETHEUS}` datasource, deterministic `<namespace>-<slug>` uids), one
  panel per documented metric, PromQL chosen by `Type` (`rate()`/`$__rate_interval`
  on counters, `histogram_quantile()` with a synthesized `_bucket` on
  histograms, `avg by (job, instance)` on gauges). Every panel `expr` references
  only a metric present in `docs/metrics.md`; the same backbone is invoked by
  the golden test, and `context7`/`dataviz` enrich the result when present but
  are never required. Complements — never modifies — the health dashboard.
- **`/design-exporter <target>`** — runs the step-0 architecture-design phase
  with broadened discovery (a preference-ordered ladder: local API spec >
  docs folder/URL > context7 > dialogue, with graceful degradation) and writes
  a reviewable architecture brief.
- **`references/discovery-inputs.md`** — the discovery input taxonomy, the
  degradation ladder, per-source extraction methods, and the architecture-brief
  format.
- **`/new-prometheus-exporter` consumes an architecture brief** when one is
  present (`./exporter-design-brief.md` or a named path), pre-filling step-0
  decisions and step-1 variables; with no brief it stays fully interactive.
- **`/add-collector --variant background`** — scaffolds a collector that
  refreshes its cache on a fixed interval (default `5m`) in a background
  goroutine instead of on the scrape's critical path, for a backend too slow
  or expensive to hit on every scrape (both HTTP and CLI flavors). Ships an
  always-emitted `<namespace>_<name>_last_refresh_timestamp_seconds`
  freshness gauge (`0` before the first successful refresh) and fails open
  on a refresh error (serves the previous cache, logs, retries next tick).
  `main.go` gains a generic, dormant `Done()`-wait shutdown seam
  (`backgroundCollectors`) that every scaffolded exporter ships from `/new`
  on, populated only once a background collector is actually added. The
  architecture-design phase (`/design-exporter`, and the `prometheus-exporter`
  skill's step 0) now proactively asks whether any collector's backend is
  slow/expensive enough to warrant this.

### Changed

- Removed the planned DB I/O flavor from scope; database targets should use
  `postgres_exporter`/`mysqld_exporter` or the config-driven `sql_exporter`.

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
