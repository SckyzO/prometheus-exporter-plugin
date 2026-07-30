#!/bin/sh
# golden-smoke.sh — end-to-end smoke test for a scaffolded exporter.
#
# Scaffolds a throwaway exporter via scaffold.sh, then runs it through the
# exact same gate a real maintainer would run right after
# /new-prometheus-exporter: `make build` then `make check` (vet, lint, test,
# vuln, actionlint, zizmor, deadcode, docs-check — see Makefile.tmpl). Both
# must succeed, the generated tree must never mention the source project
# this plugin's knowledge is derived from, and no @@VAR@@ sentinel may
# survive. `promtool check rules` then validates monitoring/prometheus/
# {alerts,rules}.yml (native/docker/podman, explicit SKIP if none available —
# see below). A `docker build -f Dockerfile .` guarded the same way (docker,
# then podman, else an explicit SKIP) proves the scaffolded Dockerfile itself
# actually builds. A final sub-check fabricates a lying docs/metrics.md line
# and proves `make docs-check` alone actually rejects it, then reverts and
# proves it accepts the clean doc again (see below).
#
# Usage:
#   test/golden-smoke.sh --flavor <http|cli> --forge <github|none> [--target-model <single|multi|multi-instance>]
#   test/golden-smoke.sh --all
#
# Each of the 4 cells in the {http,cli} x {none,github} matrix has its own
# hardcoded --var set below, wired one at a time across several tasks:
# http+none (Task 7), cli+none (Task 9), http+github (Task 14 - the first
# forge=github golden run, so also the first time actionlint/zizmor lint
# real workflow content instead of skipping on an absent .github/workflows/),
# and cli+github (Task 22, completing the matrix). The case switch below is
# a small, explicit, hardcoded set, not a discovered/growing registry -
# mirroring scaffold.sh's own --forge github|none - so an unwired
# combination fails loudly with a clear message instead of guessing at
# plausible-looking values, which is what "logs any step it skips explicitly"
# (see the header of each phase below) means for THIS script's own scope, as
# opposed to a runtime environment gap (e.g. a missing optional tool), which
# is instead handled inside the Makefile itself (actionlint/zizmor skip
# gracefully when .github/workflows/ is absent — see Makefile.tmpl) and
# simply surfaces here because this script never redirects make's own
# stdout/stderr away from the caller's terminal.
#
# --target-model <single|multi|multi-instance> (Task 2, multi-target epic;
# multi-instance added in Task 12) defaults to "single" (today's runtime,
# every cell above is single-target and unaffected). "multi" and
# "multi-instance" both require --flavor http (mirrors scaffold.sh's own
# restriction; no cli multi-target) and, beyond the standard
# build/check/promtool-rules gates every cell runs, additionally start the
# scaffolded binary and prove it serves live: "multi" probes the exporter's
# own /metrics endpoint as a target and checks the response through
# `promtool check metrics` - see the http-multi guarded block below.
# "multi-instance" starts the binary with a --config.file listing two
# instances at unreachable addresses and confirms both instances' health
# series (target="alpha", target="beta") appear on /metrics immediately, via
# the always-emitted freshness gauge - see the http-multi-instance guarded
# block below. Both the http-multi and http-multi-instance blocks are each
# followed by their own reload sub-check (Task 14, config-reload-and-
# concurrency epic): --web.enable-lifecycle off means POST /-/reload 404s,
# a config edit that reloads cleanly is proven USABLE afterwards (not just
# answered 200), a config edit that fails to parse is proven to still be
# SERVING the last-good configuration (the atomicity property), and a
# changed flags: section is refused by name. The http-multi-instance one
# also carries the one cell in the whole --all matrix that sets
# --exporter.max-requests-per-target above its default of 0.
#
# --all (Task 22, extended by Task 2, extended again by Task 12) runs all 4
# matrix cells PLUS a 5th, additional http-multi cell (flavor=http,
# forge=none, target-model=multi) PLUS a 6th, additional http-multi-instance
# cell (flavor=http, forge=none, target-model=multi-instance) in one
# invocation - see the dispatch block right after argument parsing below for
# how each cell stays isolated from the others' own pass/fail.
#
# POSIX sh + sed + grep + make, same dependency discipline as scaffold.sh
# itself. `make build`/`make check` additionally need a Go toolchain and,
# for pinned/reproducible tooling, a container engine (Docker or Podman) —
# absent either, `make` itself falls back to the host toolchain with a
# visible warning banner (see Makefile.tmpl's native-warning target); this
# script does not special-case that path, it just doesn't hide the banner.
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
assets="$root/skills/prometheus-exporter/assets"

# keep in sync with the goreleaser binary version pinned in
# assets/.github/workflows/release.yml.tmpl
GORELEASER_VERSION=2.16.0

# Pinned syft image tag for this harness's OWN containerized fallback (used
# below when native syft is not on PATH - see the image-SBOM step). Unlike
# GORELEASER_VERSION above, nothing in the shipped templates pins a syft
# version to keep this "in sync" with: Makefile.tmpl's sbom-image target
# just requires "syft on PATH" (any version), and .goreleaser.yaml.tmpl's
# own header comment says the same for the archive sboms: step. Confirmed
# by running `docker run --rm anchore/syft:v1.46.0 version` before wiring
# it in: image tags on Docker Hub carry a leading "v" (GitVersion reports
# bare "1.46.0"), same split as GORELEASER_VERSION/goreleaser's own tags
# below. Bump periodically; there is no drift to detect, just staleness.
SYFT_VERSION=1.46.0

prog=$(basename "$0")

# MATRIX_CELLS is the single source of truth for what --all runs AND for what
# .github/workflows/plugin-ci.yml's golden-smoke matrix must name. That
# workflow cannot read a shell variable, so it repeats the list literally; the
# scaffold-unit-tests job then asserts the two agree by diffing its matrix
# against `--list-cells`. Add a cell here and that assertion goes red until the
# workflow names it too, which is the point: a cell CI silently never runs is
# worse than no cell at all.
MATRIX_CELLS="http-none http-github cli-none cli-github http-multi http-multi-instance"

usage() {
  cat <<EOF >&2
Usage: $prog --flavor <http|cli> --forge <github|none> [--target-model <single|multi|multi-instance>]
       $prog --all
       $prog --list-cells
EOF
}

die() {
  echo "$prog: error: $1" >&2
  exit 1
}

flavor=""
forge=""
target_model=single
all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --flavor)
      [ $# -ge 2 ] || die "--flavor requires a value"
      flavor=$2
      shift 2
      ;;
    --forge)
      [ $# -ge 2 ] || die "--forge requires a value"
      forge=$2
      shift 2
      ;;
    --target-model)
      [ $# -ge 2 ] || die "--target-model requires a value"
      target_model=$2
      shift 2
      ;;
    --all)
      all=1
      shift
      ;;
    --list-cells)
      # One cell name per line, for CI's drift guard. Answered here, before
      # every validation below, because listing the matrix needs no
      # --flavor/--forge and does no work.
      for c in $MATRIX_CELLS; do echo "$c"; done
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# --target-model (Task 2, multi-target epic; multi-instance added in Task 12):
# defaults to "single" (today's runtime, unchanged), mirroring scaffold.sh's
# own default and validation exactly, including the http-only restriction
# (there is no cli multi-target).
case "$target_model" in
  single|multi|multi-instance) ;;
  *) die "invalid --target-model '$target_model'; must be single, multi, or multi-instance" ;;
esac
if { [ "$target_model" = multi ] || [ "$target_model" = multi-instance ]; } && [ -n "$flavor" ] && [ "$flavor" != http ]; then
  die "--target-model $target_model requires --flavor http (no cli multi-target)"
fi

# --all runs the full matrix and is mutually exclusive with a single
# --flavor/--forge cell: mixing them would leave it ambiguous whether the
# caller wants one cell or all four, and silently picking one interpretation
# over the other is exactly the kind of guess this script's fail-closed
# discipline (see header, and the grep exit-code handling further down)
# refuses to make anywhere else.
if [ "$all" -eq 1 ]; then
  [ -z "$flavor" ] && [ -z "$forge" ] || die "--all cannot be combined with --flavor/--forge"
else
  [ -n "$flavor" ] || die "--flavor is required (or pass --all to run the full matrix)"
  [ -n "$forge" ] || die "--forge is required (or pass --all to run the full matrix)"
fi

# --all (Task 22): re-invoke this same script, once per matrix cell, as a
# FRESH sh PROCESS rather than a sourced/called function - the isolation a
# plain function call sharing this process would not give for free. Every
# cell below is written with set -eu and die() (die calls exit), which is
# exactly right for a single --flavor/--forge invocation (fail immediately,
# loudly) but wrong for a driver that wants to run all 4 cells and report
# every failure together: a shared-process function call would let cell 1's
# die() tear down the whole --all run before cells 2-4 ever got a chance.
# Sequential, deliberately not backgrounded: every cell hardcodes the same
# EXPORTER_NAME (demo_exporter, see the case switch below), so two cells
# building the SAME tools image tag at once (Makefile.tmpl's tools-image
# target, keyed only on EXPORTER_NAME) would race on that tag and its mtime
# stamp file - running one cell fully to completion before starting the
# next sidesteps that entirely, and also means the 2nd-4th cells reuse the
# 1st cell's already-built tools image instead of rebuilding it.
if [ "$all" -eq 1 ]; then
  echo "== golden-smoke.sh --all: running the full matrix {http,cli} x {none,github}, plus the http-multi and http-multi-instance cells =="
  overall_rc=0
  summary=""
  # http-multi (Task 2, multi-target epic) and http-multi-instance (Task 12)
  # are a FIFTH and SIXTH, additional cell, not a full {single,multi,multi-
  # instance} x {http,cli} x {none,github} cross product: both require
  # --flavor http (no cli multi-target, same restriction validated above),
  # so each is special-cased here rather than folded into the generic
  # cell%-*/cell#*- parsing below, which assumes exactly one hyphen.
  for cell in $MATRIX_CELLS; do
    case "$cell" in
      http-multi)
        cell_flavor=http
        cell_forge=none
        cell_extra="--target-model multi"
        ;;
      http-multi-instance)
        cell_flavor=http
        cell_forge=none
        cell_extra="--target-model multi-instance"
        ;;
      *)
        cell_flavor=${cell%-*}
        cell_forge=${cell#*-}
        cell_extra=""
        ;;
    esac
    echo ""
    echo "=================================================================="
    echo "== matrix cell: $cell =="
    echo "=================================================================="
    # shellcheck disable=SC2086 # $cell_extra is a deliberately unquoted, either-empty-or-fixed-two-token flag
    if sh "$here/$prog" --flavor "$cell_flavor" --forge "$cell_forge" $cell_extra; then
      summary="$summary
  $cell: PASS"
    else
      summary="$summary
  $cell: FAIL"
      overall_rc=1
    fi
  done
  echo ""
  echo "== golden-smoke.sh --all: matrix summary =="
  printf '%s\n' "$summary"
  if [ "$overall_rc" -ne 0 ]; then
    echo "$prog --all: FAIL - at least one matrix cell failed, see summary above" >&2
  else
    echo "$prog --all: PASS - all 6 cells green"
  fi
  exit "$overall_rc"
fi

# work dir key: only suffixed for target_model=multi / multi-instance, so the
# existing 4 cells' work dirs (test/_work/http-none, etc.) are byte-identical
# to before this axis existed — target_model=single is this script's own
# default too, exactly mirroring scaffold.sh's own default.
workkey="$flavor-$forge"
case "$target_model" in
  multi) workkey="$workkey-multi" ;;
  multi-instance) workkey="$workkey-multi-instance" ;;
esac
work="$root/test/_work/$workkey"

# Brief-format contract (discovery-inputs epic): the shipped fixture must
# carry every section the discovery-inputs reference documents and
# /new-prometheus-exporter consumes. This is the tripwire for format drift
# across the reference, the command, and /new — three artifacts that must
# agree on these headers. Cell-independent (checks a committed fixture, not
# $work), placed early so it fails before any build.
echo "== brief-format contract: fixture carries every required section =="
brief_fixture="$root/test/fixtures/exporter-design-brief.md"
[ -f "$brief_fixture" ] || die "brief fixture missing: $brief_fixture"
for header in '## Provenance' '## Architecture decisions' '## Scaffold inputs' '## Open questions'; do
  if command grep -qF "$header" "$brief_fixture"; then
    echo "confirmed: fixture has section '$header'"
  else
    die "brief fixture missing required section '$header' ($brief_fixture)"
  fi
done

# Start from a clean slate rather than trusting scaffold.sh's own --force
# (which merges into a pre-existing --dst rather than wiping it): a stale
# internal/collector/testdata/ left behind by a PRIOR run of this same
# combination makes the flavor-selection move step's `mv` fail outright
# ("Directory not empty") on the second run. Real bug hit empirically while
# building this script, not a hypothetical — rm -rf here sidesteps it and
# also happens to be exactly what a trustworthy repeatable smoke test wants
# anyway: no leftover state from a previous run.
rm -rf "$work"

# Monitoring vars (Task 11): job/instance for every model except
# multi-instance, whose identifying label is @@INSTANCE_LABEL@@ (default
# "target", see scaffold.sh --instance-label) rather than Prometheus's own
# scrape-time instance label, so its health rules/alerts must aggregate and
# name by "target" instead; the multi (probe) model still uses job/instance
# since a probed target has no such custom label.
collector_health_by=job
collector_location=instance
if [ "$target_model" = multi-instance ]; then
  collector_health_by=job,target
  collector_location=target
fi

echo "== scaffolding $flavor/$forge (target-model=$target_model) into ${work#"$root"/} =="
case "$flavor-$forge" in
  http-none)
    sh "$assets/scaffold.sh" \
      --src "$assets" --dst "$work" \
      --flavor "$flavor" --forge "$forge" --target-model "$target_model" --force \
      --var EXPORTER_NAME=demo_exporter \
      --var NAMESPACE=demo \
      --var MODULE_PATH=example.com/demo_exporter \
      --var DATA_SOURCE=http://localhost:9999 \
      --var DATA_SOURCE_PATH=/api/example \
      --var DEFAULT_PORT=9999 \
      --var OWNER=acme \
      --var LICENSE=apache-2.0 \
      --var COLLECTOR_HEALTH_BY="$collector_health_by" \
      --var COLLECTOR_LOCATION="$collector_location"
    ;;
  cli-none)
    sh "$assets/scaffold.sh" \
      --src "$assets" --dst "$work" \
      --flavor "$flavor" --forge "$forge" --target-model "$target_model" --force \
      --var EXPORTER_NAME=demo_exporter \
      --var NAMESPACE=demo \
      --var MODULE_PATH=example.com/demo_exporter \
      --var DATA_SOURCE=demo_cli \
      --var DATA_SOURCE_PATH=unused \
      --var DEFAULT_PORT=9999 \
      --var OWNER=acme \
      --var LICENSE=apache-2.0 \
      --var COLLECTOR_HEALTH_BY="$collector_health_by" \
      --var COLLECTOR_LOCATION="$collector_location"
    ;;
  http-github)
    sh "$assets/scaffold.sh" \
      --src "$assets" --dst "$work" \
      --flavor http --forge github --target-model "$target_model" --force \
      --var EXPORTER_NAME=demo_exporter \
      --var NAMESPACE=demo \
      --var MODULE_PATH=example.com/demo_exporter \
      --var DATA_SOURCE=http://localhost:9999 \
      --var DATA_SOURCE_PATH=/api/example \
      --var DEFAULT_PORT=9999 \
      --var OWNER=acme \
      --var LICENSE=apache-2.0 \
      --var COLLECTOR_HEALTH_BY="$collector_health_by" \
      --var COLLECTOR_LOCATION="$collector_location"
    ;;
  cli-github)
    sh "$assets/scaffold.sh" \
      --src "$assets" --dst "$work" \
      --flavor cli --forge github --target-model "$target_model" --force \
      --var EXPORTER_NAME=demo_exporter \
      --var NAMESPACE=demo \
      --var MODULE_PATH=example.com/demo_exporter \
      --var DATA_SOURCE=demo_cli \
      --var DATA_SOURCE_PATH=unused \
      --var DEFAULT_PORT=9999 \
      --var OWNER=acme \
      --var LICENSE=apache-2.0 \
      --var COLLECTOR_HEALTH_BY="$collector_health_by" \
      --var COLLECTOR_LOCATION="$collector_location"
    ;;
  *)
    die "no golden @@VAR@@ values wired for --flavor $flavor --forge $forge (only http+none, cli+none, http+github, cli+github are wired)"
    ;;
