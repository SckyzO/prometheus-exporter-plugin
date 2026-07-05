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
#   test/golden-smoke.sh --flavor <http|cli> --forge <github|none>
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
# --all (Task 22) runs all 4 matrix cells in one invocation - see the
# dispatch block right after argument parsing below for how each cell stays
# isolated from the others' own pass/fail.
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

prog=$(basename "$0")

usage() {
  cat <<EOF >&2
Usage: $prog --flavor <http|cli> --forge <github|none>
       $prog --all
EOF
}

die() {
  echo "$prog: error: $1" >&2
  exit 1
}

flavor=""
forge=""
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
  echo "== golden-smoke.sh --all: running the full matrix {http,cli} x {none,github} =="
  overall_rc=0
  summary=""
  for cell in http-none http-github cli-none cli-github; do
    cell_flavor=${cell%-*}
    cell_forge=${cell#*-}
    echo ""
    echo "=================================================================="
    echo "== matrix cell: $cell_flavor/$cell_forge =="
    echo "=================================================================="
    if sh "$here/$prog" --flavor "$cell_flavor" --forge "$cell_forge"; then
      summary="$summary
  $cell_flavor/$cell_forge: PASS"
    else
      summary="$summary
  $cell_flavor/$cell_forge: FAIL"
      overall_rc=1
    fi
  done
  echo ""
  echo "== golden-smoke.sh --all: matrix summary =="
  printf '%s\n' "$summary"
  if [ "$overall_rc" -ne 0 ]; then
    echo "$prog --all: FAIL - at least one matrix cell failed, see summary above" >&2
  else
    echo "$prog --all: PASS - all 4 matrix cells green"
  fi
  exit "$overall_rc"
fi

work="$root/test/_work/$flavor-$forge"

# Start from a clean slate rather than trusting scaffold.sh's own --force
# (which merges into a pre-existing --dst rather than wiping it): a stale
# internal/collector/testdata/ left behind by a PRIOR run of this same
# combination makes the flavor-selection move step's `mv` fail outright
# ("Directory not empty") on the second run. Real bug hit empirically while
# building this script, not a hypothetical — rm -rf here sidesteps it and
# also happens to be exactly what a trustworthy repeatable smoke test wants
# anyway: no leftover state from a previous run.
rm -rf "$work"

echo "== scaffolding $flavor/$forge into ${work#"$root"/} =="
case "$flavor-$forge" in
  http-none)
    sh "$assets/scaffold.sh" \
      --src "$assets" --dst "$work" \
      --flavor "$flavor" --forge "$forge" --force \
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
      --flavor "$flavor" --forge "$forge" --force \
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
      --flavor http --forge github --force \
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
      --flavor cli --forge github --force \
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
# main.go's two structural markers, `// @@CLIENT_INIT@@` and
# `// @@COLLECTOR_REGISTRY@@`, are deliberately left in place forever (for
# /add-collector to find and reuse later), not data placeholders that a
# --var should have filled — asserting a bare `@@[A-Z_]*@@` with no
# exception here would make this check fail on every single green run.
echo "== no residual @@VAR@@ sentinels in ${work#"$root"/} =="
grep_rc=0
hits=$(command grep -rnI '@@[A-Z_]*@@' "$work" 2>&1) || grep_rc=$?
case "$grep_rc" in
  1) ;; # no match: clean
  0)
    filtered=$(printf '%s\n' "$hits" | grep -v -E '@@(CLIENT_INIT|COLLECTOR_REGISTRY)@@') || true
    if [ -n "$filtered" ]; then
      echo "$prog: error: residual @@VAR@@ sentinel(s) left in $work:" >&2
      echo "$filtered" >&2
      exit 1
    fi
    ;;
  *) die "residual-sentinel scan of $work failed (grep exit $grep_rc): $hits" ;;
esac

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
if command -v docker >/dev/null 2>&1; then
  echo "using docker"
  if ! ( cd "$work" && docker build -f Dockerfile -t "golden-smoke-$flavor-$forge:latest" . ); then
    die "docker build FAILED for $flavor/$forge — see output above"
  fi
  echo "confirmed: docker build PASSED ($flavor/$forge)"
elif command -v podman >/dev/null 2>&1; then
  echo "no docker; using podman"
  if ! ( cd "$work" && podman build -f Dockerfile -t "golden-smoke-$flavor-$forge:latest" . ); then
    die "docker build FAILED (via podman) for $flavor/$forge — see output above"
  fi
  echo "confirmed: docker build PASSED via podman ($flavor/$forge)"
else
  echo "SKIPPING docker build ($flavor/$forge): no docker/podman container engine found — install one to validate Dockerfile locally"
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
if [ "$flavor" = http ] && [ "$forge" = none ]; then
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
fi

echo "$prog: PASS — $flavor/$forge scaffold + build + check green"
