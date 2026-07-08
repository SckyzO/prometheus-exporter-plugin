# Metrics

<!--
docs-check parses this file as a sequence of markdown tables, one metric per
row, in this exact 4-cell shape:

| `metric_name` | Type | `label1`, `label2` | Description |
-->

<!--
RequestsCollector is deliberately listed BEFORE ExampleCollector: it has an odd
metric count (3), so as a NON-last collector it leaves a dangling half-row that
exercises emit_dashboard's half-row flush before the next collector's row
header. Do not reorder these two sections without updating the row-flush
assertion in test/generate-dashboard-backbone.sh.
-->

## RequestsCollector

Defined in `internal/collector/requests.go`.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_requests_total` | Counter | - | Total requests seen by the target. |
| `demo_request_duration_seconds` | Histogram | - | Request duration in seconds. |
| `demo_queue_depth` | Gauge | `queue` | Depth of each named queue. |

## ExampleCollector

Defined in `internal/collector/collector.go`.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_items` | Gauge | - | Number of items reported by the example target. |
| `demo_healthy` | Gauge | - | Whether the example target reports itself healthy (1) or not (0). |

## Self-instrumentation

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_exporter_collector_success` | Gauge | `collector` | Whether the last scrape of the collector succeeded (1=success, 0=failure). |
| `demo_exporter_collector_duration_seconds` | Gauge | `collector` | Duration of the last scrape for the collector, in seconds. |
