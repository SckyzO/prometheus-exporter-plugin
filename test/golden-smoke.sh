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
#   test/golden-smoke.sh --flavor <http|cli> --forge <github|none> [--target-model <single|multi>]
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
# --target-model <single|multi> (Task 2, multi-target epic) defaults to
# "single" (today's runtime, every cell above is single-target and
# unaffected). "multi" requires --flavor http (mirrors scaffold.sh's own
# restriction) and, beyond the standard build/check/promtool-rules gates
# every cell runs, additionally starts the scaffolded binary and proves
# /probe live: it probes the exporter's own /metrics endpoint as a target and
# checks the response through `promtool check metrics` — see the http-multi
# guarded block below.
#
# --all (Task 22, extended by Task 2) runs all 4 matrix cells PLUS a 5th,
# additional http-multi cell (flavor=http, forge=none, target-model=multi) in
# one invocation - see the dispatch block right after argument parsing below
# for how each cell stays isolated from the others' own pass/fail.
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

usage() {
  cat <<EOF >&2
Usage: $prog --flavor <http|cli> --forge <github|none> [--target-model <single|multi>]
       $prog --all
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# --target-model (Task 2, multi-target epic): defaults to "single" (today's
# runtime, unchanged) — mirrors scaffold.sh's own default and validation
# exactly, including the http-only restriction (there is no cli multi-target).
case "$target_model" in
  single|multi) ;;
  *) die "invalid --target-model '$target_model'; must be single or multi" ;;
esac
if [ "$target_model" = multi ] && [ -n "$flavor" ] && [ "$flavor" != http ]; then
  die "--target-model multi requires --flavor http (no cli multi-target)"
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
  echo "== golden-smoke.sh --all: running the full matrix {http,cli} x {none,github}, plus the http-multi cell =="
  overall_rc=0
  summary=""
  # http-multi (Task 2, multi-target epic) is a FIFTH, additional cell, not a
  # full {single,multi} x {http,cli} x {none,github} cross product: multi
  # requires --flavor http (no cli multi-target — same restriction validated
  # above), so it is special-cased here rather than folded into the generic
  # cell%-*/cell#*- parsing below, which assumes exactly one hyphen.
  for cell in http-none http-github cli-none cli-github http-multi; do
    case "$cell" in
      http-multi)
        cell_flavor=http
        cell_forge=none
        cell_extra="--target-model multi"
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
    echo "$prog --all: PASS - all 5 cells green"
  fi
  exit "$overall_rc"
fi

