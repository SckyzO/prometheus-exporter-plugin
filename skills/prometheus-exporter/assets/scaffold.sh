#!/bin/sh
# scaffold.sh — dependency-free @@VAR@@ templating engine.
#
# Materializes a template tree (as used under skills/prometheus-exporter/assets/)
# into a target directory: selects one code/<flavor>/ subtree, optionally drops
# the GitHub-only layer, substitutes every @@KEY@@ sentinel in file contents and
# path components, strips the .tmpl suffix, and places the chosen LICENSE.
#
# POSIX sh + sed + grep, plus the common core Unix utilities cp, mv, rm,
# rmdir, mkdir, find, tr, wc, basename, and mktemp. All ship on any Unix-like
# system in practice, but note mktemp specifically is NOT in the POSIX base
# spec (no --dry-run substitute exists in base sh) — this script is "POSIX sh
# scripting style", not "zero-dependency beyond POSIX base utilities". Do not
# add a dependency on bash, Python, Go, or any template engine here — see
# docs/design/2026-07-02-prometheus-exporter-plugin-design.md §5bis.
#
# Usage:
#   scaffold.sh --src <assets-dir> --dst <target-dir> \
#               --flavor <http|cli> --forge <github|none> \
#               [--force] [--var KEY=VALUE ...]
#
# Behavior:
#   - Copies --src to --dst, then strips the copy's own scaffold.sh (plugin
#     tooling, not part of any generated exporter's repo).
#   - Moves code/<flavor>/* into internal/collector/, then removes the whole
#     code/ staging tree (every non-selected flavor along with it). code/ in
#     the source tree is scaffold-only staging for the ONE thing that can't
#     sit at its final repo-relative path directly: multiple flavors (http/,
#     cli/, ...) all resolve to the same destination, internal/collector/, so
#     the source tree needs a directory per flavor to choose between before
#     any of them reaches it. Common templates need no such staging — they
#     already sit at their final repo-relative path under assets/ (e.g.
#     go.mod.tmpl, cmd/<name>/main.go.tmpl, internal/logger/logger.go.tmpl)
#     and are copied straight through by the cp -R above.
#   - When --forge none, drops release/github/ and top-level github/.
#   - Substitutes every @@KEY@@ (content and path components) for each --var.
#   - Strips the .tmpl suffix from file names.
#   - Fills main.go's // @@CLIENT_INIT@@ and // @@COLLECTOR_REGISTRY@@
#     markers from the selected flavor's internal/collector/wiring/
#     {client_init.frag,registry.frag}, if it shipped any, then removes that
#     staging directory. The marker comments themselves survive the fill
#     (sed inserts after them, never replacing them) so /add-collector can
#     reuse the same markers later to insert more collectors.
#   - Places the licenses/LICENSE-<license, lowercased>.txt as LICENSE, then
#     discards the unused alternatives.
#   - Fails loudly (exit 3) if any @@...@@ sentinel survives, EXCEPT the two
#     named structural markers in main.go (@@CLIENT_INIT@@,
#     @@COLLECTOR_REGISTRY@@) — those are not --var data placeholders, and
#     the wiring-marker fill above deliberately preserves them, so their
#     survival to this point is expected, not a forgotten substitution.
#   - Refuses a non-empty --dst unless --force.
set -eu

prog=$(basename "$0")

usage() {
  cat <<EOF >&2
Usage: $prog --src <assets-dir> --dst <target-dir> --flavor <http|cli> --forge <github|none> [--force] [--var KEY=VALUE ...]
EOF
}

die() {
  echo "$prog: error: $1" >&2
  exit 1
}

src=""
dst=""
flavor=""
forge=""
force=no
license_choice=""

# Temp files used to build the substitution script and to materialize `find`
# results before mutating the tree (never mutate while a `find` traversal of
# the same tree could still be in flight — see self-review notes in the task
# report for why this matters).
sedscript=$(mktemp)
pathlist=$(mktemp)
sentinels=$(mktemp)
trap 'rm -f "$sedscript" "$pathlist" "$sentinels"' EXIT

