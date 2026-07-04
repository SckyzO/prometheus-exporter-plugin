#!/bin/sh
# Edge-case tests for scaffold.sh: input validation and failure-mode coverage
# beyond the happy path in scaffold_test.sh — --flavor path traversal, --var
# KEY/VALUE validation, the residual-sentinel guard, LICENSE mismatch,
# non-empty --dst gating, --forge github retention, special-char round-trip,
# and a multi-level sentinel path rename. No Go, no network, sh+sed only.
#
# Set SCAFFOLD_BIN to point at an alternate copy of scaffold.sh (used during
# development to re-run this suite against a pre-fix snapshot for RED/GREEN
# comparisons); defaults to the real shipped script.
set -eu
here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
scaffold="${SCAFFOLD_BIN:-$root/skills/prometheus-exporter/assets/scaffold.sh}"
fixtures="$here/fixtures/mini-template"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Runs scaffold.sh with args "$@"; leaves the exit code in $rc and captures
# stdout/stderr to $out/$err for callers to inspect.
out="$work/_stdout"
err="$work/_stderr"
run() {
  rc=0
  "$scaffold" "$@" >"$out" 2>"$err" || rc=$?
}

# ---------------------------------------------------------------------------
# Finding 1 (Critical): --flavor path traversal
# ---------------------------------------------------------------------------

# 1a. Live PoC: a crafted --flavor escapes --dst entirely, exfiltrating a
# sibling directory's content into dst/code/ and rmdir'ing the original.
# src and dst are siblings one level under pocroot/, so code/../../victim
# resolves to the SAME pocroot/victim/ regardless of which side computes it —
# i.e. validating --flavor by "does src/code/<flavor> happen to exist" lets
# an attacker pick a --flavor that is "valid" against src yet reaches
# somewhere else entirely relative to dst.
mkdir -p "$work/pocroot/src/code/http"
printf 'package client\n' > "$work/pocroot/src/code/http/client.go.tmpl"
mkdir -p "$work/pocroot/victim"
printf 'TOP SECRET\n' > "$work/pocroot/victim/secret.txt"
run --src "$work/pocroot/src" --dst "$work/pocroot/dst" --flavor '../../victim' --forge none
[ "$rc" -ne 0 ] || fail "flavor traversal '../../victim' was accepted (exit 0) instead of rejected"
[ -d "$work/pocroot/victim" ] || fail "flavor traversal deleted victim/, a directory outside --dst"
[ -f "$work/pocroot/victim/secret.txt" ] || fail "flavor traversal removed/exfiltrated victim/secret.txt"
[ -e "$work/pocroot/dst" ] && fail "flavor traversal should be rejected before --dst is ever created"
grep -q 'single path component' "$err" || fail "expected a 'single path component' error, got: $(cat "$err")"

# 1b. Simpler shape check: a value with an embedded slash must be rejected
# for BEING a path (branded message), not merely because it happens not to
# match any real flavor subdirectory name (which is what the pre-fix
# existence-only check coincidentally did with the same exit code but for
# the wrong reason — a reason that stops holding the moment a subdirectory
# matching the traversal happens to exist, as 1a demonstrates).
run --src "$fixtures" --dst "$work/ab-dst" --flavor 'a/b' --forge none
[ "$rc" -ne 0 ] || fail "flavor 'a/b' was accepted"
grep -q 'single path component' "$err" || fail "flavor 'a/b' rejected for the wrong reason: $(cat "$err")"
[ -e "$work/ab-dst" ] && fail "flavor 'a/b' should be rejected before --dst is created"

# 1c. A literal dot (current-directory reference) must be rejected to guard
# against partial-path mutation: code/. is a valid path syntax that resolves
# to code/ itself, causing mv(1) to fail with "same file" error when the
# flatten step tries to mv code/./common → code/common. Reject it at validation
# time with a clear message, not at mv(1) time with a cryptic error.
run --src "$fixtures" --dst "$work/dot-dst" --flavor '.' --forge none
[ "$rc" -ne 0 ] || fail "flavor '.' was accepted"
grep -q 'single path component' "$err" || fail "flavor '.' rejected for the wrong reason: $(cat "$err")"
[ -e "$work/dot-dst" ] && fail "flavor '.' should be rejected before --dst is created"

