---
description: Generate one or more business Grafana dashboards for an already-scaffolded exporter, from a metrics.md-anchored RED/USE design dialogue on top of a deterministic, exportable-JSON backbone. Complements — never touches — the shipped health dashboard.
argument-hint: [name]
disable-model-invocation: true
---

Generate **business** Grafana dashboards for an already-scaffolded exporter in
the current working directory — the counterpart to the health dashboard
shipped at scaffold time, which this command **never modifies**. It writes new
JSON files under `monitoring/grafana/` and appends to `monitoring/README.md`;
it edits no code and re-scaffolds nothing. Run it only when the user explicitly
invokes this command, and walk every step below in order.

Optional dashboard name from the command argument: $ARGUMENTS

## 0. Confirm this is a scaffolded exporter, and detect its I/O flavor

Refuse to guess at a repository that was never scaffolded by this plugin.
Confirm `cmd/*/main.go`, `internal/collector/`, and `docs/metrics.md` all
exist; if any is missing, stop and point the user at
`/new-prometheus-exporter` instead.

Detect the flavor from what actually lives in `internal/collector/` — never
ask what you can check yourself:

| Found | Flavor |
|---|---|
| `internal/collector/client.go` (defines `NewClient`) | **http** |
| `internal/collector/execute.go` (defines `var Execute`) | **cli** |
| Neither, or both | Ask the user which flavor this repo is. |

The flavor does not change the dashboards (they are built from `docs/metrics.md`
+ the real namespace, both flavor-agnostic) — it only confirms this is a real
scaffolded exporter.

## 1. Read this repo's real values, and parse `docs/metrics.md`

A scaffolded repo has no `@@VAR@@` sentinels left — read real values:

| Value | How to read it |
|---|---|
| `NAMESPACE` | The literal in `cmd/*/main.go`'s `const namespace = "<literal>"` |
| Documented business metrics | Every metric in `docs/metrics.md`, grouped by its `## <Name>Collector` header, **excluding** the `## Self-instrumentation` section (already covered by the health dashboard) |

`docs/metrics.md` is not just the list of metric names — it is the substrate
that drives the whole dialogue below. For each metric read its name, `Type`
(Gauge/Counter/Histogram/Summary), and labels. If a brief
(`./exporter-design-brief.md`) is present, read it too — its audience,
business-alert candidates, and cardinality-budget sections seed steps 2/5/6
below instead of asking cold.

If the doc contains **no** business metric (only self-instrumentation), stop:
tell the user to add collectors and document them with `make docs-check`
first — there is nothing business to visualize yet. (The backbone enforces
this same refusal with a non-zero exit; do not hand-write an empty dashboard.)

## 2. Design dialogue — anchored in `metrics.md`

Every step below is **pre-filled by what `metrics.md` implies**; the user
confirms or adjusts. Never ask what the doc already answers.

1. **Target Grafana version** *(early)* — 11 / 12 / 13 / … It conditions
   `schemaVersion`, the panel model, and the context7 lookup. Propose the
   latest stable major (resolve it via context7 if present); the deterministic
   fallback is the health dashboard's baseline (`schemaVersion 38`, which every
   newer Grafana auto-migrates on import).
2. **Audience** — ops on-call / capacity / owner. May justify more than one
   dashboard. A brief's audience section seeds this.
3. **Method per concern** — **RED** (request-driven services: rate/errors/
   duration) vs **USE** (resources: utilization/saturation/errors), inferred
   from the `Type` mix (counters + a duration histogram ⇒ RED; utilization
   gauges ⇒ USE), then confirmed.
4. **Decomposition (1..N)** — derived from the per-collector grouping: few
   collectors ⇒ **one** dashboard (a row per collector); many / distinct
   families / distinct audiences ⇒ an **overview + per-domain drill-downs**,
   linked. Propose the split read from `metrics.md`; the user restructures.
5. **SLI selection** — candidates surface from the rows of `metrics.md`; not
   every metric deserves a panel.
6. **Template variables** — the labels column feeds the candidates. `metrics.md`
   carries no cardinality, so **ask** which labels are low-cardinality
   partitioning dimensions; default conservative — never auto-add a variable on
   a presumed high-cardinality label. `datasource` + `job` (multi-select,
   `includeAll`) are always present, like the health dashboard.
7. **Units & thresholds** — absent from `metrics.md`, inferred from name
   suffixes (`_seconds`/`_bytes`/`_ratio`) and context7 best practice, then
   confirmed.
8. **Drill-down / links** — if N dashboards, how they link, resting on the
   deterministic `<namespace>-<slug>` uids the backbone emits.

The output of this dialogue is a **decomposition descriptor**: which
dashboards, which panels, which variables, which links.

## 3. Generate into a staging directory (never straight into `monitoring/grafana/`)

Generate into a fresh temp directory first, so nothing under
`monitoring/grafana/` is touched until step 4 has checked what an overwrite
would destroy. **Protection precedes materialization** — the backbone's
`emit_dashboard` writes each file with a truncating `>`, so pointing it at the
live `monitoring/grafana/` directly would clobber a hand-made or hand-edited
dashboard *before* step 4's guard could ever run. Stage first, reconcile in
step 4, place only what clears.

**Floor (always).** Run the shared backbone — the same generator this plugin's
golden test runs, so what you ship is what CI proves — into a staging dir:

