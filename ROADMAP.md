# Roadmap

Product milestones for the `prometheus-exporter` plugin. For the day-to-day
implementation backlog, see [`TODO.md`](TODO.md) and the implementation plan
it points to.

## v0.1: MVP (released)

- The `prometheus-exporter` skill, including the architecture-first design
  phase that runs before any scaffolding.
- `/new-prometheus-exporter`: scaffolds a complete exporter repository.
- `/add-collector`: adds a collector plus its full test triad to an
  existing exporter.
- `exporter-reviewer`: the exporter-specific audit subagent.
- Two I/O flavors: **HTTP** (default) and **CLI**.
- `monitoring/` shipped with every scaffolded exporter: health alerting
  rules for Prometheus plus a health dashboard for Grafana.
- `make docs-check`: metrics documentation is validated against the code,
  not just asserted.
- A scaffolded repository builds and gates clean out of the box: `make
  build` and `make check` both pass.
- This plugin's own CI, plus a golden smoke test that scaffolds a
  throwaway exporter and proves it builds.

## v0.2 (released)

- **Discovery inputs for the architecture phase.** Step 0 grounding is
  broadened from context7 alone to a preference-ordered ladder — a local API
  spec (OpenAPI/Swagger, gRPC `.proto`), a docs folder or URL to analyze, then
  context7, degrading gracefully to dialogue when a rung is unavailable —
  fronted by the `/design-exporter` command, which emits an architecture
  brief `/new-prometheus-exporter` can consume. This strengthens
  needs-framing for exporters of internal or proprietary programs, whose docs
  context7 will not have.
- `/generate-dashboard`: a design-led command that generates 1..N business
  Grafana dashboards from a scaffolded repo's own `docs/metrics.md`, on top
  of a deterministic, golden-tested backbone that emits exportable Grafana
  JSON (one panel per documented metric, type-correct PromQL, deterministic
  `<namespace>-<slug>` uids). Complements the generic health dashboard
  shipped in v0.1; never modifies it. `context7` and the `dataviz` skill
  enrich it when present, never required.
- **Background-refresh collector variant**: `/add-collector --variant
  background` scaffolds a collector that refreshes its cache on a fixed
  interval in a background goroutine instead of on the scrape's critical
  path, so a slow or expensive backend (the driving case: a legacy device
  with a seconds-per-call interface) never blocks a scrape. The
  architecture-design phase now proactively asks whether any collector needs
  this. The lazy TTL-cache variant (refetch inline when stale, no
  goroutine — a legitimate, simpler pattern that does not give the same
  "scrape never blocks" guarantee) remains a fast-follow, not built here.

## v0.3 (released)

- **Live-target probe (discovery ladder rung 4)**: `/design-exporter` can
  now ground a design by probing a *running* instance of the target — an
  HTTP `GET` against its description surface (`/openapi.json`, `/metrics`,
  …) or a CLI `--help`/`--version`/sample invocation. Opt-in and
  consent-gated (the exact command is shown and confirmed before running);
  every capture passes through a deterministic secret-redaction backbone
  before any of it reaches the brief. It supplements the discovery walk —
  confirming and filling gaps in the higher rungs, surfacing contradictions
  as open questions — and the default walk (local spec > docs > context7 >
  dialogue) is unchanged when no live instance is offered.
- **Multi-target scaffolding** (`--target-model multi`, http flavor only):
  `/new-prometheus-exporter --target-model multi` scaffolds a
  `/probe?target=…` exporter, a fresh registry and collector set built per
  request, scoped to the target, alongside `internal/probe/`'s always-on
  http/https floor and an opt-in `--probe.target-allowlist` hardening flag.
  `--target-model single` (still the default) is unchanged. The probe seam
  holds an ordered slice of named collectors rather than exactly one, each
  probe runs under a real deadline (`--probe.timeout`,
  `--probe.timeout-offset`), and `--probe.module` selects a subset of
  collectors per probe, mirroring Blackbox/SNMP's probe-profile selection.
  Both remaining follow-ups from the first cut are now delivered:
  `/add-collector` works on a multi-target scaffold (it migrates an older
  scaffold's seam first when needed, then appends a factory), and the
  `module` query parameter is live. They decoupled cleanly, because modules
  are runtime flags naming collectors, so adding a collector can never
  invalidate one.

## v0.4

- **Optional YAML configuration file** (`--config.file`): a `flags:` section
  addressable by any flag the binary declares, and an `http_client_config:`
  section for the authentication and TLS no flag surface can express,
  honored by the HTTP flavor only (the CLI flavor refuses to start if it is
  set, since it has nothing to authenticate against). Absent
  `--config.file`, a scaffolded exporter behaves exactly as before: no
  default moves and no existing scaffold changes. Prerequisite for v0.5's
  `fanout` target model, which cannot express N instances with per-instance
  credentials through a kingpin flag surface. The instance list
  (`instances:`) and the fan-out target model itself are v0.5, not this
  release.

## v1.0

- Marketplace polish.
- A complete documentation set.

## Non-goals

- **Database monitoring.** This plugin does not scaffold a way to query a
  target's database directly, now or ever. The database engine itself is
  already well served by `postgres_exporter` / `mysqld_exporter`; arbitrary
  SQL-to-metrics is served by the config-driven `sql_exporter` (a YAML
  mapping from query to metric, no Go to write). This plugin exists for
  programs that have **no existing exporter**, reached through their HTTP
  API, gRPC, or CLI.
