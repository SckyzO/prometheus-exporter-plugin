# Exporter design brief: demo

## Provenance
- Grounded by: OpenAPI spec `./demo-openapi.yaml` (rung 1)
- Skipped: context7 (rung 3) — no library entry for this internal service; live-target probe (rung 4) — deferred capability
- Confidence: high

## Architecture decisions
- Data source: REST API — `http://localhost:9100`
- I/O flavor: http
- Target model: single-target
- Collectors (ordered):
  1. `queue` — job queue depth — endpoint `/api/v1/queues` — one gauge series per queue name
  2. `worker` — worker pool state — endpoint `/api/v1/workers` — counts by state
- Cardinality budget:
  - `queue`: label `queue` — worst case ~50 series — no reduction flag needed
  - `worker`: label `state` (fixed small enum) — ~5 series — none
- Business-alert candidates:
  - `queue`: page when a queue's depth exceeds its documented backlog ceiling for 10m
  - `worker`: warn when zero workers are in state `ready` for 5m

## Scaffold inputs
- EXPORTER_NAME: demo_exporter
- NAMESPACE: demo
- DATA_SOURCE: http://localhost:9100
- DATA_SOURCE_PATH: /api/v1/queues
- DEFAULT_PORT: 9100

## Open questions / assumptions
- Assumed `/api/v1/queues` is unpaginated; confirm against a live instance before building the `queue` collector if a deployment can exceed ~1000 queues.