# ---------------------------------------------------------------------------
# Finding 4 (Important): --var KEY validated on first char only
# ---------------------------------------------------------------------------
run --src "$fixtures" --dst "$work/key-dst" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var OWNER=acme \
  --var 'FOO/BAR=x'
[ "$rc" -ne 0 ] || fail "--var 'FOO/BAR=x' was accepted"
if grep -q 'sed:' "$err"; then fail "bad --var key crashed sed instead of failing cleanly: $(cat "$err")"; fi
grep -q 'invalid --var key' "$err" || fail "expected a branded 'invalid --var key' error, got: $(cat "$err")"

# ---------------------------------------------------------------------------
# Finding 5 (Important): newline embedded in a --var VALUE
# ---------------------------------------------------------------------------
badvalue=$(printf 'a\nb')
run --src "$fixtures" --dst "$work/nl-dst" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var "NAMESPACE=$badvalue" --var OWNER=acme
[ "$rc" -ne 0 ] || fail "--var value with an embedded newline was accepted"
if grep -q 'sed:' "$err"; then fail "newline in --var value crashed sed instead of failing cleanly: $(cat "$err")"; fi
grep -qi 'newline' "$err" || fail "expected a 'newline' error, got: $(cat "$err")"
[ -e "$work/nl-dst" ] && fail "newline in --var value left a partially-populated --dst behind"

# ---------------------------------------------------------------------------
# Finding 3 (Important): residual-sentinel guard — TRIGGER path (exit 3)
# A sentinel with no corresponding --var must survive substitution and fail
# the run with exit 3 (regression lock for the guard itself, independent of
# the grep-exit-code hardening around it).
# ---------------------------------------------------------------------------
mkdir -p "$work/res-src"
printf 'value=@@MISSING@@\n' > "$work/res-src/leftover.txt.tmpl"
run --src "$work/res-src" --dst "$work/res-dst" --flavor http --forge none
[ "$rc" -eq 3 ] || fail "a surviving @@MISSING@@ sentinel should exit 3, got rc=$rc: $(cat "$err")"
grep -q 'residual' "$err" || fail "expected a 'residual' error, got: $(cat "$err")"

# ---------------------------------------------------------------------------
# Finding 2 (Important): LICENSE placement silently no-ops on mismatch
# ---------------------------------------------------------------------------

# 2a. A LICENSE value with no matching licenses/LICENSE-<lower>.txt must die
# loudly, not silently ship the generated repo with no LICENSE at all.
run --src "$fixtures" --dst "$work/lic-bad-dst" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var OWNER=acme \
  --var LICENSE=Bogus
[ "$rc" -ne 0 ] || fail "--var LICENSE=Bogus (no matching file) was accepted; repo would ship with no LICENSE"
grep -q 'unknown --var LICENSE' "$err" || fail "expected an 'unknown --var LICENSE' error, got: $(cat "$err")"

# 2b. A LICENSE value that matches the fixture is placed at the top level,
# and the internal licenses/ menu is gone afterward.
run --src "$fixtures" --dst "$work/lic-ok-dst" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var OWNER=acme \
  --var LICENSE=apache-2.0
[ "$rc" -eq 0 ] || fail "--var LICENSE=apache-2.0 (matches fixture) failed, rc=$rc: $(cat "$err")"
[ -f "$work/lic-ok-dst/LICENSE" ] || fail "LICENSE was not placed at top level"
[ -d "$work/lic-ok-dst/licenses" ] && fail "licenses/ menu should be removed after placement"
grep -q 'Apache placeholder' "$work/lic-ok-dst/LICENSE" || fail "wrong content placed at LICENSE"

# ---------------------------------------------------------------------------
# Finding 6: test coverage gaps
# ---------------------------------------------------------------------------

# 6a. non-empty --dst is refused without --force, and accepted (merged, not
# wiped) with --force.
mkdir -p "$work/nonempty-dst"
printf 'pre-existing\n' > "$work/nonempty-dst/marker.txt"
run --src "$fixtures" --dst "$work/nonempty-dst" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var OWNER=acme
[ "$rc" -ne 0 ] || fail "non-empty --dst without --force was accepted"
[ -f "$work/nonempty-dst/marker.txt" ] || fail "refused run should not touch pre-existing --dst content"
[ -f "$work/nonempty-dst/LICENSE" ] && fail "refused run should not have scaffolded anything"

