---
description: Generate one or more business Grafana dashboards for an already-scaffolded exporter, from a metrics.md-anchored RED/USE design dialogue on top of a deterministic, exportable-JSON backbone. Complements (never touches) the shipped health dashboard.
argument-hint: [name]
disable-model-invocation: true
---

Generate **business** Grafana dashboards for an already-scaffolded exporter in
the current working directory, the counterpart to the health dashboard
shipped at scaffold time, which this command **never modifies**. It writes new
JSON files under `monitoring/grafana/` and appends to `monitoring/README.md`;
it edits no code and re-scaffolds nothing. Run it only when the user explicitly
invokes this command, and walk every step below in order.

Optional dashboard name from the command argument: $ARGUMENTS. If given, it
becomes the **title** of the overview dashboard (step 3). Its deterministic slug
and uid are left unchanged, so drill-down links and regeneration-by-uid still
work. If empty, the overview keeps its default `<namespace> - Business Overview`
title.

## 0. Confirm this is a scaffolded exporter, and detect its I/O flavor

Refuse to guess at a repository that was never scaffolded by this plugin.
Confirm `cmd/*/main.go`, `internal/collector/`, and `docs/metrics.md` all
exist; if any is missing, stop and point the user at
`/new-prometheus-exporter` instead.

Detect the flavor from what actually lives in `internal/collector/`. Never
ask what you can check yourself:

| Found | Flavor |
|---|---|
| `internal/collector/client.go` (defines `NewClient`) | **http** |
| `internal/collector/execute.go` (defines `var Execute`) | **cli** |
| Neither, or both | Ask the user which flavor this repo is. |

The flavor does not change the dashboards (they are built from `docs/metrics.md`
+ the real namespace, both flavor-agnostic). It only confirms this is a real
scaffolded exporter.

## 1. Read this repo's real values, and parse `docs/metrics.md`

A scaffolded repo has no `@@VAR@@` sentinels left. Read real values:

| Value | How to read it |
|---|---|
| `NAMESPACE` | The literal in `cmd/*/main.go`'s `const namespace = "<literal>"` |
| Documented business metrics | Every metric in `docs/metrics.md`, grouped by its `## <Name>Collector` header, **excluding** the `## Self-instrumentation` section (already covered by the health dashboard) |

`docs/metrics.md` is not just the list of metric names: it is the substrate
that drives the whole dialogue below. For each metric read its name, `Type`
(Gauge/Counter/Histogram/Summary), and labels.

If `docs/exporter-journal.md` is present, read it too, following
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/project-journal.md`:
its audience, business-alert candidates and cardinality-budget sections seed
steps 2, 5 and 6 below instead of asking cold. Reconcile it against
`docs/metrics.md` first, as that reference describes: the documented metrics
win over anything the journal claims about which collectors exist. Report
every correction to the user, but do not write it back: `## Collectors` is
`/add-collector`'s to complete, not this command's.

If the doc contains **no** business metric (only self-instrumentation), stop:
tell the user to add collectors and document them with `make docs-check`
first. There is nothing business to visualize yet. (The backbone enforces
this same refusal with a non-zero exit; do not hand-write an empty dashboard.)

## 2. Design dialogue, anchored in `metrics.md`

Every step below is **pre-filled by what `metrics.md` implies**; the user
confirms or adjusts. Never ask what the doc already answers.

1. **Target Grafana version** *(early)*: 11 / 12 / 13 / … It conditions
   `schemaVersion`, the panel model, and the context7 lookup. Propose the
   latest stable major (resolve it via context7 if present); the deterministic
   fallback is the health dashboard's baseline (`schemaVersion 38`, which every
   newer Grafana auto-migrates on import).
2. **Audience**: ops on-call / capacity / owner. May justify more than one
   dashboard. A brief's audience section seeds this.
3. **Method per concern**: **RED** (request-driven services: rate/errors/
   duration) vs **USE** (resources: utilization/saturation/errors), inferred
   from the `Type` mix (counters + a duration histogram ⇒ RED; utilization
   gauges ⇒ USE), then confirmed.
