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
