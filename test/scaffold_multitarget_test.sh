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

commonvars="--var EXPORTER_NAME=demo --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var DEFAULT_PORT=9999 --var LICENSE=apache-2.0 --var OWNER=demo --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance"

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
grep -q 'hc \*http\.Client' "$probefile" || fail "multi scaffold's probe.go lost the 'hc *http.Client' parameter that /add-collector's seam detection greps for"

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

# ---------------------------------------------------------------------------
# 4. The shipped systemd unit must be startable on the model it was scaffolded
#    for. Assert the ACTIVE ExecStart, never a commented example: a commented
#    example is what documenting this defect instead of fixing it would look
#    like, and it would leave a multi-instance operator with a service that
#    exits before it ever binds a port.
# ---------------------------------------------------------------------------
mi_unit="$work/mi/systemd/demo.service"
[ -f "$mi_unit" ] || fail "multi-instance scaffold did not ship systemd/demo.service"

# Assert the WHOLE line, not just the presence of the flag. scaffold.sh appends
# to the rendered ExecStart with sed's `&`; an edit that lost `&` would leave
# "ExecStart= --config.file=..." behind, which carries the flag, satisfies a
# substring check, and starts no binary at all. Ask what the assertion cannot
# see, then close it: this one now pins the binary path and the pre-existing
# flag as well.
grep -q '^ExecStart=/usr/local/bin/demo .*--web\.listen-address=.*--config\.file=' "$mi_unit" ||
  fail "multi-instance systemd unit's active ExecStart is not the rendered command plus --config.file (got: $(grep '^ExecStart=' "$mi_unit"))"

# Exactly one active ExecStart: systemd rejects a second one outside
# Type=oneshot, and this unit is Type=simple.
mi_execstarts=$(grep -c '^ExecStart=' "$mi_unit")
[ "$mi_execstarts" -eq 1 ] ||
  fail "multi-instance systemd unit has $mi_execstarts active ExecStart lines, expected exactly 1"

grep -q '^ExecReload=' "$mi_unit" || fail "multi-instance systemd unit's ExecReload is not active"

# single and multi start without the flag; adding it there would point them at
# a file that need not exist. Their ExecStart must come through untouched.
for m in default multi; do
  unit="$work/$m/systemd/demo.service"
  [ -f "$unit" ] || fail "$m scaffold did not ship systemd/demo.service"
  grep -q '^ExecStart=.*--config\.file=' "$unit" &&
    fail "$m scaffold's active ExecStart gained --config.file (that model starts without one)"
done

# The ExecReload surgery this block now shares its plumbing with must keep
# behaving exactly as before: commented on single, active on multi.
grep -q '^# ExecReload=' "$work/default/systemd/demo.service" ||
  fail "single scaffold's ExecReload is not commented out"
grep -q '^ExecReload=' "$work/multi/systemd/demo.service" ||
  fail "multi scaffold's ExecReload is not active"

echo "PASS: the systemd unit's ExecStart and ExecReload match the target model"

# ---------------------------------------------------------------------------
# 5. config.example.yml describes the model it was scaffolded for, and only
#    that one. This is the first application of the conditional-block seam,
#    and the property is the one the field report asked for: no file mentions
#    a model that was not chosen.
#
#    Asserted on the RENDERED file rather than the template, because the
#    template legitimately contains all three and the whole question is what
#    survives selection.
# ---------------------------------------------------------------------------
mi_cfg="$work/mi/config.example.yml"
[ -f "$mi_cfg" ] || fail "multi-instance scaffold shipped no config.example.yml"

# instances: is the one section this model cannot start without, which is why
# --config.file is mandatory here. A file that omits it is a starting point
# that cannot start.
grep -q '^# instances:' "$mi_cfg" ||
  fail "multi-instance config.example.yml has no instances: section; it is the only mandatory section on this model"
grep -q 'probe' "$mi_cfg" &&
  fail "multi-instance config.example.yml documents /probe, a route this binary never registers"
grep -q 'collectors: \[' "$mi_cfg" &&
  fail "multi-instance config.example.yml uses a module collectors: key, which this model refuses at boot (the same file says so)"

default_cfg="$work/default/config.example.yml"
grep -q 'probe' "$default_cfg" &&
  fail "single-target config.example.yml documents /probe, which only the multi model serves"
grep -q '^# instances:' "$default_cfg" &&
  fail "single-target config.example.yml documents instances:, which only multi-instance reads"

