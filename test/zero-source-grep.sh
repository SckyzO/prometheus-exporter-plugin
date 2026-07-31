#!/bin/sh
# zero-source-grep.sh — the plugin's two repo-wide "zero taught-source-leak"
# gates. Lives under test/ (already exempt from SLURM-GREP itself, alongside
# docs/, .git/, and .superpowers/ — see the exclude list below) specifically
# so that .github/workflows/plugin-ci.yml, which calls this script in CI,
# never has to spell out the literal word "slurm" in its own YAML — it would
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

# SLURM-GREP: this plugin's taught knowledge stands on prometheus.io/Go
# authority, never on naming the reference project it was derived from —
# see CLAUDE.md's Zero-source-mention rule. .git/, .superpowers/ and test/
# are excluded from the walk itself.
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
echo "== SLURM-GREP (source-project name absent outside design/plans, test, root-.github) =="
rc=0
hits=$(command grep -rin slurm . --exclude-dir=.git --exclude-dir=.superpowers --exclude-dir=test 2>&1) || rc=$?
case "$rc" in
  1) echo "SLURM-GREP: clean" ;;
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
      echo "$prog: error: SLURM-GREP found matches (source-project name leaked outside docs/design, docs/plans, test, root-.github):" >&2
      printf '%s\n' "$filtered" >&2
      exit 1
    fi
    echo "SLURM-GREP: clean (all hits confined to exempt paths: root .github/ CI, docs/design/, docs/plans/ — see header)"
    ;;
  *) die "SLURM-GREP scan itself failed (grep exit $rc): $hits" ;;
esac

# HANDLE-GREP: blocking (exit 1 on a match, same as SLURM-GREP above), and
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

echo "$prog: PASS — SLURM-GREP and HANDLE-GREP both clean"
