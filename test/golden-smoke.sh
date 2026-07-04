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
#
# v0.1 (Task 7) wires real values for exactly one combination: --flavor http
# --forge none. The case switch below is deliberately structured so Tasks
# 9/14/22 can add a branch per additional flavor/forge combination later
# (mirroring scaffold.sh's own --forge github|none: a small, explicit,
# hardcoded set, not a discovered/growing registry) — an unwired combination
# fails loudly with a clear message instead of guessing at plausible-looking
# values, which is what "logs any step it skips explicitly" (see the header
# of each phase below) means for this script's own scope, as opposed to a
# runtime environment gap (e.g. a missing optional tool), which is instead
# handled inside the Makefile itself (actionlint/zizmor skip gracefully when
# .github/workflows/ is absent — see Makefile.tmpl) and simply surfaces here
# because this script never redirects make's own stdout/stderr away from
# the caller's terminal.
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
EOF
}

die() {
  echo "$prog: error: $1" >&2
  exit 1
}

flavor=""
forge=""
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$flavor" ] || die "--flavor is required"
[ -n "$forge" ] || die "--forge is required"

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
  *)
    die "no golden @@VAR@@ values wired yet for --flavor $flavor --forge $forge (http+none and cli+none supported; see Tasks 14/22 for github)"
    ;;
esac

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

echo "$prog: PASS — $flavor/$forge scaffold + build + check green"
