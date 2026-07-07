# Generate-Dashboard Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `/generate-dashboard [name]` — a design-led command that generates 1..N exportable business Grafana dashboards for an already-scaffolded exporter, anchored entirely in `docs/metrics.md`, on top of a deterministic, golden-tested shared backbone.

**Architecture:** A deterministic backbone script (`skills/prometheus-exporter/scripts/generate-dashboard.sh`, `bash`+`jq`, container-first, invoked via `${CLAUDE_PLUGIN_ROOT}`) parses `docs/metrics.md` + the repo's real `namespace` and emits valid exportable Grafana JSON — one panel per documented business metric, type-correct PromQL, deterministic `<namespace>-<slug>` uids — and is invoked identically by both the command and the golden test (single source, no drift). The command (`commands/generate-dashboard.md`, house-styled on `/add-collector`) wraps that floor with an interactive ceiling: a `metrics.md`-anchored RED/USE dialogue, optional `context7`/`dataviz` enrichment, brief seeding, and idempotent regen — none of which the golden exercises. The golden sub-check (mirroring `golden-smoke.sh`'s mechanical `/add-collector` sub-check) invokes only the backbone and asserts JSON validity, the anti-lie `expr ⊆ metrics.md` property, and cleanliness.

**Tech Stack:** POSIX `sh` + `jq` (backbone + its shell test harness, container-first native→docker→podman like `golden-smoke.sh`), Grafana dashboard JSON model (schemaVersion 38 baseline, "Export for sharing externally" `__inputs`/`__requires`/`__elements` + `${DS_PROMETHEUS}`), PromQL (`$__rate_interval`, `rate()`, `histogram_quantile()`), Markdown command/reference prose (`commands/`, `skills/prometheus-exporter/references/`), `context7`/`dataviz` as optional interactive enhancers.

## Global Constraints

- **grep=0**: no source-project name `slurm` and no maintainer handle `sckyzo` in shipped content (enforced by `test/zero-source-grep.sh` — `slurm` repo-wide excluding `docs/`/`.git`/`.superpowers`/`test/`, `sckyzo` scoped to `skills/`/`commands/`/`agents/`; note it greps neither `sacct` nor any other source name); generated JSON in a scaffolded repo must also be clean (the golden sweeps `test/_work` for `slurm`/`sckyzo`, and this plan's Task 5 adds a dashboard-local sweep too).
- **No AI/automation attribution in any git artifact**: commit steps use `git -c commit.gpgsign=false commit -m "<conventional message with scope>"` — NO `Co-authored-by`, NO `Claude-Session:` trailer, NO "Generated with", NO claude.ai link. Conventional Commits with scope.
- **Auto-portance**: the command depends on no personal `CLAUDE.md`; `context7` and `dataviz` are used *if present, never required* (graceful degradation → deterministic baseline + warning).
- **Documented ⊆ dashboard**: every panel `expr` references only metrics present in `docs/metrics.md`.
- **Exportable format**: `__inputs`/`__requires`, datasource as `${DS_PROMETHEUS}`, **deterministic uids** `<namespace>-<slug>` (so drill-down links survive import + regeneration).
- **No re-scaffold**: never invoke `scaffold.sh`; single-file operations on an already-scaffolded repo, reading real values.
- **Container-first** for any tool dependency (jq etc.): native → docker → podman → explicit SKIP/error, matching `golden-smoke.sh`.
- **Backbone is deterministic & shared**: one generator invoked by both the command and the golden test; no context7/LLM in it.
- **PromQL best practice**: `$__rate_interval` windows, `rate()`/`histogram_quantile()`/`avg` by `Type`, `by (job, instance)`.

**Additional locked conventions (from the design spec and house style):**

- Backbone lives **outside `assets/`** (`skills/prometheus-exporter/scripts/`), so `scaffold.sh` — which copies only `assets/` — never ships it into a target repo.
- **Datasource shape:** mirror `health-dashboard.json.tmpl` exactly — declare `DS_PROMETHEUS` in `__inputs`, ship a `datasource` (type `datasource`) + `job` (multi-select, `includeAll`) template variable, and reference `${datasource}` in every panel/target. The `${DS_PROMETHEUS}` input is the exportable external-input declaration; `${datasource}` is what panels resolve against — this is precisely how the shipped health dashboard reconciles "exportable input" with "runtime datasource variable".
- **schemaVersion:** deterministic floor = **38** (the health dashboard's proven-importable baseline; Grafana auto-migrates older schemas forward on import). The interactive ceiling MAY pass a context7-resolved value for a newer major (current Grafana reports `schemaVersion: 41`); the golden always uses the 38 default.
- **Provenance:** every generated dashboard carries `tags: ["generated", "<namespace>", "business"]` and a fixed provenance sentence in `description` — no free text from `metrics.md` is interpolated into the deterministic floor (avoids JSON-escaping risk; all interpolated strings pass through `jq --arg`).
- **Histogram synthesis:** `metrics.md` lists a Histogram by its parent name only; the backbone synthesizes `<name>_bucket` for `histogram_quantile`, and the anti-lie check treats `<h>_bucket`/`<h>_sum`/`<h>_count` as derived-from-documented for every documented Histogram `<h>` (same rule as `docs-check`'s own "do not add a separate `_bucket` row" note).
- All shipped artifacts and commit messages in **English**. `bash test/zero-source-grep.sh` must pass before every commit; `claude plugin validate .` must pass for the command/docs tasks.

---

## File Structure

**Created:**
- `skills/prometheus-exporter/scripts/generate-dashboard.sh` — the deterministic backbone: parse `docs/metrics.md` + `namespace`, emit exportable Grafana JSON (Tasks 1-3). Single responsibility: `(repo, grafana-schema-version, decomposition) → valid dashboard JSON files`. No dialogue, no context7.
- `test/generate-dashboard-backbone.sh` — plain-`sh` assertion harness for the backbone (`set -eu`, `die()`, `== …==` progress, house style of `golden-smoke.sh`). Built in Task 1, extended in Tasks 2-3.
- `test/fixtures/dashboard/http/docs/metrics.md` — a concrete (no-`@@VAR@@`) metrics doc exercising Gauge/Counter/Histogram/labeled-gauge + a `## Self-instrumentation` section to prove exclusion (Task 1).
- `test/fixtures/dashboard/http/cmd/demo_exporter/main.go` — minimal file carrying `const namespace = "demo"` for the namespace reader (Task 1).
- `test/fixtures/dashboard/empty/docs/metrics.md` — a metrics doc with ONLY `## Self-instrumentation` (the zero-business-metric refusal case) (Task 1).
- `test/fixtures/dashboard/empty/cmd/demo_exporter/main.go` — minimal `const namespace = "demo"` for the empty fixture (Task 1).
- `commands/generate-dashboard.md` — the command (EN, grep=0, house-styled on `/add-collector`) (Task 4).

**Modified:**
- `test/golden-smoke.sh` — the end-to-end dashboard sub-check, gated to `--forge none` cells (http + cli) (Task 5).
- `skills/prometheus-exporter/references/dashboards-and-alerts.md` — flip "The business dashboard is v0.2 — not shipped" to "shipped", describe the real flow (Task 6).
- `skills/prometheus-exporter/SKILL.md` — update the "future `/generate-dashboard`" mentions to "shipped" (Task 6).
- `skills/prometheus-exporter/assets/monitoring/README.md.tmpl` — align the "Business dashboards" section with the real behavior (Task 6).
- `ROADMAP.md` — move the `/generate-dashboard` item to delivered/unreleased (Task 6).
- `CHANGELOG.md` — add the `## [Unreleased]` entry (Task 6).

**Explicitly NOT modified:** `skills/prometheus-exporter/assets/monitoring/grafana/health-dashboard.json.tmpl` (the health dashboard is never touched — design §1), `skills/prometheus-exporter/assets/scaffold.sh` (the backbone is never scaffolded, so `scaffold.sh` needs no change), and any collector/`metrics.md.tmpl` (the command reads a scaffolded repo's real doc, it never edits templates).

---

### Task 1: Backbone — metrics.md parser, namespace reader, zero-metric refusal

**Files:**
- Create: `skills/prometheus-exporter/scripts/generate-dashboard.sh`
- Create: `test/generate-dashboard-backbone.sh`
- Create: `test/fixtures/dashboard/http/docs/metrics.md`
- Create: `test/fixtures/dashboard/http/cmd/demo_exporter/main.go`
- Create: `test/fixtures/dashboard/empty/docs/metrics.md`
- Create: `test/fixtures/dashboard/empty/cmd/demo_exporter/main.go`

**Interfaces:**
- Produces: `generate-dashboard.sh --repo <path> [--out-dir <path>] [--grafana-schema-version <N>] [--decompose overview|per-collector] [--print-model]`. Exit codes: `0` success, `1` generic error, `2` usage error, `3` no business metrics documented (the tested refusal), `4` no `jq` and no container engine. `--print-model` prints the parsed model to stdout as TAB-separated lines (`namespace\t<ns>` then one `metric\t<Collector>\t<name>\t<Type>\t<labels|->` per business metric) and writes no files — the test seam Tasks 2-3 build their JSON assertions on. Consumed by: Task 2/3 (the emit stages call `parse_metrics`/`read_namespace`), the command (Task 4), the golden (Task 5).

This is the deterministic floor's foundation: it reuses the parsing *contract* of `internal/collector/docs_check_test.go`'s `parseMetricsDoc` (name regex `^` + backtick + `([A-Za-z_][A-Za-z0-9_]*)` + backtick + `$`; label regex extracts every backticked `([A-Za-z_][A-Za-z0-9_]*)`; cells split on `|`; `<!-- … -->` blocks skipped) but adds two things `parseMetricsDoc` does not do: it tracks the current `## <Name>Collector` header so metrics are grouped by collector, and it **excludes the `## Self-instrumentation` section** (already covered by the health dashboard — design §3). It carries no `jq` dependency yet (parsing is pure `grep`/`sed`/`awk`), but it establishes the `run_jq` container-first helper and the `--print-model` seam.

- [ ] **Step 1: Create the http fixture's metrics doc**

Create `test/fixtures/dashboard/http/docs/metrics.md`:

```markdown
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
```

- [ ] **Step 2: Create the http fixture's main.go (namespace source)**

Create `test/fixtures/dashboard/http/cmd/demo_exporter/main.go`:

```go
package main

// Minimal fixture for generate-dashboard.sh's namespace reader — only the
// const line below is read; this file is never compiled.
const namespace = "demo"

func main() {}
```

- [ ] **Step 3: Create the empty (self-instrumentation-only) fixture**

Create `test/fixtures/dashboard/empty/docs/metrics.md`:

```markdown
# Metrics

## Self-instrumentation

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_exporter_collector_success` | Gauge | `collector` | Whether the last scrape of the collector succeeded (1=success, 0=failure). |
| `demo_exporter_collector_duration_seconds` | Gauge | `collector` | Duration of the last scrape for the collector, in seconds. |
```

Create `test/fixtures/dashboard/empty/cmd/demo_exporter/main.go`:

```go
package main

const namespace = "demo"

func main() {}
```

- [ ] **Step 4: Write the failing backbone test harness (parse + refusal)**

Create `test/generate-dashboard-backbone.sh`:

```sh
#!/bin/sh
# generate-dashboard-backbone.sh — unit tests for the deterministic dashboard
# backbone (skills/prometheus-exporter/scripts/generate-dashboard.sh). Plain
# POSIX sh + set -eu, same house style as golden-smoke.sh: no bats, an
# explicit die() (exits non-zero), "== … ==" progress lines, and a final PASS
# banner. Runs the backbone against the committed fixtures under
# test/fixtures/dashboard/ (never a live repo), so it is hermetic and
# rerunnable. jq is required for the JSON assertions in Tasks 2-3; this task's
# own assertions (parse model + refusal) need no jq.
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
prog=$(basename "$0")
backbone="$root/skills/prometheus-exporter/scripts/generate-dashboard.sh"
http_fixture="$root/test/fixtures/dashboard/http"
empty_fixture="$root/test/fixtures/dashboard/empty"
work="$root/test/_work/dashboard-backbone"

die() {
  echo "$prog: error: $1" >&2
  exit 1
}

[ -f "$backbone" ] || die "backbone not found: $backbone"
rm -rf "$work"
mkdir -p "$work"

echo "== model: namespace is read from cmd/*/main.go's const namespace =="
model=$(sh "$backbone" --repo "$http_fixture" --print-model)
printf '%s\n' "$model" | grep -qxF "namespace	demo" \
  || die "expected 'namespace<TAB>demo' in --print-model output, got:
$model"

echo "== model: exactly the 5 business metrics, self-instrumentation excluded =="
metric_count=$(printf '%s\n' "$model" | grep -c '^metric	') || true
[ "$metric_count" -eq 5 ] || die "expected 5 business metrics, got $metric_count:
$model"
printf '%s\n' "$model" | grep -q '^metric	ExampleCollector	demo_items	Gauge	-$' \
  || die "expected the demo_items Gauge row grouped under ExampleCollector"
printf '%s\n' "$model" | grep -q '^metric	RequestsCollector	demo_request_duration_seconds	Histogram	-$' \
  || die "expected the demo_request_duration_seconds Histogram row under RequestsCollector"
printf '%s\n' "$model" | grep -q '^metric	RequestsCollector	demo_queue_depth	Gauge	queue$' \
  || die "expected the demo_queue_depth Gauge row to carry its 'queue' label"
if printf '%s\n' "$model" | grep -q 'demo_exporter_collector_success'; then
  die "self-instrumentation metric leaked into the model — the ## Self-instrumentation section must be excluded"
fi

echo "== refusal: a self-instrumentation-only repo exits 3, not an empty dashboard =="
rc=0
out=$(sh "$backbone" --repo "$empty_fixture" --out-dir "$work" 2>&1) || rc=$?
[ "$rc" -eq 3 ] || die "expected exit 3 on a repo with zero business metrics, got exit $rc:
$out"
printf '%s\n' "$out" | grep -qi 'no business metrics' \
  || die "expected a 'no business metrics' message on refusal, got:
$out"

echo "$prog: PASS — parser, namespace reader, and zero-metric refusal all green"
```

- [ ] **Step 5: Run the harness to confirm it fails (RED)**

Run: `sh test/generate-dashboard-backbone.sh`
Expected: **FAIL** — `generate-dashboard-backbone.sh: error: backbone not found: …/scripts/generate-dashboard.sh` (the script does not exist yet).

- [ ] **Step 6: Create the backbone with parsing, namespace reader, refusal, and the jq helper**

Create `skills/prometheus-exporter/scripts/generate-dashboard.sh`:

```sh
#!/bin/sh
# generate-dashboard.sh — the deterministic backbone behind /generate-dashboard.
#
# Reads an already-scaffolded exporter repo's docs/metrics.md and its real
# namespace (const namespace in cmd/*/main.go), then emits 1..N exportable
# Grafana dashboards — one panel per DOCUMENTED business metric, PromQL chosen
# by the metric's Type, deterministic <namespace>-<slug> uids. It is
# deterministic by construction: no dialogue, no context7, no LLM — which is
# exactly what lets both /generate-dashboard AND test/golden-smoke.sh invoke
# this one script (single source, no drift). The command layers an interactive
# ceiling (dialogue, context7, dataviz) on top; the golden bypasses all of it
# and tests only this floor.
#
# It never runs scaffold.sh and never edits templates: single-file operations
# on real values, exactly like /add-collector.
#
# Usage:
#   generate-dashboard.sh --repo <path> --out-dir <path>
#                         [--grafana-schema-version <N>]   (default 38)
#                         [--decompose overview|per-collector] (default overview)
#   generate-dashboard.sh --repo <path> --print-model      (debug/test seam)
#
# Exit codes: 0 ok, 1 error, 2 usage, 3 no business metrics documented,
#             4 no jq and no container engine.
set -eu

prog=$(basename "$0")

die() { echo "$prog: error: $1" >&2; exit 1; }
usage() {
  cat >&2 <<EOF
Usage: $prog --repo <path> --out-dir <path> [--grafana-schema-version <N>]
             [--decompose overview|per-collector]
       $prog --repo <path> --print-model
EOF
  exit 2
}

repo=""
out_dir=""
schema_version=38
decompose=overview
print_model=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
    --out-dir) [ $# -ge 2 ] || usage; out_dir=$2; shift 2 ;;
    --grafana-schema-version) [ $# -ge 2 ] || usage; schema_version=$2; shift 2 ;;
    --decompose) [ $# -ge 2 ] || usage; decompose=$2; shift 2 ;;
    --print-model) print_model=1; shift ;;
    -h|--help) usage ;;
    *) echo "$prog: error: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$repo" ] || usage
