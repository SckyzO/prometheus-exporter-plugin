#!/bin/sh
# queue-budget-sweep.sh: the measurement behind the concurrency ceiling.
#
# Scaffolds a real http multi-instance exporter, drops the sweep fixtures into
# its internal/collector/, and runs them there. It measures the rendered
# templates, not a copy of them, which is the whole point: the numbers this
# prints are about the code a third party would receive.
#
# The sweep itself, and why its parameters are what they are, is documented in
# test/fixtures/queue-sweep/sweep_common_test.go.
#
# Usage:
#   sh test/queue-budget-sweep.sh              # every column
#   sh test/queue-budget-sweep.sh --baseline   # only the columns that compile
#                                              # against pre-phase-2 templates
#
# --baseline exists so the "before" column can be measured on an older commit
# with this same script: the configured-wait-budget column calls a method that
# does not exist there, and a compile failure is not a measurement.
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)

baseline=no
[ "${1:-}" = "--baseline" ] && baseline=yes

command -v go >/dev/null 2>&1 || { echo "SKIP: go toolchain not found" >&2; exit 0; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sh "$root/skills/prometheus-exporter/assets/scaffold.sh" \
  --src "$root/skills/prometheus-exporter/assets" \
  --dst "$work/out" \
  --flavor http --forge none --target-model multi-instance \
  --var EXPORTER_NAME=sweep_exporter \
  --var NAMESPACE=sweep \
  --var OWNER=acme \
  --var DEFAULT_PORT=9999 \
  --var MODULE_PATH=example.com/sweep_exporter \
  --var DATA_SOURCE=http://localhost:9999 \
  --var DATA_SOURCE_PATH=/api/example \
  --var LICENSE=apache-2.0 \
  --var COLLECTOR_HEALTH_BY=status \
  --var COLLECTOR_LOCATION=location \
  >/dev/null

cp "$here/fixtures/queue-sweep/sweep_common_test.go" "$work/out/internal/collector/"
if [ "$baseline" = no ]; then
  cp "$here/fixtures/queue-sweep/sweep_budget_test.go" "$work/out/internal/collector/"
fi

cd "$work/out"
go mod tidy >/dev/null 2>&1 || true

# -count=1 defeats the test cache: a cached PASS is not a measurement either.
go test ./internal/collector/ -run 'TestQueueBudgetSweep' -v -count=1 2>&1 | grep -E 'SWEEP|FAIL|ok |--- '
