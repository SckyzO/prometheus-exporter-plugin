# Metrics

## SingleCollector

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_only_gauge` | Gauge | - | The single documented business metric. |

## Self-instrumentation

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_exporter_collector_success` | Gauge | `collector` | Whether the last scrape of the collector succeeded (1=success, 0=failure). |