esac

# Forge matrix (Task 14): .github/ (the whole opt-out GitHub layer - workflows,
# dependabot.yml, CODEOWNERS, issue/PR templates) must exist if and only if
# --forge github was requested. Checked immediately after scaffolding, same
# reasoning as the grep-clean checks below: fail fast, before burning a full
# build+check cycle on a scaffold that already got the forge layer wrong.
echo "== .github/ presence matches --forge ($flavor/$forge) =="
if [ "$forge" = github ]; then
  [ -d "$work/.github/workflows" ] || die ".github/workflows/ missing after a --forge github scaffold ($flavor/$forge)"
  echo "confirmed: .github/workflows/ present ($flavor/$forge)"
else
  [ -d "$work/.github" ] && die ".github/ present after a --forge $forge scaffold - the GitHub layer should have been dropped ($flavor/$forge)"
  echo "confirmed: .github/ absent ($flavor/$forge)"
fi

# Configuration-layer presence (YAML config epic): internal/config/config.go
# and config.example.yml ship unconditionally, no --forge/--flavor gate, so
# this check is not nested in an if: every cell must have both. Checked here,
# same fail-fast-before-build reasoning as the forge check just above.
echo "== internal/config/ present ($flavor/$forge) =="
[ -f "$work/internal/config/config.go" ] || die "internal/config/config.go missing after scaffold ($flavor/$forge)"
[ -f "$work/config.example.yml" ] || die "config.example.yml missing after scaffold ($flavor/$forge)"
echo "confirmed: configuration layer present ($flavor/$forge)"

# git-init the scaffold (Task 14): a real /new-prometheus-exporter run leaves
# an actual repo behind, and by the time anyone runs `make check` on it,
# `git init` has happened - it is the single most basic step of "create a new
# project", well before a first commit or a remote. This was never load-
# bearing for any EARLIER golden combination (http-none, cli-none) because
# --forge none ships no .github/workflows/ at all, so actionlint/zizmor
# always took the Makefile's own "no .github/workflows found" skip path
# before either tool's own git-repository requirement could ever matter.
# http-github is the first combination that actually gives them real content
# to lint, and actionlint hard-requires running inside a git repository to
# even start ("no project was found in any parent directories") - found
# empirically running this exact combination while building this task, not
# a hypothetical. `-c init.defaultBranch=main` only pins the branch name Git
# reports for this throwaway repo (silences Git's own advice noise); nothing
# here reads it back.
echo "== git init ($flavor/$forge), matching a real post-scaffold repo =="
( cd "$work" && git -c init.defaultBranch=main init -q )

# Both grep-clean checks below run BEFORE any build, deliberately: `make
# build`/`make check` produce a compiled bin/@@EXPORTER_NAME@@ binary inside
# $work, and a `grep -r` sweep that runs AFTER that exists always degrades
# to a useless "binary file matches" hit with no visible content — hit
# empirically while developing this script (a real false positive, not a
# hypothetical). Checking scaffold-correctness immediately after
# scaffold.sh, before any build, avoids that noise entirely and also fails
# faster on a genuinely broken scaffold instead of burning a full build+check
# cycle first. `-I` on both (skip a match inside any binary file outright,
# rather than reporting a contentless "binary file matches" line) is kept as
# a second, independent layer of defense: the first check below scans the
# whole test/_work tree, which may still hold a stale bin/ from a PAST run
# of a different --flavor/--forge combination that this run's own `rm -rf
# "$work"` never touches.
#
# Hard gate: this plugin's taught knowledge stands on prometheus.io/Go
# authority, never on naming the reference project it was derived from —
# so that name must never leak into a generated exporter's own tree. `command
# grep`, not a bare `grep`, deliberately: some interactive shells alias/wrap
# grep in ways that mangle -r output (seen in the wild while building this
# plugin) — `command` bypasses any such wrapper.
#
# grep's exit status is 0 (match found — bad), 1 (no match — clean), or 2+
# (the scan itself failed, e.g. a bad path). Treating "not 0" as a blanket
# "clean", the way a plain `if grep ...; then` would, silently turns a
# failed scan into a false PASS — same three-way discipline scaffold.sh's
# own residual-sentinel guard applies, applied here too.
echo "== grep-clean: no source-project name / maintainer handle leaked under test/_work =="
grep_rc=0
hits=$(command grep -rinI -e slurm -e sckyzo "$root/test/_work" 2>&1) || grep_rc=$?
case "$grep_rc" in
  1) ;; # no match: clean
  0)
    echo "$prog: error: 'slurm' or 'sckyzo' found under test/_work (source-project / maintainer-handle leakage):" >&2
    echo "$hits" >&2
    exit 1
    ;;
  *) die "slurm/sckyzo grep scan of test/_work failed (grep exit $grep_rc): $hits" ;;
esac

# No @@VAR@@ sentinel may survive scaffolding, with the same narrow, named
# exception scaffold.sh's own internal residual-sentinel guard carries:
# main.go's structural markers, `// @@CLIENT_INIT@@`, `// @@CLIENT_BUILD@@`
# and `// @@COLLECTOR_REGISTRY@@` (single-target), `// @@PROBE_FACTORIES@@`
# (multi-target), `// @@INSTANCE_FACTORIES@@` (multi-instance, Task 12), are
# deliberately left in place forever (for /add-collector to find and reuse
# later), not data placeholders that a --var should have filled, so
# asserting a bare `@@[A-Z_]*@@` with no exception here would make this
# check fail on every single green run.
echo "== no residual @@VAR@@ sentinels in ${work#"$root"/} =="
grep_rc=0
hits=$(command grep -rnI '@@[A-Z_]*@@' "$work" 2>&1) || grep_rc=$?
case "$grep_rc" in
  1) ;; # no match: clean
  0)
    filtered=$(printf '%s\n' "$hits" | grep -v -E '@@(CLIENT_INIT|CLIENT_BUILD|COLLECTOR_REGISTRY|PROBE_FACTORIES|INSTANCE_FACTORIES)@@') || true
    if [ -n "$filtered" ]; then
      echo "$prog: error: residual @@VAR@@ sentinel(s) left in $work:" >&2
      echo "$filtered" >&2
      exit 1
    fi
    ;;
  *) die "residual-sentinel scan of $work failed (grep exit $grep_rc): $hits" ;;
esac

# Task 1 (tranche A hardening): no `master`-branch assumption may survive
# scaffolding. release-process.md.tmpl used to hardcode `git checkout
# master` / `gh pr create --base master`, which silently breaks the
# playbook for any repo whose default branch is `main` (GitHub's default
# since 2020, and this plugin's own `git -c init.defaultBranch=main init`
# above). Same three-way grep exit-code discipline as the residual-@@VAR@@
# check above: 0 = match found (bad), 1 = no match (clean), 2+ = the scan
# itself failed — never treat "not 0" as a blanket pass.
echo "== no master-branch assumption in generated docs/release-process.md ($flavor/$forge) =="
release_doc="$work/docs/release-process.md"
[ -f "$release_doc" ] || die "docs/release-process.md missing after scaffold — cannot check for a master-branch assumption ($flavor/$forge)"
grep_rc=0
hits=$(command grep -nE 'git checkout master|--base master' "$release_doc" 2>&1) || grep_rc=$?
case "$grep_rc" in
  1) ;; # no match: clean
  0)
    echo "$prog: error: master-branch assumption left in $release_doc:" >&2
    echo "$hits" >&2
    exit 1
    ;;
  *) die "master-branch scan of $release_doc failed (grep exit $grep_rc): $hits" ;;
esac

# samples/ holds raw target output and the target's own API documentation.
# It must survive a clone (so its README is tracked) while its contents never
# reach git (they are not anonymized and may carry hostnames, tenants,
# credentials, or third-party documentation). Both halves are asserted:
# a directory that is fully ignored would not exist after a clone, and a
# directory that is fully tracked would leak.
echo "== samples/ survives a clone, its contents do not ($flavor/$forge) =="
[ -d "$work/samples" ] || die "samples/ missing after scaffold ($flavor/$forge)"
[ -f "$work/samples/README.md" ] || die "samples/README.md missing after scaffold ($flavor/$forge)"
if git -C "$work" check-ignore -q samples/README.md; then
  die "samples/README.md is gitignored; samples/ would not survive a clone ($flavor/$forge)"
fi
printf '{"gate": 1}\n' > "$work/samples/_gate-probe.json"
git -C "$work" check-ignore -q samples/_gate-probe.json \
  || die "a file dropped in samples/ is NOT gitignored ($flavor/$forge)"
rm -f "$work/samples/_gate-probe.json"

# CLAUDE.md states this repository's invariants. The generic no-residual-
# sentinel scan would catch an entirely unsubstituted @@TARGET_MODEL@@, but
# not a template that hardcodes "single" in every cell, which is the failure
# this assertion exists for.
echo "== CLAUDE.md states this cell's real target model and flavor ($flavor/$forge) =="
claude_md="$work/CLAUDE.md"
[ -f "$claude_md" ] || die "CLAUDE.md missing after scaffold ($flavor/$forge)"
grep -q "^| Target model | \`$target_model\` |$" "$claude_md" \
  || die "CLAUDE.md does not state target model '$target_model' ($flavor/$forge): $(grep -n 'Target model' "$claude_md" 2>/dev/null || echo '<no Target model row>')"
grep -q "^| I/O flavor | \`$flavor\` |$" "$claude_md" \
  || die "CLAUDE.md does not state I/O flavor '$flavor' ($flavor/$forge): $(grep -n 'I/O flavor' "$claude_md" 2>/dev/null || echo '<no I/O flavor row>')"

# The README carries a generated collector list between two markers.
# /add-collector regenerates everything between them from docs/metrics.md.
# Assert the markers exist exactly once each, in the right order, and that
# the block is not empty on a fresh scaffold.
echo "== README carries the generated-collectors markers, paired and ordered ($flavor/$forge) =="
readme="$work/README.md"
[ -f "$readme" ] || die "README.md missing after scaffold ($flavor/$forge)"
n_begin=$(grep -c '^<!-- BEGIN GENERATED COLLECTORS -->$' "$readme" || true)
n_end=$(grep -c '^<!-- END GENERATED COLLECTORS -->$' "$readme" || true)
[ "$n_begin" = 1 ] || die "expected exactly 1 BEGIN GENERATED COLLECTORS marker in README.md, found $n_begin ($flavor/$forge)"
[ "$n_end" = 1 ] || die "expected exactly 1 END GENERATED COLLECTORS marker in README.md, found $n_end ($flavor/$forge)"
l_begin=$(grep -n '^<!-- BEGIN GENERATED COLLECTORS -->$' "$readme" | cut -d: -f1)
l_end=$(grep -n '^<!-- END GENERATED COLLECTORS -->$' "$readme" | cut -d: -f1)
[ "$l_begin" -lt "$l_end" ] || die "README.md collector markers out of order (BEGIN line $l_begin, END line $l_end) ($flavor/$forge)"
grep -q '^- \[`example`\](docs/metrics.md#examplecollector)$' "$readme" \
  || die "README.md generated block does not list the bundled example collector ($flavor/$forge)"

# .github/workflows/dev-release.yml only exists for --forge github (asserted
# above); when present, its push trigger must include `main` so a freshly
# scaffolded repo using the modern default branch name still gets a dev
# release built on every push. Guarded on the file's own existence (rather
# than re-testing --forge) so a --forge none cell, which never creates this
# file, skips cleanly instead of failing on a file that was never supposed
# to exist.
echo "== dev-release.yml triggers on main, when present ($flavor/$forge) =="
dev_release_wf="$work/.github/workflows/dev-release.yml"
if [ -f "$dev_release_wf" ]; then
  grep -q 'main' "$dev_release_wf" || die "dev-release.yml does not trigger on main ($flavor/$forge)"
  echo "confirmed: dev-release.yml triggers on main ($flavor/$forge)"
else
  echo "SKIPPING dev-release.yml main-trigger check ($flavor/$forge): no .github/workflows/dev-release.yml (forge=none)"
fi

echo "== make build ($flavor/$forge) =="
if ! ( cd "$work" && make build ); then
  die "make build FAILED for $flavor/$forge — see output above"
fi

echo "== make check ($flavor/$forge) =="
if ! ( cd "$work" && make check ); then
  die "make check FAILED for $flavor/$forge — see output above"
fi

# config.example.yml must LOAD, not merely exist. It is the file
# docs/configuration.md tells the operator to copy and run, and it ships
# unchanged across every flavor and target model, so an entry naming a flag
# only one of them declares makes it exit 1 out of the box. That is exactly
# what happened once: collector.example.timeout does not exist on a
# multi-target binary, and the existence check above could not see it.
# --help is enough: --config.file is read and validated before kingpin gets
# its arguments, so a bad file fails here without binding a port.
echo "== config.example.yml loads ($flavor/$forge) =="
if ! ( cd "$work" && ./bin/demo_exporter --config.file=config.example.yml --help >/dev/null 2>&1 ); then
  ( cd "$work" && ./bin/demo_exporter --config.file=config.example.yml --help >/dev/null ) || true
  die "config.example.yml FAILED to load for $flavor/$forge; the shipped example must work on every cell"
fi
echo "confirmed: config.example.yml loads ($flavor/$forge)"

# --exporter.max-requests-per-target's boot-time guard (Task 10, obligation
# 1): --collector.example.timeout=0s combined with a configured ceiling must
# refuse to boot, naming the collector, rather than silently building a
# Client whose limiter wait is unbounded. http-only and single-only: this
# guard lives in the http flavor's client_build.frag, and only the single
# target model builds a Client from --collector.<name>.timeout this way (cli
# needs no equivalent guard: exampleData's context.WithTimeout(ctx, 0)
# already bounds the wait instead of leaving it unbounded, and multi/
# multi-instance never reach this flag combination the same way). Neither
# make build nor make docs-check can catch a regression here: this is a
# runtime refusal, not a compile-time or source-scan property.
#
# Run under `timeout`, on an explicit loopback port, unlike a live-server
# check elsewhere in this script: this is a negative test (the process is
# expected to exit almost immediately, not become ready), so there is no
# /healthz to poll. If this guard ever regresses, the process does not exit
# at all: os.Exit(1) at // @@CLIENT_BUILD@@ is what would normally fire well
# before web.ListenAndServe runs, so a regression here means the binary goes
# on to bind a port and serve forever, exactly the "hangs the harness on
# regression instead of failing it" defect this shape fixes. `-k 2` escalates
# to SIGKILL 2s after the initial TERM, in case a stuck process ignores it;
# without --preserve-status, GNU timeout always reports 124 on an actual
# timeout, regardless of how the underlying process responds to the signal,
# which is what lets rc=124 below be read unambiguously as "did not refuse".
if [ "$flavor" = http ] && [ "$target_model" = single ]; then
  echo "== --exporter.max-requests-per-target boot-time guard ($flavor/$forge) =="
  refuse_log="$work/.golden-smoke-max-requests-refusal.log"
  refuse_port=9989
  # This script runs under `set -eu`: the correct-refusal outcome exits
  # non-zero (1) by design, so the subshell must be on the LEFT of `||`, not
  # a bare statement, or `set -e` would abort the whole harness right here on
  # the very PASS path this guard exists to confirm. refuse_rc=0 first, then
  # `||` only overwrites it with the subshell's real exit status when that
  # subshell itself is non-zero; `$?` inside the `||` arm still refers to the
  # command that just failed, not to the assignment.
  refuse_rc=0
  ( cd "$work" && timeout -k 2 5 ./bin/demo_exporter --collector.example.timeout=0s --exporter.max-requests-per-target=1 --web.listen-address="127.0.0.1:$refuse_port" >"$refuse_log" 2>&1 ) || refuse_rc=$?
  if [ "$refuse_rc" -eq 124 ]; then
    die "boot-time guard: exporter did NOT refuse to boot within 5s with --collector.example.timeout=0s and a configured ceiling (it kept running and had to be killed) ($flavor/$forge), see $refuse_log"
  fi
  if [ "$refuse_rc" -eq 0 ]; then
    die "boot-time guard: exporter exited 0 instead of refusing --collector.example.timeout=0s under a configured ceiling ($flavor/$forge), see $refuse_log"
  fi
  grep -q 'a positive --collector.example.timeout is required' "$refuse_log" \
    || die "boot-time guard: refusal message does not name the collector/timeout as expected ($flavor/$forge), see $refuse_log"
  echo "confirmed: --collector.example.timeout=0s with a configured ceiling refuses to boot, naming the collector ($flavor/$forge)"