```sh
staging=$(mktemp -d)
bash "${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/scripts/generate-dashboard.sh" \
  --repo . --out-dir "$staging" \
  --grafana-schema-version <schemaVersion from step 2> \
  --decompose <overview|per-collector from step 2's decomposition>
```

This writes valid, exportable `<slug>.json` files into `$staging` — one panel
per documented business metric, PromQL chosen by `Type` (`rate()` on counters,
`histogram_quantile()` on histograms with a synthesized `_bucket`, `avg` on
gauges; `$__rate_interval` windows; `by (job, instance)`), deterministic
`<namespace>-<slug>` uids, exportable `__inputs`/`__requires` with a
`${DS_PROMETHEUS}` datasource input. Every `expr` references only a metric in
`docs/metrics.md` — the anti-lie guarantee.

**Ceiling (interactive only, never breaks the floor).** Refine the STAGED
files in `$staging` (never the live directory) with the Grafana version known:

- **context7** — `resolve-library-id grafana` → `query-docs` for (a) the exact
  `schemaVersion` and panel model of that version, and (b) dataviz best
  practice (panel type by metric type, units, thresholds). Use it to refine the
  staged JSON (pick a stat/gauge/bar-gauge where it reads better than a
  timeseries, set thresholds, add a per-label breakdown the user asked for).
- **`dataviz`** — if the skill is present, use it to polish layout and color.
- Never add a metric absent from `docs/metrics.md`. The ceiling only reshapes
  what the floor already grounded.

**If context7 is absent**, ship the floor as-is and warn: "dashboards generated
against the baseline schema, not verified against Grafana <version>." **If
`dataviz` is absent**, ship without the polish — no blocker. The command always
produces at least the valid deterministic floor.

## 4. Reconcile against `monitoring/grafana/`, then place — never clobber silently

For each staged `$staging/<slug>.json`, compare it against any existing
`monitoring/grafana/<slug>.json` **before** moving it into place (design §7 —
this is exactly why step 3 staged into a temp dir instead of writing the live
directory):

- **No existing file** → move it in.
- **Existing file carrying `tags: ["generated", …]`** (this command's own
  provenance, plus a stable `<namespace>-<slug>` uid) → a prior generation:
  show a diff (e.g. `diff <(jq -S . monitoring/grafana/<slug>.json) <(jq -S . "$staging"/<slug>.json)`)
  and ask before overwriting. On confirm, move the staged file over it; the
  stable uid preserves drill-down links and any dashboard already imported from
  it.
- **Existing file WITHOUT that tag** → hand-made: **never overwrite it without
  explicit confirmation**. Offer a different slug
  (`monitoring/grafana/<other>.json`) or skip it.

Only move a staged file into `monitoring/grafana/` after this check clears it,
then discard `$staging`. Never run `scaffold.sh` — this is file-by-file
adaptation, like `/add-collector`.

## 5. Update the wiring

Append the generated dashboards to `monitoring/README.md`'s import list
(Grafana UI / HTTP API / file provisioning) — **without** claiming they are
auto-provisioned. Do not touch `docker-compose.yml` (no Grafana service is
added — that depends on the user's Grafana topology) and do not touch the
health dashboard.

## 6. Verify — show the real output

Verify the dashboards you generated this run — `monitoring/grafana/overview.json`
plus any per-collector `<slug>.json` you just placed — not the whole directory,
which also holds the untouched health dashboard. First, confirm each is
well-formed JSON:

```sh
for f in monitoring/grafana/overview.json <any per-collector slugs you generated>; do
  echo "== $f =="; jq empty "$f" && echo "valid JSON"
done
```

Show it. Then prove the anti-lie property, scoped to panel **expressions** only:
every namespace-prefixed token in every panel `expr` must be a documented metric
(a documented Histogram `<h>`'s `<h>_bucket` counting as derived from its parent).
Scope to `.panels[].targets[].expr` via `jq` — never the whole JSON text —
because the `$job` template variable legitimately references the
self-instrumentation metric via
`label_values(<ns>_exporter_collector_success, job)` (mirroring the health
dashboard), which is not a panel expr and not a business metric; a whole-text
scan would wrongly flag it and the health dashboard's title:

```sh
ns=$(grep -hoE 'const[[:space:]]+namespace[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' cmd/*/main.go | head -n1 | sed -E 's/.*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/')
for f in monitoring/grafana/overview.json <any per-collector slugs you generated>; do
  jq -r '.panels[]?.targets[]?.expr // empty' "$f"
done | grep -oE "${ns}_[A-Za-z0-9_]+" | sort -u
```

Confirm every name printed is documented in `docs/metrics.md` (a Histogram
`<h>`'s `<h>_bucket` counting as derived from its documented parent). This is the
dashboard analogue of `make docs-check`'s PromQL bar — and exactly the property
the golden test asserts on this same backbone.

## 7. What's next

- Import each dashboard in Grafana (UI "Import → Upload JSON file", the HTTP
  API, or file provisioning) and pick the Prometheus datasource when prompted.
- Re-running this command after `/add-collector` is safe: it reuses each uid
  and asks before overwriting a generated file (step 4).
- Commit with `feat(monitoring): add generated business dashboard(s)` (see
  `CONTRIBUTING.md`'s commit-message convention).