[ -d "$repo" ] || die "repo not found: $repo"
case "$decompose" in overview|per-collector) ;; *) die "--decompose must be overview or per-collector" ;; esac

# run_jq — container-first jq, native → docker → podman → exit 4. Every jq call
# in this script is stdin/args → stdout only (no bind mounts needed): filters
# are passed as args, data arrives on stdin, output goes to stdout. That keeps
# the containerized fallback a plain `run … -i <image>` with no volume
# plumbing. Pinned image tag, bumped periodically (same discipline as
# golden-smoke.sh's SYFT_VERSION/GORELEASER_VERSION).
JQ_IMAGE=ghcr.io/jqlang/jq:1.7.1
run_jq() {
  if command -v jq >/dev/null 2>&1; then
    jq "$@"
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -i "$JQ_IMAGE" "$@"
  elif command -v podman >/dev/null 2>&1; then
    podman run --rm -i "$JQ_IMAGE" "$@"
  else
    echo "$prog: error: jq is required (native, or a docker/podman engine to run $JQ_IMAGE) — install jq or a container engine" >&2
    exit 4
  fi
}

# read_namespace — the metric prefix and uid prefix, read from the real
# const namespace = "<literal>" in cmd/*/main.go (design §3). Never guessed.
read_namespace() {
  ns=$(grep -hoE 'const[[:space:]]+namespace[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' "$repo"/cmd/*/main.go 2>/dev/null \
        | head -n1 | sed -E 's/.*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/')
  [ -n "$ns" ] || die "could not read 'const namespace = \"…\"' from $repo/cmd/*/main.go"
  printf '%s\n' "$ns"
}

# parse_metrics — emit one TAB line per DOCUMENTED business metric:
#   <Collector>\t<name>\t<Type>\t<labels-comma-joined-or-->
# Reuses docs_check_test.go's parseMetricsDoc CONTRACT (backtick-quoted name
# cell, backtick-quoted labels, `|`-split cells, <!-- --> comment skipping) and
# adds two things it lacks: current-## header tracking (so metrics are grouped
# by collector) and exclusion of the ## Self-instrumentation section (design
# §3 — already covered by the health dashboard). awk keeps it single-pass and
# dependency-free.
parse_metrics() {
  doc="$repo/docs/metrics.md"
  [ -f "$doc" ] || die "docs/metrics.md not found: $doc"
  awk '
    /<!--/ { incomment=1 }
    incomment { if (/-->/) incomment=0; next }
    /^##[[:space:]]+/ {
      hdr=$0; sub(/^##[[:space:]]+/,"",hdr); sub(/[[:space:]]+$/,"",hdr)
      section=hdr
      # Self-instrumentation is excluded outright.
      if (tolower(section) ~ /self-instrumentation/) { skip=1 } else { skip=0 }
      next
    }
    skip { next }
    /^\|/ {
      line=$0
      # Split into cells on "|"; cells[2]=name, cells[3]=type, cells[4]=labels.
      n=split(line, cells, "|")
      if (n < 5) next
      name=cells[2]; type=cells[3]; labels=cells[4]
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",name)
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",type)
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",labels)
      # Name cell must be exactly one backtick-quoted identifier (excludes the
      # header row "Metric" and the |---|---| separator row).
      if (name !~ /^`[A-Za-z_][A-Za-z0-9_]*`$/) next
      gsub(/`/,"",name)
      # Type is informational — the real parseMetricsDoc/docs-check never
      # validates it, so this must not either. An unrecognized Type is WARNED
      # (to stderr, so it never pollutes the model on stdout) and the metric is
      # still INCLUDED, never silently dropped: silently dropping a typo'd Type
      # could, in the degenerate case, flip a repo with real metrics into the
      # zero-business-metric refusal (exit 3). expr_for treats an unknown Type
      # as a gauge.
      if (type != "Gauge" && type != "Counter" && type != "Histogram" && type != "Summary") {
        printf "generate-dashboard.sh: warning: metric `%s` has an unrecognized Type `%s` (expected Gauge/Counter/Histogram/Summary) — treating it as a gauge\n", name, type > "/dev/stderr"
      }
      # Extract each backticked label; "-" (or no backticks) yields none.
      out=""
      s=labels
      while (match(s, /`[A-Za-z_][A-Za-z0-9_]*`/)) {
        tok=substr(s, RSTART, RLENGTH); gsub(/`/,"",tok)
        out = (out=="" ? tok : out "," tok)
        s=substr(s, RSTART+RLENGTH)
      }
      if (out=="") out="-"
      if (section=="") section="Metrics"
      printf "metric\t%s\t%s\t%s\t%s\n", section, name, type, out
    }
  ' "$doc"
}

