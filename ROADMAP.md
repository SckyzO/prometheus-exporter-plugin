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

- **Discovery inputs for the architecture phase.** Today step 0 discovers a
  target's API surface through context7 alone. Broaden it to accept, in
  preference order: a local API spec (OpenAPI/Swagger, gRPC `.proto`), a
  docs folder or URL to analyze, context7, and a live-target probe — with
  graceful degradation when context7 lacks the target or isn't installed.
  This strengthens needs-framing for exporters of internal or proprietary
  programs, whose docs context7 will not have.
- A third I/O flavor: **DB**.
- `/generate-dashboard`: a design-led command that generates a business
  Grafana dashboard, complementing the generic health dashboard shipped in
  v0.1.
- Cache and background-refresh collector variants.
- Advanced multi-target support.

## v1.0

- Marketplace polish.
- A complete documentation set.
