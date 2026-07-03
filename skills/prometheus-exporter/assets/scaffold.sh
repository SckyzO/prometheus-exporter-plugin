#!/bin/sh
# scaffold.sh — dependency-free @@VAR@@ templating engine.
#
# Materializes a template tree (as used under skills/prometheus-exporter/assets/)
# into a target directory: selects one code/<flavor>/ subtree, optionally drops
# the GitHub-only layer, substitutes every @@KEY@@ sentinel in file contents and
# path components, strips the .tmpl suffix, and places the chosen LICENSE.
#
# POSIX sh + sed + grep only. No runtime dependency beyond core Unix utilities
# (cp, mv, rm, mkdir, find, tr) that ship on any Unix-like system. Do not add a
# dependency on bash, Python, Go, or any template engine here — see
# docs/design/2026-07-02-prometheus-exporter-plugin-design.md §5bis.
#
# Usage:
#   scaffold.sh --src <assets-dir> --dst <target-dir> \
#               --flavor <http|cli> --forge <github|none> \
#               [--force] [--var KEY=VALUE ...]
#
# Behavior:
#   - Copies --src to --dst.
#   - Keeps code/common/ and code/<flavor>/, drops other code/<x>/ dirs, then
#     flattens code/<flavor>/* up into code/ (the real cmd/ + internal/collector/
#     destination mapping is layered on top of this in a later scaffold.sh
#     revision, once the real asset tree exists — this generic flatten rule is
#     the stable contract other tasks build on).
#   - When --forge none, drops release/github/ and top-level github/.
#   - Substitutes every @@KEY@@ (content and path components) for each --var.
#   - Strips the .tmpl suffix from file names.
#   - Places the licenses/LICENSE-<license, lowercased>.txt as LICENSE, then
#     discards the unused alternatives.
#   - Fails loudly (exit 3) if any @@...@@ sentinel survives.
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
trap 'rm -f "$sedscript" "$pathlist"' EXIT

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
      case "$key" in
        [A-Z_]*) ;;
        *) die "invalid --var key '$key', expected an uppercase identifier" ;;
      esac
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

if [ -d "$src/code" ] && [ ! -d "$src/code/$flavor" ]; then
  avail=""
  for d in "$src"/code/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    [ "$n" = common ] && continue
    avail="$avail $n"
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

# Flavor selection: keep code/common/ and code/<flavor>/, drop the rest.
if [ -d "$dst/code" ]; then
  for d in "$dst"/code/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    case "$name" in
      common|"$flavor") ;;
      *) rm -rf "$d" ;;
    esac
  done
fi

# Forge selection: drop GitHub-only directories when the user opts out.
# rm -rf on a path that doesn't exist (e.g. no release/ yet) is a silent no-op.
if [ "$forge" = none ]; then
  rm -rf "$dst/release/github" "$dst/github"
fi

# Flatten the selected flavor's files up into code/ (generic Task 3 rule; a
# later revision refines the real cmd/ + internal/collector/ destination
# mapping once the real asset tree exists).
if [ -d "$dst/code/$flavor" ]; then
  for entry in "$dst/code/$flavor"/* "$dst/code/$flavor"/.[!.]* "$dst/code/$flavor"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      mv "$entry" "$dst/code/"
    fi
  done
  rmdir "$dst/code/$flavor"
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

# Place the chosen LICENSE, then discard the unused alternatives — the
# licenses/ menu is scaffold-only content and never ships in the generated
# repo, whether or not a license was actually selected.
if [ -d "$dst/licenses" ]; then
  if [ -n "$license_choice" ]; then
    lower=$(printf '%s' "$license_choice" | tr '[:upper:]' '[:lower:]')
    if [ -f "$dst/licenses/LICENSE-$lower.txt" ]; then
      mv "$dst/licenses/LICENSE-$lower.txt" "$dst/LICENSE"
    fi
  fi
  rm -rf "$dst/licenses"
fi

# Fail loudly if any @@VAR@@ sentinel survives substitution.
if grep -rn '@@[A-Z_]*@@' "$dst"; then
  echo "$prog: error: residual @@VAR@@ sentinel(s) left in $dst" >&2
  exit 3
fi

echo "scaffolded $dst"