ns=$(read_namespace)
model=$(parse_metrics)
metric_lines=$(printf '%s\n' "$model" | grep -c '^metric	' || true)

if [ "$print_model" -eq 1 ]; then
  printf 'namespace\t%s\n' "$ns"
  [ -n "$model" ] && printf '%s\n' "$model"
  exit 0
fi

if [ "$metric_lines" -eq 0 ]; then
  echo "$prog: error: no business metrics documented in $repo/docs/metrics.md (only self-instrumentation) — add collectors and document them with 'make docs-check' first" >&2
  exit 3
fi

# Emission (Tasks 2-3) is wired below in later tasks; --out-dir is required for
# it.
[ -n "$out_dir" ] || usage
die "dashboard emission not implemented yet (Task 2)"
```

- [ ] **Step 7: Run the harness to confirm it passes (GREEN)**

Run: `sh test/generate-dashboard-backbone.sh`
Expected: **PASS** — all four `==` checks green (`namespace demo`; 5 business metrics with the grouping/label/exclusion assertions; refusal exit 3 with the "no business metrics" message), ending `generate-dashboard-backbone.sh: PASS`.

- [ ] **Step 8: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add skills/prometheus-exporter/scripts/generate-dashboard.sh \
        test/generate-dashboard-backbone.sh \
        test/fixtures/dashboard/
git -c commit.gpgsign=false commit -m "feat(dashboard): parse docs/metrics.md into a dashboard metric model"
```

---

### Task 2: Backbone — exportable baseline dashboard (1 panel/metric, type-correct PromQL)

**Files:**
- Modify: `skills/prometheus-exporter/scripts/generate-dashboard.sh` (replace the Task 1 `die "… not implemented yet"` tail with the single-`overview` emit path; add `unit_for`, `expr_for`, `emit_panel`, `emit_dashboard`)
- Modify: `test/generate-dashboard-backbone.sh` (append the JSON-emission assertions)

**Interfaces:**
- Consumes: `read_namespace`, `parse_metrics`, `run_jq` (Task 1).
- Produces: `emit_dashboard <slug> <title> <links-json> <model-lines>` writing `<out-dir>/<slug>.json`; `expr_for <name> <Type>` returning the PromQL string; `unit_for <name>` returning a Grafana unit (`s`/`bytes`/`percentunit`/empty); `emit_panel` returning one panel object as JSON. The default single-dashboard slug is `overview` → uid `<namespace>-overview`, file `<out-dir>/overview.json`. Consumed by Task 3 (decomposition reuses `emit_dashboard`/`emit_panel`), Task 5 (golden asserts the emitted JSON), Task 4 (command runs it).

This is the crux deliverable: a valid **exportable** Grafana dashboard, mirroring `health-dashboard.json.tmpl`'s shape (schemaVersion 38, `__inputs`/`__requires`/`__elements`, `datasource`+`job` template variables, `by (job, instance)` aggregation) but with concrete metric names and one `timeseries` panel per documented business metric, grouped into one `row` per collector. PromQL is chosen by `Type` (grounded via context7): Counter → `sum by (job, instance) (rate(<m>{job=~"$job"}[$__rate_interval]))`; Histogram → `histogram_quantile(0.95, sum by (job, instance, le) (rate(<m>_bucket{job=~"$job"}[$__rate_interval])))` (classic client_golang histogram — the `le` label MUST be in the `by` clause; `_bucket` is synthesized because `metrics.md` never lists it); Gauge/Summary → `avg by (job, instance) (<m>{job=~"$job"})`. Every string that reaches the JSON passes through `jq --arg`, so no hand-rolled escaping and no injection surface.

- [ ] **Step 1: Append the JSON-emission assertions to the harness (RED)**

Append to `test/generate-dashboard-backbone.sh`, immediately before the final `echo "$prog: PASS …"` line:

```sh
echo "== emit: overview.json is well-formed and exportable =="
rm -rf "$work"; mkdir -p "$work"
sh "$backbone" --repo "$http_fixture" --out-dir "$work" >/dev/null
overview="$work/overview.json"
[ -f "$overview" ] || die "expected $overview to be generated"
jq empty "$overview" || die "overview.json is not valid JSON"
[ "$(jq -r '.uid' "$overview")" = "demo-overview" ] || die "uid must be demo-overview (namespace-slug), got $(jq -r '.uid' "$overview")"
[ "$(jq -r '.schemaVersion' "$overview")" = "38" ] || die "schemaVersion must default to 38"
[ "$(jq -r '.__inputs[0].name' "$overview")" = "DS_PROMETHEUS" ] || die "exportable format must declare DS_PROMETHEUS in __inputs"
jq -e '.__elements == {} and (.__requires | length > 0)' "$overview" >/dev/null || die "exportable format must carry __elements and __requires"
jq -e '.tags | index("generated")' "$overview" >/dev/null || die "generated dashboards must be tagged 'generated' for regen detection"
jq -e '[.templating.list[].name] == ["datasource","job"]' "$overview" >/dev/null || die "must ship datasource + job template variables like the health dashboard"
jq -e '.templating.list[] | select(.name=="job") | .multi == true and .includeAll == true' "$overview" >/dev/null || die "job variable must be multi-select with includeAll, like health"

echo "== emit: one timeseries panel per business metric, one row per collector =="
[ "$(jq '[.panels[] | select(.type=="timeseries")] | length' "$overview")" = "5" ] || die "expected exactly 5 timeseries panels (one per business metric)"
[ "$(jq '[.panels[] | select(.type=="row")] | length' "$overview")" = "2" ] || die "expected exactly 2 rows (RequestsCollector, ExampleCollector)"

echo "== emit: an odd-count non-last collector's trailing panel never overlaps the next row header =="
# RequestsCollector (3 metrics, odd, listed FIRST in the fixture) leaves a
# dangling half-row; its trailing demo_queue_depth panel must sit strictly
# above ExampleCollector's row header (>= panel y + panel height 8), proving
# emit_dashboard flushed the half-row. Without the flush the header lands at
# demo_queue_depth's own y (overlap).
qd_y=$(jq -r '.panels[] | select(.title=="demo_queue_depth") | .gridPos.y' "$overview")
ex_row_y=$(jq -r '.panels[] | select(.type=="row" and .title=="ExampleCollector") | .gridPos.y' "$overview")
[ "$ex_row_y" -ge "$((qd_y + 8))" ] || die "ExampleCollector row header (y=$ex_row_y) overlaps RequestsCollector's trailing demo_queue_depth panel (y=$qd_y) — half-row not flushed"

echo "== emit: PromQL is type-correct, uses \$__rate_interval and by (job, instance) =="
gauge_expr=$(jq -r '.panels[] | select(.title=="demo_items") | .targets[0].expr' "$overview")
[ "$gauge_expr" = 'avg by (job, instance) (demo_items{job=~"$job"})' ] || die "gauge expr wrong: $gauge_expr"
counter_expr=$(jq -r '.panels[] | select(.title=="demo_requests_total") | .targets[0].expr' "$overview")
[ "$counter_expr" = 'sum by (job, instance) (rate(demo_requests_total{job=~"$job"}[$__rate_interval]))' ] || die "counter expr wrong: $counter_expr"
hist_expr=$(jq -r '.panels[] | select(.title=="demo_request_duration_seconds") | .targets[0].expr' "$overview")
[ "$hist_expr" = 'histogram_quantile(0.95, sum by (job, instance, le) (rate(demo_request_duration_seconds_bucket{job=~"$job"}[$__rate_interval])))' ] || die "histogram expr wrong: $hist_expr"

echo "== emit: units inferred from name suffix =="
[ "$(jq -r '.panels[] | select(.title=="demo_request_duration_seconds") | .fieldConfig.defaults.unit' "$overview")" = "s" ] || die "_seconds histogram must get unit 's'"

echo "== emit: every panel datasource is the \${datasource} variable, never a hardcoded uid =="
jq -e '[.panels[] | select(.type=="timeseries") | .datasource.uid] | unique == ["${datasource}"]' "$overview" >/dev/null || die "panels must reference the \${datasource} variable"
jq -e '[.panels[] | select(.type=="timeseries") | .targets[0].datasource.uid] | unique == ["${datasource}"]' "$overview" >/dev/null || die "targets must reference the \${datasource} variable"
```