# Escape a literal string for safe use as the REPLACEMENT side of a sed
# s/// command: backslash must be doubled first, then / (our delimiter) and
# & (means "whole match" in a replacement) are backslash-escaped.
sed_escape_repl() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\\&/g' -e 's/\//\\\//g'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)
      [ $# -ge 2 ] || die "--src requires a value"
      src=$2
      shift 2
      ;;
    --dst)
      [ $# -ge 2 ] || die "--dst requires a value"
      dst=$2
      shift 2
      ;;
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
    --force)
      force=yes
      shift
      ;;
    --var)
      [ $# -ge 2 ] || die "--var requires a value"
      kv=$2
      case "$kv" in
        *=*) ;;
        *) die "invalid --var '$kv', expected KEY=VALUE" ;;
      esac
      key=${kv%%=*}
      value=${kv#*=}
      # Validate the WHOLE key, not just its first character: this string is
      # spliced verbatim into a sed script line as `s/@@KEY@@/.../g'`, so a
      # stray `/` (or any other sed-delimiter/metacharacter) anywhere in the
      # key corrupts that generated sed command.
      case "$key" in
        ''|[!A-Z_]*|*[!A-Z0-9_]*) die "invalid --var key '$key', expected an uppercase identifier (A-Z, 0-9, _ only)" ;;
      esac
      if [ "$(printf '%s' "$value" | wc -l)" -ne 0 ]; then
        die "invalid --var value for key '$key': embedded newline not allowed"
      fi
      escaped=$(sed_escape_repl "$value")
      printf 's/@@%s@@/%s/g\n' "$key" "$escaped" >> "$sedscript"
      if [ "$key" = LICENSE ]; then
        license_choice=$value
      fi
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

[ -n "$src" ] || die "--src is required"
[ -n "$dst" ] || die "--dst is required"
[ -n "$flavor" ] || die "--flavor is required"
[ -n "$forge" ] || die "--forge is required"
[ -d "$src" ] || die "--src directory does not exist: $src"

case "$forge" in
  github|none) ;;
  *) die "invalid --forge '$forge', expected 'github' or 'none'" ;;
esac

# Reject any --flavor that is not a single path component. Below, $flavor is
# spliced verbatim into real filesystem paths against both $src and $dst
# (code/$flavor). Validating it only by "does this path exist" (as opposed to
# by shape) lets a value like '../../x' walk out of the intended code/
# subtree entirely: if some sibling directory happens to exist at that
# resolved location, the flavor gets accepted as "valid", and the later
# move step then mv's that directory's contents into $dst/internal/collector/
# and rm -rf's the code/ tree afterward — i.e. arbitrary-directory
# exfiltration into the generated output plus arbitrary-directory deletion,
# both outside the --dst sandbox. A single path component can never do that.
case "$flavor" in
  ''|.|*/*|*..*) die "invalid --flavor: must be a single path component" ;;
esac

if [ -d "$src/code" ] && [ ! -d "$src/code/$flavor" ]; then
  avail=""
  for d in "$src"/code/*/; do
    [ -d "$d" ] || continue
    avail="$avail $(basename "$d")"
  done
  die "unknown --flavor '$flavor'; available:$avail"
fi

# Refuse a non-empty --dst unless --force. Checked without relying on
# `ls -A` or `find -mindepth` (both are common but non-POSIX extensions);
# this glob trio matches regular entries, dotfiles, and `..?*`-style names
# while skipping `.`/`..` themselves.
dst_has_entries() {
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      return 0
    fi
  done
  return 1
}

if [ -d "$dst" ] && [ "$force" != yes ] && dst_has_entries "$dst"; then
  die "destination '$dst' already exists and is not empty (use --force to proceed anyway)"
fi

mkdir -p "$dst"

# Copy the template tree verbatim.
cp -R "$src/." "$dst/"

# scaffold.sh itself ships alongside the templates under --src (so it can be
# invoked as skills/prometheus-exporter/assets/scaffold.sh) but is a
# plugin-tooling file, not part of any generated exporter's repo — strip the
# copy the cp -R above just made. rm -f on a path that doesn't exist (e.g. a
# test fixture --src with no scaffold.sh of its own) is a silent no-op.
rm -f "$dst/scaffold.sh"

