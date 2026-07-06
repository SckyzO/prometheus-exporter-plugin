# Roadmap

Product milestones for the `prometheus-exporter` plugin. For the day-to-day
implementation backlog, see [`TODO.md`](TODO.md) and the implementation plan
it points to.

## v0.1: MVP (current)

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

## v0.2

- **Discovery inputs for the architecture phase** *(delivered, unreleased)*.
  Step 0 grounding is broadened from context7 alone to a preference-ordered
  ladder — a local API spec (OpenAPI/Swagger, gRPC `.proto`), a docs folder or
  URL to analyze, then context7, degrading gracefully to dialogue when a rung
  is unavailable — fronted by the `/design-exporter` command, which emits an
  architecture brief `/new-prometheus-exporter` can consume. This strengthens
  needs-framing for exporters of internal or proprietary programs, whose docs
  context7 will not have. A **live-target probe** rung is deferred to a v0.2.x
  fast-follow.
- `/generate-dashboard`: a design-led command that generates a business
  Grafana dashboard, complementing the generic health dashboard shipped in
  v0.1.
- Cache and background-refresh collector variants.
- Advanced multi-target support.

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