- [ ] **Step 2: Run the harness to confirm the new assertions fail (RED)**

Run: `sh test/generate-dashboard-backbone.sh`
Expected: **FAIL** at the first new check — the Task 1 tail still `die`s with `dashboard emission not implemented yet (Task 2)`, so `overview.json` is never written and the harness dies on `expected …/overview.json to be generated`.

- [ ] **Step 3: Replace the Task 1 tail with the emit functions and single-overview path**

In `skills/prometheus-exporter/scripts/generate-dashboard.sh`, replace this Task 1 tail:

```sh
# Emission (Tasks 2-3) is wired below in later tasks; --out-dir is required for
# it.
[ -n "$out_dir" ] || usage
die "dashboard emission not implemented yet (Task 2)"
```

with:

```sh
[ -n "$out_dir" ] || usage
mkdir -p "$out_dir"

# unit_for — infer a Grafana unit from the Prometheus name suffix (design §5.7:
# units are absent from metrics.md, inferred from _seconds/_bytes/_ratio). An
# empty result means "leave unit unset" (Grafana's dimensionless default).
unit_for() {
  case "$1" in
    *_seconds) echo "s" ;;
    *_bytes) echo "bytes" ;;
    *_ratio) echo "percentunit" ;;
    *) echo "" ;;
  esac
}

# expr_for <name> <Type> — PromQL by metric Type (design §6.3, grounded via
# context7). $__rate_interval windows (never a hardcoded [5m]); by (job,
# instance) for multi-instance safety; the Histogram _bucket series is
# synthesized from the parent (metrics.md never lists _bucket) and the le label
# is added to the by-clause, as a classic client_golang histogram requires.
expr_for() {
  _name=$1; _type=$2
  case "$_type" in
    Counter)
      printf 'sum by (job, instance) (rate(%s{job=~"$job"}[$__rate_interval]))' "$_name" ;;
    Histogram)
      printf 'histogram_quantile(0.95, sum by (job, instance, le) (rate(%s_bucket{job=~"$job"}[$__rate_interval])))' "$_name" ;;
    *) # Gauge, Summary
      printf 'avg by (job, instance) (%s{job=~"$job"})' "$_name" ;;
  esac
}

# emit_panel <id> <x> <y> <w> <h> <title> <expr> <unit> — one timeseries panel
# object, built entirely with jq --arg (no hand-rolled JSON escaping). Mirrors
# the health dashboard's own timeseries panel (palette-classic line style,
# table legend, multi tooltip). unit is added only when non-empty.
emit_panel() {
  run_jq -n \
    --argjson id "$1" --argjson x "$2" --argjson y "$3" --argjson w "$4" --argjson h "$5" \
    --arg title "$6" --arg expr "$7" --arg unit "$8" \
    '{
      datasource: {type:"prometheus", uid:"${datasource}"},
      type:"timeseries", id:$id, title:$title,
      gridPos:{h:$h,w:$w,x:$x,y:$y},
      fieldConfig:{
        defaults: (
          {color:{mode:"palette-classic"},
           custom:{drawStyle:"line",fillOpacity:10,lineInterpolation:"smooth",lineWidth:2,showPoints:"never",spanNulls:false,stacking:{group:"A",mode:"none"}}}
          + (if $unit=="" then {} else {unit:$unit} end)
        ),
        overrides:[]
      },
      options:{legend:{calcs:["last","max"],displayMode:"table",placement:"bottom",showLegend:true},tooltip:{mode:"multi",sort:"desc"}},
      targets:[{datasource:{type:"prometheus",uid:"${datasource}"},expr:$expr,legendFormat:"{{job}}/{{instance}}",refId:"A"}]
    }'
}

# emit_dashboard <slug> <title> <links_json> <model> — assemble one exportable
# dashboard from the model lines given on stdin-substitute (passed as $4), and
# write <out-dir>/<slug>.json. Panels are laid out two-per-row (w=12,h=8), a
# row header per collector, y advancing deterministically. All panel objects
# are collected into a temp file and slurped into a JSON array so the whole
# thing is one jq assembly at the end.
emit_dashboard() {
  _slug=$1; _title=$2; _links=$3; _model=$4
  _panels_tmp="$out_dir/.panels.$_slug.json"
  : > "$_panels_tmp"
  _id=1; _y=0; _col=""; _slot=0
  printf '%s\n' "$_model" | while IFS='	' read -r _tag _collector _name _type _labels; do
    [ "$_tag" = metric ] || continue
    if [ "$_collector" != "$_col" ]; then
      # Flush a dangling half-row left by the previous collector: an odd panel
      # count leaves _slot odd with _y NOT yet advanced past that trailing
      # panel's band, so without this a NON-last odd-count collector's next
      # row header would land at the same y as that panel (a visual overlap in
      # Grafana). Only fires when a previous collector was seen (_col non-empty
      # ⇒ _slot reflects real panels); the very first collector has _slot=0.
      if [ $(( _slot % 2 )) -eq 1 ]; then _y=$((_y+8)); fi
      # New collector: emit a full-width row header, reset the 2-column slot.
      run_jq -n --argjson id "$_id" --arg title "$_collector" --argjson y "$_y" \
        '{type:"row",id:$id,title:$title,collapsed:false,gridPos:{h:1,w:24,x:0,y:$y}}' >> "$_panels_tmp"
      _id=$((_id+1)); _y=$((_y+1)); _col="$_collector"; _slot=0
    fi
    _x=$(( (_slot % 2) * 12 ))
    _expr=$(expr_for "$_name" "$_type")
    _unit=$(unit_for "$_name")
    emit_panel "$_id" "$_x" "$_y" 12 8 "$_name" "$_expr" "$_unit" >> "$_panels_tmp"
    _id=$((_id+1)); _slot=$((_slot+1))
    [ $(( _slot % 2 )) -eq 0 ] && _y=$((_y+8))
  done

  panels_json=$(run_jq -s '.' < "$_panels_tmp")
  rm -f "$_panels_tmp"

  run_jq -n \
    --argjson panels "$panels_json" \
    --argjson links "$_links" \
    --arg ns "$ns" --arg title "$_title" --arg uid "$ns-$_slug" \
    --argjson schema "$schema_version" \
    '{
      __inputs:[{name:"DS_PROMETHEUS",label:"Prometheus",description:"",type:"datasource",pluginId:"prometheus",pluginName:"Prometheus"}],
      __elements:{},
      __requires:[
        {type:"grafana",id:"grafana",name:"Grafana",version:"10.0.0"},
        {type:"datasource",id:"prometheus",name:"Prometheus",version:"1.0.0"},
        {type:"panel",id:"timeseries",name:"Time series",version:""},
        {type:"panel",id:"row",name:"Row",version:""}
      ],
      annotations:{list:[]},
      description:("Business metrics for " + $ns + ", generated by /generate-dashboard from docs/metrics.md. Safe to regenerate — see monitoring/README.md."),
      editable:true,
      graphTooltip:1,
      links:$links,
      panels:$panels,
      refresh:"30s",
      schemaVersion:$schema,
      tags:["generated",$ns,"business"],
      templating:{list:[
        {current:{},hide:0,includeAll:false,label:"Data Source",multi:false,name:"datasource",options:[],query:"prometheus",refresh:1,regex:"",type:"datasource"},
        {current:{},datasource:{type:"prometheus",uid:"${datasource}"},hide:0,includeAll:true,label:"Job",multi:true,name:"job",options:[],query:("label_values(" + $ns + "_exporter_collector_success, job)"),refresh:2,regex:"",sort:1,type:"query"}
      ]},
      time:{from:"now-6h",to:"now"},
      timepicker:{},
      timezone:"browser",
      title:$title,
      uid:$uid,
      version:1
    }' > "$out_dir/$_slug.json"
}

# Task 2 ships only the single-overview decomposition; Task 3 adds
# per-collector. A trivial default so the golden needs no dialogue in CI.
case "$decompose" in
  overview)
    emit_dashboard overview "$ns — Business Overview" '[]' "$model"
    echo "$prog: generated $out_dir/overview.json"
    ;;
  per-collector)
    die "--decompose per-collector not implemented yet (Task 3)"
    ;;
esac
```