# Flavor selection: move the chosen flavor's files into internal/collector/
# (their real destination), then drop the whole code/ staging tree — this
# removes every non-selected flavor in the same step, along with the
# selected flavor's own, now-emptied directory. Guarded on the selected
# flavor actually existing in $src (e.g. no code/ at all yet, or a flavor
# with no files of its own): rm -rf on a path that doesn't exist is a silent
# no-op, so the final rm -rf below is safe either way.
if [ -d "$dst/code/$flavor" ]; then
  mkdir -p "$dst/internal/collector"
  for entry in "$dst/code/$flavor"/* "$dst/code/$flavor"/.[!.]* "$dst/code/$flavor"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      mv "$entry" "$dst/internal/collector/"
    fi
  done
fi
rm -rf "$dst/code"

# Forge selection: drop GitHub-only directories when the user opts out.
# rm -rf on a path that doesn't exist (e.g. no release/ yet) is a silent no-op.
if [ "$forge" = none ]; then
  rm -rf "$dst/release/github" "$dst/github"
fi

# Substitute @@KEY@@ sentinels in file contents. Materialize the file list
# first so every rewrite operates on a snapshot rather than a live traversal.
find "$dst" -type f -print > "$pathlist"
while IFS= read -r file; do
  sed -f "$sedscript" "$file" > "$file.scaffoldtmp"
  mv "$file.scaffoldtmp" "$file"
done < "$pathlist"

# Rename path components containing @@KEY@@ sentinels. -depth lists a
# directory's contents before the directory itself (post-order), and each
# rename only ever touches the entry's own basename (never a full multi
# segment path), so a parent is only renamed once every descendant already
# has its final name — no rename ever targets a not-yet-existing directory.
find "$dst" -depth -print > "$pathlist"
while IFS= read -r path; do
  case "$path" in
    *@@*)
      base=${path##*/}
      dir=${path%/*}
      newbase=$(printf '%s\n' "$base" | sed -f "$sedscript")
      if [ "$newbase" != "$base" ]; then
        mv "$path" "$dir/$newbase"
      fi
      ;;
  esac
done < "$pathlist"

# Strip the .tmpl suffix.
find "$dst" -type f -name '*.tmpl' -print > "$pathlist"
while IFS= read -r file; do
  mv "$file" "${file%.tmpl}"
done < "$pathlist"

# Flavor wiring-marker injection: fill main.go's two structural markers
# (// @@CLIENT_INIT@@, // @@COLLECTOR_REGISTRY@@ — defined by Task 4's
# main.go.tmpl) with the selected flavor's wiring snippets, if it shipped
# any. Flavor snippets stage under code/<flavor>/wiring/{client_init.frag,
# registry.frag} (mirror-layout, exactly like every other flavor file) and so
# land at internal/collector/wiring/ after the flavor-selection move earlier
# in this script. By this point they are also fully @@KEY@@-substituted,
# since the content-substitution pass above runs over every file under $dst
# regardless of extension, and path-renamed/.tmpl-stripped, since it runs
# after both of those steps, so cmd/*/main.go already sits at its final path.
#
# This is a hardcoded, fixed pair (frag basename -> marker name), not a
# discovered or growing registry, mirroring this same script's own
# --forge github|none precedent. sed's `r` command inserts the frag file's
# content immediately AFTER the matched marker line without consuming it, so
# the marker comment itself survives verbatim in the output — deliberate, so
# /add-collector can find and reuse the same marker later to insert
# additional collectors. That is also why the residual-sentinel guard below
# still needs (and already has) its CLIENT_INIT/COLLECTOR_REGISTRY exemption
# after this step runs, not just before it.
if [ -d "$dst/internal/collector/wiring" ]; then
  mainfile=""
  for f in "$dst"/cmd/*/main.go; do
    [ -f "$f" ] || continue
    [ -z "$mainfile" ] || die "expected exactly one cmd/*/main.go for flavor-wiring injection, found more than one"
    mainfile=$f
  done
  [ -n "$mainfile" ] || die "flavor shipped internal/collector/wiring/ snippets but no cmd/*/main.go was found to inject them into"

  # Both sed addresses below are anchored to match ONLY a line that (modulo
  # surrounding blank/tab) consists solely of the marker comment, e.g.
  # `\t// @@CLIENT_INIT@@`. This is deliberate, not defensive-for-its-own-
  # sake: register()'s own doc comment in main.go.tmpl prose-mentions
  # `// @@COLLECTOR_REGISTRY@@` inside a sentence ("...marker in main()
  # below.") to point readers at the real marker. An unanchored
  # `/@@COLLECTOR_REGISTRY@@/` address matches that prose line too and
  # splices executable Go statements into the middle of a comment block,
  # which breaks the build with "non-declaration statement outside function
  # body" — caught empirically while implementing this, not a hypothetical.
  if [ -f "$dst/internal/collector/wiring/client_init.frag" ]; then
    grep -q '^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$' "$mainfile" || die "$mainfile has no standalone // @@CLIENT_INIT@@ marker line to inject into"
    sed -e '\|^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$|r '"$dst"'/internal/collector/wiring/client_init.frag' "$mainfile" > "$mainfile.scaffoldtmp"
    mv "$mainfile.scaffoldtmp" "$mainfile"
  fi
  if [ -f "$dst/internal/collector/wiring/registry.frag" ]; then
    grep -q '^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$' "$mainfile" || die "$mainfile has no standalone // @@COLLECTOR_REGISTRY@@ marker line to inject into"
    sed -e '\|^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$|r '"$dst"'/internal/collector/wiring/registry.frag' "$mainfile" > "$mainfile.scaffoldtmp"
    mv "$mainfile.scaffoldtmp" "$mainfile"
  fi

  # wiring/ is scaffold-only staging, like licenses/ below — it must never
  # ship in the generated repo now that its content has been spliced into
  # main.go above.
  rm -rf "$dst/internal/collector/wiring"
fi

# Place the chosen LICENSE, then discard the unused alternatives — the
# licenses/ menu is scaffold-only content and never ships in the generated
# repo, whether or not a license was actually selected. A LICENSE var that
# doesn't match any available file (typo, e.g. "Apache2.0") must fail loudly:
# silently skipping the mv and then unconditionally rm -rf'ing licenses/
# anyway would ship the generated repo with NO license file and no error.
if [ -d "$dst/licenses" ]; then
  if [ -n "$license_choice" ]; then
    lower=$(printf '%s' "$license_choice" | tr '[:upper:]' '[:lower:]')
    if [ -f "$dst/licenses/LICENSE-$lower.txt" ]; then
      mv "$dst/licenses/LICENSE-$lower.txt" "$dst/LICENSE"
    else
      avail=""
      for f in "$dst"/licenses/LICENSE-*.txt; do
        [ -f "$f" ] || continue
        b=${f##*/}
        b=${b#LICENSE-}
        b=${b%.txt}
        avail="$avail $b"
      done
      die "unknown --var LICENSE='$license_choice'; available:$avail"
    fi
  fi
  rm -rf "$dst/licenses"
fi

# Fail loudly if any @@VAR@@ sentinel survives substitution. grep's exit
# status is 0 (match found), 1 (no match, clean), or 2+ (the scan itself
# failed, e.g. a read error) — treating "not 0" as a blanket "clean" (as a
# plain `if grep ...; then` does) silently turns a failed scan into a false
# success. Capture the real code and branch on all three cases explicitly.
grep_rc=0
grep -rn '@@[A-Z_]*@@' "$dst" > "$sentinels" || grep_rc=$?
case "$grep_rc" in
  0|1) ;;
  *) die "residual-sentinel scan of $dst failed (grep exit $grep_rc)" ;;
esac

# main.go's two structural markers (@@CLIENT_INIT@@, @@COLLECTOR_REGISTRY@@)
# are deliberately left as literal comments for a later flavor-specific
# scaffold.sh step to replace — they are not --var data placeholders, so
# their survival is expected, not a forgotten substitution. Filter exactly
# these two named sentinels out before judging the scan; anything else that
# matches the broad @@[A-Z_]*@@ shape still fails loudly below, same as
# before. (A hardcoded pair, not a discovered list, mirrors --forge's own
# hardcoded github|none: a small, deliberately fixed set, not a growing
# registry that would justify discovery.) Same explicit-exit-code discipline
# as the scan above, even though $sentinels is a script-written temp file
# (not a traversal of arbitrary --dst content) and so is a far less likely
# source of a genuine grep-internal failure.
# Line-grained exception: grep -v drops whole physical lines, so a forgotten
# @@FOO@@ sharing a line with one of the two markers would be swallowed too.
# Fine today because each marker sits alone on its own line in main.go.
filtered_rc=0
grep -v -E '@@(CLIENT_INIT|COLLECTOR_REGISTRY)@@' "$sentinels" > "$pathlist" || filtered_rc=$?
case "$filtered_rc" in
  0)
    echo "$prog: error: residual @@VAR@@ sentinel(s) left in $dst" >&2
    cat "$pathlist" >&2
    exit 3
    ;;
  1) ;;
  *) die "residual-sentinel filter of $dst failed (grep exit $filtered_rc)" ;;
esac

echo "scaffolded $dst"
