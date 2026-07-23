#!/bin/sh
# Scaffold-level assertions for the --target-model axis (single|multi): no Go,
# no network, sh+sed only — same dependency discipline as scaffold_test.sh and
# scaffold_edge_test.sh alongside it. Unlike those two, this test scaffolds
# from the REAL assets tree (skills/prometheus-exporter/assets), not the
# mini-template fixture: the mini-template fixture never staged a mains/ split
# or internal/probe/ (it predates this feature and exists to test the generic
# templating engine in isolation), so exercising --target-model here needs the
# real, shipped mains/single/, mains/multi/, and internal/probe/ templates.
#
# Set SCAFFOLD_BIN to point at an alternate copy of scaffold.sh (mirrors
# scaffold_edge_test.sh's own override knob); defaults to the real shipped
# script.
set -eu
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
assets="$root/skills/prometheus-exporter/assets"
scaffold="${SCAFFOLD_BIN:-$assets/scaffold.sh}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Runs scaffold.sh with args "$@"; leaves the exit code in $rc and captures
# stdout/stderr to $out/$err for callers to inspect — same convention as
# scaffold_edge_test.sh's own run() helper.
out="$work/_stdout"
err="$work/_stderr"
run() {
  rc=0
  "$scaffold" "$@" >"$out" 2>"$err" || rc=$?
}

commonvars="--var EXPORTER_NAME=demo --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var DEFAULT_PORT=9999 --var LICENSE=apache-2.0 --var OWNER=demo"

# ---------------------------------------------------------------------------
# 1. --target-model multi (http/none): ships internal/probe/probe.go, and
#    cmd/*/main.go wires the /probe endpoint via probe.NewHandler.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086 # $commonvars is a deliberately unquoted word list
run --src "$assets" --dst "$work/multi" --flavor http --forge none --target-model multi $commonvars
[ "$rc" -eq 0 ] || fail "multi scaffold exited $rc, expected 0 (stderr: $(cat "$err"))"

[ -f "$work/multi/internal/probe/probe.go" ] || fail "multi scaffold did not ship internal/probe/probe.go"
[ -f "$work/multi/internal/probe/probe_test.go" ] || fail "multi scaffold did not ship internal/probe/probe_test.go"

mainfile=$(find "$work/multi/cmd" -maxdepth 2 -name main.go)
[ -n "$mainfile" ] || fail "multi scaffold has no cmd/*/main.go"
grep -q '/probe' "$mainfile" || fail "multi scaffold's main.go does not register the /probe route"
grep -q 'probe.NewHandler' "$mainfile" || fail "multi scaffold's main.go does not call probe.NewHandler"

grep -q 'var factories \[\]probe.NamedFactory' "$mainfile" || fail "multi scaffold's main.go does not declare the factories slice"
grep -q '// @@PROBE_FACTORIES@@' "$mainfile" || fail "multi scaffold's main.go lost the // @@PROBE_FACTORIES@@ marker (/add-collector appends there)"

probefile="$work/multi/internal/probe/probe.go"
grep -q 'factories \[\]NamedFactory' "$probefile" || fail "multi scaffold's probe.go does not hold N named factories"

# The multi main model carries only its own marker (// @@PROBE_FACTORIES@@);
# it must never retain the single-target markers verbatim as dead comments.
grep -q '// @@CLIENT_INIT@@' "$mainfile" && fail "multi scaffold's main.go still has a // @@CLIENT_INIT@@ marker (single-only)"
grep -q '// @@CLIENT_BUILD@@' "$mainfile" && fail "multi scaffold's main.go still has a // @@CLIENT_BUILD@@ marker (single-only)"
grep -q '// @@COLLECTOR_REGISTRY@@' "$mainfile" && fail "multi scaffold's main.go still has a // @@COLLECTOR_REGISTRY@@ marker (single-only)"

echo "PASS: --target-model multi ships internal/probe and wires /probe"