- [ ] **Step 4: Run the harness to confirm all assertions pass (GREEN)**

Run: `sh test/generate-dashboard-backbone.sh`
Expected: **PASS** — the Task 1 checks plus every new `emit:` check green (valid JSON; uid `demo-overview`; schemaVersion 38; `DS_PROMETHEUS` input; `__elements`/`__requires`; `generated` tag; `datasource`+`job` vars with multi/includeAll; 5 timeseries + 2 rows; the non-last odd-count collector's trailing panel not overlapping the next row header; the three exact PromQL strings; unit `s`; `${datasource}` everywhere), ending `generate-dashboard-backbone.sh: PASS`. (Requires `jq` present, or a docker/podman engine for `$JQ_IMAGE`.)

- [ ] **Step 5: Eyeball one generated dashboard end-to-end**

Run:

```sh
rm -rf test/_work/dashboard-eyeball && mkdir -p test/_work/dashboard-eyeball
sh skills/prometheus-exporter/scripts/generate-dashboard.sh \
  --repo test/fixtures/dashboard/http --out-dir test/_work/dashboard-eyeball
jq '{uid, schemaVersion, tags, panels: [.panels[] | {type, title}]}' test/_work/dashboard-eyeball/overview.json
rm -rf test/_work/dashboard-eyeball
```

Expected: `uid` `demo-overview`, `schemaVersion` `38`, `tags` `["generated","demo","business"]`, and a `panels` list in the fixture's order: the `RequestsCollector` `row` header, then its `timeseries` panels `demo_requests_total`, `demo_request_duration_seconds`, `demo_queue_depth`, then the `ExampleCollector` `row` header, then `demo_items`, `demo_healthy` — a human confirmation the layout reads correctly (and that the RequestsCollector→ExampleCollector row boundary does not overlap), not just that assertions pass.

- [ ] **Step 6: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add skills/prometheus-exporter/scripts/generate-dashboard.sh test/generate-dashboard-backbone.sh
git -c commit.gpgsign=false commit -m "feat(dashboard): emit an exportable baseline Grafana dashboard from metrics.md"
```

---

### Task 3: Backbone — N-dashboard decomposition + drill-down links (stable uids)

**Files:**
- Modify: `skills/prometheus-exporter/scripts/generate-dashboard.sh` (implement the `per-collector` branch)
- Modify: `test/generate-dashboard-backbone.sh` (append decomposition assertions)

**Interfaces:**
- Consumes: `emit_dashboard`, `parse_metrics`, `ns` (Task 2).
- Produces: `--decompose per-collector` mode writing `<out-dir>/overview.json` (a nav dashboard whose panels are the per-collector overviews PLUS dashboard-level `links` to each drill-down) and one `<out-dir>/<collector-slug>.json` per collector, each carrying a link back to `<namespace>-overview`. Slug for a drill-down = the collector's lowercased-underscored name (e.g. `RequestsCollector` → `requests`). uids: `<namespace>-overview`, `<namespace>-<collector-slug>` — deterministic, so drill-down `/d/<uid>` links survive Grafana's import-time uid regeneration and survive regeneration by this script (design §6.3, §7).

The decomposition is the design's §6.1 "beaucoup de collecteurs ⇒ overview + drill-downs par domaine, liés". The floor keeps it mechanical and deterministic: one drill-down per collector, linked both ways by deterministic uid. Links use Grafana's `type:"link", url:"/d/<uid>"` form with `includeVars:true`+`keepTime:true` so the `datasource`/`job`/time selection carries across the drill-down.

- [ ] **Step 1: Append decomposition assertions (RED)**

Append to `test/generate-dashboard-backbone.sh`, before the final PASS line:

```sh
echo "== decompose per-collector: overview + one drill-down per collector, linked by stable uid =="
rm -rf "$work"; mkdir -p "$work"
sh "$backbone" --repo "$http_fixture" --out-dir "$work" --decompose per-collector >/dev/null
for f in overview example requests; do
  [ -f "$work/$f.json" ] || die "expected $work/$f.json in per-collector mode"
  jq empty "$work/$f.json" || die "$f.json is not valid JSON"
done
[ "$(jq -r '.uid' "$work/requests.json")" = "demo-requests" ] || die "drill-down uid must be demo-requests"
# overview links to every drill-down by deterministic /d/<uid>.
jq -e '[.links[].url] | index("/d/demo-requests")' "$work/overview.json" >/dev/null || die "overview must link to /d/demo-requests"
jq -e '[.links[].url] | index("/d/demo-example")' "$work/overview.json" >/dev/null || die "overview must link to /d/demo-example"
# each drill-down links back to the overview.
jq -e '[.links[].url] | index("/d/demo-overview")' "$work/requests.json" >/dev/null || die "requests drill-down must link back to /d/demo-overview"
# a drill-down only contains its own collector's panels.
jq -e '[.panels[] | select(.type=="timeseries") | .title] | sort == ["demo_queue_depth","demo_request_duration_seconds","demo_requests_total"]' "$work/requests.json" >/dev/null || die "requests.json must contain exactly the RequestsCollector metrics"

echo "== decompose: uids are stable across regeneration (idempotent-by-uid, design §7) =="
# Regeneration-uid-stability is called "indispensable" by design §6.3/§7 (it is
# the precondition for the command's diff-and-confirm regen and for drill-down
# links surviving a re-run), so it is a PERMANENT harness assertion, not a
# one-off manual check: generate twice into the same dir and confirm the uid
# does not drift.
rm -rf "$work"; mkdir -p "$work"
sh "$backbone" --repo "$http_fixture" --out-dir "$work" --decompose per-collector >/dev/null
uid1=$(jq -r '.uid' "$work/requests.json")
sh "$backbone" --repo "$http_fixture" --out-dir "$work" --decompose per-collector >/dev/null
uid2=$(jq -r '.uid' "$work/requests.json")
[ "$uid1" = "$uid2" ] || die "drill-down uid drifted across regeneration: '$uid1' vs '$uid2' (design §7 requires idempotent-by-uid)"
[ "$uid1" = "demo-requests" ] || die "drill-down uid must be the deterministic 'demo-requests', got '$uid1'"
```

- [ ] **Step 2: Run the harness to confirm the new block fails (RED)**

Run: `sh test/generate-dashboard-backbone.sh`
Expected: **FAIL** — the `per-collector` branch still `die`s with `--decompose per-collector not implemented yet (Task 3)`, so no drill-down files are written and the harness dies on `expected …/overview.json in per-collector mode`.

- [ ] **Step 3: Implement the per-collector branch**

In `skills/prometheus-exporter/scripts/generate-dashboard.sh`, replace:

```sh
  per-collector)
    die "--decompose per-collector not implemented yet (Task 3)"
    ;;
```

with:

```sh
  per-collector)
    # collector_slug — lowercase, drop a trailing "collector", underscore-join
    # camelCase word boundaries: RequestsCollector -> requests,
    # HttpClientRequestsCollector -> http_client_requests. Deterministic.
    collector_slug() {
      printf '%s\n' "$1" \
        | sed -E 's/Collector$//' \
        | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' \
        | tr '[:upper:]' '[:lower:]'
    }

    collectors=$(printf '%s\n' "$model" | awk -F'\t' '$1=="metric"{print $2}' | awk '!seen[$0]++')

    # Build the overview's dashboard-level links (one per drill-down) and emit
    # each drill-down with a single back-link to the overview.
    overview_links="[]"
    for c in $collectors; do
      slug=$(collector_slug "$c")
      submodel=$(printf '%s\n' "$model" | awk -F'\t' -v c="$c" '$1=="metric" && $2==c')
      back_link=$(run_jq -n --arg uid "$ns-overview" \
        '[{asDropdown:false,icon:"external link",includeVars:true,keepTime:true,tags:[],targetBlank:false,title:"Overview",tooltip:"",type:"link",url:("/d/" + $uid)}]')
      emit_dashboard "$slug" "$ns — $c" "$back_link" "$submodel"
      overview_links=$(printf '%s\n' "$overview_links" \
        | run_jq --arg uid "$ns-$slug" --arg title "$c" \
            '. + [{asDropdown:false,icon:"external link",includeVars:true,keepTime:true,tags:[],targetBlank:false,title:$title,tooltip:"",type:"link",url:("/d/" + $uid)}]')
    done

    emit_dashboard overview "$ns — Business Overview" "$overview_links" "$model"
    echo "$prog: generated $out_dir/overview.json and $(printf '%s\n' "$collectors" | wc -l | tr -d ' ') drill-down(s)"
    ;;
```

- [ ] **Step 4: Run the harness to confirm decomposition passes (GREEN)**

Run: `sh test/generate-dashboard-backbone.sh`
Expected: **PASS** — every prior check plus the decomposition block: `overview.json`, `example.json`, `requests.json` all valid; `requests.json` uid `demo-requests`; overview links to `/d/demo-requests` and `/d/demo-example`; `requests.json` links back to `/d/demo-overview`; `requests.json` holds exactly the three RequestsCollector metrics; and the uid is **stable across a second regeneration** (`uid1 == uid2 == demo-requests`, design §7's idempotent-by-uid guarantee — the precondition for the command's diff-and-confirm regen in Task 4). Ends `generate-dashboard-backbone.sh: PASS`.

- [ ] **Step 5: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add skills/prometheus-exporter/scripts/generate-dashboard.sh test/generate-dashboard-backbone.sh
git -c commit.gpgsign=false commit -m "feat(dashboard): add N-dashboard decomposition with stable drill-down uids"
```