# multi keeps what is genuinely its own: the /probe module examples, with the
# collectors: key that model does accept. Asserted so a later tightening of
# the conditionals cannot silently empty this file.
multi_cfg="$work/multi/config.example.yml"
grep -q 'probe?target=' "$multi_cfg" ||
  fail "multi config.example.yml lost its /probe module examples"
grep -q 'collectors: \[' "$multi_cfg" ||
  fail "multi config.example.yml lost the module collectors: key, which this model accepts"

# No conditional marker reaches any rendered file. The residual-sentinel guard
# would also catch this, but assert it here: that guard carries an allowlist
# and these must never be added to it.
for m in default multi mi; do
  if grep -rq '@@IF\|@@ENDIF@@' "$work/$m" 2>/dev/null; then
    fail "$m scaffold leaked a conditional marker: $(grep -rl '@@IF\|@@ENDIF@@' "$work/$m" | head -3)"
  fi
done

echo "PASS: config.example.yml describes only the target model it was scaffolded for"

# The property the field report asked for, applied to the whole tree rather
# than one file: no rendered artifact mentions a route, a model or a flavor
# this scaffold did not produce. Checked on the two selectors that actually
# mislead a reader, /probe (a route only multi registers) and the CLI-flavor
# asides in an http tree.
for m in default mi; do
  if grep -rln '/probe' "$work/$m" --include='*.md' --include='*.yml' 2>/dev/null | grep -q .; then
    fail "$m scaffold documents /probe, a route only a multi build registers: $(grep -rln '/probe' "$work/$m" --include='*.md' --include='*.yml' | head -3)"
  fi
done
if ! grep -rq 'probe?target=' "$work/multi" --include='*.md' 2>/dev/null; then
  fail "multi scaffold lost its own /probe documentation"
fi
for m in default multi mi; do
  if grep -rlin 'CLI flavor\|CLI-flavor' "$work/$m" --include='*.md' --include='*.yml' 2>/dev/null | grep -q .; then
    fail "$m scaffold (http) carries a CLI-flavor aside: $(grep -rlin 'CLI flavor\|CLI-flavor' "$work/$m" --include='*.md' --include='*.yml' | head -3)"
  fi
done

echo "PASS: no rendered doc or config mentions a target model or flavor that was not chosen"

# The container path must be able to start the model it was scaffolded for,
# the same claim the systemd unit now carries. Naming the file on the command
# line is only half of it in a container: without the mount the flag points at
# nothing, and `restart: unless-stopped` turns that into a permanent crash
# loop rather than one visible failure.
for f in docker-compose.yml docker-compose.minimal.yml; do
  mi_c="$work/mi/$f"
  [ -f "$mi_c" ] || fail "multi-instance scaffold shipped no $f"
  grep -q -- '- --config.file=' "$mi_c" ||
    fail "multi-instance $f passes no --config.file; the container exits before it binds"
  grep -q ':/etc/demo/config.yml:ro' "$mi_c" ||
    fail "multi-instance $f names --config.file but mounts nothing at that path"

  for m in default multi; do
    other="$work/$m/$f"
    grep -q -- '- --config.file=' "$other" &&
      fail "$m $f gained --config.file; that model starts without one"
  done
done

echo "PASS: the container path can start a multi-instance build, mount included"

# ---------------------------------------------------------------------------
# 6. What the assertions above cannot see, and this repository has now shipped
#    three times: a guardrail that covers a path in a way that cannot see the
#    defect. Everything so far checks that unwanted text is GONE. Nothing
#    checked that wanted text SURVIVED, and gating by hand over-dropped six
#    passages with every assertion, and golden-smoke, staying green.
#
#    So: structure, and a floor of content that must exist on every model.
# ---------------------------------------------------------------------------

