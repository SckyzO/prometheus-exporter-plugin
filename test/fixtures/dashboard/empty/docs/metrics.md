# Metrics

## Self-instrumentation

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_exporter_collector_success` | Gauge | `collector` | Whether the last scrape of the collector succeeded (1=success, 0=failure). |
| `demo_exporter_collector_duration_seconds` | Gauge | `collector` | Duration of the last scrape for the collector, in seconds. |