fi

# promtool check rules (Task 12): monitoring/prometheus/{alerts,rules}.yml must
# be valid Prometheus rule files — the same anti-lie bar as docs-check, just
# for PromQL instead of Go source. promtool itself is not in the tools image
# (scripts/docker/tools/Dockerfile has no use for it outside this one check),
# so this step degrades through three tiers instead of hard-failing when
# nothing is available: native promtool, then docker, then podman, each
# running the official `prom/prometheus` image's own promtool. If none of
# the three exist, log an explicit SKIP and move on — silently saying nothing
# here would be indistinguishable from "checked and clean", exactly the kind
# of false confidence this whole script exists to prevent.
echo "== promtool check rules ($flavor/$forge) =="
if command -v promtool >/dev/null 2>&1; then
  echo "using native promtool"
  if ! ( cd "$work" && promtool check rules monitoring/prometheus/rules.yml monitoring/prometheus/alerts.yml ); then
    die "promtool check rules FAILED for $flavor/$forge — see output above"
  fi
  echo "confirmed: promtool check rules PASSED ($flavor/$forge)"
elif command -v docker >/dev/null 2>&1; then
  echo "no native promtool; using docker run prom/prometheus:latest"
  if ! docker run --rm -v "$work:/rules" -w /rules --entrypoint promtool prom/prometheus:latest \
       check rules monitoring/prometheus/rules.yml monitoring/prometheus/alerts.yml; then
    die "promtool check rules FAILED (via docker) for $flavor/$forge — see output above"
  fi
  echo "confirmed: promtool check rules PASSED via docker ($flavor/$forge)"
elif command -v podman >/dev/null 2>&1; then
  echo "no native promtool and no docker; using podman run prom/prometheus:latest"
  if ! podman run --rm -v "$work:/rules:Z" -w /rules --entrypoint promtool prom/prometheus:latest \
       check rules monitoring/prometheus/rules.yml monitoring/prometheus/alerts.yml; then
    die "promtool check rules FAILED (via podman) for $flavor/$forge — see output above"
  fi
  echo "confirmed: promtool check rules PASSED via podman ($flavor/$forge)"
else
  echo "SKIPPING promtool check rules ($flavor/$forge): no native promtool and no docker/podman container engine found — install one to validate monitoring/prometheus/*.yml locally"
fi

# http-multi live-probe check (Task 2, multi-target epic): a scaffolded
# multi-target exporter must actually SERVE /probe, not just build and pass
# its own unit tests. Starts the just-built binary, probes its OWN /metrics
# endpoint as a live http:// target (self-contained — no external dependency
# or network access needed), and confirms the response is a valid
# OpenMetrics/Prometheus exposition carrying probe_success/probe_duration_seconds.
# Only runs for target_model=multi; single-target scaffolds have no /probe
# route at all (asserted separately, right after scaffolding, above).
#
# trap ... EXIT here is this script's only background process, so installing
# it is safe: no earlier step in this file left one behind to clobber, and it
# guarantees the server is killed even if a later `die`/set -eu exit fires
# mid-check, rather than leaking an orphaned listener on $probe_port.
if [ "$target_model" = multi ]; then
  echo "== http-multi: starting the scaffolded binary to exercise /probe live ($flavor/$forge) =="
  bin="$work/bin/demo_exporter"
  [ -x "$bin" ] || die "http-multi: $bin missing or not executable after make build ($flavor/$forge)"

  probe_port=9999
  probe_log="$work/.golden-smoke-server.log"
  "$bin" --web.listen-address="127.0.0.1:$probe_port" --log.level=info >"$probe_log" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT

  # Poll /healthz until the server actually accepts connections. Bounded
  # (15 x 1s = 15s ceiling) so a broken startup fails fast instead of hanging
  # this script forever; integer `sleep` only (no fractional seconds), same
  # POSIX-utilities discipline as scaffold.sh's own header comment.
  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$probe_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi: server process exited before becoming ready — see $probe_log ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi: server did not become ready on 127.0.0.1:$probe_port within 15s — see $probe_log ($flavor/$forge)"
  echo "confirmed: server ready on 127.0.0.1:$probe_port ($flavor/$forge)"

  probe_out="$work/.golden-smoke-probe-output.txt"
  if ! curl -fsS "http://127.0.0.1:$probe_port/probe?target=http://127.0.0.1:$probe_port/metrics" -o "$probe_out"; then
    die "http-multi: curl /probe?target=... FAILED ($flavor/$forge) — see $probe_log"
  fi
  echo "confirmed: /probe?target=http://127.0.0.1:$probe_port/metrics returned a response ($flavor/$forge)"

  grep -q '^probe_success ' "$probe_out" || die "http-multi: /probe response is missing probe_success ($flavor/$forge)"
  grep -q '^probe_duration_seconds ' "$probe_out" || die "http-multi: /probe response is missing probe_duration_seconds ($flavor/$forge)"
  echo "confirmed: /probe response carries probe_success and probe_duration_seconds ($flavor/$forge)"

  echo "== http-multi: promtool check metrics on the /probe response ($flavor/$forge) =="
  if command -v promtool >/dev/null 2>&1; then
    echo "using native promtool"
    if ! promtool check metrics < "$probe_out"; then
      die "http-multi: promtool check metrics FAILED for the /probe response ($flavor/$forge)"
    fi
    echo "confirmed: promtool check metrics PASSED ($flavor/$forge)"
  elif command -v docker >/dev/null 2>&1; then
    echo "no native promtool; using docker run prom/prometheus:latest"
    if ! docker run --rm -i --entrypoint promtool prom/prometheus:latest check metrics < "$probe_out"; then
      die "http-multi: promtool check metrics FAILED (via docker) for the /probe response ($flavor/$forge)"
    fi
    echo "confirmed: promtool check metrics PASSED via docker ($flavor/$forge)"
  elif command -v podman >/dev/null 2>&1; then
    echo "no native promtool and no docker; using podman run prom/prometheus:latest"
    if ! podman run --rm -i --entrypoint promtool prom/prometheus:latest check metrics < "$probe_out"; then
      die "http-multi: promtool check metrics FAILED (via podman) for the /probe response ($flavor/$forge)"
    fi
    echo "confirmed: promtool check metrics PASSED via podman ($flavor/$forge)"
  else
    echo "SKIPPING promtool check metrics ($flavor/$forge): no native promtool and no docker/podman container engine found — install one to validate the /probe response locally"
  fi

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT
  echo "confirmed: http-multi live-probe check PASSED ($flavor/$forge)"
fi

# http-multi modules sub-check (volet A): a scaffolded multi-target exporter
# must boot with a modules: section, serve a probe that names one, and refuse
# the two ambiguous cases with a 400. It probes its OWN /metrics as the
# target, so no authenticated backend exists here: this proves the boot, the
# refusals and the status codes, NOT authentication end to end. That claim is
# carried by internal/probe's Go tests and by nothing else.
#
# Same trap discipline as the live-probe block above: that block killed its
# server and ran `trap - EXIT` before returning, so nothing is installed here.
if [ "$target_model" = multi ]; then
  echo "== http-multi: modules: section sub-check ($flavor/$forge) =="
  bin="$work/bin/demo_exporter"
  [ -x "$bin" ] || die "http-multi modules: $bin missing or not executable after make build ($flavor/$forge)"

  mods_config="$work/.golden-smoke-modules-config.yml"
  cat > "$mods_config" <<'EOF'
modules:
  default:
    http_client_config:
      basic_auth: { username: monitor, password: hunter2 }
  other:
    http_client_config:
      basic_auth: { username: other, password: sesame }
  onlyexample:
    collectors: [example]
EOF

  # Rule 9: modules: alongside a top-level http_client_config: must fail the
  # boot rather than silently ignore one of them. This refusal lives in
  # ResolveModules, which the design spec's own step order (kingpin.MustParse
  # is step 3, ResolveModules is step 5, see the multi-target-module-
  # credentials design doc) places AFTER kingpin parses. That means --help
  # exits before ever reaching it and returns 0 regardless of this conflict,
  # confirmed empirically while writing this check: --help against this exact
  # config exits 0 while a real start exits 1. So this starts the process for
  # real too.
  #
  # If this refusal is ever silently removed, main() proceeds past
  # ResolveModules and blocks forever in web.ListenAndServe on
  # 127.0.0.1:9998 instead of exiting. A plain foreground
  # `if "$bin" ...; then die; fi` would hang right here instead of catching
  # that regression, so this backgrounds the process and bounds the wait to
  # 10s, the same idiom the live-probe block above uses: still running after
  # 10s means the boot did NOT refuse (the regression this check exists to
  # catch), a non-zero exit means the refusal fired (the pass).
  both_config="$work/.golden-smoke-modules-both.yml"
  cat > "$both_config" <<'EOF'
http_client_config:
  basic_auth: { username: monitor, password: hunter2 }
modules:
  prod:
    http_client_config:
      basic_auth: { username: prod, password: hunter2 }
EOF
  "$bin" --config.file="$both_config" --web.listen-address=127.0.0.1:9998 >/dev/null 2>&1 &
  refusal_pid=$!
  i=0
  while [ "$i" -lt 10 ]; do
    kill -0 "$refusal_pid" 2>/dev/null || break
    i=$((i + 1))
    sleep 1
  done
  if kill -0 "$refusal_pid" 2>/dev/null; then
    kill "$refusal_pid" >/dev/null 2>&1 || true
    wait "$refusal_pid" 2>/dev/null || true
    die "http-multi modules: a modules: section alongside a top-level http_client_config: did not fail the boot within 10s; the refusal did not fire and the process is serving ($flavor/$forge)"
  fi
  if wait "$refusal_pid"; then
    die "http-multi modules: a modules: section alongside a top-level http_client_config: was accepted ($flavor/$forge)"
  fi
  echo "confirmed: modules: plus a top-level http_client_config: is refused ($flavor/$forge)"

  mods_port=9999
  mods_log="$work/.golden-smoke-server-modules.log"
  "$bin" --config.file="$mods_config" --web.listen-address="127.0.0.1:$mods_port" --log.level=info >"$mods_log" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$mods_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi modules: server exited before becoming ready, see $mods_log ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi modules: server did not become ready on 127.0.0.1:$mods_port within 15s, see $mods_log ($flavor/$forge)"
  echo "confirmed: server ready with a 3-module configuration ($flavor/$forge)"

  mods_target="http://127.0.0.1:$mods_port/metrics"
  probe_code() {
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$mods_port/probe?target=$mods_target&module=$1"
  }

  code=$(probe_code default)
  [ "$code" = 200 ] || die "http-multi modules: ?module=default returned $code, want 200 ($flavor/$forge)"

  # Rule 2 step 2: a module that carries only a collector subset falls back to
  # the default module's credentials rather than probing in the clear.
  code=$(probe_code onlyexample)
  [ "$code" = 200 ] || die "http-multi modules: ?module=onlyexample returned $code, want 200 ($flavor/$forge)"

  # Rule 3: two credential-bearing modules in one request is ambiguous.
  code=$(probe_code default,other)
  [ "$code" = 400 ] || die "http-multi modules: ?module=default,other returned $code, want 400 ($flavor/$forge)"

  echo "confirmed: module selection serves 200 and refuses an ambiguous credential pair with 400 ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT
  echo "confirmed: http-multi modules sub-check PASSED ($flavor/$forge)"
fi

# http-multi reload sub-check (Task 14, config-reload-and-concurrency epic):
# the four reload assertions this epic exists to prove. Two server
# lifecycles on the SAME port: first WITHOUT --web.enable-lifecycle
# (assertion 1, the closed default), then a fresh restart WITH it
# (assertions 2-4, all against that one running process, so the gauge and
# the module table carry state across them the way a real operator's
# sequence would). Every launch is backgrounded behind an explicit
# --web.listen-address plus the same bounded 15x1s ready-wait loop used
# throughout this script (see the boot-time-guard block above and this
# task's own brief): a hung foreground launch here would eat the CI job
# timeout instead of failing loudly, and has done exactly that once before
# in this file's history.
#
# Assertions 2 and 3 deliberately CHANGE the file's content between reloads
# (a module added, then a file that no longer parses at all) rather than
# re-POSTing the unchanged file: reloading an unchanged file is a
# documented no-op in internal/reload (Task 9's own hard-won lesson, cited
# in this task's brief) that never calls apply, so an assertion built on
# one would stay green even against a broken reload implementation.
if [ "$target_model" = multi ]; then
  echo "== http-multi: reload sub-check ($flavor/$forge) =="
  bin="$work/bin/demo_exporter"
  [ -x "$bin" ] || die "http-multi reload: $bin missing or not executable after make build ($flavor/$forge)"

  reload_port=9999
  reload_cfg="$work/.golden-smoke-reload-config.yml"
  reload_body="$work/.golden-smoke-reload-body.txt"
  reload_metrics="$work/.golden-smoke-reload-metrics.txt"
  cat > "$reload_cfg" <<'EOF'
modules:
  default:
    http_client_config:
      basic_auth: { username: monitor, password: hunter2 }