# A heading that lost its parent is the signature of an @@ENDIF@@ landing one
# heading too early. The obvious check, "no ### before the document's first
# ##", is structurally incapable of seeing it: every real over-drop of this
# class happens deep in the file, under some earlier ##. Written that way once,
# it stayed green on exactly the defect it was named for.
#
# The invariant that does hold: a subsection's PARENT must not change between
# target models. If gating removes the ## a ### was authored under, that ###
# reattaches to whatever ## precedes it instead, and the pairing diverges.
parentmap() { # <rendered .md> -> "<h3 title>\t<nearest preceding h2 title>"
  awk '/^## /{h2=substr($0,4)} /^### /{print substr($0,5) "\t" h2}' "$1"
}
for f in README.md SECURITY.md docs/configuration.md docs/metrics.md docs/development.md; do
  for m in multi mi; do
    [ -f "$work/$m/$f" ] && [ -f "$work/default/$f" ] || continue
    parentmap "$work/default/$f" > "$work/_pm-default"
    parentmap "$work/$m/$f" > "$work/_pm-$m"
    # Only headings present in BOTH renders can be compared; one that exists on
    # a single model is legitimately model-specific.
    while IFS="$(printf '\t')" read -r h3 parent; do
      # Test the LINE for presence, not the parent: a heading whose parent
      # gated away entirely has an empty parent, and skipping on an empty
      # parent is skipping exactly the defect this loop is named for. That
      # is how the first cut of this check stayed green under its own
      # mutation. Mutation-tested in both directions.
      other=$(awk -F'\t' -v h="$h3" '$1==h{print $2; found=1; exit} END{exit !found}' "$work/_pm-$m") || continue
      [ "$other" = "$parent" ] ||
        fail "$f: subsection '$h3' sits under '$parent' on single but under '${other:-(no parent at all)}' on $m; gating removed the level-2 heading it was authored beneath"
    done < "$work/_pm-default"
  done
done

# Content that is model-independent must reach every model. Each string below
# stands for a passage a hand-written gate actually swallowed.
for m in default multi mi; do
  grep -q 'CycloneDX' "$work/$m/SECURITY.md" ||
    fail "$m SECURITY.md lost the supply-chain section; it describes signing and SBOMs, which no target model changes"
  grep -q 'Prometheus scrape endpoint' "$work/$m/README.md" ||
    fail "$m README.md lost its endpoint table"
  grep -q 'Bounding outbound concurrency' "$work/$m/docs/configuration.md" ||
    fail "$m docs/configuration.md lost the concurrency section"
done

# Content that IS model-dependent must reach exactly the models that serve it.
# /-/reload is the one the first pass got wrong: multi-instance registers the
# route and its README stopped documenting it.
for m in multi mi; do
  grep -q '/-/reload' "$work/$m/README.md" ||
    fail "$m README.md does not document POST /-/reload, which this model registers"
done
grep -q '/-/reload' "$work/default/README.md" &&
  fail "single-target README.md documents POST /-/reload, which that model has no route for"

# A bulleted lead-in with no bullets under it reads as a truncated document.
# Checked on the one section that is gated three ways.
# A lead-in that promised a list and got none. Anchored on the lead-in's
# TEXT, normalized across line wraps, not on a physical line: a previous
# version matched the second line of a two-line wrap, so reflowing that
# sentence silently turned the assertion into a no-op. A blanket "any bolded
# lead-in must be followed by a list" rule was tried and rejected: a bolded
# lead-in followed by prose is ordinary Markdown, and the rule fired on four
# innocent paragraphs.
for m in default multi mi; do
  cfg="$work/$m/docs/configuration.md"
  [ -f "$cfg" ] || continue
  # Paragraphs, blank-line separated, each flattened to one line.
  awk 'BEGIN{RS="";FS="\n"} {p=""; for(i=1;i<=NF;i++) p = p (i>1?" ":"") $i; print p}' "$cfg" > "$work/_paras"
  n=$(grep -n 'worth knowing before you set a number' "$work/_paras" | head -1 | cut -d: -f1)
  if [ -n "$n" ]; then
    nextp=$(sed -n "$((n + 1))p" "$work/_paras")
    case "$nextp" in
      "- "*) ;;
      *) fail "$m docs/configuration.md introduces the ceiling bullets and then lists none; next paragraph is: $nextp" ;;
    esac
  fi
done

echo "PASS: gating dropped nothing a model still needs, and left no orphaned heading"

# ---------------------------------------------------------------------------
# 7. The cli flavor, from the REAL assets tree.
#
#    Every tree above is --flavor http; the only cli runs are the two
#    rejection cases, and scaffold_edge_test.sh uses a synthetic fixture. That
#    blind spot let a regression ship: docs/configuration.md's worked examples
#    hardcoded an http-only flag name, so a cli repository was told to run a
#    flag its binary does not declare. golden-smoke builds cli, but
#    `make docs-check` only reconciles docs/metrics.md against the collector
#    sources, so it cannot see configuration.md or validation-checklist.md.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
run --src "$assets" --dst "$work/cli" --flavor cli --forge none $commonvars
[ "$rc" -eq 0 ] || fail "cli scaffold exited $rc, expected 0 (stderr: $(cat "$err"))"

cli_cfgdoc="$work/cli/docs/configuration.md"
grep -q 'no-collector.command_exec' "$cli_cfgdoc" ||
  fail "cli docs/configuration.md does not name this flavor's own self-instrumentation collector in its worked examples"