run --src "$fixtures" --dst "$work/nonempty-dst" --force \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var OWNER=acme
[ "$rc" -eq 0 ] || fail "non-empty --dst with --force failed, rc=$rc: $(cat "$err")"
[ -f "$work/nonempty-dst/marker.txt" ] || fail "--force should merge, not wipe, pre-existing --dst content"
[ -f "$work/nonempty-dst/cmd/redis_exporter/main.go" ] || fail "--force run did not scaffold"

# 6b. --forge github retains both the top-level github/ dir and release/github/.
run --src "$fixtures" --dst "$work/forge-dst" \
  --flavor http --forge github \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var OWNER=acme
[ "$rc" -eq 0 ] || fail "--forge github run failed, rc=$rc: $(cat "$err")"
[ -d "$work/forge-dst/github" ] || fail "--forge github should retain top-level github/"
[ -d "$work/forge-dst/release/github" ] || fail "--forge github should retain release/github/"

# 6c. special-char value round-trip: /, &, and \ all substitute literally in
# file CONTENT. Deliberately uses OWNER (a content-only sentinel in this
# fixture, never a path component) rather than NAMESPACE/EXPORTER_NAME:
# those two are also used as path components (see 6d), and a value
# containing "/" would there be split into extra path segments by `mv` —
# a real but separate, pre-existing limitation of path-component sentinels
# uncovered while writing this test, out of scope for this fix pass (no
# review finding calls for it; tracked as a follow-up, not fixed here).
run --src "$fixtures" --dst "$work/special-dst" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var 'OWNER=a/b&c\d'
[ "$rc" -eq 0 ] || fail "special-char round-trip run failed, rc=$rc: $(cat "$err")"
content=$(cat "$work/special-dst/keep.txt")
[ "$content" = 'owner=a/b&c\d' ] || fail "special-char round-trip mismatch: got [$content]"

# 6d. multi-level (>=2 deep) sentinel path rename.
run --src "$fixtures" --dst "$work/deep-dst" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var OWNER=acme
[ "$rc" -eq 0 ] || fail "multi-level rename run failed, rc=$rc: $(cat "$err")"
[ -f "$work/deep-dst/internal/collector/redis_exporter/redissub/deep.go" ] || fail "2-level-deep sentinel path was not renamed"
[ -f "$work/deep-dst/internal/collector/redis_exporter/shallow.go" ] || fail "1-level sentinel path (sibling of the 2-level one) was not renamed"
grep -q 'package deep // redis' "$work/deep-dst/internal/collector/redis_exporter/redissub/deep.go" || fail "content substitution missing inside the renamed multi-level path"

# 6e. scaffold.sh self-copy: the fixture ships its own scaffold.sh (a stand-in
# for the real plugin tooling file) precisely so this assertion has something
# to catch. It must never survive into scaffolded output — it's plugin
# tooling, not part of a generated exporter's repo.
run --src "$fixtures" --dst "$work/selfcopy-dst" \
  --flavor http --forge none \
  --var EXPORTER_NAME=redis_exporter --var NAMESPACE=redis --var OWNER=acme
[ "$rc" -eq 0 ] || fail "self-copy-strip run failed, rc=$rc: $(cat "$err")"
[ ! -e "$work/selfcopy-dst/scaffold.sh" ] || fail "scaffold.sh should not be copied into scaffolded output"

# ---------------------------------------------------------------------------
# Task 5: HTTP-flavor wiring-marker injection. scaffold.sh must fill
# // @@CLIENT_INIT@@ and // @@COLLECTOR_REGISTRY@@ in main.go from the
# selected flavor's code/<flavor>/wiring/*.frag snippets, keep each marker
# comment line itself intact (so /add-collector can reuse it later), and
# remove the internal/collector/wiring/ staging directory afterward so it
# never ships in the generated repo. Exercised against the REAL assets tree
# (not fixtures/mini-template): the wiring frags and the markers they fill
# are real production content, not scaffold-engine plumbing, and
# mini-template deliberately carries neither.
# ---------------------------------------------------------------------------
realassets="$root/skills/prometheus-exporter/assets"
run --src "$realassets" --dst "$work/wiring-dst" --flavor http --forge none \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0
[ "$rc" -eq 0 ] || fail "real-assets http scaffold (for wiring-injection check) failed, rc=$rc: $(cat "$err")"
mainfile="$work/wiring-dst/cmd/demo_exporter/main.go"
[ -f "$mainfile" ] || fail "scaffolded main.go missing at $mainfile"

