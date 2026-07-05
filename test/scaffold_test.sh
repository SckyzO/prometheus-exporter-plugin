#!/bin/sh
# Unit test for scaffold.sh — no Go, no network, sh+sed only.
set -eu
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sh "$root/skills/prometheus-exporter/assets/scaffold.sh" \
  --src "$here/fixtures/mini-template" \
  --dst "$work/out" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter \
  --var NAMESPACE=redis \
  --var OWNER=acme

fail() { echo "FAIL: $1" >&2; exit 1; }

# path rename applied
[ -f "$work/out/cmd/redis_exporter/main.go" ] || fail "path @@EXPORTER_NAME@@ not renamed"
# content substitution applied
grep -q 'namespace = "redis"' "$work/out/cmd/redis_exporter/main.go" || fail "@@NAMESPACE@@ not substituted"
# flavor selection: http moved into internal/collector/, code/ staging removed entirely (cli along with it)
[ -f "$work/out/internal/collector/client.go" ] || fail "http flavor file missing from internal/collector/"
[ ! -d "$work/out/code" ] || fail "code/ staging tree should be removed after flavor selection"
# common file at its final (root) path survives flavor selection untouched
[ -f "$work/out/keep.txt" ] || fail "common file at final path missing"
# forge none: .github/ (the whole GitHub layer) dropped
[ ! -d "$work/out/.github" ] || fail "forge=none should drop .github/"
# no residual sentinels anywhere
if grep -rn '@@[A-Z_]*@@' "$work/out"; then fail "residual @@VAR@@ left"; fi
# .tmpl suffix stripped
if find "$work/out" -name '*.tmpl' | grep -q .; then fail ".tmpl suffix not stripped"; fi
echo "PASS"