EOF

  reload_post() {
    curl -s -o "$reload_body" -w '%{http_code}' -X POST "http://127.0.0.1:$reload_port/-/reload"
  }
  reload_probe_code() {
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$reload_port/probe?target=http://127.0.0.1:$reload_port/metrics&module=$1"
  }
  # Shared by both the EXIT trap below (so a die() anywhere in this block
  # still cleans up) and this block's own normal-completion path: see the
  # comment on the final cleanup call for why this specifically matters
  # for assertions 3 and 3b, which make the exporter log its own absolute
  # --config.file path.
  reload_cleanup() {
    rm -f "$reload_log1" "$reload_log2" "$reload_cfg" "$reload_body" "$reload_metrics"
  }
  # Declared empty here, before it is ever assigned (right before the
  # restart, below): reload_cleanup and the first trap installation both
  # reference it, and this script runs under `set -u`, so it must exist as
  # at least an empty string before assertion 1's trap could ever fire.
  reload_log2=""

  # Assertion 0 (final fix wave, this same epic): a multi build started with
  # NO --config.file must treat SIGHUP as a no-op SUCCESS, not a failure.
  # --config.file defaults to "" on multi (the documented allow-any starting
  # posture, see docs/configuration.md), so before this fix a SIGHUP
  # delivered there fell into reloadOnce's fail() path and pinned
  # demo_exporter_config_last_reload_successful at 0 forever: nothing ever
  # runs a second reload to clear it, so ConfigReloadFailed fires 5m later on
  # an otherwise perfectly healthy exporter. Own port and own trap, entirely
  # separate from assertions 1-4 below, so this process's lifetime (which
  # never sees --config.file at all) never overlaps theirs.
  noconfig_port=9997
  noconfig_log="$work/.golden-smoke-reload-noconfig.log"
  "$bin" --web.listen-address="127.0.0.1:$noconfig_port" --log.level=info >"$noconfig_log" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true; rm -f "$noconfig_log"' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$noconfig_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi reload: server exited before becoming ready (assertion 0, no --config.file), see $noconfig_log ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi reload: server did not become ready within 15s (assertion 0, no --config.file) ($flavor/$forge)"

  # Confirm the gauge starts at 1 (Run sets it before serving even the first
  # scrape) before SIGHUP ever fires, so a later read of "1" cannot be
  # mistaken for "never checked" instead of "never moved".
  curl -fsS "http://127.0.0.1:$noconfig_port/metrics" -o "$reload_metrics" \
    || die "http-multi reload: assertion 0 curl /metrics (pre-SIGHUP) FAILED ($flavor/$forge)"
  command grep -q '^demo_exporter_config_last_reload_successful 1$' "$reload_metrics" \
    || die "http-multi reload: assertion 0 gauge is not 1 before SIGHUP ($flavor/$forge)"

  kill -HUP "$server_pid" || die "http-multi reload: sending SIGHUP to a --config.file-less process failed ($flavor/$forge)"
  # No synchronous signal from the process itself once SIGHUP is sent: give
  # reloadOnce a moment to run, then poll like every other wait in this file.
  sleep 1
  kill -0 "$server_pid" 2>/dev/null \
    || die "http-multi reload: process exited after SIGHUP with no --config.file; SIGHUP must be a no-op there, not fatal ($flavor/$forge)"
  curl -fsS "http://127.0.0.1:$noconfig_port/metrics" -o "$reload_metrics" \
    || die "http-multi reload: assertion 0 curl /metrics (post-SIGHUP) FAILED ($flavor/$forge)"
  command grep -q '^demo_exporter_config_last_reload_successful 1$' "$reload_metrics" \
    || die "http-multi reload: assertion 0 - SIGHUP with no --config.file moved the gauge away from 1; a --config.file-less exporter must never trip ConfigReloadFailed ($flavor/$forge)"
  echo "confirmed: assertion 0 - SIGHUP with no --config.file is a no-op success, gauge stays at 1 ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  rm -f "$noconfig_log"
  trap - EXIT

  # Assertion 1: no --web.enable-lifecycle -> POST /-/reload is a plain 404,
  # the closed default (the same answer as any other unknown path, not a
  # 405 or a 401 from a route that exists but refuses).
  reload_log1="$work/.golden-smoke-reload-server-1.log"
  "$bin" --config.file="$reload_cfg" --web.listen-address="127.0.0.1:$reload_port" --log.level=info >"$reload_log1" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true; reload_cleanup' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$reload_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi reload: server exited before becoming ready (assertion 1), see $reload_log1 ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi reload: server did not become ready within 15s (assertion 1) ($flavor/$forge)"

  code=$(reload_post)
  [ "$code" = 404 ] || die "http-multi reload: POST /-/reload without --web.enable-lifecycle returned $code, want 404 ($flavor/$forge)"
  echo "confirmed: assertion 1 - POST /-/reload without --web.enable-lifecycle is 404 ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT

  # Restart WITH --web.enable-lifecycle. One process now carries assertions
  # 2, 3, 3b and 4 in sequence.
  reload_log2="$work/.golden-smoke-reload-server-2.log"
  "$bin" --config.file="$reload_cfg" --web.enable-lifecycle --web.listen-address="127.0.0.1:$reload_port" --log.level=info >"$reload_log2" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true; reload_cleanup' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$reload_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi reload: server exited before becoming ready (restart with --web.enable-lifecycle), see $reload_log2 ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi reload: server did not become ready within 15s after restart with --web.enable-lifecycle ($flavor/$forge)"

  # Assertion 2: add a module ("staging") the boot file never declared,
  # reload, and confirm the new module is actually USABLE afterwards
  # (a live /probe?module=staging), not merely that the reload answered.
  cat > "$reload_cfg" <<'EOF'
modules:
  default:
    http_client_config:
      basic_auth: { username: monitor, password: hunter2 }
  staging:
    http_client_config:
      basic_auth: { username: staging, password: hunter3 }
EOF
  code=$(reload_post)
  [ "$code" = 200 ] || die "http-multi reload: assertion 2 (add module) POST /-/reload returned $code, want 200 ($flavor/$forge), body: $(cat "$reload_body")"
  curl -fsS "http://127.0.0.1:$reload_port/metrics" -o "$reload_metrics" \
    || die "http-multi reload: assertion 2 curl /metrics FAILED ($flavor/$forge)"
  command grep -q '^demo_exporter_config_last_reload_successful 1$' "$reload_metrics" \
    || die "http-multi reload: assertion 2 did not leave demo_exporter_config_last_reload_successful at 1 ($flavor/$forge)"
  code=$(reload_probe_code staging)
  [ "$code" = 200 ] || die "http-multi reload: assertion 2's new module 'staging' is not usable after reload, /probe?module=staging returned $code ($flavor/$forge)"
  echo "confirmed: assertion 2 - adding a module and reloading returns 200, sets the gauge to 1, and the new module probes 200 ($flavor/$forge)"

  # Assertion 3: a file that does not parse at all. This is the atomicity
  # proof at the PARSE layer: the PREVIOUS module table (both "default"
  # and the "staging" module assertion 2 just added) must still be
  # SERVED, not just the process still being up.
  printf 'modules:\n  broken: [this is not valid yaml\n' > "$reload_cfg"
  code=$(reload_post)
  [ "$code" = 500 ] || die "http-multi reload: assertion 3 (broken file) POST /-/reload returned $code, want 500 ($flavor/$forge)"
  curl -fsS "http://127.0.0.1:$reload_port/metrics" -o "$reload_metrics" \
    || die "http-multi reload: assertion 3 curl /metrics FAILED ($flavor/$forge)"
  command grep -q '^demo_exporter_config_last_reload_successful 0$' "$reload_metrics" \
    || die "http-multi reload: assertion 3 did not drive demo_exporter_config_last_reload_successful to 0 ($flavor/$forge)"
  code=$(reload_probe_code default)
  [ "$code" = 200 ] || die "http-multi reload: assertion 3's PREVIOUS module 'default' stopped being served after a broken reload ($code) ($flavor/$forge)"
  code=$(reload_probe_code staging)
  [ "$code" = 200 ] || die "http-multi reload: assertion 3's PREVIOUS module 'staging' stopped being served after a broken reload ($code) ($flavor/$forge)"
  echo "confirmed: assertion 3 - a broken file is refused with 500, the gauge drops to 0, and the previous modules (default, staging) are still served ($flavor/$forge)"

  # Assertion 3b: the SAME atomicity property, but at a DIFFERENT layer.
  # Assertion 3's file fails to PARSE, so internal/reload's reloadOnce
  # returns on config.Load's own error before apply is ever entered (see
  # reload.go.tmpl) - it can never see a commit-before-validate bug INSIDE
  # apply, which is where the design's prepare-then-commit property
  # actually lives. This file is valid YAML that fails one layer deeper,
  # inside buildModules's own ValidateModules call (an unknown collector
  # name), which DOES run inside apply, after the candidate module map is
  # built but before probeHandler.SetConfig ever commits it. Confirmed by
  # mutation: a real commit-before-validate bug in the apply closure keeps
  # assertion 3 green (config.Load never reaches it) but turns this one
  # red (see this task's report for the reproduction).
  cat > "$reload_cfg" <<'EOF'
modules:
  bogus:
    collectors: [nosuchcollector]
EOF
  code=$(reload_post)
  [ "$code" = 500 ] || die "http-multi reload: assertion 3b (prepare-stage failure) POST /-/reload returned $code, want 500 ($flavor/$forge)"
  curl -fsS "http://127.0.0.1:$reload_port/metrics" -o "$reload_metrics" \
    || die "http-multi reload: assertion 3b curl /metrics FAILED ($flavor/$forge)"
  command grep -q '^demo_exporter_config_last_reload_successful 0$' "$reload_metrics" \
    || die "http-multi reload: assertion 3b did not drive demo_exporter_config_last_reload_successful to 0 ($flavor/$forge)"
  code=$(reload_probe_code default)
  [ "$code" = 200 ] || die "http-multi reload: assertion 3b's PREVIOUS module 'default' stopped being served after a prepare-stage-failing reload ($code) ($flavor/$forge)"
  code=$(reload_probe_code staging)
  [ "$code" = 200 ] || die "http-multi reload: assertion 3b's PREVIOUS module 'staging' stopped being served after a prepare-stage-failing reload ($code) ($flavor/$forge)"
  echo "confirmed: assertion 3b - a file that fails inside the prepare phase, not just parsing, is refused with 500, the gauge drops to 0, and the previous modules (default, staging) are still served ($flavor/$forge)"

  # Assertion 4: a "flags:" section the boot file never had. Refused whole,
  # naming the offending key, rather than applying the modules: half and
  # leaving the process describing neither file.
  cat > "$reload_cfg" <<'EOF'
flags:
  log.level: debug
modules:
  default:
    http_client_config:
      basic_auth: { username: monitor, password: hunter2 }
  staging:
    http_client_config:
      basic_auth: { username: staging, password: hunter3 }
EOF
  code=$(reload_post)
  [ "$code" = 500 ] || die "http-multi reload: assertion 4 (flags: change) POST /-/reload returned $code, want 500 ($flavor/$forge)"
  command grep -qF 'log.level' "$reload_body" \
    || die "http-multi reload: assertion 4's refusal message does not name the changed flags key 'log.level' ($flavor/$forge): $(cat "$reload_body")"
  echo "confirmed: assertion 4 - a flags: section change is refused with 500, naming the key ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true

  # Assertions 3 and 3b deliberately feed the exporter a file that fails,
  # and both resulting error messages name that file by its ABSOLUTE path
  # (see internal/config's config.Load: `fmt.Errorf("parse %s: %w", path,
  # err)`, and buildModules's own wrapped errors). That path is $work's,
  # rooted at this repository's own checkout location, which on a
  # maintainer's own machine can itself contain the maintainer's handle
  # (this repository's own top-level directory does). Left behind,
  # $reload_log2 would carry that string into test/_work, where the NEXT
  # matrix cell's own grep-clean sweep scans the WHOLE tree, not just its
  # own work dir, by design (see that check's own comment on catching a
  # stale file from a PAST run) - and would misreport a leaked maintainer
  # handle that was never in any shipped template, only in this test's own
  # scratch output. reload_cleanup runs here on the normal-completion path,
  # AND, via the trap it is also armed under above, on any die() inside
  # this block: a die() bypasses the rest of this normal-completion code
  # entirely, so relying on this call alone would leave the scratch files
  # behind on exactly the failure path this cleanup exists for.
  reload_cleanup
  trap - EXIT
  echo "confirmed: http-multi reload sub-check PASSED ($flavor/$forge)"
fi

# http-multi-instance live check (Task 12, multi-instance target model): a
# scaffolded multi-instance exporter must actually SERVE every configured
# instance's health series on /metrics, not just build and pass its own unit
# tests. --config.file is REQUIRED for this model: main.go refuses to start
# without one (see internal/config's own doc comment), so this writes a
# minimal one listing two instances at deliberately UNREACHABLE local
# addresses (127.0.0.1:1; nothing ever listens there). The background
# pollers for both instances fail to reach their target, but that failure is
# fail-open by design (see internal/collector/collector.go's background-
# refresh Collect doc comment: the freshness gauge is ALWAYS sent, even
# before any refresh has completed), so StatusTracker still counts at least
# one emitted metric per instance per scrape and reports
# demo_exporter_collector_success{collector="example",target="<name>"} 1,
# on the very FIRST scrape, immediately after boot, with no need for the
# unreachable backends to ever answer. Proving that is the whole point of
# this check: an operator's exporter must not go dark just because one of
# its watched machines is unreachable.
#
# Only runs for target_model=multi-instance; single/multi scaffolds have no
# --config.file requirement and no per-instance "target" label at all.
#
# trap ... EXIT here mirrors the http-multi block above exactly: this is a
# separate cell invocation (a fresh process, see the --all dispatch above),
# so there is no earlier background process in THIS run to clobber.
if [ "$target_model" = multi-instance ]; then
  echo "== http-multi-instance: starting the scaffolded binary against two unreachable instances ($flavor/$forge) =="
  bin="$work/bin/demo_exporter"
  [ -x "$bin" ] || die "http-multi-instance: $bin missing or not executable after make build ($flavor/$forge)"

  mi_config="$work/.golden-smoke-multi-instance-config.yml"
  cat > "$mi_config" <<'EOF'
