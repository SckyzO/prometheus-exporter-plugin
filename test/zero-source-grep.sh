#!/bin/sh
# zero-source-grep.sh — the plugin's two repo-wide "zero taught-source-leak"
# gates. Lives under test/ (already exempt from SOURCE-GREP itself, alongside
# .git/ and .superpowers/, plus docs/design/ and docs/plans/ filtered after
# the scan — see the exclude list below) specifically
# so that .github/workflows/plugin-ci.yml, which calls this script in CI,
# never has to spell out a denylisted term in its own YAML — it would
# otherwise trip the very gate it's running, the same self-reference problem
# test/golden-smoke.sh's own detector already had to be exempted from (Task
# 7's decision, see CLAUDE.md's Zero-source-mention rule).
#
# Same three-way grep exit-code discipline test/golden-smoke.sh already
# uses: 0 = match found (bad), 1 = no match (clean), 2+ = the scan itself
# failed — never treat "not 0" as a blanket pass. `command grep`, not a bare
# `grep`: some interactive shells alias/wrap grep in ways that mangle -r
# output (see golden-smoke.sh's own header for this exact gotcha).
#
# Usage: test/zero-source-grep.sh
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
prog=$(basename "$0")
cd "$root"

die() {
  echo "$prog: error: $1" >&2
  exit 1
}

# SOURCE-GREP: this plugin's taught knowledge stands on prometheus.io/Go
# authority, never on naming the reference project it was derived from —
# see CLAUDE.md's Zero-source-mention rule. .git/, .superpowers/ and test/
# are excluded from the walk itself.
#
# SOURCE_TERMS is the denylist: the reference project's own name plus the
# concrete systems it monitored, whose names would identify it just as
# surely. docs/design/re-sync.md §1 is the authority for what belongs here;
# add a term whenever a re-sync derives templates from a new reference.
#
# Two rules for adding one, both learned the hard way:
#
#   - It must not appear in any shipped artifact TODAY. Run the term against
#     the tree before adding it, or the gate lands red.
#   - It must be specific enough to survive a substring match. This grep is
#     case-insensitive with NO word boundary, so a short term will collide.
#     "tape" was rejected on exactly that ground: ROADMAP.md legitimately
#     says "tape libraries" about a generic slow device. "ibm" was rejected
#     as three characters that a base64 hash in assets/go.sum can produce by
#     chance at the next dependency bump, even though it is clean today.
#
# Names of PUBLIC Prometheus exporters (node_exporter, snmp_exporter,
# blackbox_exporter, ipmi_exporter, postgres_exporter, sql_exporter...) must
# NEVER go in this list. They are cited on purpose across the references and
# the templates, as ecosystem precedent for a convention this plugin adopts,
# and denylisting one would fail the build on a correct citation.
#
# docs/ is NOT excluded wholesale any more. It used to be, back when it held
# nothing but design and planning history. Now that docs/ also hosts
# user-facing documentation the README links to, a blanket exclude-dir would
# blind this gate to shipped prose, which is exactly what it exists to guard.
# Only docs/design/ and docs/plans/ are exempt, and for the same reason as
# before: they are the maintainer's own working history, never loaded by the
# plugin. They are filtered AFTER the scan rather than by --exclude-dir, for
# the basename reason spelled out below.
#
# .github/ is NOT added to that --exclude-dir list, deliberately: GNU
# grep's --exclude-dir matches by BASENAME ONLY, not by path — proved
# empirically while writing this script (planted a canary word inside
# skills/prometheus-exporter/assets/.github/, the shipped/TAUGHT GitHub-
# workflow templates, then confirmed --exclude-dir=.github hid it too, not
# just this repo's own root .github/). Adding that exclude-dir would blind
# this gate to the one place under .github/ that genuinely needs scanning.
# Instead, root .github/ (this repo's own CI — plugin tooling, never
# shipped/taught, the exact same reasoning that already exempts test/ and
# .superpowers/) is filtered out AFTER the scan, anchored on the leading
# "./" grep emits when searching from ".", so it cannot also match the
# nested, taught .github/ under skills/ (which always shows as
# "./skills/...", never "./.github/...").
SOURCE_TERMS="slurm ts4500 sacct sinfo"
# Single walk over the tree, one alternation, rather than one walk per term.
source_re=$(printf '%s' "$SOURCE_TERMS" | tr ' ' '|')

echo "== SOURCE-GREP ($SOURCE_TERMS absent outside design/plans, test, root-.github) =="
rc=0
hits=$(command grep -rEin "$source_re" . --exclude-dir=.git --exclude-dir=.superpowers --exclude-dir=test 2>&1) || rc=$?
case "$rc" in
  1) echo "SOURCE-GREP: clean" ;;
  0)
    # .claude/settings.local.json is per-machine Claude Code state that git
    # ignores; it records the literal commands a contributor approved, so
    # anyone who ever ran a grep for the detector word has it sitting in
    # there and would trip this gate locally while CI, on a fresh checkout,
    # stayed green. Only that one file is filtered, not .claude/ wholesale:
    # a repository may legitimately TRACK .claude/settings.json (README's
    # "Sharing with a team"), and that one must keep being scanned.
    #
    # Narrow fix. The general problem is that this gate walks the working
    # tree, ignored files included, rather than what git actually tracks.
    filtered=$(printf '%s\n' "$hits" \
      | grep -v -e '^\./\.github/' -e '^\./docs/design/' -e '^\./docs/plans/' \
                -e '^\./\.claude/settings\.local\.json:') || true
    if [ -n "$filtered" ]; then
      echo "$prog: error: SOURCE-GREP found matches (source-project name leaked outside docs/design, docs/plans, test, root-.github):" >&2
      printf '%s\n' "$filtered" >&2
      exit 1
    fi
    echo "SOURCE-GREP: clean (all hits confined to exempt paths: root .github/ CI, docs/design/, docs/plans/ — see header)"
    ;;
  *) die "SOURCE-GREP scan itself failed (grep exit $rc): $hits" ;;
esac

# HANDLE-GREP: blocking (exit 1 on a match, same as SOURCE-GREP above), and
# has been since this script existed. A handle in taught content ships to
# every third party who installs the plugin, which is a real defect, not a
# style nit. Scoped to the taught content
# under skills/ commands/ agents/ only — the maintainer's own real handle
# legitimately appears in .claude-plugin/*.json, LICENSE, README.md, and
# the root CLAUDE.md (exempt by design — see CLAUDE.md's
# Zero-source-mention rule). .github/ was never in this check's path
# list, so no
# basename-collision concern applies here.
echo "== HANDLE-GREP (maintainer handle absent from taught content) =="
rc=0
hits=$(command grep -rin sckyzo skills/ commands/ agents/ 2>&1) || rc=$?
case "$rc" in
  1) echo "HANDLE-GREP: clean" ;;
  0)
    echo "$prog: error: HANDLE-GREP found matches under skills/ commands/ agents/:" >&2
    printf '%s\n' "$hits" >&2
    exit 1
    ;;
  *) die "HANDLE-GREP scan itself failed (grep exit $rc): $hits" ;;
esac

echo "$prog: PASS — SOURCE-GREP and HANDLE-GREP both clean"