# The marker-injection checks below only prove main.go itself was patched;
# they say nothing about whether the http flavor's own source files actually
# made it into the scaffolded tree. Assert those exist too.
for f in collector.go collector_test.go client.go; do
  [ -f "$work/wiring-dst/internal/collector/$f" ] || fail "expected internal/collector/$f to exist after an http-flavor scaffold"
done

grep -q 'exampleTarget := kingpin.Flag' "$mainfile" || fail "client_init.frag was not injected into main.go"
grep -q '// @@CLIENT_INIT@@' "$mainfile" || fail "// @@CLIENT_INIT@@ marker must survive injection so /add-collector can reuse it"
grep -q 'register("example"' "$mainfile" || fail "registry.frag was not injected into main.go"
grep -q '// @@COLLECTOR_REGISTRY@@' "$mainfile" || fail "// @@COLLECTOR_REGISTRY@@ marker must survive injection so /add-collector can reuse it"
[ ! -d "$work/wiring-dst/internal/collector/wiring" ] || fail "internal/collector/wiring/ staging dir should be removed after injection"

# Regression lock for a real bug hit while building this: register()'s own
# doc comment in main.go.tmpl prose-mentions "// @@COLLECTOR_REGISTRY@@"
# inside a sentence ("...marker in main() below."), to point readers at the
# real marker below it. An unanchored sed address matches that prose line
# too and splices a second copy of registry.frag into the middle of the
# comment block — main.go still contains 'register("example"' (the two
# checks above pass), but the output no longer compiles ("non-declaration
# statement outside function body"). Asserting an exact count of 1 is what
# actually catches that failure mode; mere presence does not.
regcount=$(grep -c 'register("example"' "$mainfile")
[ "$regcount" -eq 1 ] || fail "expected exactly 1 injected register(\"example\" call, found $regcount (regex likely matches register()'s own doc-comment prose mention of the marker too)"
initcount=$(grep -c 'exampleTarget := kingpin.Flag' "$mainfile")
[ "$initcount" -eq 1 ] || fail "expected exactly 1 injected client_init.frag copy, found $initcount"

# ---------------------------------------------------------------------------
# Task 11: flavor-specific docs/metrics.md relocation. code/<flavor>/
# metrics.md.tmpl (staged like every other flavor file) must end up at
# docs/metrics.md — NOT internal/collector/metrics.md[.tmpl], its generic
# flavor-selection staging location — with @@VAR@@ substitution already
# applied, exactly like every other common doc under docs/. Exercised
# against the REAL assets tree, same reasoning as the wiring-marker block
# above: this is real production content (mini-template ships no
# metrics.md.tmpl of its own), not scaffold-engine plumbing.
# ---------------------------------------------------------------------------
run --src "$realassets" --dst "$work/metricsdoc-dst" --flavor cli --forge none \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=demo_cli --var DATA_SOURCE_PATH=unused \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0
[ "$rc" -eq 0 ] || fail "real-assets cli scaffold (for metrics.md relocation check) failed, rc=$rc: $(cat "$err")"
metricsdoc="$work/metricsdoc-dst/docs/metrics.md"
[ -f "$metricsdoc" ] || fail "docs/metrics.md missing after a cli-flavor scaffold"
grep -q '`demo_example`' "$metricsdoc" || fail "docs/metrics.md does not document the cli flavor's own @@NAMESPACE@@_example metric — flavor-specific content did not land, or @@VAR@@ substitution did not reach it"
[ ! -e "$work/metricsdoc-dst/internal/collector/metrics.md.tmpl" ] || fail "metrics.md.tmpl staging file should not survive in internal/collector/"
[ ! -e "$work/metricsdoc-dst/internal/collector/metrics.md" ] || fail "metrics.md should not remain in internal/collector/ after relocation to docs/"

echo "PASS"