4. **Decomposition (1..N)**, derived from the per-collector grouping: few
   collectors ⇒ **one** dashboard (a row per collector); many / distinct
   families / distinct audiences ⇒ an **overview + per-domain drill-downs**,
   linked. Propose the split read from `metrics.md`; the user restructures.
5. **SLI selection**: candidates surface from the rows of `metrics.md`; not
   every metric deserves a panel.
6. **Template variables**: the labels column feeds the candidates. `metrics.md`
   carries no cardinality, so **ask** which labels are low-cardinality
   partitioning dimensions; default conservative: never auto-add a variable on
   a presumed high-cardinality label. `datasource` + `job` (multi-select,
   `includeAll`) are always present, like the health dashboard.
7. **Units & thresholds**: absent from `metrics.md`, inferred from name
   suffixes (`_seconds`/`_bytes`/`_ratio`) and context7 best practice, then
   confirmed.
8. **Drill-down / links**: if N dashboards, how they link, resting on the
   deterministic `<namespace>-<slug>` uids the backbone emits.

The output of this dialogue is a **decomposition descriptor**: which
dashboards, which panels, which variables, which links.

## 3. Generate into a staging directory (never straight into `monitoring/grafana/`)

Generate into a fresh temp directory first, so nothing under
`monitoring/grafana/` is touched until step 4 has checked what an overwrite
would destroy. **Protection precedes materialization**: the backbone's
`emit_dashboard` writes each file with a truncating `>`, so pointing it at the
live `monitoring/grafana/` directly would clobber a hand-made or hand-edited
dashboard *before* step 4's guard could ever run. Stage first, reconcile in
step 4, place only what clears.

**Floor (always).** Run the shared backbone (the same generator this plugin's
golden test runs, so what you ship is what CI proves) into a staging dir:

```sh
staging=$(mktemp -d)
bash "${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/scripts/generate-dashboard.sh" \
  --repo . --out-dir "$staging" \
  --grafana-schema-version <schemaVersion from step 2> \
  --decompose <overview|per-collector from step 2's decomposition>
```

This writes valid, exportable `<slug>.json` files into `$staging`: one panel
per documented business metric, PromQL chosen by `Type` (`rate()` on counters,
`histogram_quantile()` on histograms with a synthesized `_bucket`, `avg` on
gauges; `$__rate_interval` windows; `by (job, instance)`), deterministic
`<namespace>-<slug>` uids, exportable `__inputs`/`__requires` with a
`${DS_PROMETHEUS}` datasource input. Every `expr` references only a metric in
`docs/metrics.md`, the anti-lie guarantee.

**Ceiling (interactive only, never breaks the floor).** Refine the STAGED
files in `$staging` (never the live directory) with the Grafana version known:

- **context7**: `resolve-library-id grafana` → `query-docs` for (a) the exact
  `schemaVersion` and panel model of that version, and (b) dataviz best
  practice (panel type by metric type, units, thresholds). Use it to refine the
  staged JSON (pick a stat/gauge/bar-gauge where it reads better than a
  timeseries, set thresholds, add a per-label breakdown the user asked for).
- **`dataviz`**: if the skill is present, use it to polish layout and color.
- **Name**: if the user supplied a name via `$ARGUMENTS`, set the staged
  overview dashboard's `.title` to it (edit the staged JSON in `$staging`). Leave
  its `uid` and filename/slug at their deterministic defaults. This renames only
  the display title, never the identity the drill-down links and regeneration
  rely on.
- Never add a metric absent from `docs/metrics.md`. The ceiling only reshapes
  what the floor already grounded.

**If context7 is absent**, ship the floor as-is and warn: "dashboards generated
against the baseline schema, not verified against Grafana <version>." **If
`dataviz` is absent**, ship without the polish. This is not a blocker: the command always
produces at least the valid deterministic floor.

## 4. Reconcile against `monitoring/grafana/`, then place: never clobber silently

