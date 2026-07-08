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
single_fixture="$root/test/fixtures/dashboard/single"
collide_fixture="$root/test/fixtures/dashboard/collide"
collidethree_fixture="$root/test/fixtures/dashboard/collidethree"
badname_fixture="$root/test/fixtures/dashboard/badname"
degenerate_fixture="$root/test/fixtures/dashboard/degenerate"
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

echo "== emit: an odd-count last (single-metric) collector still emits, no set -e abort =="
rm -rf "$work"; mkdir -p "$work"
rc=0
sh "$backbone" --repo "$single_fixture" --out-dir "$work" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || die "single 1-metric collector must emit (exit 0), got exit $rc — set -e abort on an odd-count last collector"
[ -f "$work/overview.json" ] || die "single-collector overview.json was not written"
[ "$(jq '[.panels[] | select(.type=="timeseries")] | length' "$work/overview.json")" = "1" ] || die "expected exactly 1 timeseries panel for the single-metric fixture"
[ "$(jq '[.panels[] | select(.type=="row")] | length' "$work/overview.json")" = "1" ] || die "expected exactly 1 row for the single-collector fixture"
if ls "$work"/.panels.* >/dev/null 2>&1; then die "a stale .panels.* temp file was left in the output dir"; fi

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

echo "== usage: an invalid --decompose value is a usage error (exit 2) =="
rc=0
sh "$backbone" --repo "$http_fixture" --out-dir "$work" --decompose bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || die "invalid --decompose must exit 2 (usage error), got exit $rc"

echo "== decompose: colliding collector slugs fail loud, never silently clobber =="
rm -rf "$work"; mkdir -p "$work"
rc=0
out=$(sh "$backbone" --repo "$collide_fixture" --out-dir "$work" --decompose per-collector 2>&1) || rc=$?
[ "$rc" -ne 0 ] || die "colliding collector slugs must fail (non-zero exit), got exit 0"
printf '%s\n' "$out" | grep -qi 'collide' || die "collision refusal should mention the collision, got: $out"

echo "== decompose: a collector name that isn't a clean identifier fails loud =="
rm -rf "$work"; mkdir -p "$work"
rc=0
out=$(sh "$backbone" --repo "$badname_fixture" --out-dir "$work" --decompose per-collector 2>&1) || rc=$?
[ "$rc" -ne 0 ] || die "an un-sluggable collector name must fail (non-zero exit), got exit 0"
printf '%s\n' "$out" | grep -qi 'clean identifier' || die "un-sluggable refusal should mention 'clean identifier', got: $out"

echo "== decompose: a collision between the 2nd and 3rd collectors is still caught (accumulation is newline-separated) =="
rm -rf "$work"; mkdir -p "$work"
rc=0
out=$(sh "$backbone" --repo "$collidethree_fixture" --out-dir "$work" --decompose per-collector 2>&1) || rc=$?
[ "$rc" -ne 0 ] || die "a late (2nd-vs-3rd) collector slug collision must still fail (non-zero exit), got exit 0 — seen_slugs accumulation is broken"
printf '%s\n' "$out" | grep -qi 'collide' || die "late-collision refusal should mention the collision, got: $out"

echo "== decompose: a collector whose name slugs to empty (named only 'Collector') fails loud =="
rm -rf "$work"; mkdir -p "$work"
rc=0
out=$(sh "$backbone" --repo "$degenerate_fixture" --out-dir "$work" --decompose per-collector 2>&1) || rc=$?
[ "$rc" -ne 0 ] || die "a collector that slugs to empty must fail (non-zero exit), got exit 0"
printf '%s\n' "$out" | grep -qi 'empty slug' || die "empty-slug refusal should mention 'empty slug', got: $out"

echo "$prog: PASS — parser, namespace reader, and zero-metric refusal all green"