---

### Task 4: The `/generate-dashboard` command

**Files:**
- Create: `commands/generate-dashboard.md`

**Interfaces:**
- Consumes: the backbone `skills/prometheus-exporter/scripts/generate-dashboard.sh` (Tasks 1-3) via `${CLAUDE_PLUGIN_ROOT}`; the same real-value reads `/add-collector` does (`namespace` from `cmd/*/main.go`, flavor from `internal/collector/client.go`↔http / `execute.go`↔cli); `docs/metrics.md`; optionally `exporter-design-brief.md`, `context7`, `dataviz`.
- Produces: no code interface — a command file. Verified by `claude plugin validate .` and `test/zero-source-grep.sh`.

The command is the interactive ceiling over the deterministic floor. It mirrors `/add-collector`'s house style exactly: frontmatter (`description`/`argument-hint`/`disable-model-invocation:true`), `$ARGUMENTS` as a candidate, Step 0 confirms a scaffolded repo + detects flavor, numbered steps that read real values, an idempotent refusal before writing, a **Verify** step that shows real output, and a **What's next**. Everything version-sensitive (the Grafana schema, dataviz best practice) is confirmed via context7 first, degrading gracefully to the deterministic baseline + a warning when context7 is absent. The command never invents a metric absent from `metrics.md`; the floor it invokes guarantees `expr ⊆ metrics.md`.

- [ ] **Step 1: Write the command file**

Create `commands/generate-dashboard.md`:

````markdown
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

```sh
for f in monitoring/grafana/*.json; do echo "== $f =="; jq empty "$f" && echo "valid JSON"; done
```

Show it. Then prove the anti-lie property on the generated files: every
namespace-prefixed token in every panel `expr` is either a documented metric
or a documented Histogram's synthesized `_bucket`/`_sum`/`_count`:

```sh
ns=$(grep -hoE 'const[[:space:]]+namespace[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' cmd/*/main.go | head -n1 | sed -E 's/.*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/')
grep -rhoE "${ns}_[A-Za-z0-9_]+" monitoring/grafana/*.json | sort -u
```

