#!/bin/sh
# zero-source-grep.sh — the plugin's two repo-wide "zero taught-source-leak"
# gates. Lives under test/ (already exempt from SLURM-GREP itself, alongside
# docs/, .git/, and .superpowers/ — see the exclude list below) specifically
# so that .github/workflows/plugin-ci.yml, which calls this script in CI,
# never has to spell out the literal word "slurm" in its own YAML — it would
# otherwise trip the very gate it's running, the same self-reference problem
# test/golden-smoke.sh's own detector already had to be exempted from (Task
# 7's decision, see CLAUDE.md's Global Constraints).
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
# see CLAUDE.md's Global Constraints. docs/, .git/, .superpowers/, and
# test/ are excluded from the walk itself (established Task 7 exclude-dir
# list, unchanged here).
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
echo "== SLURM-GREP (source-project name absent outside docs/test/root-.github) =="
rc=0
hits=$(command grep -rin slurm . --exclude-dir=docs --exclude-dir=.git --exclude-dir=.superpowers --exclude-dir=test 2>&1) || rc=$?
case "$rc" in
  1) echo "SLURM-GREP: clean" ;;
  0)
    filtered=$(printf '%s\n' "$hits" | grep -v '^\./\.github/') || true
    if [ -n "$filtered" ]; then
      echo "$prog: error: SLURM-GREP found matches (source-project name leaked outside docs/test/root-.github):" >&2
      printf '%s\n' "$filtered" >&2
      exit 1
    fi
    echo "SLURM-GREP: clean (all hits confined to this repo's own root .github/ CI, exempt — see header)"
    ;;
  *) die "SLURM-GREP scan itself failed (grep exit $rc): $hits" ;;
esac

# HANDLE-GREP: non-blocking-by-design hygiene, scoped to the taught content
# under skills/ commands/ agents/ only — the maintainer's own real handle
# legitimately appears in .claude-plugin/*.json, LICENSE, README.md, and
# the root CLAUDE.md (exempt by design — see CLAUDE.md's Global
# Constraints). .github/ was never in this check's path list, so no
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