instances:
  - { name: alpha, address: http://127.0.0.1:1 }
  - { name: beta,  address: http://127.0.0.1:1 }
EOF

  mi_port=9999
  mi_log="$work/.golden-smoke-server-multi-instance.log"
  "$bin" --config.file="$mi_config" --web.listen-address="127.0.0.1:$mi_port" --log.level=info >"$mi_log" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT

  # Poll /healthz until the server actually accepts connections. Bounded
  # (15 x 1s = 15s ceiling) so a broken startup fails fast instead of hanging
  # this script forever, same discipline as the http-multi block above.
  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$mi_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi-instance: server process exited before becoming ready, see $mi_log ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi-instance: server did not become ready on 127.0.0.1:$mi_port within 15s, see $mi_log ($flavor/$forge)"
  echo "confirmed: server ready on 127.0.0.1:$mi_port with 2 unreachable instances configured ($flavor/$forge)"

  mi_out="$work/.golden-smoke-metrics-multi-instance.txt"
  if ! curl -fsS "http://127.0.0.1:$mi_port/metrics" -o "$mi_out"; then
    die "http-multi-instance: curl /metrics FAILED ($flavor/$forge), see $mi_log"
  fi
  echo "confirmed: /metrics returned a response ($flavor/$forge)"

  for inst in alpha beta; do
    grep -q "demo_exporter_collector_success{collector=\"example\",target=\"$inst\"} 1" "$mi_out" \
      || die "http-multi-instance: /metrics is missing demo_exporter_collector_success{collector=\"example\",target=\"$inst\"}=1 ($flavor/$forge)"
  done
  echo "confirmed: /metrics carries collector_success=1 for both target=\"alpha\" and target=\"beta\", despite both backends being unreachable ($flavor/$forge)"

  # --exporter.max-requests-per-target's own self-instrumentation series
  # (Task 10): registered in mains/multi-instance/main.go.tmpl regardless of
  # whether a ceiling was configured on THIS run (it was not, above), so it
  # must still expose its HELP/TYPE line and a zero-valued _count, the same
  # "declared, always present, a permanent zero without a ceiling" contract
  # docs/metrics.md documents. Catches a registration line silently dropped
  # or renamed, which neither make build nor make docs-check can see: both
  # are source-level checks, not a live /metrics check.
  #
  # Labeled by outcome ("success"/"error", see code/http/limiter.go.tmpl)
  # since the deferred-minors fix round: a bare HistogramVec has no child
  # series at all until a label combination is first observed, which would
  # make this metric ABSENT rather than a truthful zero on a build that
  # never attaches a ceiling, exactly the regression this permanent-zero
  # contract exists to catch. limiter.go.tmpl's own init() pre-populates
  # both outcome values for this reason; check both explicitly rather than
  # the pre-label unlabeled shape.
  for outcome in success error; do
    grep -q "demo_exporter_request_wait_seconds_count{outcome=\"$outcome\"} 0" "$mi_out" \
      || die "http-multi-instance: /metrics is missing demo_exporter_request_wait_seconds_count{outcome=\"$outcome\"}=0 ($flavor/$forge)"
  done
  echo "confirmed: /metrics carries demo_exporter_request_wait_seconds{outcome=\"success\"|\"error\"}, both registered and zero with no ceiling configured ($flavor/$forge)"

  echo "== http-multi-instance: promtool check metrics on /metrics ($flavor/$forge) =="
  if command -v promtool >/dev/null 2>&1; then
    echo "using native promtool"
    if ! promtool check metrics < "$mi_out"; then
      die "http-multi-instance: promtool check metrics FAILED for /metrics ($flavor/$forge)"
    fi
    echo "confirmed: promtool check metrics PASSED ($flavor/$forge)"
  elif command -v docker >/dev/null 2>&1; then
    echo "no native promtool; using docker run prom/prometheus:latest"
    if ! docker run --rm -i --entrypoint promtool prom/prometheus:latest check metrics < "$mi_out"; then
      die "http-multi-instance: promtool check metrics FAILED (via docker) for /metrics ($flavor/$forge)"
    fi
    echo "confirmed: promtool check metrics PASSED via docker ($flavor/$forge)"
  elif command -v podman >/dev/null 2>&1; then
    echo "no native promtool and no docker; using podman run prom/prometheus:latest"
    if ! podman run --rm -i --entrypoint promtool prom/prometheus:latest check metrics < "$mi_out"; then
      die "http-multi-instance: promtool check metrics FAILED (via podman) for /metrics ($flavor/$forge)"
    fi
    echo "confirmed: promtool check metrics PASSED via podman ($flavor/$forge)"
  else
    echo "SKIPPING promtool check metrics ($flavor/$forge): no native promtool and no docker/podman container engine found - install one to validate /metrics locally"
  fi

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT
  echo "confirmed: http-multi-instance live check PASSED ($flavor/$forge)"
fi

# http-multi-instance reload sub-check (Task 14, config-reload-and-concurrency
# epic): the four reload assertions, run against the two-unreachable-instance
# shape the live check above already exercises, PLUS Step 2's own
# requirement: this cell must exercise --exporter.max-requests-per-target
# with a NON-ZERO ceiling at least once across the whole --all matrix, or
# the limiter's non-trivial path (an actual channel send inside Acquire, not
# the nil-Limiter fast path) never runs anywhere in it: every other check in
# this matrix leaves the ceiling at its default of 0 (see
# code/http/limiter.go.tmpl's own NewLimiter, which returns nil for a
# non-positive limit). Folded into the SAME restart that carries assertions
# 2-4 below, rather than a third server lifecycle: the flag only needs to be
# live while that server is up.
#
# Same discipline as the http-multi reload sub-check above: assertions 2 and
# 3 CHANGE the file's content between reloads (an instance added, then a
# file that no longer parses), never a re-POST of the unchanged file, which
# internal/reload's own no-op fast path would let pass even against broken
# reload code (Task 9's own hard-won lesson, cited in this task's brief).
if [ "$target_model" = multi-instance ]; then
  echo "== http-multi-instance: reload sub-check ($flavor/$forge) =="
  bin="$work/bin/demo_exporter"
  [ -x "$bin" ] || die "http-multi-instance reload: $bin missing or not executable after make build ($flavor/$forge)"

  reload_port=9999
  reload_cfg="$work/.golden-smoke-reload-multi-instance-config.yml"
  reload_body="$work/.golden-smoke-reload-mi-body.txt"
  reload_metrics="$work/.golden-smoke-reload-mi-metrics.txt"
  cat > "$reload_cfg" <<'EOF'
instances:
  - { name: alpha, address: http://127.0.0.1:1 }
EOF

  reload_post() {
    curl -s -o "$reload_body" -w '%{http_code}' -X POST "http://127.0.0.1:$reload_port/-/reload"
  }
  # Shared by both the EXIT trap below (so a die() anywhere in this block
  # still cleans up) and this block's own normal-completion path: see the
  # comment on the final cleanup call for why this specifically matters
  # for assertions 3 and 3b, which make the exporter log its own absolute
  # --config.file path.
  reload_cleanup() {
    rm -f "$reload_log1" "$reload_log2" "$reload_cfg" "$reload_body" "$reload_metrics"
  }
  # Declared empty here, before it is ever assigned (right before the
  # restart, below): reload_cleanup and the first trap installation both
  # reference it, and this script runs under `set -u`, so it must exist as
  # at least an empty string before assertion 1's trap could ever fire.
  reload_log2=""

  # Assertion 1: no --web.enable-lifecycle -> POST /-/reload is a plain 404,
  # the closed default.
  reload_log1="$work/.golden-smoke-reload-mi-server-1.log"
  "$bin" --config.file="$reload_cfg" --web.listen-address="127.0.0.1:$reload_port" --log.level=info >"$reload_log1" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true; reload_cleanup' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$reload_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi-instance reload: server exited before becoming ready (assertion 1), see $reload_log1 ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi-instance reload: server did not become ready within 15s (assertion 1) ($flavor/$forge)"

  code=$(reload_post)
  [ "$code" = 404 ] || die "http-multi-instance reload: POST /-/reload without --web.enable-lifecycle returned $code, want 404 ($flavor/$forge)"
  echo "confirmed: assertion 1 - POST /-/reload without --web.enable-lifecycle is 404 ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT

  # Restart WITH --web.enable-lifecycle AND a non-zero
  # --exporter.max-requests-per-target (Step 2): the one cell in the whole
  # --all matrix that ever sets it above 0.
  reload_log2="$work/.golden-smoke-reload-mi-server-2.log"
  "$bin" --config.file="$reload_cfg" --web.enable-lifecycle --exporter.max-requests-per-target=1 --web.listen-address="127.0.0.1:$reload_port" --log.level=info >"$reload_log2" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true; reload_cleanup' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$reload_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi-instance reload: server exited before becoming ready (restart with --web.enable-lifecycle), see $reload_log2 ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi-instance reload: server did not become ready within 15s after restart with --web.enable-lifecycle ($flavor/$forge)"

  # The non-trivial limiter path: alpha's background poller ran its first
  # refresh against an unreachable address, so Acquire returned almost
  # immediately, but with a real, non-nil Limiter this time it still went
  # through the channel send/receive in Acquire (see code/http/limiter.go.tmpl)
  # and recorded an observation. Bounded poll (10 x 1s), not a single-shot
  # read: the refresh runs in a goroutine Start launches asynchronously, so
  # there is no guarantee it has completed by the moment /healthz first
  # answers.
  #
  # outcome="success" specifically, not the metric family in general: only
  # one instance (alpha) is watched at this point in the reload sub-check
  # (beta is added by assertion 2, below), so its poller is the only caller
  # ever contending for the ceiling's single slot. An uncontended Acquire
  # always takes the immediate-send branch (see limiter.go.tmpl's Acquire),
  # never the ctx.Done() one, so outcome="error" has no way to move off its
  # init()-seeded zero here; asserting on it would either always fail or
  # only pass by accident.
  reload_wait_ready=0
  reload_wait_count=0
  i=0
  while [ "$i" -lt 10 ]; do
    curl -fsS "http://127.0.0.1:$reload_port/metrics" -o "$reload_metrics" 2>/dev/null || true
    reload_wait_count=$(command grep 'demo_exporter_request_wait_seconds_count{outcome="success"} ' "$reload_metrics" 2>/dev/null | awk '{print $2}')
    if [ -n "$reload_wait_count" ] && [ "$reload_wait_count" != "0" ]; then
      reload_wait_ready=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$reload_wait_ready" -eq 1 ] \
    || die "http-multi-instance reload: demo_exporter_request_wait_seconds_count{outcome=\"success\"} is still 0 after 10s with --exporter.max-requests-per-target=1 set; the non-trivial limiter path did not run ($flavor/$forge)"
  echo "confirmed: --exporter.max-requests-per-target=1 exercises the non-trivial limiter path (demo_exporter_request_wait_seconds_count{outcome=\"success\"}=$reload_wait_count) ($flavor/$forge)"

  # Assertion 2: add an instance ("beta") the boot file never declared,
  # reload, and confirm it is actually SERVED afterwards (its
  # collector_success series appears), not merely that the reload answered.
  cat > "$reload_cfg" <<'EOF'
instances:
  - { name: alpha, address: http://127.0.0.1:1 }
  - { name: beta,  address: http://127.0.0.1:1 }
EOF
  code=$(reload_post)
  [ "$code" = 200 ] || die "http-multi-instance reload: assertion 2 (add instance) POST /-/reload returned $code, want 200 ($flavor/$forge), body: $(cat "$reload_body")"
  curl -fsS "http://127.0.0.1:$reload_port/metrics" -o "$reload_metrics" \
    || die "http-multi-instance reload: assertion 2 curl /metrics FAILED ($flavor/$forge)"
  command grep -q '^demo_exporter_config_last_reload_successful 1$' "$reload_metrics" \
    || die "http-multi-instance reload: assertion 2 did not leave demo_exporter_config_last_reload_successful at 1 ($flavor/$forge)"
  command grep -q 'demo_exporter_collector_success{collector="example",target="beta"} 1' "$reload_metrics" \
    || die "http-multi-instance reload: assertion 2's new instance 'beta' is not served after reload (no collector_success series) ($flavor/$forge)"
  echo "confirmed: assertion 2 - adding an instance and reloading returns 200, sets the gauge to 1, and the new instance 'beta' is served ($flavor/$forge)"

  # Assertion 3: a file that does not parse at all. Atomicity proof at the
  # PARSE layer: BOTH previously-live instances (alpha, added at boot;
  # beta, added by assertion 2) must still be served.
  printf 'instances:\n  - { name: broken, address: [this is not valid yaml\n' > "$reload_cfg"
  code=$(reload_post)
  [ "$code" = 500 ] || die "http-multi-instance reload: assertion 3 (broken file) POST /-/reload returned $code, want 500 ($flavor/$forge)"
  curl -fsS "http://127.0.0.1:$reload_port/metrics" -o "$reload_metrics" \
    || die "http-multi-instance reload: assertion 3 curl /metrics FAILED ($flavor/$forge)"
  command grep -q '^demo_exporter_config_last_reload_successful 0$' "$reload_metrics" \
    || die "http-multi-instance reload: assertion 3 did not drive demo_exporter_config_last_reload_successful to 0 ($flavor/$forge)"
  for inst in alpha beta; do
    command grep -q "demo_exporter_collector_success{collector=\"example\",target=\"$inst\"} 1" "$reload_metrics" \
      || die "http-multi-instance reload: assertion 3's PREVIOUS instance '$inst' stopped being served after a broken reload ($flavor/$forge)"
  done
  echo "confirmed: assertion 3 - a broken file is refused with 500, the gauge drops to 0, and the previous instances (alpha, beta) are still served ($flavor/$forge)"

  # Assertion 3b: the SAME atomicity property, at a DIFFERENT layer.
  # Assertion 3's file fails to PARSE, so internal/reload's reloadOnce
  # returns on config.Load's own error before apply is ever entered (see
  # reload.go.tmpl) - it can never see a commit-before-validate bug INSIDE
  # apply, which is where the design's prepare-then-commit property
  # actually lives. This file is valid YAML that fails one layer deeper,
  # inside ResolveInstances (an instance referencing an unknown module),
  # which DOES run inside apply, before registry.Prepare is even called
  # and long before registry.Commit could mutate anything. Confirmed by
  # mutation: a real commit-before-validate bug in the apply closure keeps
  # assertion 3 green (config.Load never reaches it) but turns this one
  # red (see this task's report for the reproduction).
  cat > "$reload_cfg" <<'EOF'
instances:
  - { name: gamma, address: http://127.0.0.1:1, module: nosuchmodule }
EOF
  code=$(reload_post)
  [ "$code" = 500 ] || die "http-multi-instance reload: assertion 3b (prepare-stage failure) POST /-/reload returned $code, want 500 ($flavor/$forge)"
  curl -fsS "http://127.0.0.1:$reload_port/metrics" -o "$reload_metrics" \
    || die "http-multi-instance reload: assertion 3b curl /metrics FAILED ($flavor/$forge)"
  command grep -q '^demo_exporter_config_last_reload_successful 0$' "$reload_metrics" \
    || die "http-multi-instance reload: assertion 3b did not drive demo_exporter_config_last_reload_successful to 0 ($flavor/$forge)"
  for inst in alpha beta; do
    command grep -q "demo_exporter_collector_success{collector=\"example\",target=\"$inst\"} 1" "$reload_metrics" \
      || die "http-multi-instance reload: assertion 3b's PREVIOUS instance '$inst' stopped being served after a prepare-stage-failing reload ($flavor/$forge)"
  done
  echo "confirmed: assertion 3b - a file that fails inside the prepare phase, not just parsing, is refused with 500, the gauge drops to 0, and the previous instances (alpha, beta) are still served ($flavor/$forge)"

  # Assertion 4: a "flags:" section the boot file never had. Refused whole,
  # naming the offending key.
  cat > "$reload_cfg" <<'EOF'
flags:
  log.level: debug
instances:
  - { name: alpha, address: http://127.0.0.1:1 }
  - { name: beta,  address: http://127.0.0.1:1 }
EOF
  code=$(reload_post)
  [ "$code" = 500 ] || die "http-multi-instance reload: assertion 4 (flags: change) POST /-/reload returned $code, want 500 ($flavor/$forge)"
  command grep -qF 'log.level' "$reload_body" \
    || die "http-multi-instance reload: assertion 4's refusal message does not name the changed flags key 'log.level' ($flavor/$forge): $(cat "$reload_body")"
  echo "confirmed: assertion 4 - a flags: section change is refused with 500, naming the key ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true

  # Assertions 3 and 3b deliberately feed the exporter a file that fails,
  # and both resulting error messages name that file by its ABSOLUTE path
  # in the exporter's own log (see internal/config's config.Load:
  # `fmt.Errorf("parse %s: %w", path, err)`, and ResolveInstances's own
  # wrapped errors). Leaving that in $reload_log2 would let a LATER matrix
  # cell's whole-tree grep-clean sweep mistake this repository's own
  # checkout path for a leaked maintainer handle. reload_cleanup runs here
  # on the normal-completion path, AND, via the trap it is also armed
  # under above, on any die() inside this block: a die() bypasses the rest
  # of this normal-completion code entirely, so relying on this call alone
  # would leave the scratch files behind on exactly the failure path this
  # cleanup exists for.
  reload_cleanup
  trap - EXIT
  echo "confirmed: http-multi-instance reload sub-check PASSED ($flavor/$forge)"
fi

# Second-collector check (multi-target epic): the whole point of widening the
# probe seam is that a SECOND collector can be appended at the
# // @@PROBE_FACTORIES@@ marker and still compile. This is the mechanical core
# of what /add-collector does on a multi-target scaffold. The command itself is
# an LLM prompt and cannot be run from a shell, so this proves the seam, not the
# command's judgement — but the seam is what did not hold before.
#
# Placed AFTER the http-multi live-probe block's own teardown above (kill /
# wait / trap - EXIT): no server is running and no trap is installed when this
# section starts its own.
if [ "$target_model" = multi ]; then
  echo "== appending a second collector at // @@PROBE_FACTORIES@@ =="

  # $ns: the --var NAMESPACE= value this cell scaffolded with, read back from
  # the generated main.go rather than hardcoded here — same trick the
  # dashboard-backbone sub-check's own $ns already uses further down this
  # script (search 'could not read namespace').
  mainfile=$(ls "$work"/cmd/*/main.go)
  ns=$(command grep -hoE 'const[[:space:]]+namespace[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' "$mainfile" | head -n1 | sed -E 's/.*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/')
  [ -n "$ns" ] || die "second-collector check: could not read namespace from $mainfile"

  # A second collector, derived from the scaffolded one: same five-piece shape,
  # different type name and different metric names, so a clash would surface as
  # a duplicate-registration panic rather than passing silently.
  sed -e 's/ExampleCollector/SecondCollector/g' \
      -e 's/exampleStats/secondStats/g' \
      -e 's/exampleData/secondData/g' \
      -e 's/parseExample/parseSecond/g' \
      -e 's/exampleGetMetrics/secondGetMetrics/g' \
      -e 's/NewExampleCollector/NewSecondCollector/g' \
      -e "s/${ns}_items/${ns}_second_items/g" \
      -e "s/${ns}_healthy/${ns}_second_healthy/g" \
      "$work/internal/collector/collector.go" > "$work/internal/collector/collector_second.go"

  # Append its factory at the marker, exactly as /add-collector does. Anchored
  # on the marker as a STANDALONE `// @@PROBE_FACTORIES@@` line via sed's `r`
  # (read-file) command — NOT a bare substring search: main.go's own doc
  # comment sitting right above the real marker also mentions the literal text
  # "@@PROBE_FACTORIES@@" in prose ("The // @@PROBE_FACTORIES@@ marker below is
  # where scaffold.sh injects the..."), so an unanchored match would ALSO
  # splice into that comment, ahead of `var factories`'s own declaration —
  # confirmed empirically while writing this check (it does not compile: "undefined:
  # factories"). Same anchored-line discipline, and the same class of bug, the
  # existing /add-collector sub-check's own splice onto // @@CLIENT_INIT@@ /
  # // @@COLLECTOR_REGISTRY@@ already guards against further down this script.
  marker_re='^[[:blank:]]*// @@PROBE_FACTORIES@@[[:blank:]]*$'
  grep -q "$marker_re" "$mainfile" || die "second-collector check: no standalone // @@PROBE_FACTORIES@@ marker in $mainfile"

  second_factory_frag="$work/internal/collector/.second_factory.frag.tmp"
  cat > "$second_factory_frag" <<'EOF'
	factories = append(factories, probe.NamedFactory{
		Name: "second",
		New: func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
			if hc != nil {
				return collector.NewSecondCollector(ctx, log, collector.NewClientFor(target, hc)), nil
			}
			return collector.NewSecondCollector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
EOF
  sed -e '\|^[[:blank:]]*// @@PROBE_FACTORIES@@[[:blank:]]*$|r '"$second_factory_frag" "$mainfile" > "$mainfile.new" && mv "$mainfile.new" "$mainfile"
  rm -f "$second_factory_frag"

  # Regression-lock, mirroring the /add-collector sub-check's own exact-count
  # guards further down this script: catches either a marker miss (0) or an
  # unanchored match splicing in more than once (2+, the bug the anchored sed
  # above avoids in the first place).
  second_factory_count=$(grep -c 'Name: "second"' "$mainfile")
  [ "$second_factory_count" -eq 1 ] || die "second-collector check: expected exactly 1 injected second NamedFactory, found $second_factory_count ($flavor/$forge)"

  gofmt -w "$mainfile" "$work/internal/collector/collector_second.go"

  # `make check` alone does NOT rebuild bin/@@EXPORTER_NAME@@ (check's own
  # prerequisites are vet/lint/test/vuln/actionlint/zizmor/deadcode/docs-check —
  # no `build` — see Makefile.tmpl's own check target); confirmed empirically
  # while writing this section. Without an explicit rebuild here, the live
  # probe below would start the STALE single-collector binary from the
  # standard `make build` step earlier in this script and never actually
  # gather the second collector at all. `make build` runs first so a compile
  # failure is attributed to the right step.
  echo "== make build (two collectors on the multi-target seam) =="
  if ! ( cd "$work" && make build ); then
    die "make build FAILED after appending a second collector — the probe seam does not compile with two collectors"
  fi

  echo "== make check (two collectors on the multi-target seam) =="
  if ! ( cd "$work" && make check ); then
    die "make check FAILED after appending a second collector — the probe seam does not hold N collectors"
  fi
  echo "confirmed: make build/check PASSED with two collectors compiled into the probe seam ($flavor/$forge)"

  echo "== two-collector live /probe: starting the rebuilt binary =="
  bin="$work/bin/demo_exporter"
  [ -x "$bin" ] || die "two-collector check: $bin missing or not executable after make build ($flavor/$forge)"

  probe_log2="$work/.golden-smoke-server-2col.log"
  "$bin" --web.listen-address="127.0.0.1:$probe_port" --log.level=info >"$probe_log2" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$probe_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "two-collector check: server process exited before becoming ready — see $probe_log2 ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "two-collector check: server did not become ready on 127.0.0.1:$probe_port within 15s — see $probe_log2 ($flavor/$forge)"
  echo "confirmed: two-collector server ready on 127.0.0.1:$probe_port ($flavor/$forge)"

  probe_body="$work/.golden-smoke-probe-2col.txt"
  if ! curl -fsS "http://127.0.0.1:$probe_port/probe?target=http://127.0.0.1:$probe_port/metrics" -o "$probe_body"; then
    die "two-collector check: curl /probe?target=... FAILED ($flavor/$forge) — see $probe_log2"
  fi

  # Assert on the collector HEALTH series, not the business metrics. This
  # probe targets the exporter's OWN /metrics, so each collector's data fetch
  # (@@DATA_SOURCE_PATH@@ against that target) fails and emits zero business
  # metrics — @@NAMESPACE@@_items / @@NAMESPACE@@_second_items will NOT
  # appear, and probe_success is not asserted to be 1 for the same reason the
  # http-multi block above never asserts it either. What IS always emitted,
  # once per registered-and-gathered collector regardless of its own fetch
  # outcome, is StatusTracker's @@NAMESPACE@@_exporter_collector_success{collector="<name>"}
  # — that appearing for collector="second" is the reliable proof the second
  # collector was wired into the seam and gathered.
  command grep -q "probe_timeout_seconds" "$probe_body" || die "two-collector probe is missing probe_timeout_seconds"
  for name in example second; do
    command grep -q "collector_success{collector=\"$name\"}" "$probe_body" \
      || die "two-collector probe did not gather collector \"$name\" (no collector_success series)"
  done
  echo "confirmed: single probe gathered both collector=\"example\" and collector=\"second\" ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT

  echo "== module selection on the live exporter =="
  # Restart with a config file naming a module that selects only the second
  # collector, then probe with &module=only-second. The example collector
  # must NOT be gathered: its health series must be absent, proving the
  # module parameter does real work end to end, not just passing a unit test.
  second_mod_config="$work/.golden-smoke-second-module-config.yml"
  cat > "$second_mod_config" <<'EOF'
modules:
  only-second:
    collectors: [second]
EOF
  probe_log3="$work/.golden-smoke-server-module.log"
  "$bin" --config.file="$second_mod_config" --web.listen-address="127.0.0.1:$probe_port" --log.level=info >"$probe_log3" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$probe_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "module-selection check: server process exited before becoming ready — see $probe_log3 ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "module-selection check: server did not become ready on 127.0.0.1:$probe_port within 15s — see $probe_log3 ($flavor/$forge)"
  echo "confirmed: module-scoped server ready on 127.0.0.1:$probe_port ($flavor/$forge)"

  module_body="$work/.golden-smoke-probe-module.txt"
  if ! curl -fsS "http://127.0.0.1:$probe_port/probe?target=http://127.0.0.1:$probe_port/metrics&module=only-second" -o "$module_body"; then
    die "module-selection check: curl /probe?target=...&module=only-second FAILED ($flavor/$forge) — see $probe_log3"
  fi

  # Do not assert probe_success's value here either — same reasoning as above.
  command grep -q 'collector_success{collector="second"}' "$module_body" \
    || die "module probe did not gather the collector it selected"
  command grep -q 'collector_success{collector="example"}' "$module_body" \
    && die "module probe gathered a collector the module did not select"
  echo "confirmed: module-scoped probe gathered only collector=\"second\" ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT
  echo "confirmed: second-collector seam check PASSED ($flavor/$forge)"
fi

# docs-check lie-injection (Task 11): the whole point of `make docs-check` is
# that it CANNOT be green while docs/metrics.md documents a metric that does
# not exist in code. Prove that property empirically rather than trusting it:
# fabricate exactly such a lie, confirm the gate fails, revert, confirm it
# passes again. A well-formed table row (see docs/metrics.md's own header
# comment for the exact format internal/collector/docs_check_test.go parses)
# naming a metric that cannot possibly exist — an UPPERCASE name guarantees
# no accidental collision with any real (always-lowercase, @@NAMESPACE@@-
# prefixed) extracted metric.
echo "== docs-check lie-injection ($flavor/$forge): a fabricated metric must fail make docs-check =="
metrics_doc="$work/docs/metrics.md"
[ -f "$metrics_doc" ] || die "docs/metrics.md missing after scaffold — cannot run the lie-injection sub-check ($flavor/$forge)"

lie_line='| `THIS_METRIC_DOES_NOT_EXIST_lie_injection_check` | Counter | - | Injected by golden-smoke.sh to prove make docs-check actually catches a lying doc. |'
printf '%s\n' "$lie_line" >> "$metrics_doc"

if ( cd "$work" && make docs-check ); then
  die "make docs-check PASSED with a fabricated metric injected into docs/metrics.md — the gate does not actually catch a lying doc ($flavor/$forge)"
fi
echo "confirmed: make docs-check FAILS on the injected lie, as expected ($flavor/$forge)"

# Revert: drop exactly the injected line, nothing else.
grep -v -F "$lie_line" "$metrics_doc" > "$metrics_doc.tmp"
mv "$metrics_doc.tmp" "$metrics_doc"

if ! ( cd "$work" && make docs-check ); then
  die "make docs-check still FAILS after reverting the injected lie — docs/metrics.md was not cleanly restored ($flavor/$forge)"
fi
echo "confirmed: make docs-check PASSES again after reverting the injected lie ($flavor/$forge)"

# Guarded docker build (Task 13): Dockerfile is a self-contained multi-stage
# build (it COPYs this scaffold's own source and compiles it — see the
# file's own header comment), so `docker build .` must actually succeed on a
# fresh scaffold, not just parse. Guarded the same way promtool is above,
# minus the "native" tier — building an image always needs a container
# engine, there is no host-only equivalent: docker, then podman, else an
# explicit SKIP, never a silent pass. The image is tagged and left in the
# local engine's cache (same trade-off promtool's `docker run prom/prometheus`
# pull above already makes) rather than removed afterwards — re-running this
# script repeatedly benefits from the layer cache instead of re-pulling/
# re-compiling the Go toolchain layer every time.
echo "== docker build ($flavor/$forge) =="
engine=""
if command -v docker >/dev/null 2>&1; then
  engine=docker
  echo "using docker"
  if ! ( cd "$work" && docker build -f Dockerfile -t "golden-smoke-$flavor-$forge:latest" . ); then
    die "docker build FAILED for $flavor/$forge — see output above"
  fi
  echo "confirmed: docker build PASSED ($flavor/$forge)"
elif command -v podman >/dev/null 2>&1; then
  engine=podman
  echo "no docker; using podman"
  if ! ( cd "$work" && podman build -f Dockerfile -t "golden-smoke-$flavor-$forge:latest" . ); then
    die "docker build FAILED (via podman) for $flavor/$forge — see output above"
  fi
  echo "confirmed: docker build PASSED via podman ($flavor/$forge)"
else
  echo "SKIPPING docker build ($flavor/$forge): no docker/podman container engine found — install one to validate Dockerfile locally"
fi

# Canonical CycloneDX image SBOM (Task 4, tranche A hardening): until now,
# the container image's only SBOM was the BuildKit-native SPDX attestation
# dockers_v2's own `sbom: "true"` bakes into the manifest at release time
# (see .goreleaser.yaml.tmpl) — GoReleaser cannot itself produce a
# CycloneDX SBOM for an image it builds (its sboms: block only ever accepts
# archive artifacts, a documented upstream limitation), so the image's
# canonical, uniform-with-the-archives CycloneDX SBOM instead comes from
# the new `make sbom-image` target (syft), proved here against the exact
# image the docker build step immediately above just produced
# ($image_ref). The SPDX attestation is untouched by any of this — this is
# additive, not a replacement.
#
# Same layered, never-silent-pass discipline as every guarded step above,
# reusing the SAME $engine the standard build already resolved (no fresh
# docker/podman probe):
#   1. $engine set (an image actually got built above) AND native syft on
#      PATH -> run the REAL `make sbom-image` target, dogfooding Step 1
#      itself rather than merely proving "syft works somehow".
#   2. $engine = docker, no native syft -> the fallback a native-syft-less
#      CI runner needs: `docker save` to a tarball, then a pinned,
#      version-checked anchore/syft:$SYFT_VERSION container scanning that
#      tarball via the documented `docker-archive:` source scheme.
#   3. $engine = podman, no native syft -> explicit SKIP (this fallback is
#      only wired for docker's `docker save`, same scoping call as the
#      goreleaser-check step above for podman).
#   4. no engine at all -> explicit SKIP (nothing was built to SBOM).
# A real failure in tier 1 or 2 calls die — never swallowed as a SKIP.
#
# The CycloneDX marker is matched tolerant of surrounding whitespace around
# the colon (`"bomFormat"[[:space:]]*:[[:space:]]*"CycloneDX"`): confirmed
# empirically against real syft 1.46.0 output that it emits compact JSON
# with NO space after the colon (`"bomFormat":"CycloneDX"`), not the
# spaced-out form a hand-written example might suggest — asserting the
# literal spaced form would have made this check fail on real output.
echo "== image SBOM: CycloneDX via make sbom-image / syft ($flavor/$forge) =="
image_ref="golden-smoke-$flavor-$forge:latest"
sbom_out="$work/demo_exporter.image.cdx.json"
bom_marker='"bomFormat"[[:space:]]*:[[:space:]]*"CycloneDX"'
if [ -n "$engine" ] && command -v syft >/dev/null 2>&1; then
  echo "using native syft: make sbom-image IMAGE=$image_ref"
  if ! ( cd "$work" && make sbom-image "IMAGE=$image_ref" ); then
    die "make sbom-image FAILED for $flavor/$forge — see output above"
  fi
  [ -f "$sbom_out" ] || die "make sbom-image reported success but $sbom_out was not created ($flavor/$forge)"
  grep -Eq "$bom_marker" "$sbom_out" || die "make sbom-image output $sbom_out is not a CycloneDX SBOM (no bomFormat:CycloneDX marker) ($flavor/$forge)"
  echo "confirmed: make sbom-image produced a CycloneDX SBOM ($flavor/$forge)"
elif [ "$engine" = docker ]; then
  echo "no native syft; using docker save + docker run anchore/syft:v${SYFT_VERSION}"
  image_tar="$work/.golden-smoke-image.tar"
  if ! docker save "$image_ref" -o "$image_tar"; then
    die "docker save $image_ref FAILED for $flavor/$forge — see output above"
  fi
  if ! docker run --rm -v "$work":/w "anchore/syft:v${SYFT_VERSION}" \
       docker-archive:/w/.golden-smoke-image.tar -o cyclonedx-json=/w/demo_exporter.image.cdx.json; then
    rm -f "$image_tar"
    die "syft (via docker, docker-archive) FAILED to generate an image SBOM for $flavor/$forge — see output above"
  fi
  rm -f "$image_tar"
  [ -f "$sbom_out" ] || die "syft (via docker) reported success but $sbom_out was not created ($flavor/$forge)"
  grep -Eq "$bom_marker" "$sbom_out" || die "syft (via docker) output $sbom_out is not a CycloneDX SBOM (no bomFormat:CycloneDX marker) ($flavor/$forge)"
  echo "confirmed: docker-archive syft scan produced a CycloneDX SBOM ($flavor/$forge)"
elif [ "$engine" = podman ]; then
  echo "SKIPPING image SBOM check ($flavor/$forge): podman found but no native syft, and this check's containerized fallback is only wired for docker (docker save) — install syft, or docker, to generate a local image SBOM"
else
  echo "SKIPPING image SBOM check ($flavor/$forge): no docker/podman container engine found and no native syft on PATH (same as the standard Dockerfile build above)"
fi

# Guarded Dockerfile.minimal build (Task 2, tranche A hardening): the
# distroless/minimal image variant ships to every scaffolded exporter but,
# until now, was never actually built here — only Dockerfile was. Reuses
# the SAME $engine the standard build immediately above already resolved
# (docker, podman, or empty) — no second command -v docker/podman
# detection: if the standard build above found no engine, $engine is still
# empty here and this step SKIPs for the identical reason, rather than
# re-probing from scratch.
echo "== docker build Dockerfile.minimal ($flavor/$forge) =="
if [ "$engine" = docker ]; then
  if ! ( cd "$work" && docker build -f Dockerfile.minimal -t "golden-smoke-min-$flavor-$forge:latest" . ); then
    die "docker build (Dockerfile.minimal) FAILED for $flavor/$forge — see output above"
  fi
  echo "confirmed: docker build (Dockerfile.minimal) PASSED ($flavor/$forge)"
elif [ "$engine" = podman ]; then
  if ! ( cd "$work" && podman build -f Dockerfile.minimal -t "golden-smoke-min-$flavor-$forge:latest" . ); then
    die "docker build (Dockerfile.minimal) FAILED (via podman) for $flavor/$forge — see output above"
  fi
  echo "confirmed: docker build (Dockerfile.minimal) PASSED via podman ($flavor/$forge)"
else
  echo "SKIPPING docker build Dockerfile.minimal ($flavor/$forge): no docker/podman container engine found (same as the standard Dockerfile build above)"
fi

# Compose config validation (Task 2): docker-compose.yml and
# docker-compose.minimal.yml both ship to every scaffolded exporter but,
# until now, neither was ever parsed by anything. `compose ... config -q`
# needs no env — both templates default IMAGE and HOST_PORT via
# ${VAR:-default} — and exits non-zero on a malformed file, so a clean run
# here actually proves valid compose syntax rather than just the files'
# presence on disk.
#
# Still gated on the SAME $engine resolved by the standard build above, not
# a fresh docker/podman probe: an empty $engine SKIPs immediately, for the
# identical reason the two builds above did. What IS checked fresh here is
# narrower than the engine choice itself — whether that already-resolved
# engine also has a working "compose" subcommand, since the compose plugin
# can be absent even when the engine binary is present. podman's compose
# story is split across two possible providers (a registered `podman
# compose` external helper, or the standalone podman-compose script), so
# both are tried before giving up.
echo "== compose config validation ($flavor/$forge) =="
compose_cmd=""
if [ "$engine" = docker ] && docker compose version >/dev/null 2>&1; then
  compose_cmd="docker compose"
elif [ "$engine" = podman ] && podman compose version >/dev/null 2>&1; then
  compose_cmd="podman compose"
elif [ "$engine" = podman ] && command -v podman-compose >/dev/null 2>&1; then
  compose_cmd="podman-compose"
fi

if [ -n "$compose_cmd" ]; then
  for compose_file in docker-compose.yml docker-compose.minimal.yml; do
    echo "validating $compose_file via $compose_cmd ($flavor/$forge)"
    if ! ( cd "$work" && $compose_cmd -f "$compose_file" config -q ); then
      die "$compose_cmd -f $compose_file config FAILED for $flavor/$forge — see output above"
    fi
    echo "confirmed: $compose_file is valid compose syntax ($flavor/$forge)"
  done
elif [ -z "$engine" ]; then
  echo "SKIPPING compose config validation ($flavor/$forge): no docker/podman container engine found (same as the standard Dockerfile build above)"
elif [ "$engine" = docker ]; then
  echo "SKIPPING compose config validation ($flavor/$forge): docker found but the compose plugin is unavailable (docker compose version failed) — install the compose plugin to validate compose files locally"
else
  echo "SKIPPING compose config validation ($flavor/$forge): podman found but no compose provider is available (tried podman compose and podman-compose) — install one to validate compose files locally"
fi

# goreleaser check (Task 3, tranche A hardening): .goreleaser.yaml ships to
# every scaffolded exporter regardless of --forge (release is host-agnostic;
# only .github/ itself is forge-gated — see .goreleaser.yaml.tmpl's own
# header comment), so this step runs in every cell, not just github ones.
# `goreleaser check` validates the file's schema without building anything.
# Same container-first / graceful-skip idiom as the promtool and docker
# build steps above: native `goreleaser` on PATH first, then the SAME
# $engine already resolved by the docker build step above if it is docker
# (no fresh docker probe — same reasoning as the Dockerfile.minimal build's
# own comment above); podman is not wired as a third tier here since it was
# never confirmed against this exact image/mount combination, so a
# podman-only host gets an explicit SKIP rather than an unverified path. A
# schema error must fail the cell outright (die), never be swallowed as a
# SKIP.
#
# `check` needs a git remote despite its own docs describing it as a pure
# syntax check: empirically (found while wiring this step) it builds a real
# SCM client from .goreleaser.yaml's release.github config, and that
# hard-fails ("no remote configured to list refs from") against the bare
# `git init` above, which deliberately stops short of adding one (see that
# step's own comment on why — it mirrors a real post-scaffold repo before a
# first commit or remote exists). The remote is added here instead, right
# before the one check that actually needs it, rather than retrofitting the
# earlier git-init step for every cell including ones that never reach this
# far. The URL is never dialed — reconfirmed with `docker run --network
# none` — only its owner/repo shape is parsed locally, so a fake,
# unreachable one is fine. Hardcoded to acme/demo_exporter, matching the
# OWNER/EXPORTER_NAME every golden cell already hardcodes in its own --var
# set above.
echo "== goreleaser check ($flavor/$forge) =="
( cd "$work" && git remote add origin https://github.com/acme/demo_exporter.git )
if command -v goreleaser >/dev/null 2>&1; then
  echo "using native goreleaser"
  if ! ( cd "$work" && goreleaser check ); then
    die "goreleaser check FAILED for $flavor/$forge — see output above"
  fi
  echo "confirmed: goreleaser check PASSED ($flavor/$forge)"
elif [ "$engine" = docker ]; then
  echo "no native goreleaser; using docker run goreleaser/goreleaser:v${GORELEASER_VERSION}"
  if ! docker run --rm -v "$work":/w -w /w "goreleaser/goreleaser:v${GORELEASER_VERSION}" check; then
    die "goreleaser check FAILED (via docker) for $flavor/$forge — see output above"
  fi
  echo "confirmed: goreleaser check PASSED via docker ($flavor/$forge)"
else
  echo "SKIPPING goreleaser check ($flavor/$forge): no native goreleaser and no docker found (podman not wired for this check) — install goreleaser or docker to validate .goreleaser.yaml locally"
fi

# Mechanical /add-collector sub-check (Task 22, optional per the task's own
# brief — deferred from Task 16's by-hand proof, see that task's report).
# /add-collector itself is assistant-driven (name validation, endpoint and
# metric choices, alert tiering — real judgment calls, not something to
# script), so this does NOT simulate the whole command: it mechanically
# exercises only the SCRIPTABLE backbone every real run also does — copy
# the flavor's own collector template, rename its identifiers, splice a
# register(...) call at the // @@COLLECTOR_REGISTRY@@ marker, add a
# docs/metrics.md row — then make build + make docs-check (this
# sub-check's own literal, deliberately narrow scope). The goal is to catch
# a FUTURE template/marker edit that would break /add-collector, not to
# re-validate everything Task 16 already proved by hand.
#
# Runs once, only for http/none: the mechanism under test (marker
# anchoring, @@VAR@@ substitution order, docs-check) does not vary by
# --forge, so repeating it per forge variant would buy nothing. Scoped to
# the http flavor only, not cli too — flagged as a follow-up in this task's
# report rather than doubling the unverified surface here.
#
# Deliberately builds ONLY the non-test half of the triad (no
# queue_test.go): copying the TEST template for a 2nd collector requires
# first dropping several shared package-level declarations (the
# statusTrackerSuccessMetric const, TestRequestDuration_CustomRegistryReachable,
# — see commands/add-collector.md's own "shared-declaration exclusion
# list"), a balanced-block deletion that is real template-shape-specific
# surgery, not a mechanical rename — exactly the kind of fragile scripting
# this sub-check's own brief warns against shipping. make build/docs-check
# need no test file at all, so skipping it sidesteps that fragility
# entirely rather than attempting it unreliably.
#
# ORDER MATTERS below, and was wrong on the first attempt while writing
# this sub-check (caught empirically, not by inspection, then fixed): the
# identifier rename (example->queue) MUST run BEFORE @@VAR@@ substitution,
# not after. @@MODULE_PATH@@'s real value in this golden fixture is
# example.com/demo_exporter, which contains the substring "example" too —
# renaming AFTER substitution corrupts it into queue.com/demo_exporter and
# go build fails ("no required module provides package queue.com/...").
# Renaming first is safe in both directions: no @@VAR@@ sentinel NAME
# contains "example".
#
# Skipped for target_model=multi and multi-instance (Task 2, multi-target
# epic; multi-instance added in Task 12): this sub-check splices at the
# // @@CLIENT_INIT@@ / // @@COLLECTOR_REGISTRY@@ markers, which neither a
# multi-target main.go (it only has its own // @@PROBE_FACTORIES@@ marker)
# nor a multi-instance main.go (it only has its own
# // @@INSTANCE_FACTORIES@@ marker) carries at all. /add-collector itself
# stays single-only for this epic (documented follow-up for multi, see Task
# 3; multi-instance's own /add-collector branch, Task 10, appends at
# // @@INSTANCE_FACTORIES@@ instead, a different splice this mechanical
# sub-check does not exercise), so there is nothing for this mechanical
# sub-check to exercise on either model here.
if [ "$flavor" = http ] && [ "$forge" = none ] && [ "$target_model" = single ]; then
  echo "== mechanical /add-collector sub-check ($flavor/$forge): scaffolded templates still support adding a 2nd collector =="
  addc_tmpl="$assets/code/http/collector.go.tmpl"
  addc_client_frag="$assets/code/http/wiring/client_init.frag"
  addc_build_frag="$assets/code/http/wiring/client_build.frag"
  addc_registry_frag="$assets/code/http/wiring/registry.frag"
  addc_main="$work/cmd/demo_exporter/main.go"
  addc_metrics_doc="$work/docs/metrics.md"
  addc_qclient="$work/internal/collector/.addc_client_init.frag.tmp"
  addc_qbuild="$work/internal/collector/.addc_client_build.frag.tmp"
  addc_qregistry="$work/internal/collector/.addc_registry.frag.tmp"

  # 1. Materialize queue.go: rename identifiers + the two metric-name
  # literals (items/healthy -> queue_items/queue_healthy — avoiding a
  # same-name collision with the example collector's own demo_items/
  # demo_healthy, which neither make build nor make docs-check would catch
  # on their own: both are AST/compile-level checks, not a live registry
  # check) BEFORE substituting @@VAR@@.
  sed \
    -e 's/@@NAMESPACE@@_items/@@NAMESPACE@@_queue_items/' \
    -e 's/@@NAMESPACE@@_healthy/@@NAMESPACE@@_queue_healthy/' \
    -e 's/example/queue/g' \
    -e 's/Example/Queue/g' \
    "$addc_tmpl" > "$work/internal/collector/queue.go.tmp"
  sed \
    -e 's/@@MODULE_PATH@@/example.com\/demo_exporter/g' \
    -e 's/@@DATA_SOURCE_PATH@@/\/api\/queue/g' \
    -e 's/@@NAMESPACE@@/demo/g' \
    "$work/internal/collector/queue.go.tmp" > "$work/internal/collector/queue.go"
  rm -f "$work/internal/collector/queue.go.tmp"

  # 2. Build queue's own client_init/client_build/registry fragments (same
  # rename, same order) and splice them at the SAME three markers scaffold.sh
  # itself used: the markers survive scaffolding verbatim for exactly this
  # reuse (see scaffold.sh's own comment on why /add-collector needs them
  # intact). All three are required, not just the first and last: client_init
  # only DECLARES queueTarget/queueTimeout/queueClient, and client_build is
  # what consumes the timeout and assigns the client. Injecting client_init
  # and registry alone leaves queueTimeout declared and not used, which is a
  # compile error, so this sub-check is the executable contract that
  # /add-collector must fill all three.
  # registry.frag also carries the http_client_requests and
  # http_client_request_wait self-instrumentation registrations (shared,
  # already wired once by scaffold.sh), both filtered out of this copy so
  # neither is registered a second time: kingpin panics on a duplicate long
  # flag name ("--collector.http_client_requests"/"--collector.http_client_request_wait"),
  # which make build cannot catch (it only fails at process startup, not at
  # compile time), so a filter that misses either name here would leave a
  # binary that builds clean and then dies on its first run.
  sed -e 's/example/queue/g' -e 's/Example/Queue/g' "$addc_client_frag" \
    | sed -e 's/@@DATA_SOURCE@@/http:\/\/localhost:9999/g' > "$addc_qclient"
  sed -e 's/example/queue/g' -e 's/Example/Queue/g' "$addc_build_frag" > "$addc_qbuild"
  sed -e 's/example/queue/g' -e 's/Example/Queue/g' "$addc_registry_frag" \
    | grep -v 'register("http_client_requests"' \
    | grep -v 'register("http_client_request_wait"' > "$addc_qregistry"

  grep -q '^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$' "$addc_main" || die "add-collector sub-check: no standalone // @@CLIENT_INIT@@ marker in $addc_main"
  sed -e '\|^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$|r '"$addc_qclient" "$addc_main" > "$addc_main.tmp" && mv "$addc_main.tmp" "$addc_main"
  grep -q '^[[:blank:]]*// @@CLIENT_BUILD@@[[:blank:]]*$' "$addc_main" || die "add-collector sub-check: no standalone // @@CLIENT_BUILD@@ marker in $addc_main"
  sed -e '\|^[[:blank:]]*// @@CLIENT_BUILD@@[[:blank:]]*$|r '"$addc_qbuild" "$addc_main" > "$addc_main.tmp" && mv "$addc_main.tmp" "$addc_main"
  grep -q '^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$' "$addc_main" || die "add-collector sub-check: no standalone // @@COLLECTOR_REGISTRY@@ marker in $addc_main"
  sed -e '\|^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$|r '"$addc_qregistry" "$addc_main" > "$addc_main.tmp" && mv "$addc_main.tmp" "$addc_main"
  rm -f "$addc_qclient" "$addc_qbuild" "$addc_qregistry"

  # Regression-lock, mirroring scaffold_edge_test.sh's own exact-count check
  # for this same class of bug: an unanchored marker match would ALSO splice
  # into register()'s own doc-comment prose mention of
  # // @@COLLECTOR_REGISTRY@@, and either miscount here or fail to compile.
  addc_regcount=$(grep -c 'register("queue"' "$addc_main")
  [ "$addc_regcount" -eq 1 ] || die "add-collector sub-check: expected exactly 1 injected register(\"queue\" call, found $addc_regcount ($flavor/$forge)"

  # 3. docs/metrics.md row — minimal, matching the shipped 4-cell format.
  cat >> "$addc_metrics_doc" <<'EOF'

## QueueCollector

Defined in `internal/collector/queue.go`.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_queue_items` | Gauge | - | Number of items reported by the queue target. |
| `demo_queue_healthy` | Gauge | - | Whether the queue target reports itself healthy (1) or not (0). |
EOF

  echo "== add-collector sub-check: make build ($flavor/$forge) =="
  if ! ( cd "$work" && make build ); then
    die "add-collector sub-check: make build FAILED after mechanically adding queue — a template/marker change likely broke /add-collector ($flavor/$forge)"
  fi

  echo "== add-collector sub-check: make docs-check ($flavor/$forge) =="
  if ! ( cd "$work" && make docs-check ); then
    die "add-collector sub-check: make docs-check FAILED after mechanically adding queue — docs/metrics.md and internal/collector/queue.go disagree ($flavor/$forge)"
  fi
  echo "confirmed: add-collector sub-check PASSED ($flavor/$forge)"

  # Background-refresh collector epic (docs/design/2026-07-06-background-
  # refresh-collector-design.md): extend this SAME http/none /add-collector
  # sub-check to ALSO mechanically exercise the NEW --variant background
  # branch, right after the synchronous "queue" sub-check above. Named
  # "tape" after this epic's own driving case
  # (docs/design/2026-07-06-background-refresh-collector-design.md's IBM
  # TS4500 tape library) — deliberately distinct from "queue" above, so the
  # two mechanical sub-checks never collide on an identifier or a metric
  # name in the same package. Same rename-before-substitute ordering
  # discipline as the queue sub-check above (see its own comment for why:
  # @@MODULE_PATH@@'s value contains the substring "example" too).
  echo "== mechanical /add-collector --variant background sub-check ($flavor/$forge): background template compiles and wires into the Done() seam =="
  addc_bg_tmpl="$assets/code/http/variants/background_collector.go.tmpl"
  addc_bg_main="$work/cmd/demo_exporter/main.go"
  addc_bg_metrics_doc="$work/docs/metrics.md"
  addc_bg_client="$work/internal/collector/.addc_bg_client_init.frag.tmp"
  addc_bg_build="$work/internal/collector/.addc_bg_client_build.frag.tmp"
  addc_bg_registry="$work/internal/collector/.addc_bg_registry.frag.tmp"

  [ -f "$addc_bg_tmpl" ] || die "background collector template missing: $addc_bg_tmpl"

  # 1. Materialize tape.go: identical rename-then-substitute order as queue
  # above.
  sed \
    -e 's/@@NAMESPACE@@_items/@@NAMESPACE@@_tape_items/' \
    -e 's/@@NAMESPACE@@_healthy/@@NAMESPACE@@_tape_healthy/' \
    -e 's/example/tape/g' \
    -e 's/Example/Tape/g' \
    "$addc_bg_tmpl" > "$work/internal/collector/tape.go.tmp"
  sed \
    -e 's/@@MODULE_PATH@@/example.com\/demo_exporter/g' \
    -e 's/@@DATA_SOURCE_PATH@@/\/api\/tape/g' \
    -e 's/@@NAMESPACE@@/demo/g' \
    "$work/internal/collector/tape.go.tmp" > "$work/internal/collector/tape.go"
  rm -f "$work/internal/collector/tape.go.tmp"

  # 2. Flags under // @@CLIENT_INIT@@ (target, timeout, interval), plus the
  # deferred-assignment tapeClient declaration commands/add-collector.md's
  # background variant now teaches, the same shape as the queue sub-check's
  # own client_init above with one added interval flag: this marker only
  # DECLARES tapeTarget/tapeTimeout/tapeInterval/tapeClient, and
  # // @@CLIENT_BUILD@@ below is what actually assigns tapeClient, so this
  # step alone would leave tapeClient declared and never assigned, a compile
  # error, until step 3 fills it in. The marker comment itself survives
  # every previous injection (see scaffold.sh's own comment on why), so it
  # is still there to reuse.
  cat > "$addc_bg_client" <<'EOF'
	tapeTarget := kingpin.Flag("collector.tape.target", "Base URL the tape collector scrapes.").Default("http://localhost:9999").String()
	tapeTimeout := kingpin.Flag("collector.tape.timeout", "Per-request timeout for the tape collector.").Default("5s").Duration()
	tapeInterval := kingpin.Flag("collector.tape.interval", "Refresh interval for the tape collector.").Default("5m").Duration()
	// Declared here, assigned at // @@CLIENT_BUILD@@ once flags are parsed.
	// The registry closure below captures it by reference and only
	// dereferences it later, in main's construction loop.
	var tapeClient *collector.Client
EOF
  grep -q '^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$' "$addc_bg_main" || die "add-collector background sub-check: no standalone // @@CLIENT_INIT@@ marker in $addc_bg_main"
  sed -e '\|^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$|r '"$addc_bg_client" "$addc_bg_main" > "$addc_bg_main.tmp" && mv "$addc_bg_main.tmp" "$addc_bg_main"
  rm -f "$addc_bg_client"

  # 3. // @@CLIENT_BUILD@@: build tapeClient from cfg.HTTPClientConfig, or
  # fall back to the plain transport, exactly like the queue sub-check's own
  # client_build splice above. commands/add-collector.md's background
  # variant section is explicit that this marker does not vary by variant,
  # so this reuses the SAME generic client_build.frag the queue splice reads
  # from, renamed to tape/Tape instead of queue/Queue.
  sed -e 's/example/tape/g' -e 's/Example/Tape/g' "$addc_build_frag" > "$addc_bg_build"
  grep -q '^[[:blank:]]*// @@CLIENT_BUILD@@[[:blank:]]*$' "$addc_bg_main" || die "add-collector background sub-check: no standalone // @@CLIENT_BUILD@@ marker in $addc_bg_main"
  sed -e '\|^[[:blank:]]*// @@CLIENT_BUILD@@[[:blank:]]*$|r '"$addc_bg_build" "$addc_bg_main" > "$addc_bg_main.tmp" && mv "$addc_bg_main.tmp" "$addc_bg_main"
  rm -f "$addc_bg_build"

  # 4. Registry snippet under // @@COLLECTOR_REGISTRY@@: eager-construct +
  # Start(ctx) + append(backgroundCollectors, ...) ALL INSIDE the
  # register(...) closure (see commands/add-collector.md's own note on
  # why: this splice point sits BEFORE kingpin.Parse() in main.go, so log
  # is still nil and every flag pointer still holds its zero value there,
  # the closure defers all of this to the registry loop later in main(),
  # which runs after Parse() and after log is assigned). Passes the
  # tapeClient step 3 built rather than an inline collector.NewClient(...):
  # the command's background variant reuses the same shared,
  # http_client_config-aware client the synchronous queue sub-check builds,
  # never a bespoke unauthenticated one.
  cat > "$addc_bg_registry" <<'EOF'
	register("tape", func() prometheus.Collector {
		tapeColl := collector.NewTapeCollector(log, tapeClient, *tapeInterval)
		tapeColl.Start(ctx)
		backgroundCollectors = append(backgroundCollectors, tapeColl)
		return tapeColl
	}, true)
EOF
  grep -q '^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$' "$addc_bg_main" || die "add-collector background sub-check: no standalone // @@COLLECTOR_REGISTRY@@ marker in $addc_bg_main"
  sed -e '\|^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$|r '"$addc_bg_registry" "$addc_bg_main" > "$addc_bg_main.tmp" && mv "$addc_bg_main.tmp" "$addc_bg_main"
  rm -f "$addc_bg_registry"

  # Regression-lock, mirroring the queue sub-check's own exact-count guard
  # above: an unanchored marker match would ALSO splice into register()'s
  # own doc-comment prose mention of // @@COLLECTOR_REGISTRY@@.
  addc_bg_regcount=$(grep -c 'register("tape"' "$addc_bg_main")
  [ "$addc_bg_regcount" -eq 1 ] || die "add-collector background sub-check: expected exactly 1 injected register(\"tape\" call, found $addc_bg_regcount ($flavor/$forge)"
  addc_bg_clientcount=$(grep -c 'tapeTarget := kingpin.Flag' "$addc_bg_main")
  [ "$addc_bg_clientcount" -eq 1 ] || die "add-collector background sub-check: expected exactly 1 injected client_init copy, found $addc_bg_clientcount ($flavor/$forge)"
  addc_bg_buildcount=$(grep -c 'tapeClient = collector.NewClient(\*tapeTarget, \*tapeTimeout)' "$addc_bg_main")
  [ "$addc_bg_buildcount" -eq 1 ] || die "add-collector background sub-check: expected exactly 1 injected client_build copy, found $addc_bg_buildcount ($flavor/$forge)"

  # 5. docs/metrics.md row, including the freshness gauge, the metric
  # Decision 4/6 of the background-refresh design exist for.
  cat >> "$addc_bg_metrics_doc" <<'EOF'

## TapeCollector

Defined in `internal/collector/tape.go`.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_tape_items` | Gauge | - | Number of items reported by the tape target. |
| `demo_tape_healthy` | Gauge | - | Whether the tape target reports itself healthy (1) or not (0). |
| `demo_tape_last_refresh_timestamp_seconds` | Gauge | - | Unix time of the last successful tape refresh. Alert if time() - this > 2 x the collector's configured interval. |
EOF

  echo "== add-collector background sub-check: make build ($flavor/$forge) =="
  if ! ( cd "$work" && make build ); then
    die "add-collector background sub-check: make build FAILED after mechanically adding tape — the background template or the Done() seam likely broke ($flavor/$forge)"
  fi

  echo "== add-collector background sub-check: make docs-check ($flavor/$forge) =="
  if ! ( cd "$work" && make docs-check ); then
    die "add-collector background sub-check: make docs-check FAILED after mechanically adding tape — docs/metrics.md and internal/collector/tape.go disagree ($flavor/$forge)"
  fi
  echo "confirmed: add-collector background sub-check PASSED ($flavor/$forge)"
fi

# Deterministic dashboard-backbone sub-check (generate-dashboard epic,
# docs/design/2026-07-07-generate-dashboard-design.md): the /generate-dashboard command
# is assistant-driven (a metrics.md-anchored RED/USE dialogue, context7
# enrichment — real judgment calls), so this does NOT simulate the command. It
# exercises only the SCRIPTABLE floor every real run also invokes: the shared
# backbone (skills/prometheus-exporter/scripts/generate-dashboard.sh), then
# asserts the properties the design fixes — valid exportable JSON, the anti-lie
# expr-subset-of-metrics.md property, and cleanliness. Runs in both --forge
# none cells (http and cli): the forge is irrelevant to dashboards, but the two
# flavors ship DIFFERENT default metric shapes (http: label-less items/healthy;
# cli: example_entries + a labeled example{key}), so both exercise the backbone
# for free (the scaffold already exists; no extra build). Guarded container-
# first on jq exactly like the promtool step above: native -> docker -> podman
# -> explicit SKIP, never a silent pass.
if [ "$forge" = none ]; then
  echo "== dashboard-backbone sub-check ($flavor/$forge): generate + validate business dashboards =="
  dash_backbone="$root/skills/prometheus-exporter/scripts/generate-dashboard.sh"
  [ -f "$dash_backbone" ] || die "dashboard backbone missing: $dash_backbone"

  jq_cmd=""
  if command -v jq >/dev/null 2>&1; then
    jq_cmd="jq"
  elif command -v docker >/dev/null 2>&1; then
    jq_cmd="docker run --rm -i ghcr.io/jqlang/jq:1.7.1"
  elif command -v podman >/dev/null 2>&1; then
    jq_cmd="podman run --rm -i ghcr.io/jqlang/jq:1.7.1"
  fi

  if [ -z "$jq_cmd" ]; then
    echo "SKIPPING dashboard-backbone sub-check ($flavor/$forge): no native jq and no docker/podman engine found — install jq or a container engine to validate generated dashboards locally"
  else
    # Generate into a CLEAN staging dir, never the live monitoring/grafana:
    # that dir already holds the scaffold-shipped health-dashboard.json (v0.1),
    # which this command never touches (design §1) — but its title field
    # ("<name> / Exporter Health") and its own panels reference the
    # self-instrumentation metrics, both absent from the business model.
    # Scanning it would raise a FALSE anti-lie violation on a file this backbone
    # never wrote. Staging first also mirrors what the real command does
    # (mktemp, reconcile, then place), so checks 3-4 below scope to exactly what
    # the backbone produced.
    dash_out="$work/.dash-staging"
    rm -rf "$dash_out"; mkdir -p "$dash_out"
    # 1. /new ships one ExampleCollector with real business metrics documented
    # in docs/metrics.md, so the backbone must succeed and produce an overview.
    if ! sh "$dash_backbone" --repo "$work" --out-dir "$dash_out"; then
      die "dashboard-backbone sub-check: generate-dashboard.sh failed on the scaffolded $flavor repo ($flavor/$forge)"
    fi
    [ -f "$dash_out/overview.json" ] || die "dashboard-backbone sub-check: overview.json not generated ($flavor/$forge)"

    # 2. Well-formed JSON (the jq-empty gate the design mandates).
    if ! cat "$dash_out/overview.json" | $jq_cmd empty; then
      die "dashboard-backbone sub-check: overview.json is not valid JSON ($flavor/$forge)"
    fi
    echo "confirmed: overview.json is well-formed exportable JSON ($flavor/$forge)"

    # 3. Anti-lie: every <namespace>_* token in every panel expr must be a
    # documented metric, or a documented Histogram's synthesized _bucket/_sum/
    # _count. Build the allowed set from the backbone's OWN --print-model seam,
    # NEVER by re-parsing metrics.md here: the mechanical /add-collector
    # sub-check earlier in this script appends ## QueueCollector/## TapeCollector
    # to $work/docs/metrics.md AFTER ## Self-instrumentation, so any hand-rolled
    # "stop at Self-instrumentation" re-parse would miss those sections and
    # raise a FALSE anti-lie violation (demo_queue_*/demo_tape_* are real,
    # documented, and the backbone does emit panels for them). --print-model
    # applies the exact same section-tracking + Self-instrumentation exclusion
    # the emitter used, so the allowed set stays in lockstep with what the
    # backbone actually put in the panels — single source, no drift. Each
    # Histogram (field 4 == Type) expands to its synthesized derived series.
    ns=$(grep -hoE 'const[[:space:]]+namespace[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' "$work"/cmd/*/main.go | head -n1 | sed -E 's/.*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/')
    [ -n "$ns" ] || die "dashboard-backbone sub-check: could not read namespace ($flavor/$forge)"
    allowed=$(sh "$dash_backbone" --repo "$work" --print-model | awk -F'\t' '
      $1=="metric" {
        print $3
        if ($4 ~ /Histogram/) { print $3 "_bucket"; print $3 "_sum"; print $3 "_count" }
      }' | sort -u)
    # Extract tokens from panel EXPRESSIONS only (.panels[].targets[].expr), via
    # jq — not the whole JSON text. Design §10.2 fixes the anti-lie property to
    # "chaque panel expr ne référence que des métriques documentées", and the
    # backbone legitimately references a self-instrumentation metric OUTSIDE any
    # panel expr — the $job template variable's
    # label_values(<ns>_exporter_collector_success, job) query, mirroring the
    # health dashboard (design §6.3). That metric is (correctly) excluded from
    # --print-model's business model, so a whole-file scan would false-positive
    # on it; scoping to panel exprs matches the stated property exactly.
    tokens=$(for f in "$dash_out"/*.json; do cat "$f" | $jq_cmd -r '.panels[]?.targets[]?.expr // empty'; done | grep -oE "${ns}_[A-Za-z0-9_]+" | sort -u)
    for t in $tokens; do
      if ! printf '%s\n' "$allowed" | grep -qxF "$t"; then
        die "dashboard-backbone sub-check: panel expr references '$t', which is not documented in docs/metrics.md — anti-lie violation ($flavor/$forge)"
      fi
    done
    echo "confirmed: every panel expr references only documented metrics ($flavor/$forge)"

    # 4. Cleanliness: no source-project name / maintainer handle and no residual
    # @@VAR@@ in any generated dashboard. The tree-wide test/_work sweep for
    # slurm/sckyzo runs right after scaffold.sh — BEFORE this sub-check creates
    # monitoring/grafana/*.json — so the generated JSON needs its OWN local
    # slurm/handle sweep here (design §10.3), not only the @@VAR@@ guard. Both
    # are match=fail; a JSON file is text, so -I only guards against a stray
    # binary in the glob.
    if command grep -niI -e slurm -e sckyzo "$dash_out"/*.json; then
      die "dashboard-backbone sub-check: 'slurm' or the maintainer handle leaked into a generated dashboard ($flavor/$forge)"
    fi
    if command grep -nI '@@[A-Z_]*@@' "$dash_out"/*.json; then
      die "dashboard-backbone sub-check: residual @@VAR@@ sentinel in a generated dashboard ($flavor/$forge)"
    fi
    echo "confirmed: generated dashboards are clean — no slurm/handle, no residual @@VAR@@ ($flavor/$forge)"

    # 5. Zero-business-metric refusal: point the backbone at a doc stripped to
    # only its ## Self-instrumentation section and confirm it exits 3 rather
    # than emitting an empty dashboard.
    dash_empty="$work/.dash-empty"
    rm -rf "$dash_empty"; mkdir -p "$dash_empty/docs" "$dash_empty/cmd/demo_exporter"
    cp "$work"/cmd/*/main.go "$dash_empty/cmd/demo_exporter/main.go"
    # Keep ONLY the ## Self-instrumentation section — NOT "everything from it to
    # EOF". The mechanical /add-collector sub-check above appends ##
    # QueueCollector/## TapeCollector AFTER ## Self-instrumentation, so a
    # sed-to-EOF slice ('/## Self-instrumentation/,$p') would drag those business
    # collectors in; the doc would still document business metrics and the
    # backbone would emit a dashboard (exit 0) instead of refusing (exit 3). Same
    # append-after-Self-instrumentation gotcha the anti-lie set avoids by using
    # --print-model. awk prints lines only while inside the Self-instrumentation
    # section, resetting at the next ## header.
    awk '/^## /{p=($0 ~ /Self-instrumentation/)} p' "$work/docs/metrics.md" > "$dash_empty/docs/metrics.md"
    rc=0
    sh "$dash_backbone" --repo "$dash_empty" --out-dir "$dash_empty/out" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] || die "dashboard-backbone sub-check: expected exit 3 on a self-instrumentation-only doc, got $rc ($flavor/$forge)"
    rm -rf "$dash_empty"
    echo "confirmed: backbone refuses a zero-business-metric repo with exit 3 ($flavor/$forge)"

    rm -rf "$dash_out"
    echo "confirmed: dashboard-backbone sub-check PASSED ($flavor/$forge)"
  fi
fi

echo "$prog: PASS — $flavor/$forge scaffold + build + check green"