Confirm every name printed is documented in `docs/metrics.md` (allowing a
Histogram `<h>`'s `<h>_bucket`). This is the dashboard analogue of
`make docs-check`'s PromQL bar.

## 7. What's next

- Import each dashboard in Grafana (UI "Import → Upload JSON file", the HTTP
  API, or file provisioning) and pick the Prometheus datasource when prompted.
- Re-running this command after `/add-collector` is safe: it reuses each uid
  and asks before overwriting a generated file (step 4).
- Commit with `feat(monitoring): add generated business dashboard(s)` (see
  `CONTRIBUTING.md`'s commit-message convention).
````

- [ ] **Step 2: Validate the plugin and confirm the command is grep-clean**

Run:

```sh
claude plugin validate .
grep -nE 'slurm|sacct|sckyzo' commands/generate-dashboard.md || echo "grep-clean"
```

Expected: `claude plugin validate .` reports the plugin valid (the new command's frontmatter parses: `description`, `argument-hint`, `disable-model-invocation`), and the grep prints `grep-clean` (no source-project name or maintainer handle).

- [ ] **Step 3: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add commands/generate-dashboard.md
git -c commit.gpgsign=false commit -m "feat(dashboard): add the /generate-dashboard command"
```

---

### Task 5: Golden sub-check — the backbone proven end-to-end on a scaffolded repo

**Files:**
- Modify: `test/golden-smoke.sh` (add the dashboard sub-check, gated to `--forge none` cells)

**Interfaces:**
- Consumes: the backbone `skills/prometheus-exporter/scripts/generate-dashboard.sh` (Tasks 1-3), a freshly scaffolded `$work` repo (already built earlier in the script), the `$root`/`$work`/`$flavor`/`$forge`/`die` variables in scope.
- Produces: an end-to-end assertion block mirroring the mechanical `/add-collector` sub-check's shape — invoke the backbone against the scaffolded repo, then assert `jq empty`, the anti-lie `expr ⊆ metrics.md` property (Histogram `_bucket` allowed), cleanliness (no `slurm`/handle, no `@@VAR@@`), and the zero-business-metric refusal.

This is the tested "floor" the design's crux hinges on: the golden invokes only the deterministic backbone (context7/dialogue are absent in headless CI, and the design deliberately does not test the ceiling). It runs in both `--forge none` cells — `http/none` and `cli/none` — because the forge is irrelevant to dashboards but the flavor's *default metric names differ* (http ships label-less `<ns>_items`/`<ns>_healthy`; cli ships `<ns>_example_entries` + a labeled `<ns>_example{key}`), so covering both flavors exercises the label-column path for cheap (no extra build — the scaffold already exists in each cell). It is guarded container-first on `jq` (native → docker → podman → explicit SKIP), exactly like the promtool step.

- [ ] **Step 1: Confirm the anchor the sub-check inserts before**

Run: `grep -n 'echo "\$prog: PASS' test/golden-smoke.sh`
Expected: one match — the final `echo "$prog: PASS — $flavor/$forge scaffold + build + check green"` line. The new sub-check is inserted immediately **before** it, after the existing mechanical `/add-collector` sub-check's closing `fi`.

- [ ] **Step 2: Insert the dashboard sub-check**

In `test/golden-smoke.sh`, immediately before the final line
`echo "$prog: PASS — $flavor/$forge scaffold + build + check green"`, insert:

```sh
# Deterministic dashboard-backbone sub-check (generate-dashboard epic,
# docs/plans/2026-07-07-generate-dashboard.md): the /generate-dashboard command
# is assistant-driven (a metrics.md-anchored RED/USE dialogue, context7
# enrichment — real judgment calls), so this does NOT simulate the command. It
# exercises only the SCRIPTABLE floor every real run also invokes: the shared
# backbone (skills/prometheus-exporter/scripts/generate-dashboard.sh), then
# asserts the properties the design fixes — valid exportable JSON, the anti-lie
# expr-subset-of-metrics.md property, and cleanliness. Runs in both --forge
# none cells (http and cli): the forge is irrelevant to dashboards, but the two
# flavors ship DIFFERENT default metric shapes (http: label-less items/healthy;
# cli: example_entries + a labeled example{key}), so both exercise the backbone
# for free (the scaffold already exists; no extra build). Guarded container-
# first on jq exactly like the promtool step above: native -> docker -> podman
# -> explicit SKIP, never a silent pass.
if [ "$forge" = none ]; then
  echo "== dashboard-backbone sub-check ($flavor/$forge): generate + validate business dashboards =="
  dash_backbone="$root/skills/prometheus-exporter/scripts/generate-dashboard.sh"
  [ -f "$dash_backbone" ] || die "dashboard backbone missing: $dash_backbone"

  jq_cmd=""
  if command -v jq >/dev/null 2>&1; then
    jq_cmd="jq"
  elif command -v docker >/dev/null 2>&1; then
    jq_cmd="docker run --rm -i ghcr.io/jqlang/jq:1.7.1"
  elif command -v podman >/dev/null 2>&1; then
    jq_cmd="podman run --rm -i ghcr.io/jqlang/jq:1.7.1"
  fi

  if [ -z "$jq_cmd" ]; then
    echo "SKIPPING dashboard-backbone sub-check ($flavor/$forge): no native jq and no docker/podman engine found — install jq or a container engine to validate generated dashboards locally"
  else
    dash_out="$work/monitoring/grafana"
    # 1. /new ships one ExampleCollector with real business metrics documented
    # in docs/metrics.md, so the backbone must succeed and produce an overview.
    if ! sh "$dash_backbone" --repo "$work" --out-dir "$dash_out"; then
      die "dashboard-backbone sub-check: generate-dashboard.sh failed on the scaffolded $flavor repo ($flavor/$forge)"
    fi
    [ -f "$dash_out/overview.json" ] || die "dashboard-backbone sub-check: overview.json not generated ($flavor/$forge)"

    # 2. Well-formed JSON (the jq-empty gate the design mandates).
    if ! cat "$dash_out/overview.json" | $jq_cmd empty; then
      die "dashboard-backbone sub-check: overview.json is not valid JSON ($flavor/$forge)"
    fi
    echo "confirmed: overview.json is well-formed exportable JSON ($flavor/$forge)"

    # 3. Anti-lie: every <namespace>_* token in every panel expr must be a
    # documented metric, or a documented Histogram's synthesized _bucket/_sum/
    # _count. Build the allowed set from the backbone's OWN --print-model seam,
    # NEVER by re-parsing metrics.md here: the mechanical /add-collector
    # sub-check earlier in this script appends ## QueueCollector/## TapeCollector
    # to $work/docs/metrics.md AFTER ## Self-instrumentation, so any hand-rolled
    # "stop at Self-instrumentation" re-parse would miss those sections and
    # raise a FALSE anti-lie violation (demo_queue_*/demo_tape_* are real,
    # documented, and the backbone does emit panels for them). --print-model
    # applies the exact same section-tracking + Self-instrumentation exclusion
    # the emitter used, so the allowed set stays in lockstep with what the
    # backbone actually put in the panels — single source, no drift. Each
    # Histogram (field 4 == Type) expands to its synthesized derived series.
    ns=$(grep -hoE 'const[[:space:]]+namespace[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' "$work"/cmd/*/main.go | head -n1 | sed -E 's/.*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/')
    [ -n "$ns" ] || die "dashboard-backbone sub-check: could not read namespace ($flavor/$forge)"
    allowed=$(sh "$dash_backbone" --repo "$work" --print-model | awk -F'\t' '
      $1=="metric" {
        print $3
        if ($4 ~ /Histogram/) { print $3 "_bucket"; print $3 "_sum"; print $3 "_count" }
      }' | sort -u)
    tokens=$(grep -rhoE "${ns}_[A-Za-z0-9_]+" "$dash_out"/*.json | sort -u)
    for t in $tokens; do
      if ! printf '%s\n' "$allowed" | grep -qxF "$t"; then
        die "dashboard-backbone sub-check: panel expr references '$t', which is not documented in docs/metrics.md — anti-lie violation ($flavor/$forge)"
      fi
    done
    echo "confirmed: every panel expr references only documented metrics ($flavor/$forge)"

    # 4. Cleanliness: no source-project name / maintainer handle and no residual
    # @@VAR@@ in any generated dashboard. The tree-wide test/_work sweep for
    # slurm/sckyzo runs right after scaffold.sh — BEFORE this sub-check creates
    # monitoring/grafana/*.json — so the generated JSON needs its OWN local
    # slurm/handle sweep here (design §10.3), not only the @@VAR@@ guard. Both
    # are match=fail; a JSON file is text, so -I only guards against a stray
    # binary in the glob.
    if command grep -niI -e slurm -e sckyzo "$dash_out"/*.json; then
      die "dashboard-backbone sub-check: 'slurm' or the maintainer handle leaked into a generated dashboard ($flavor/$forge)"
    fi
    if command grep -nI '@@[A-Z_]*@@' "$dash_out"/*.json; then
      die "dashboard-backbone sub-check: residual @@VAR@@ sentinel in a generated dashboard ($flavor/$forge)"
    fi
    echo "confirmed: generated dashboards are clean — no slurm/handle, no residual @@VAR@@ ($flavor/$forge)"

    # 5. Zero-business-metric refusal: point the backbone at a doc stripped to
    # only its ## Self-instrumentation section and confirm it exits 3 rather
    # than emitting an empty dashboard.
    dash_empty="$work/.dash-empty"
    rm -rf "$dash_empty"; mkdir -p "$dash_empty/docs" "$dash_empty/cmd/demo_exporter"
    cp "$work"/cmd/*/main.go "$dash_empty/cmd/demo_exporter/main.go"
    # Keep only from "## Self-instrumentation" onward (drop all business rows),
    # so the copied doc documents zero business metrics.
    sed -n '/## Self-instrumentation/,$p' "$work/docs/metrics.md" > "$dash_empty/docs/metrics.md"
    rc=0
    sh "$dash_backbone" --repo "$dash_empty" --out-dir "$dash_empty/out" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] || die "dashboard-backbone sub-check: expected exit 3 on a self-instrumentation-only doc, got $rc ($flavor/$forge)"
    rm -rf "$dash_empty"
    echo "confirmed: backbone refuses a zero-business-metric repo with exit 3 ($flavor/$forge)"

    echo "confirmed: dashboard-backbone sub-check PASSED ($flavor/$forge)"
  fi
fi
```

- [ ] **Step 3: Run the http/none golden cell**

Run: `sh test/golden-smoke.sh --flavor http --forge none`
Expected: the full golden cell runs to completion and, near the end, prints the dashboard sub-check's `confirmed:` lines (well-formed JSON; every panel expr documented; no residual `@@VAR@@`; exit-3 refusal) then `confirmed: dashboard-backbone sub-check PASSED (http/none)`, ending `golden-smoke.sh: PASS — http/none scaffold + build + check green`. (If neither `jq` nor a container engine is installed, the sub-check prints its explicit `SKIPPING …` line instead and the cell still passes.)

- [ ] **Step 4: Run the cli/none golden cell (labeled-metric coverage)**

Run: `sh test/golden-smoke.sh --flavor cli --forge none`
Expected: same shape as Step 3 for `cli/none`. This proves the backbone handles the cli flavor's labeled default metric (`<ns>_example{key}`) — its panel expr `avg by (job, instance) (demo_example{job=~"$job"})` references only the documented `demo_example`, passing the anti-lie check. Ends `golden-smoke.sh: PASS — cli/none scaffold + build + check green`.

- [ ] **Step 5: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS` (the sub-check names `slurm`/`sckyzo` nowhere; `test/` is exempt regardless).

```bash
git add test/golden-smoke.sh
git -c commit.gpgsign=false commit -m "test(dashboard): add the golden generate-dashboard backbone sub-check"
```

---

### Task 6: Documentation — mark `/generate-dashboard` shipped

**Files:**
- Modify: `skills/prometheus-exporter/references/dashboards-and-alerts.md` (the "business dashboard is v0.2 — not shipped" section)
- Modify: `skills/prometheus-exporter/SKILL.md` (two "future/later addition" mentions)
- Modify: `skills/prometheus-exporter/assets/monitoring/README.md.tmpl` (the "Business dashboards" section)
- Modify: `ROADMAP.md` (the v0.2 `/generate-dashboard` bullet)
- Modify: `CHANGELOG.md` (the `## [Unreleased]` block)

**Interfaces:**
- Consumes: nothing — prose bookkeeping.
- Produces: docs that describe `/generate-dashboard` as delivered, matching the real flow (design §12). Verified by `claude plugin validate .` and `test/zero-source-grep.sh`.

Every one of these files currently says `/generate-dashboard` does not exist yet; this task flips them to "shipped" and describes the real flow (deterministic exportable backbone + metrics.md-anchored dialogue + context7/dataviz ceiling). `monitoring/README.md.tmpl` is a shipped template, so its edit must stay generic (no source-project name) and keep its `@@VAR@@` sentinels intact.

- [ ] **Step 1: Flip the reference's business-dashboard section**

In `skills/prometheus-exporter/references/dashboards-and-alerts.md`, replace the section that begins `## The business dashboard is v0.2 — not shipped, and not this plugin today` and its body (through the paragraph ending `…the reference shape to imitate.`) with:

```markdown
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
```

- [ ] **Step 2: Update the reference's checklist line**

In the same file, replace the checklist bullet:

```markdown
- [ ] A business dashboard is either hand-built today or deferred to
      `/generate-dashboard` once v0.2 ships it — never presented as
      something this plugin already generates.
```

with:

```markdown
- [ ] A business dashboard is generated with `/generate-dashboard`, whose
      every panel `expr` is grep-checked against `docs/metrics.md` (a
      Histogram's `_bucket` counting as derived from its documented parent) —
      never a metric the code can't produce.
```

- [ ] **Step 3: Update `SKILL.md`'s two mentions**

In `skills/prometheus-exporter/SKILL.md`, replace in the Scope paragraph:

```markdown
the only two this plugin ships, ever; database targets are out of scope
(see `references/exporter-architecture.md`). A design-led
business-dashboard command is a later addition, noted below where relevant
but not part of this workflow yet.
```

with:

```markdown
the only two this plugin ships, ever; database targets are out of scope
(see `references/exporter-architecture.md`). A design-led
business-dashboard command (`/generate-dashboard`) complements this workflow
at step 5, noted below where relevant.
```

Then, in step 5's paragraph, replace:

```markdown
is actually met. Ship `monitoring/` with Prometheus health alerts,
recording rules, and a health Grafana dashboard — a business dashboard via
a future `/generate-dashboard` command is a later addition, not part of
this workflow.
```

with:

```markdown
is actually met. Ship `monitoring/` with Prometheus health alerts,
recording rules, and a health Grafana dashboard; generate business
dashboards from `docs/metrics.md` with `/generate-dashboard` once your
collectors are in place.
```

- [ ] **Step 4: Align the shipped `monitoring/README.md.tmpl`**

In `skills/prometheus-exporter/assets/monitoring/README.md.tmpl`, replace the `## Business dashboards` section body:

```markdown
A business-metric dashboard (what your collectors actually measure — queue
depth, error rates, saturation, whatever your target's domain is) is
deliberately **not** shipped here: unlike the health dashboard above, there
is no version of it that's generic across every exporter. Build one by
hand, or with `/generate-dashboard` (if you have the scaffolding plugin
available) — a short design pass (audience, the RED/USE method, key
metrics, template variables, drill-down) before generating the Grafana
JSON, the same discipline that produced the health dashboard here.
```

with:

```markdown
A business-metric dashboard (what your collectors actually measure — queue
depth, error rates, saturation, whatever your target's domain is) is
deliberately **not** shipped here: unlike the health dashboard above, there
is no version of it that's generic across every exporter. Generate one from
this repo's own `docs/metrics.md` with `/generate-dashboard` (if you have the
scaffolding plugin available) — a short design pass (audience, the RED/USE
method, key metrics, template variables, drill-down) on top of a deterministic
backbone that emits exportable Grafana JSON, one panel per documented metric.
The generated dashboards land here in `grafana/` next to `health-dashboard.json`
and import the same way; every panel query references only a metric documented
in `docs/metrics.md`.
```

- [ ] **Step 5: Move the ROADMAP item to delivered**

In `ROADMAP.md`, replace:

```markdown
- `/generate-dashboard`: a design-led command that generates a business
  Grafana dashboard, complementing the generic health dashboard shipped in
  v0.1.
```

with:

```markdown
- `/generate-dashboard` *(delivered, unreleased)*: a design-led command that
  generates 1..N business Grafana dashboards from a scaffolded repo's own
  `docs/metrics.md`, on top of a deterministic, golden-tested backbone that
  emits exportable Grafana JSON (one panel per documented metric, type-correct
  PromQL, deterministic `<namespace>-<slug>` uids). Complements the generic
  health dashboard shipped in v0.1; never modifies it. `context7` and the
  `dataviz` skill enrich it when present, never required.
```

- [ ] **Step 6: Add the CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Added`, add as a new bullet (immediately after the `## [Unreleased]` `### Added` header, before the existing `/design-exporter` bullet):

```markdown
- **`/generate-dashboard [name]`** — generates 1..N business Grafana dashboards
  for an already-scaffolded exporter from its own `docs/metrics.md`, via a
  RED/USE design dialogue on top of a deterministic backbone
  (`skills/prometheus-exporter/scripts/generate-dashboard.sh`, `bash`+`jq`,
  container-first). Emits **exportable** JSON (`__inputs`/`__requires`,
  `${DS_PROMETHEUS}` datasource, deterministic `<namespace>-<slug>` uids), one
  panel per documented metric, PromQL chosen by `Type` (`rate()`/`$__rate_interval`
  on counters, `histogram_quantile()` with a synthesized `_bucket` on
  histograms, `avg by (job, instance)` on gauges). Every panel `expr` references
  only a metric present in `docs/metrics.md`; the same backbone is invoked by
  the golden test, and `context7`/`dataviz` enrich the result when present but
  are never required. Complements — never modifies — the health dashboard.
```

- [ ] **Step 7: Validate, zero-source gate, then commit**

Run:

```sh
claude plugin validate .
bash test/zero-source-grep.sh
```

Expected: `claude plugin validate .` reports the plugin valid; `zero-source-grep.sh: PASS` (the shipped `monitoring/README.md.tmpl` and skill edits name no source project or handle, and its `@@VAR@@` sentinels are untouched).

```bash
git add skills/prometheus-exporter/references/dashboards-and-alerts.md \
        skills/prometheus-exporter/SKILL.md \
        skills/prometheus-exporter/assets/monitoring/README.md.tmpl \
        ROADMAP.md CHANGELOG.md
git -c commit.gpgsign=false commit -m "docs(dashboard): mark /generate-dashboard shipped across references and changelog"
```

---

## Self-Review

**1. Spec coverage** (design `2026-07-07-generate-dashboard-design.md`):

- §1 objective / §4 flow (confirm → read+parse → dialogue → generate → wire → verify → what's next): Task 4 command steps 0-7.
- §2 invariants (grep=0, auto-portance, documented ⊆ dashboard, real values, exportable): Global Constraints + Task 2 (exportable emit) + Task 5 (anti-lie golden) + Task 4 (degradation).
- §3 inputs / parsing contract (reuse `parseMetricsDoc` regexes, exclude Self-instrumentation): Task 1 `parse_metrics`.
- §5 metrics.md-anchored dialogue (8 steps): Task 4 step 2.
- §6 backbone (deterministic floor) + ceiling (context7/dataviz): Tasks 1-3 (floor) + Task 4 §3 (ceiling). §6.3 PromQL-by-Type, `$__rate_interval`, `by (job, instance)`, exportable, deterministic uids, provenance tag: Task 2.
- §7 regeneration (idempotent-by-uid, diff+confirm, never scaffold): Task 3 Step 1/4 (uid-stability, now a permanent harness assertion) + Task 4 §3 (stage into a temp dir) → §4 (tag-aware diff+confirm *before* placement, so a hand-made file is never clobbered).
- §8 output/wiring (files under `monitoring/grafana/`, README import list, no compose/provisioning): Task 4 §4 (place) + §5 (README wiring).
- §9 graceful degradation (context7/dataviz/brief): Task 4 §1/§3.
- §10 tests (golden sub-check: jq empty + anti-lie via `--print-model` + local slurm/handle+`@@VAR@@` cleanliness + zero-metric refusal; http/none + cli/none): Task 5.
- §11 edge cases (non-scaffolded refusal, zero business metric, histogram `_bucket`, undocumented-metric warning, unrecognized-Type warn-and-include): Task 4 §0/§1 + Task 1 refusal + Task 1 `parse_metrics` Type warning + Task 2 histogram + Task 4 §6.
- §12 artifacts (command, backbone, golden hook, reference flip, SKILL, ROADMAP, CHANGELOG, monitoring README): Tasks 4/1-3/5/6.
- §13 task breakdown: folded into 6 tasks (parsing+refusal; baseline; decomposition; command; golden; docs) — brief-seeding folded into the command (Task 4 step 1), as it is untested command prose a reviewer reviews with the command.

**Resolved open items (design §14):** (1) Backbone tech = `bash`+`jq`, container-first, at `skills/prometheus-exporter/scripts/generate-dashboard.sh` (outside `assets/` so `scaffold.sh` never ships it); CLI contract + exit codes in Task 1's Interfaces. jq (not pure heredoc) chosen because `metrics.md` help/description text and titles must be JSON-safe — `jq --arg` escapes correctly where hand-rolled bash escaping is the anti-pattern; jq -n per panel keeps each template small and readable, sidestepping the "one giant jq expression" unwieldiness. (2) Golden covers `http/none` **and** `cli/none` — both `--forge none` cells, since forge is dashboard-irrelevant but the two flavors' default metric shapes differ (label-less vs labeled), and the sub-check adds no extra build. (3) Slug scheme = `overview` for the single/nav dashboard (uid `<ns>-overview`, avoiding collision with health's `<ns>-exporter-health`), and the lowercased-underscored collector name per drill-down (uid `<ns>-<collector-slug>`). (4) The golden feeds the backbone its default decomposition (single `overview`, one panel per metric, a row per collector) with no `--decompose`/descriptor — deterministic, so no dialogue is needed in CI.

**2. Placeholder scan:** no `TBD`/`TODO`/`similar to above`/"add error handling". Every step carries full code or an exact command + expected output. The Task 1/2 script tails that say "not implemented yet (Task N)" are deliberate, tested RED states (the harness asserts they fail), each explicitly replaced in the next task's Step 3 — not lingering placeholders.

**3. Type/name consistency:** the backbone flags (`--repo`/`--out-dir`/`--grafana-schema-version`/`--decompose`/`--print-model`), exit codes (0/1/2/3/4), functions (`run_jq`, `read_namespace`, `parse_metrics`, `unit_for`, `expr_for`, `emit_panel`, `emit_dashboard`, `collector_slug`), the `--print-model` line shape (`namespace\t…`, `metric\t<Collector>\t<name>\t<Type>\t<labels|->` — its field-3=name, field-4=Type layout is relied on by both the Task 1 harness and Task 5's golden anti-lie set), the uid scheme (`<ns>-overview`, `<ns>-<slug>`), the default `schemaVersion` (38), the datasource pattern (`DS_PROMETHEUS` input + `${datasource}` in panels), the `generated`/`<ns>`/`business` tags, and the anti-lie allowed-set rule (documented names ∪ Histogram `_bucket`/`_sum`/`_count`) are used identically across Tasks 1-5 and the command/docs prose. The three exact PromQL strings asserted in Task 2's harness match `expr_for`'s three branches verbatim.

**4. Pre-flight review fixes (7, re-reviewed on the touched tasks):**

- **BLOCKING — golden anti-lie drift (Task 5 §item 3):** the allowed metric-name set is now built from the backbone's own `--print-model` (the Task 1 seam), not a hand-rolled re-parse of `metrics.md`. This fixes the false violation the earlier version would hit on the mandatory http/none cell, where the `/add-collector` sub-check appends `## QueueCollector`/`## TapeCollector` *after* `## Self-instrumentation`. Single source, no drift; Histogram `_bucket`/`_sum`/`_count` still allowed.
- **BLOCKING — golden cleanliness (Task 5 §item 4):** added a dashboard-local `command grep -niI -e slurm -e sckyzo "$dash_out"/*.json` (design §10.3's source-name half), since the tree-wide `test/_work` sweep runs before the generated JSON exists. The `@@VAR@@` guard remains.
- **BLOCKING — command silent data loss (Task 4 §3/§4):** §3 now stages into `mktemp -d` (never the live `monitoring/grafana/`), and §4 reconciles tag-aware (hand-made = no `generated` tag → never overwrite without explicit ok) and places only what clears. Protection provably precedes materialization in the in-order walk.
- **Non-blocking — `emit_dashboard` row math (Task 2 §Step 3):** a half-row flush (`_y += 8` when the prior collector left `_slot` odd) runs before a new collector's row header, preventing overlap. The http fixture now lists the odd-count `RequestsCollector` first (non-last), and Task 2's harness asserts `ExampleCollector`'s row header sits at `>= demo_queue_depth.y + 8` — a real regression lock.
- **Non-blocking — `parse_metrics` Type strictness (Task 1 §Step 6):** an unrecognized `Type` is now warned to stderr and the metric is still included (treated as a gauge downstream), never silently dropped — so a typo can't flip a real repo into the exit-3 refusal.
- **Non-blocking — Global Constraints grep=0 wording:** corrected to describe the real `zero-source-grep.sh` enforcement (`slurm` repo-wide, `sckyzo` scoped; not `sacct`).
- **Non-blocking — uid-stability test (Task 3):** folded the two-run uid-diff into `test/generate-dashboard-backbone.sh` as a permanent assertion (was a one-off manual snippet); the standalone step was removed and the commit step renumbered.
