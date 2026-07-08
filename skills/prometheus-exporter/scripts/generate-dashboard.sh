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
# §3 -- already covered by the health dashboard). awk keeps it single-pass and
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
      # Type is informational -- the real parseMetricsDoc/docs-check never
      # validates it, so this must not either. An unrecognized Type is WARNED
      # (to stderr, so it never pollutes the model on stdout) and the metric is
      # still INCLUDED, never silently dropped: silently dropping a mis-typed Type
      # could, in the degenerate case, flip a repo with real metrics into the
      # zero-business-metric refusal (exit 3). expr_for treats an unknown Type
      # as a gauge.
      if (type != "Gauge" && type != "Counter" && type != "Histogram" && type != "Summary") {
        printf "generate-dashboard.sh: warning: metric `%s` has an unrecognized Type `%s` (expected Gauge/Counter/Histogram/Summary) -- treating it as a gauge\n", name, type > "/dev/stderr"
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
