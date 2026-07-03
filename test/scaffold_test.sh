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
# flavor selection: http kept, cli dropped
[ -f "$work/out/code/client.go" ] || fail "http flavor file missing"
[ ! -d "$work/out/code/cli" ] || fail "cli flavor dir should be dropped"
# forge none: github dir dropped
[ ! -d "$work/out/github" ] || fail "forge=none should drop github/"
# no residual sentinels anywhere
if grep -rn '@@[A-Z_]*@@' "$work/out"; then fail "residual @@VAR@@ left"; fi
# .tmpl suffix stripped
if find "$work/out" -name '*.tmpl' | grep -q .; then fail ".tmpl suffix not stripped"; fi
echo "PASS"
