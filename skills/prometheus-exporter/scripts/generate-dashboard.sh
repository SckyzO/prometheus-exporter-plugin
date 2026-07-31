#!/bin/sh
# generate-dashboard.sh: the deterministic backbone behind /prometheus-exporter:generate-dashboard.
#
# Reads an already-scaffolded exporter repo's docs/metrics.md and its real
# namespace (const namespace in cmd/*/main.go), then emits 1..N exportable
# Grafana dashboards, one panel per DOCUMENTED business metric, PromQL chosen
# by the metric's Type, deterministic <namespace>-<slug> uids. It is
# deterministic by construction: no dialogue, no context7, no LLM. That is
# exactly what lets both /prometheus-exporter:generate-dashboard AND test/golden-smoke.sh invoke
# this one script (single source, no drift). The command layers an interactive
# ceiling (dialogue, context7, dataviz) on top; the golden bypasses all of it
# and tests only this floor.
#
# It never runs scaffold.sh and never edits templates: single-file operations
# on real values, exactly like /prometheus-exporter:add-collector.
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
case "$decompose" in overview|per-collector) ;; *) echo "$prog: error: --decompose must be overview or per-collector" >&2; usage ;; esac

# run_jq: container-first jq, native → docker → podman → exit 4. Every jq call
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
    echo "$prog: error: jq is required (native, or a docker/podman engine to run $JQ_IMAGE). Install jq or a container engine" >&2
    exit 4
  fi
}

# read_namespace: the metric prefix and uid prefix, read from the real
# const namespace = "<literal>" in cmd/*/main.go (design §3). Never guessed.
read_namespace() {
  ns=$(grep -hoE 'const[[:space:]]+namespace[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' "$repo"/cmd/*/main.go 2>/dev/null \
        | head -n1 | sed -E 's/.*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/')
  [ -n "$ns" ] || die "could not read 'const namespace = \"…\"' from $repo/cmd/*/main.go"
  printf '%s\n' "$ns"
}

# parse_metrics: emit one TAB line per DOCUMENTED business metric:
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
  echo "$prog: error: no business metrics documented in $repo/docs/metrics.md (only self-instrumentation). Add collectors and document them with 'make docs-check' first" >&2
  exit 3
fi

[ -n "$out_dir" ] || usage
mkdir -p "$out_dir"

# unit_for: infer a Grafana unit from the Prometheus name suffix (design §5.7:
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

# expr_for <name> <Type>: PromQL by metric Type (design §6.3, grounded via
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

# emit_panel <id> <x> <y> <w> <h> <title> <expr> <unit>: one timeseries panel
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

# emit_dashboard <slug> <title> <links_json> <model>: assemble one exportable
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
    if [ $(( _slot % 2 )) -eq 0 ]; then _y=$((_y+8)); fi
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
      description:("Business metrics for " + $ns + ", generated by /prometheus-exporter:generate-dashboard from docs/metrics.md. Safe to regenerate. See monitoring/README.md."),
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
    emit_dashboard overview "$ns - Business Overview" '[]' "$model"
    echo "$prog: generated $out_dir/overview.json"
    ;;
  per-collector)
    # collector_slug: lowercase, drop a trailing "collector", underscore-join
    # camelCase word boundaries: RequestsCollector -> requests,
    # HttpClientRequestsCollector -> http_client_requests. Deterministic.
    collector_slug() {
      printf '%s\n' "$1" \
        | sed -E 's/Collector$//' \
        | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' \
        | tr '[:upper:]' '[:lower:]'
    }

    collectors=$(printf '%s\n' "$model" | awk -F'\t' '$1=="metric"{print $2}' | awk '!seen[$0]++')

    # Fail loud on any collector name the floor can't turn into a stable
    # slug/uid, rather than silently clobbering a sibling drill-down or writing
    # a degenerate file. Validate the whole names here, before `for` word-splits
    # them. Only per-collector mode needs a slug, overview mode uses the name
    # only as a row title, so this lives in this branch, not globally.
    if printf '%s\n' "$collectors" | grep -qvE '^[A-Za-z_][A-Za-z0-9_]*$'; then
      bad=$(printf '%s\n' "$collectors" | grep -vE '^[A-Za-z_][A-Za-z0-9_]*$' | head -n1)
      die "collector name '$bad' is not a clean identifier (letters, digits, underscore only): cannot derive a stable per-collector slug/uid; rename the collector or use --decompose overview"
    fi

    # Build the overview's dashboard-level links (one per drill-down) and emit
    # each drill-down with a single back-link to the overview.
    overview_links="[]"
    seen_slugs=""
    for c in $collectors; do
      slug=$(collector_slug "$c")
      [ -n "$slug" ] || die "collector '$c' produces an empty slug (is it named only 'Collector'?). Rename it so a stable uid can be derived"
      prev=$(printf '%s\n' "$seen_slugs" | awk -F'\t' -v s="$slug" '$1==s{print $2; exit}')
      [ -z "$prev" ] || die "collectors '$prev' and '$c' both map to slug '$slug': rename one so their drill-down dashboards and uids don't collide"
      seen_slugs=$(printf '%s\n%s\t%s' "$seen_slugs" "$slug" "$c")
      submodel=$(printf '%s\n' "$model" | awk -F'\t' -v c="$c" '$1=="metric" && $2==c')
      back_link=$(run_jq -n --arg uid "$ns-overview" \
        '[{asDropdown:false,icon:"external link",includeVars:true,keepTime:true,tags:[],targetBlank:false,title:"Overview",tooltip:"",type:"link",url:("/d/" + $uid)}]')
      emit_dashboard "$slug" "$ns - $c" "$back_link" "$submodel"
      overview_links=$(printf '%s\n' "$overview_links" \
        | run_jq --arg uid "$ns-$slug" --arg title "$c" \
            '. + [{asDropdown:false,icon:"external link",includeVars:true,keepTime:true,tags:[],targetBlank:false,title:$title,tooltip:"",type:"link",url:("/d/" + $uid)}]')
    done

    emit_dashboard overview "$ns - Business Overview" "$overview_links" "$model"
    echo "$prog: generated $out_dir/overview.json and $(printf '%s\n' "$collectors" | wc -l | tr -d ' ') drill-down(s)"
    ;;
esac