# work dir key: only suffixed with -multi when target_model=multi, so the
# existing 4 cells' work dirs (test/_work/http-none, etc.) are byte-identical
# to before this axis existed — target_model=single is this script's own
# default too, exactly mirroring scaffold.sh's own default.
workkey="$flavor-$forge"
[ "$target_model" = multi ] && workkey="$workkey-multi"
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
      --var LICENSE=apache-2.0
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
      --var LICENSE=apache-2.0
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
      --var LICENSE=apache-2.0
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
      --var LICENSE=apache-2.0
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
# main.go's structural markers — `// @@CLIENT_INIT@@` and
# `// @@COLLECTOR_REGISTRY@@` (single-target), `// @@PROBE_FACTORIES@@`
# (multi-target) — are deliberately left in place forever (for /add-collector
# to find and reuse later), not data placeholders that a --var should have
# filled — asserting a bare `@@[A-Z_]*@@` with no exception here would make
# this check fail on every single green run.
echo "== no residual @@VAR@@ sentinels in ${work#"$root"/} =="
grep_rc=0
hits=$(command grep -rnI '@@[A-Z_]*@@' "$work" 2>&1) || grep_rc=$?
case "$grep_rc" in
  1) ;; # no match: clean
  0)
    filtered=$(printf '%s\n' "$hits" | grep -v -E '@@(CLIENT_INIT|COLLECTOR_REGISTRY|PROBE_FACTORIES)@@') || true
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
# Skipped for target_model=multi (Task 2, multi-target epic): this sub-check
# splices at the // @@CLIENT_INIT@@ / // @@COLLECTOR_REGISTRY@@ markers,
# which a multi-target main.go doesn't carry at all (it only has its own
# // @@PROBE_FACTORIES@@ marker) — /add-collector itself stays single-only
# for this epic (documented follow-up for multi, see Task 3), so there is
# nothing for this mechanical sub-check to exercise here.
if [ "$flavor" = http ] && [ "$forge" = none ] && [ "$target_model" != multi ]; then
  echo "== mechanical /add-collector sub-check ($flavor/$forge): scaffolded templates still support adding a 2nd collector =="
  addc_tmpl="$assets/code/http/collector.go.tmpl"
  addc_client_frag="$assets/code/http/wiring/client_init.frag"
  addc_registry_frag="$assets/code/http/wiring/registry.frag"
  addc_main="$work/cmd/demo_exporter/main.go"
  addc_metrics_doc="$work/docs/metrics.md"
  addc_qclient="$work/internal/collector/.addc_client_init.frag.tmp"
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

  # 2. Build queue's own client_init/registry fragments (same rename, same
  # order) and splice them at the SAME two markers scaffold.sh itself used
  # — the markers survive scaffolding verbatim for exactly this reuse (see
  # scaffold.sh's own comment on why /add-collector needs them intact).
  # registry.frag also carries the http_client_requests self-instrumentation
  # registration (shared, already wired once by scaffold.sh) — filtered out
  # of this copy so it is not registered a second time.
  sed -e 's/example/queue/g' -e 's/Example/Queue/g' "$addc_client_frag" \
    | sed -e 's/@@DATA_SOURCE@@/http:\/\/localhost:9999/g' > "$addc_qclient"
  sed -e 's/example/queue/g' -e 's/Example/Queue/g' "$addc_registry_frag" \
    | grep -v 'register("http_client_requests"' > "$addc_qregistry"

  grep -q '^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$' "$addc_main" || die "add-collector sub-check: no standalone // @@CLIENT_INIT@@ marker in $addc_main"
  sed -e '\|^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$|r '"$addc_qclient" "$addc_main" > "$addc_main.tmp" && mv "$addc_main.tmp" "$addc_main"
  grep -q '^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$' "$addc_main" || die "add-collector sub-check: no standalone // @@COLLECTOR_REGISTRY@@ marker in $addc_main"
  sed -e '\|^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$|r '"$addc_qregistry" "$addc_main" > "$addc_main.tmp" && mv "$addc_main.tmp" "$addc_main"
  rm -f "$addc_qclient" "$addc_qregistry"

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

  # Background-refresh collector epic (docs/plans/2026-07-06-background-
  # refresh-collector.md, Task 7): extend this SAME http/none /add-collector
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

  # 2. Flags under // @@CLIENT_INIT@@ (target, timeout, interval) — the
  # SAME marker the queue sub-check already injected into above; the marker
  # comment itself survives every previous injection (see scaffold.sh's own
  # comment on why), so it is still there to reuse.
  cat > "$addc_bg_client" <<'EOF'
	tapeTarget := kingpin.Flag("collector.tape.target", "Base URL the tape collector scrapes.").Default("http://localhost:9999").String()
	tapeTimeout := kingpin.Flag("collector.tape.timeout", "Per-request timeout for the tape collector.").Default("5s").Duration()
	tapeInterval := kingpin.Flag("collector.tape.interval", "Refresh interval for the tape collector.").Default("5m").Duration()
EOF
  grep -q '^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$' "$addc_bg_main" || die "add-collector background sub-check: no standalone // @@CLIENT_INIT@@ marker in $addc_bg_main"
  sed -e '\|^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$|r '"$addc_bg_client" "$addc_bg_main" > "$addc_bg_main.tmp" && mv "$addc_bg_main.tmp" "$addc_bg_main"
  rm -f "$addc_bg_client"

  # 3. Registry snippet under // @@COLLECTOR_REGISTRY@@: eager-construct +
  # Start(ctx) + append(backgroundCollectors, ...) ALL INSIDE the
  # register(...) closure (see commands/add-collector.md §5's own note on
  # why: this splice point sits BEFORE kingpin.Parse() in main.go, so log
  # is still nil and every flag pointer still holds its zero value there —
  # the closure defers all of this to the registry loop later in main(),
  # which runs after Parse() and after log is assigned).
  cat > "$addc_bg_registry" <<'EOF'
	register("tape", func() prometheus.Collector {
		tapeColl := collector.NewTapeCollector(log, collector.NewClient(*tapeTarget, *tapeTimeout), *tapeInterval)
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

  # 4. docs/metrics.md row, including the freshness gauge — the metric
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
# docs/plans/2026-07-07-generate-dashboard.md): the /generate-dashboard command
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