grep -q 'no-collector.http_client_requests' "$cli_cfgdoc" &&
  fail "cli docs/configuration.md tells the operator to run --no-collector.http_client_requests, a flag a cli binary never declares"

grep -q 'collector="command_exec"' "$work/cli/docs/validation-checklist.md" ||
  fail "cli docs/validation-checklist.md expects the http flavor's series names; the operator would chase a series this binary never emits"

# Every collector flag the cli docs name must exist in the binary. This is the
# generic form of the two greps above, and it is what would have caught the
# regression without anyone naming the flag first.
#
# -E, not BRE: the first cut of this used '--no\?-collector\.', where \? makes
# the preceding "o" optional rather than the "no-" group, so the pattern read
# as --n(o?)-collector and matched --no-collector and --n-collector but never
# --collector. The strip below was dead code and the loop inspected no
# per-collector option flag at all. Mutation-tested in both directions.
#
# The two flag shapes need different lookups, which is why this is not one
# grep. A toggle (--[no-]collector.<name>, two segments) is built by
# concatenation in register(), so "collector.<name>" appears nowhere as a
# literal and the collector's own name is what must be found. An option
# (--collector.<name>.<opt>, three segments) is declared as a whole string in
# kingpin.Flag, so the literal is what must be found.
# Two details that each cost this check its own defect once.
#
# LC_ALL=C on the sort: under a UTF-8 locale glibc collation ignores
# punctuation at the primary level, so "example.timeout" and
# "example.time_out" compare EQUAL and `sort -u` silently drops one before the
# lookup runs. A typo'd flag colliding that way with a real one was invisible
# locally while failing in CI, which runs C.UTF-8.
#
# The trailing segment is anchored, '(\.[a-z0-9_]+)*' rather than a blanket
# '[a-z0-9_.]+', so a flag written at the end of a sentence does not absorb
# the period and turn a correct document into a false failure.
check_collector_flags() { # <label> <rendered tree>
  _doc="$2/docs/configuration.md"
  [ -f "$_doc" ] || return 0
  for _flag in $(grep -ohE -- '--(no-)?collector\.[a-z0-9_]+(\.[a-z0-9_]+)*' "$_doc" \
                 | sed 's/^--\(no-\)\?collector\.//' | LC_ALL=C sort -u); do
    case $_flag in
      *.*) _needle="collector.$_flag" ;; # option flag: declared as a whole string
      *)   _needle="$_flag" ;;           # toggle: the name register() takes
    esac
    grep -rq "\"$_needle\"" "$2/cmd" "$2/internal" ||
      fail "$1 docs/configuration.md names --collector.$_flag, which appears nowhere in the generated sources"
  done
}

# Run over EVERY rendering, not just cli. Scoping this to one cell is how three
# instances of the very defect it detects kept shipping on the other two: the
# flag surface varies by target model as much as by flavor.
check_collector_flags single "$work/default"
check_collector_flags multi "$work/multi"
check_collector_flags multi-instance "$work/mi"
check_collector_flags cli "$work/cli"

echo "PASS: every rendering's docs name only flags that binary actually declares"

# The same parent-stability invariant as above, on the FLAVOR axis. It is run
# here rather than in that loop only because $work/cli is rendered at this
# point in the file and not earlier.
#
# Running it on the model axis alone was itself the defect: this PR's whole
# subject is that prose varies by flavor as well as by target model, so leaving
# the flavor axis uncovered left the invariant blind to half of what it guards.
# Mutation-tested: gating a level-2 heading out of the cli rendering leaves the
# model-axis loop green and turns this one red.
for f in README.md SECURITY.md docs/configuration.md docs/metrics.md docs/development.md; do
  [ -f "$work/cli/$f" ] && [ -f "$work/default/$f" ] || continue
  parentmap "$work/default/$f" > "$work/_pm-default"
  parentmap "$work/cli/$f" > "$work/_pm-cli"
  while IFS="$(printf '\t')" read -r h3 parent; do
    other=$(awk -F'\t' -v h="$h3" '$1==h{print $2; found=1; exit} END{exit !found}' "$work/_pm-cli") || continue
    [ "$other" = "$parent" ] ||
      fail "$f: subsection '$h3' sits under '$parent' on http but under '${other:-(no parent at all)}' on cli; gating removed the level-2 heading it was authored beneath"
  done < "$work/_pm-default"
done

echo "PASS: no subsection changed parent between flavors either"

echo "PASS"