# ---------------------------------------------------------------------------
# 2. Default (no --target-model, and explicit --target-model single): no
#    internal/probe/, no /probe route — single-target behaviour is unchanged.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
run --src "$assets" --dst "$work/default" --flavor http --forge none $commonvars
[ "$rc" -eq 0 ] || fail "default (single) scaffold exited $rc, expected 0 (stderr: $(cat "$err"))"
[ ! -d "$work/default/internal/probe" ] || fail "default (single) scaffold shipped internal/probe/ (should be multi-only)"
default_main=$(find "$work/default/cmd" -maxdepth 2 -name main.go)
[ -n "$default_main" ] || fail "default (single) scaffold has no cmd/*/main.go"
grep -q '/probe' "$default_main" && fail "default (single) scaffold's main.go registers /probe (should be multi-only)"

echo "PASS: default (single) scaffold ships no internal/probe and no /probe route"

# shellcheck disable=SC2086
run --src "$assets" --dst "$work/explicit-single" --flavor http --forge none --target-model single $commonvars
[ "$rc" -eq 0 ] || fail "explicit --target-model single scaffold exited $rc, expected 0 (stderr: $(cat "$err"))"
[ ! -d "$work/explicit-single/internal/probe" ] || fail "explicit --target-model single scaffold shipped internal/probe/"

echo "PASS: explicit --target-model single matches the default"

# ---------------------------------------------------------------------------
# 2b. --target-model multi-instance (http/none): ships internal/instance/, no
#     internal/probe/, wires WrapRegistererWith, and ships the BACKGROUND
#     collector as its starter.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
run --src "$assets" --dst "$work/mi" --flavor http --forge none --target-model multi-instance --instance-label target $commonvars
[ "$rc" -eq 0 ] || fail "multi-instance scaffold exited $rc, expected 0 (stderr: $(cat "$err"))"

[ -f "$work/mi/internal/instance/instance.go" ] || fail "multi-instance scaffold did not ship internal/instance/instance.go"
[ ! -d "$work/mi/internal/probe" ] || fail "multi-instance scaffold shipped internal/probe/ (should be multi-only)"

mi_main=$(find "$work/mi/cmd" -maxdepth 2 -name main.go)
[ -n "$mi_main" ] || fail "multi-instance scaffold has no cmd/*/main.go"
grep -q 'WrapRegistererWith' "$mi_main" || fail "multi-instance main.go does not wrap per-instance labels"
grep -q 'var factories \[\]instance.Factory' "$mi_main" || fail "multi-instance main.go does not declare the instance factories slice"
grep -q '// @@INSTANCE_FACTORIES@@' "$mi_main" || fail "multi-instance main.go lost the // @@INSTANCE_FACTORIES@@ marker (/add-collector appends there)"
grep -q '/probe' "$mi_main" && fail "multi-instance main.go registers /probe (should be multi-only)"

# The starter collector must be the background variant (has Start/Done), not the
# synchronous one.
grep -q 'func (c \*ExampleCollector) Start(' "$work/mi/internal/collector/collector.go" || fail "multi-instance starter collector is not the background variant"

echo "PASS: --target-model multi-instance ships internal/instance and the background starter"

# ---------------------------------------------------------------------------
# 2c. --target-model multi-instance --flavor cli must be rejected.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
run --src "$assets" --dst "$work/bad-cli-mi" --flavor cli --forge none --target-model multi-instance $commonvars
[ "$rc" -ne 0 ] || fail "--target-model multi-instance --flavor cli was accepted, expected rejection"
grep -q 'target-model multi-instance requires --flavor http' "$err" || fail "expected a clear cli-rejection message, got: $(cat "$err")"

echo "PASS: --target-model multi-instance --flavor cli is rejected"

# ---------------------------------------------------------------------------
# 3. --target-model multi --flavor cli must be rejected: there is no cli
#    multi-target (Global Constraint, docs/design/2026-07-10-multi-target-design.md).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
run --src "$assets" --dst "$work/bad-cli-multi" --flavor cli --forge none --target-model multi $commonvars
[ "$rc" -ne 0 ] || fail "--target-model multi --flavor cli was accepted (exit 0), expected a non-zero rejection"
[ -e "$work/bad-cli-multi" ] && fail "--target-model multi --flavor cli should be rejected before --dst is created"
grep -q 'target-model multi requires --flavor http' "$err" || fail "expected a clear cli-rejection message, got: $(cat "$err")"

echo "PASS: --target-model multi --flavor cli is rejected with a clear message"

echo "PASS"