For each staged `$staging/<slug>.json`, compare it against any existing
`monitoring/grafana/<slug>.json` **before** moving it into place (design §7,
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
then discard `$staging`. Never run `scaffold.sh`: this is file-by-file
adaptation, like `/add-collector`.

## 5. Update the wiring

Append the generated dashboards to `monitoring/README.md`'s import list
(Grafana UI / HTTP API / file provisioning), **without** claiming they are
auto-provisioned. Do not touch `docker-compose.yml` (no Grafana service is
added, since that depends on the user's Grafana topology) and do not touch the
health dashboard.

## 6. Verify: show the real output

Verify the dashboards you generated this run (`monitoring/grafana/overview.json`
plus any per-collector `<slug>.json` you just placed), not the whole directory,
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
Scope to `.panels[].targets[].expr` via `jq` (never the whole JSON text)
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
dashboard analogue of `make docs-check`'s PromQL bar, and exactly the property
the golden test asserts on this same backbone.

## 6b. Record the design in the journal

Only once step 6's `jq empty` and panel-expr anti-lie checks have both printed
green. Never before: an entry written ahead of its gate records an outcome
that has not happened yet.

If `docs/exporter-journal.md` is absent, offer to create it now, per
`project-journal.md`'s degradation rules, writing all eight headers from its
`## Format` with a placeholder line under every section this step cannot fill
yet (its `## Section ownership` rule), then continue. A file holding only the
two sections below would be missing headers, which is exactly what
`## Degradation` calls corrupt, so the next command would open with a
rebuild-or-leave prompt on a perfectly healthy repository. If the journal is
already corrupt, ask before writing anything.

**Never skip that offer on the grounds that a repository holding business
metrics must already have run `/add-collector` and been offered a journal
there.** An exporter scaffolded before the journal shipped has collectors and
no journal, which is precisely the upgrade path `## Degradation` describes,
and `## Section ownership` makes this command the only one that ever fills
`## Dashboards`: everything below is lost for good rather than merely
postponed. If the offer is declined, say so in one line and skip the rest of
this step, since the dashboards themselves are already on disk.

Then replace the journal's `## Dashboards` section with one line per dashboard
produced:

```
- <audience>, <RED | USE> because <reason>, <decomposition>, files: <paths>
```

The header itself is already in the file, carrying a placeholder line until
this step first fills it (`project-journal.md`'s `## Section ownership`):
replace what sits under the header, never write the header, and never read
that placeholder as an absent section.

Everything on that line is chosen in the dialogue above and **cannot be read
back from the JSON**: the emitted panels show what was built, never why RED
was chosen over USE, nor why the set was split into an overview plus
drill-downs rather than one dashboard. A second session that extends or
regenerates a dashboard reads this and stays consistent with the first.

Append one dated `## Session log` line naming the dashboards written.

## 7. What's next

- Import each dashboard in Grafana (UI "Import → Upload JSON file", the HTTP
  API, or file provisioning) and pick the Prometheus datasource when prompted.
- Re-running this command after `/add-collector` is safe: it reuses each uid
  and asks before overwriting a generated file (step 4).
- Commit with `feat(monitoring): add generated business dashboard(s)` (see
  `CONTRIBUTING.md`'s commit-message convention), staging
  `docs/exporter-journal.md` alongside them: the journal is a committed file
  (`project-journal.md`'s `## Lifecycle`), so step 6b's edit belongs in the
  same commit as the dashboards it describes.

End with the resumption block `project-journal.md` defines, and only once
step 6's checks have been shown green:

```
Dashboards written to <paths>. jq empty and the panel-expr anti-lie scan are green.
Journal: <N> of <M> collectors built. Next planned: `<next>` (<variant>).

Safe to /clear now: everything above is in docs/exporter-journal.md.
Then run:

    /add-collector <next>
```

When no unticked collector remains, drop the `Next planned:` clause and the
`Then run:` lines with it: this command is the end of the lifecycle, and
there is no next one to name. Print the block; never invoke the command.

With no usable journal (absent and step 6b's offer declined, or corrupt and
left untouched at its prompt) there is no list to read from. Drop the
`Journal:` line rather than inventing counts. The rest of the block still
holds: the checks are green and the dashboards are on disk.
