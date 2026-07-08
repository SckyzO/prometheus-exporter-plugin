# Dashboards and alerts: Prometheus alerting, recording rules, and the health dashboard

This is step 5 of the workflow: what a scaffolded exporter ships so it can be
*observed*, not just scraped (`cicd-and-release.md` covers the release
pipeline; `packaging-and-ops.md` and `security-and-hardening.md` cover the
rest of this step). Everything below matches
`monitoring/prometheus/alerts.yml.tmpl`, `monitoring/prometheus/rules.yml.tmpl`,
`monitoring/grafana/health-dashboard.json.tmpl`, and `monitoring/README.md.tmpl`
as shipped — read those alongside this document, not instead of it. The
candidate business alerts this document's `/add-collector` section
materializes are drafted one step earlier, at architecture time
(`exporter-architecture.md`'s §6).

## The boundary: alerting is Prometheus's job; dashboards are Grafana's

`monitoring/README.md` states this plainly: **alerting is a Prometheus
concern**, core to what this scaffold ships, versioned and enforced the same
way code is; **dashboards are a Grafana concern**, an extension this
scaffold ships one example of (health) plus the pattern to build your own
(business). The two live in the same `monitoring/` directory but answer
different questions — an alert pages or warns someone; a dashboard is looked
at, by a person, after something already got their attention (an alert,
an incident, curiosity). Don't reach for a dashboard panel to do an alert's
job, or vice versa.

## Two tiers, one pattern

Every rule in `alerts.yml` follows the same shape: a `severity` of `warning`
or `critical`, a `for:` duration to de-flap transient blips, and two
portable, site-neutral labels/annotations conventions:

| Convention | Value | Purpose |
|---|---|---|
| `severity` | `warning`, `critical` | Alertmanager routing |
| `component` | `exporter` | Filtering / namespacing |
| `for:` | set on every alert | De-flaps transient blips |
| `summary` / `description` | annotations | One-line headline + full sentence |

Site-specific labels — `team`, `runbook_url`, `dashboard_url`, cluster/env
tags — are **deliberately absent** from this file. They're added through
Prometheus `external_labels` or Alertmanager routing config instead, which
is what keeps `alerts.yml` itself portable across environments rather than
baked to one team's paging setup. Thresholds throughout are reasonable
defaults, not fixed constants — tune them to your deployment size and
operational tolerance, per the comments in `alerts.yml` and
`docs/configuration.md`'s `scrape_interval`/`scrape_timeout` guidance.

### Tier 1: health (generic, active, uncommented)

Built entirely from this exporter's own self-instrumentation
(`@@NAMESPACE@@_exporter_collector_success`,
`@@NAMESPACE@@_exporter_collector_duration_seconds` —
`project-scaffold.md`'s `StatusTracker`) plus Prometheus's own `up`. Four
rules, identical for every I/O flavor this plugin scaffolds because the
self-instrumentation itself is identical:

| Alert | Expression | `for:` | `severity` |
|---|---|---|---|
| `ExporterDown` | `up{job="@@EXPORTER_NAME@@"} == 0` | 5m | critical |
| `ExporterMetricsMissing` | `absent(@@NAMESPACE@@_exporter_collector_success)` | 15m | critical |
| `ExporterCollectorFailing` | `@@NAMESPACE@@_exporter_collector_success == 0` | 10m | warning |
| `ExporterCollectorDurationHigh` | `..._duration_seconds > 5` | 10m | warning |
| `ExporterCollectorDurationHigh` (second rule, same name) | `..._duration_seconds > 20` | 10m | critical |

Two design decisions worth understanding, not just copying:

- **`ExporterMetricsMissing` exists because `up == 1` alone isn't enough.**
  `up` only proves Prometheus reached `/metrics` — it says nothing about
  whether `@@NAMESPACE@@_exporter_collector_success` is actually present. An
  empty collector registry (every `--no-collector.*` flag set) or a broken
  `StatusTracker` registration would leave that metric entirely absent, and
  `ExporterCollectorFailing` would then never fire — healthy-looking purely
  by omission. `absent(...)` closes that blind spot. It can legitimately
  co-fire with `ExporterDown` during a full outage; that overlap is what
  Alertmanager inhibition rules are for, not something to suppress in this
  file.
- **`ExporterCollectorFailing` is deliberately a single warning tier, not
  warning/critical.** How serious "one collector down" is depends entirely
  on *which* collector — a fact this generic template cannot know. Split it
  into per-collector tiers once you know which of your own collectors are
  critical-path; don't invent a severity split this file has no basis for.

### Tier 2: business (target-specific — a taught pattern, not a shipped alert)

What your own collectors measure is specific to your target, so there is no
single business alert that's honest for every exporter this plugin can
scaffold. `alerts.yml` ships a **commented-out** worked example instead of a
fabricated one — a `#` YAML comment, so it can neither break `promtool check
rules` nor assert a metric that doesn't exist for your flavor — teaching the
identical warning/critical + `for:` + portable-labels shape against the
bundled `ExampleCollector`'s placeholder metric:

```yaml
#   - alert: ExampleTargetDegraded
#     expr: @@NAMESPACE@@_your_metric_name > 100
#     for: 10m
#     labels:
#       severity: warning
#       component: exporter
#   - alert: ExampleTargetDegraded
#     expr: @@NAMESPACE@@_your_metric_name > 500
#     for: 10m
#     labels:
#       severity: critical
#       component: exporter
```

**`/add-collector` proposes a real, uncommented alert here for every
collector you add** (its own step 7) — the candidate alert you wrote down at
architecture time (`exporter-architecture.md`'s §6: *"what functional
condition, if this collector's own metrics showed it, should page or warn
someone?"*) becomes this concrete two-rule block, inserted immediately
before the shipped teaching comment (which stays, for the next collector
after this one):

```yaml
- alert: <Name>Degraded
  expr: <namespace>_<metric>{<label selector, if any>} > <warning threshold>
  for: 10m
  labels:
    severity: warning
    component: exporter
- alert: <Name>Degraded
  expr: <namespace>_<metric>{<label selector, if any>} > <critical threshold>
  for: 10m
  labels:
    severity: critical
    component: exporter
```

If none of a collector's metrics has a sensible "bad" direction (a purely
informational gauge), `/add-collector` says so explicitly and skips
proposing an alert rather than inventing a meaningless threshold — the same
anti-fabrication discipline as the commented example above.

## Recording rules: pre-computed, and NaN-guarded where it's real

`rules.yml` ships one active recording rule:

```
job:@@NAMESPACE@@_exporter_collector_duration_seconds:avg_healthy
  = sum by (job) (..._duration_seconds * ..._success)
    / (sum by (job) (..._success) > 0)
```

Read literally, it's "average scrape duration across collectors that
succeeded on their last scrape" — the multiplication zeroes out a failed
collector's duration before summing (`_success` is always exactly `0` or
`1`, since both metrics share the same `collector` label set, emitted from
the same `StatusTracker.Collect` call — never anything else), so a
fast-failing collector's near-zero duration can't quietly drag the healthy
average down.

**The `(... > 0)` guard is not decorative here — read why before copying it
elsewhere.** If *every* collector is failing at once (the scraped target is
entirely unreachable, say), every collector is still present and reporting,
just at value `0` — so both the numerator and the denominator evaluate to
the literal number `0`. That's a **real `0/0`**, not merely "no data," and
without the guard PromQL would return `NaN`. The guard turns that case into
"no data" instead, which is the honest answer: the average duration of the
currently-healthy collectors is meaningless when there are none.

A second, commented example shows the more familiar counter-based form of
the same guard — `rate(...) / (rate(...) > 0)` — applied to this exporter's
own request/command duration histogram (`@@NAMESPACE@@_exporter_request_duration_seconds`
on HTTP, `@@NAMESPACE@@_exporter_command_duration_seconds` on CLI; only one
of the two applies to your flavor). Here the guard matters for the more
textbook reason: on a quiet exporter with zero requests in the last 5
minutes, both rates are exactly `0` — `0/0` without the guard, "no data"
with it, instead of a bogus 100%-error-rate-looking `NaN`. Reach for this
form once a real collector has a counter metric of its own to build an
error-rate ratio from.

## PromQL validated against existing metrics — the same anti-lie bar as docs-check

Every expression in `alerts.yml`/`rules.yml` must name a metric that
actually exists in `internal/collector/*.go` — the alerting equivalent of
`docs-and-governance.md`'s "the docs can't lie" rule, just for PromQL
instead of prose. Three independent checks enforce this at different times:

1. **`/add-collector`'s own step 7** refuses to propose an alert against
   anything other than a metric its own step 3 just emitted — "no other
   metric name is acceptable here," in the command's own words.
2. **`exporter-reviewer`'s Step 9** flags any alert `expr` naming a metric
   it can't find in `internal/collector/*.go` during an audit.
3. **This plugin's own golden smoke test** (`test/golden-smoke.sh`) runs
   `promtool check rules monitoring/prometheus/rules.yml
   monitoring/prometheus/alerts.yml` against every scaffolded flavor/forge
   combination — guarded the same way as everywhere else in that script
   (native `promtool` → Docker's `prom/prometheus` image → Podman → an
   explicit skip, never a silent pass) — proving the *shipped* rules
   actually parse and validate, not just that they look plausible.

Run the same check yourself before wiring a new rule file into Prometheus:

```bash
promtool check rules monitoring/prometheus/rules.yml monitoring/prometheus/alerts.yml
# or, with no local promtool:
docker run --rm -v "$(pwd):/rules" --entrypoint promtool prom/prometheus:latest \
  check rules /rules/monitoring/prometheus/rules.yml /rules/monitoring/prometheus/alerts.yml
```

Both should report `SUCCESS`. Note what this validation does *not* cover,
though: `promtool check rules` is not part of the generated repository's own
`make check` (and isn't wired into `ci.yml.tmpl`) — it's documented in
`monitoring/README.md` as a step to run yourself (or add to your own CI) each
time you touch these files, independently re-verified against the shipped
templates by this plugin's golden test rather than by the generated
repository's automation.

**Match your real `job_name`.** `ExporterDown` hardcodes
`up{job="@@EXPORTER_NAME@@"}`, matching `docs/configuration.md`'s example
`scrape_configs` entry. If your own Prometheus config uses a different
`job_name`, every `job=`-selecting expression across both files needs the
same edit — otherwise the alert silently never fires, comparing against a
label value no series will ever carry.

## The health dashboard (v0.1, shipped)

`monitoring/grafana/health-dashboard.json` is importable as-is (Grafana UI
"Import → Upload JSON file", the HTTP API, or file provisioning) and is
templatable precisely because the self-instrumentation it visualizes is
identical across every flavor this plugin scaffolds — only the namespace and
`job` label vary. Panels, grouped by row:

- **Exporter Health** — Target Up (Prometheus's own scrape outcome,
  independent of anything the exporter reports), Collectors OK / Collectors
  FAIL / Collectors Healthy (%), each aggregated `sum by (job, instance)`
  (or `count by`) so the panel stays correct with more than one instance
  sharing a `job` label, not just a single-target deployment.
- **Collector Status** — current OK/FAIL per collector, colored
  green/red.
- **Collector Health History** — the same signal as a state timeline over
  the visible time range.
- **Scrape Duration** — a status-history colored by duration threshold
  (green `<1s`, yellow `1-5s`, red `>5s`), a sorted bar gauge of the latest
  duration per collector, and a time series of duration over time — the
  panel description calls this out as "useful for spotting a slow
  degradation before it trips `ExporterCollectorDurationHigh`," tying the
  dashboard directly back to the alert tier above.
- **Build Info** — `go_build_info`, client_golang's standard build-info
  collector; explicitly *not* the same thing as this exporter's own release
  tag (a local `go build` typically reports `(devel)`).

Two template variables: `datasource` (pick your Prometheus data source) and
`job` (the scrape `job` label(s) to show — **multi-select**, `includeAll`
defaulting to every job, populated via
`label_values(@@NAMESPACE@@_exporter_collector_success, job)`). There is no
business-metric panel here, by design — see below.

## The business dashboard (v0.2, shipped)

A business-metric dashboard (queue depth, error rates, saturation — whatever
your target's own domain is) is generated by **`/generate-dashboard [name]`**,
the design-led counterpart to the shipped health dashboard. Unlike the health
dashboard, there is no single business dashboard generic across every exporter,
so this command **builds one from your own `docs/metrics.md`**:

- **A deterministic backbone** (`skills/prometheus-exporter/scripts/generate-dashboard.sh`,
  `bash`+`jq`, container-first) parses `docs/metrics.md` + the repo's real
  namespace and emits valid **exportable** Grafana JSON — one panel per
  documented business metric, PromQL chosen by `Type` (`rate()` on counters,
  `histogram_quantile()` with a synthesized `_bucket` on histograms, `avg` on
  gauges; `$__rate_interval` windows; `by (job, instance)` aggregation),
  deterministic `<namespace>-<slug>` uids, and `${DS_PROMETHEUS}` datasource
  inputs. This same backbone is invoked by this plugin's golden test, so the
  generated shape is CI-proven.
- **A design dialogue** on top, anchored entirely in `metrics.md`: target
  Grafana version, audience, RED vs USE (inferred from the `Type` mix),
  1..N decomposition (a row per collector, or an overview + linked per-domain
  drill-downs), SLI selection, template variables (conservative — never an
  auto-variable on a presumed high-cardinality label), units/thresholds, and
  drill-down links resting on the deterministic uids. `context7` (the exact
  schema for the target Grafana version) and the `dataviz` skill (layout
  polish) refine the result when present, and are never required — with
  neither, the deterministic floor still ships, with a warning.

The command **never touches the health dashboard**, never provisions Grafana
or adds a compose service (that depends on your Grafana topology), and never
invents a metric absent from `docs/metrics.md`: every panel `expr` references
only a documented metric (a Histogram's `_bucket` counts as derived from its
documented parent) — the dashboard analogue of `make docs-check`'s anti-lie
bar. Re-running it is safe: it reuses each uid and asks before overwriting a
previously generated file.

## Wiring it up

```yaml
# /etc/prometheus/prometheus.yml
scrape_configs:
  - job_name: '@@EXPORTER_NAME@@'
    static_configs:
      - targets: ['@@EXPORTER_NAME@@.example.internal:@@DEFAULT_PORT@@']

rule_files:
  - /etc/prometheus/rules/@@EXPORTER_NAME@@_alerts.yml
  - /etc/prometheus/rules/@@EXPORTER_NAME@@_rules.yml
```

Reload Prometheus (`SIGHUP` or `/-/reload`) and check **Status → Rules** for
the `@@NAMESPACE@@.alerts` and `@@NAMESPACE@@.rules` groups loading without
error. `monitoring/README.md`'s own "What's not in this folder" section is
worth reading once: Alertmanager routing/silencing/receivers and
Prometheus storage/retention/scrape-interval tuning are both explicitly out
of scope here, site-specific by nature — see the Alertmanager docs and
`docs/configuration.md` respectively.

## Checklist

- [ ] Every alert has a `severity` (`warning`/`critical`), a `component`,
      and a `for:` — no bare threshold with no de-flap window.
- [ ] Site-specific labels (`team`, `runbook_url`, cluster/env) stay out of
      `alerts.yml` — added via `external_labels` or Alertmanager routing.
- [ ] A new business alert's `expr` names only a metric the collector it's
      attached to actually emits — never asserted, always grep-checked
      against `internal/collector/*.go`.
- [ ] A recording rule dividing two aggregates is guarded with
      `/ (denominator > 0)` whenever "every input is simultaneously zero"
      is a real, reachable state — not just when it looks stylistically
      safer.
- [ ] `promtool check rules monitoring/prometheus/rules.yml
      monitoring/prometheus/alerts.yml` reports `SUCCESS` before you wire a
      changed rule file into a real Prometheus.
- [ ] The health dashboard's `job` variable stays multi-select with
      `includeAll`; any new panel aggregates `by (job, instance)`, not a
      bare instant value that breaks the moment a second instance exists.
- [ ] A business dashboard is generated with `/generate-dashboard`, whose
      every panel `expr` is grep-checked against `docs/metrics.md` (a
      Histogram's `_bucket` counting as derived from its documented parent) —
      never a metric the code can't produce.
