#!/bin/sh
# scaffold.sh: dependency-free @@VAR@@ templating engine.
#
# Materializes a template tree (as used under skills/prometheus-exporter/assets/)
# into a target directory: selects one code/<flavor>/ subtree, selects one
# mains/<target-model>/ entry point, optionally drops the GitHub-only layer,
# substitutes every @@KEY@@ sentinel in file contents and path components,
# strips the .tmpl suffix, and places the chosen LICENSE.
#
# POSIX sh + sed + grep, plus the common core Unix utilities cp, mv, rm,
# rmdir, mkdir, find, tr, wc, basename, and mktemp. All ship on any Unix-like
# system in practice, but note mktemp specifically is NOT in the POSIX base
# spec (no --dry-run substitute exists in base sh). This script is "POSIX sh
# scripting style", not "zero-dependency beyond POSIX base utilities". Do not
# add a dependency on bash, Python, Go, or any template engine here: see
# docs/design/2026-07-02-prometheus-exporter-plugin-design.md §5bis.
#
# Usage:
#   scaffold.sh --src <assets-dir> --dst <target-dir> \
#               --flavor <http|cli> --forge <github|none> \
#               [--target-model <single|multi|multi-instance>] \
#               [--instance-label <name>] \
#               [--force] [--var KEY=VALUE ...]
#
# --target-model defaults to "single" (today's runtime, unchanged). "multi"
# requires --flavor http (there is no cli multi-target) and ships a
# /probe?target=… handler (internal/probe/) instead of a fixed-target
# collector registry. "multi-instance" also requires --flavor http and ships
# internal/instance/ instead: one process watches a fixed list of machines
# declared in --config.file, each refreshed by its own background poller, all
# served through a single /metrics. --instance-label (default "target") names
# the identifying label applied per instance; only multi-instance reads it.
# See mains/single/, mains/multi/, and mains/multi-instance/.
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
#     any of them reaches it. Common templates need no such staging: they
#     already sit at their final repo-relative path under assets/ (e.g.
#     go.mod.tmpl, cmd/<name>/main.go.tmpl, internal/logger/logger.go.tmpl)
#     and are copied straight through by the cp -R above.
#   - When --forge none, drops .github/ (the whole GitHub layer: workflows,
#     dependabot.yml, CODEOWNERS, issue/PR templates). Mirror-layout means
#     that is the ONLY forge-conditional directory: everything else under
#     assets/ (including .goreleaser*.yaml) already sits at its final,
#     always-shipped repo-relative path and is untouched by --forge.
#   - Substitutes every @@KEY@@ (content and path components) for each --var.
#   - Strips the .tmpl suffix from file names.
#   - Selects mains/<target-model>/main.go.tmpl as the one cmd/<name>/main.go,
#     then removes the whole mains/ staging tree; drops internal/probe/ unless
#     --target-model multi, drops internal/instance/ unless --target-model
#     multi-instance, and drops internal/reload/ unless --target-model multi
#     or multi-instance.
#   - Fills main.go's structural markers: // @@CLIENT_INIT@@,
#     // @@CLIENT_BUILD@@ and // @@COLLECTOR_REGISTRY@@ (single-target),
#     // @@PROBE_FACTORIES@@ (multi-target), // @@INSTANCE_FACTORIES@@
#     (multi-instance), from the selected flavor's
#     internal/collector/wiring/{client_init.frag,client_build.frag,
#     registry.frag,probe_factory.frag,instance_factory.frag}, whichever the
#     chosen main model actually carries a marker for, then removes that
#     staging directory.
#     The marker comments themselves survive the fill (sed inserts after
#     them, never replacing them) so /add-collector can reuse the same
#     markers later to insert more collectors.
#   - Places the licenses/LICENSE-<license, lowercased>.txt as LICENSE, then
#     discards the unused alternatives.
#   - Fails loudly (exit 3) if any @@...@@ sentinel survives, EXCEPT the
#     named structural markers in main.go (@@CLIENT_INIT@@, @@CLIENT_BUILD@@,
#     @@COLLECTOR_REGISTRY@@, @@PROBE_FACTORIES@@, @@INSTANCE_FACTORIES@@):
#     those are not --var data placeholders, and the wiring-marker fill above
#     deliberately preserves them, so their survival to this point is
#     expected, not a forgotten substitution.
#   - Refuses a non-empty --dst unless --force.
set -eu

prog=$(basename "$0")

usage() {
  cat <<EOF >&2
Usage: $prog --src <assets-dir> --dst <target-dir> --flavor <http|cli> --forge <github|none> [--target-model <single|multi|multi-instance>] [--instance-label <name>] [--force] [--var KEY=VALUE ...]
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
target_model="single"
instance_label="target"
force=no
license_choice=""

# Temp files used to build the substitution script and to materialize `find`
# results before mutating the tree (never mutate while a `find` traversal of
# the same tree could still be in flight: see self-review notes in the task
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
    --target-model)
      [ $# -ge 2 ] || die "--target-model requires a value"
      target_model=$2
      shift 2
      ;;
    --instance-label)
      [ $# -ge 2 ] || die "--instance-label requires a value"
      instance_label=$2
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

case "$target_model" in
  single|multi|multi-instance) ;;
  *) die "invalid --target-model '$target_model'; must be single, multi, or multi-instance" ;;
esac
if { [ "$target_model" = multi ] || [ "$target_model" = multi-instance ]; } && [ "$flavor" != http ]; then
  die "--target-model $target_model requires --flavor http (no cli multi-target)"
fi

# Validate the instance label (a Prometheus label name) and register its
# substitution. It appears only in the multi-instance main; the sed rule is a
# harmless no-op for every other model.
case "$instance_label" in
  ''|[!a-zA-Z_]*|*[!a-zA-Z0-9_]*) die "invalid --instance-label '$instance_label'; must be a valid Prometheus label name (letters, digits, underscore; not starting with a digit)" ;;
esac
printf 's/@@INSTANCE_LABEL@@/%s/g\n' "$(sed_escape_repl "$instance_label")" >> "$sedscript"

# Reject any --flavor that is not a single path component. Below, $flavor is
# spliced verbatim into real filesystem paths against both $src and $dst
# (code/$flavor). Validating it only by "does this path exist" (as opposed to
# by shape) lets a value like '../../x' walk out of the intended code/
# subtree entirely: if some sibling directory happens to exist at that
# resolved location, the flavor gets accepted as "valid", and the later
# move step then mv's that directory's contents into $dst/internal/collector/
# and rm -rf's the code/ tree afterward, i.e. arbitrary-directory
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
# plugin-tooling file, not part of any generated exporter's repo. Strip the
# copy the cp -R above just made. rm -f on a path that doesn't exist (e.g. a
# test fixture --src with no scaffold.sh of its own) is a silent no-op.
rm -f "$dst/scaffold.sh"

# Flavor selection: move the chosen flavor's files into internal/collector/
# (their real destination), then drop the whole code/ staging tree: this
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

# Main entry-point model selection (single|multi), mirroring flavor selection
# above: place the chosen main.go into the one cmd/<name>/ dir (which already
# ships security.go), then drop the whole mains/ staging tree.
if [ -d "$dst/mains" ]; then
  [ -f "$dst/mains/$target_model/main.go.tmpl" ] || die "no main.go template for --target-model '$target_model'"
  cmddir=""
  for d in "$dst"/cmd/*/; do
    [ -d "$d" ] || continue
    [ -z "$cmddir" ] || die "expected exactly one cmd/*/ dir, found more than one"
    cmddir=$d
  done
  [ -n "$cmddir" ] || die "no cmd/*/ directory to place the selected main.go into"
  mv "$dst/mains/$target_model/main.go.tmpl" "${cmddir}main.go.tmpl"
fi
rm -rf "$dst/mains"

# internal/probe/ is multi-only: a single-target scaffold never ships it.
if [ "$target_model" != multi ]; then
  rm -rf "$dst/internal/probe"
fi

# internal/instance/ is multi-instance-only: no other model ships it.
if [ "$target_model" != multi-instance ]; then
  rm -rf "$dst/internal/instance"
fi

# internal/reload/ is for the configuration-file-driven models only. A
# single-target scaffold's file holds "flags:" (which cannot be reloaded, see
# internal/config) and "http_client_config:" (whose file-backed secrets and TLS
# material prometheus/common already re-reads per request), so there would be
# nothing left for a reload to do there.
if [ "$target_model" != multi ] && [ "$target_model" != multi-instance ]; then
  rm -rf "$dst/internal/reload"
fi

# client_model is a direct dependency for a multi-target OR multi-instance
# scaffold, never for single: internal/probe (multi only) and
# internal/reload's own test file (multi AND multi-instance, see
# internal/reload/reload_test.go.tmpl's "dto" import) both import
# "github.com/prometheus/client_model/go" directly, but nothing under a
# single-target tree does (client_golang itself needs it only transitively).
# go.mod.tmpl therefore ships client_model in the INDIRECT require() block
# unconditionally, and this reclassifies it to the direct block here, at
# scaffold time, for --target-model multi OR multi-instance, deliberately
# NOT a static go.mod.tmpl edit, which would leave a single-target
# scaffold's go.mod direct/indirect split permanently out of sync with what
# `go mod tidy` would produce (verified empirically: `go mod tidy`
# immediately demotes it back to indirect on a single-target tree, since
# nothing there imports it directly), a real regression against this plan's
# own single-target-tree-is-unchanged constraint. Anchored on the module
# path only (no version pin) for BOTH the client_golang insertion point and
# the client_model line being deleted: the version spliced into the direct
# block is READ OFF that deleted indirect line at scaffold time, never
# hardcoded here, so a future Dependabot bump of client_model's version in
# go.mod.tmpl can't silently desync the inserted line from the deleted one.
# (A prior version of this block hardcoded the version on both sides: a
# go.mod.tmpl bump would then leave the version-pinned delete regex no
# longer matching the now-bumped indirect line (so it survived) while the
# insert still fired with the stale hardcoded version, landing client_model
# TWICE with two conflicting versions and breaking `go build`/`go mod tidy`
# for multi/multi-instance scaffolds only.)
if { [ "$target_model" = multi ] || [ "$target_model" = multi-instance ]; } && [ -f "$dst/go.mod.tmpl" ]; then
  # [[:blank:]]* here, not a literal tab: unlike the sed addresses below (GNU
  # sed treats \t as tab, verified empirically), GNU grep's default (non -P)
  # mode does NOT expand \t to a tab in the pattern, so a \t-anchored grep
  # silently matches nothing here, caught empirically while implementing
  # this fix. Mirrors this same script's own marker-matching grep further
  # down ("^[[:blank:]]*// $marker[[:blank:]]*\$").
  clientmodelline=$(grep '^[[:blank:]]*github\.com/prometheus/client_model[[:blank:]]' "$dst/go.mod.tmpl" | head -n 1)
  [ -n "$clientmodelline" ] || die "go.mod.tmpl has no github.com/prometheus/client_model require line to reclassify for --target-model $target_model"
  clientmodelversion=$(printf '%s\n' "$clientmodelline" | awk '{print $2}')
  [ -n "$clientmodelversion" ] || die "could not read a version out of go.mod.tmpl's client_model line: $clientmodelline"
  clientmodelfrag=$(mktemp)
  printf '\tgithub.com/prometheus/client_model %s\n' "$clientmodelversion" > "$clientmodelfrag"
  sed \
    -e '/^\tgithub\.com\/prometheus\/client_model[[:blank:]]/d' \
    -e "\\|^\\tgithub\\.com/prometheus/client_golang[[:blank:]]|r $clientmodelfrag" \
    "$dst/go.mod.tmpl" > "$dst/go.mod.tmpl.scaffoldtmp"
  mv "$dst/go.mod.tmpl.scaffoldtmp" "$dst/go.mod.tmpl"
  rm -f "$clientmodelfrag"
fi

# Multi-instance requires the BACKGROUND collector as its starter: a scrape must
# never block on a slow or dead machine (see the design doc's background
# mandate). Swap the synchronous starter for the background variant, and ship
# the shared test declarations the background test file relies on. Runs BEFORE
# the variants/ removal below (which drops the staging dir for every model) and
# before the @@VAR@@ substitution pass (so these files are templated like any
# other).
if [ "$target_model" = multi-instance ] && [ -d "$dst/internal/collector/variants" ]; then
  if [ -f "$dst/internal/collector/variants/background_collector.go.tmpl" ]; then
    mv "$dst/internal/collector/variants/background_collector.go.tmpl" "$dst/internal/collector/collector.go.tmpl"
  fi
  if [ -f "$dst/internal/collector/variants/background_collector_test.go.tmpl" ]; then
    mv "$dst/internal/collector/variants/background_collector_test.go.tmpl" "$dst/internal/collector/collector_test.go.tmpl"
  fi
  if [ -f "$dst/internal/collector/variants/collector_shared_test.go.tmpl" ]; then
    mv "$dst/internal/collector/variants/collector_shared_test.go.tmpl" "$dst/internal/collector/collector_shared_test.go.tmpl"
  fi
  if [ -f "$dst/internal/collector/variants/metrics.md.tmpl" ]; then
    mv "$dst/internal/collector/variants/metrics.md.tmpl" "$dst/internal/collector/metrics.md.tmpl"
  fi
fi

# variants/ (the background_collector.go.tmpl + test that /add-collector adds,
# see code/<flavor>/variants/) is /add-collector's own staging ground: it
# reads those templates directly from the PLUGIN tree (exactly as it reads
# code/<flavor>/collector.go.tmpl today), never through scaffold.sh. Landed
# at internal/collector/variants/ by the flavor-selection move above like any
# other flavor file, it must never reach a scaffolded repo: left in place, a
# @@VAR@@-substituted, .tmpl-stripped background_collector.go would sit in its
# own internal/collector/variants PACKAGE (a subdirectory is a distinct
# package regardless of its package clause), which can never see
# internal/collector's own Client/logger declarations: go build ./... fails
# on it with "undefined: Client". Mirrors the existing wiring/ staging removal
# below. rm -rf on a path that doesn't exist is a silent no-op, so this is
# harmless for a flavor that ships no variants/ at all.
rm -rf "$dst/internal/collector/variants"

# Flavor-specific docs: code/<flavor>/metrics.md.tmpl (if shipped) documents
# that flavor's own collector metrics truthfully - its metric names differ
# per flavor (e.g. http's @@NAMESPACE@@_items vs cli's @@NAMESPACE@@_example),
# so, unlike every other file under docs/, this one cannot be a single file
# shared by every flavor: a name accurate for one flavor would be an
# undocumented-in-code lie for another, exactly what make docs-check (see
# internal/collector/docs_check_test.go) exists to catch. It stages under
# code/<flavor>/ so the flavor selection above already picked the right one,
# then lands in internal/collector/ alongside every other flavor file above -
# the correct staging location, but the WRONG final path (its real home is
# docs/metrics.md, not internal/collector/metrics.md.tmpl) - so relocate the
# whole file here, before the generic substitution/rename/tmpl-strip passes
# below, which then apply to it at its real path exactly like every other
# common doc under docs/ already does. Guarded the same way every other
# optional flavor file is: a flavor that ships none is a silent no-op.
if [ -f "$dst/internal/collector/metrics.md.tmpl" ]; then
  mv "$dst/internal/collector/metrics.md.tmpl" "$dst/docs/metrics.md.tmpl"
fi

# Forge selection: drop the GitHub-only layer when the user opts out.
# Mirror-layout (assets/.github/... -> final .github/...) means this is the
# ONE forge-conditional directory; .goreleaser.yaml/.goreleaser.dev.yaml and
# everything else under assets/ are host-agnostic and always shipped
# regardless of --forge. rm -rf on a path that doesn't exist (e.g. a test
# fixture --src with no .github/ of its own) is a silent no-op.
if [ "$forge" = none ]; then
  rm -rf "$dst/.github"
fi

# Substitute @@KEY@@ sentinels in file contents. Materialize the file list
# first so every rewrite operates on a snapshot rather than a live traversal.
# `sed ... > tmp` creates a brand-new inode for tmp (default-permissioned per
# umask, NOT copying $file's mode), so the `mv` right after silently drops
# any executable bit $file had, a real regression for shipped helper
# scripts like scripts/docker/tools/{goreport.sh,deps-report.sh}, which are
# invoked as bare paths (relying on the exec bit + shebang) by the Makefile.
# Recorded before the rewrite and reapplied after, POSIX chmod +x only
# (never a specific octal mode: that would require a non-POSIX
# `stat`/`chmod --reference`, whose flag spelling differs between GNU and
# BSD/macOS: see the header comment's POSIX-utilities constraint).
find "$dst" -type f -print > "$pathlist"
while IFS= read -r file; do
  if [ -x "$file" ]; then was_exec=yes; else was_exec=no; fi
  sed -f "$sedscript" "$file" > "$file.scaffoldtmp"
  mv "$file.scaffoldtmp" "$file"
  [ "$was_exec" = yes ] && chmod +x "$file"
done < "$pathlist"

# Rename path components containing @@KEY@@ sentinels. -depth lists a
# directory's contents before the directory itself (post-order), and each
# rename only ever touches the entry's own basename (never a full multi
# segment path), so a parent is only renamed once every descendant already
# has its final name: no rename ever targets a not-yet-existing directory.
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

# Flavor wiring-marker injection: fill main.go's structural markers
# (// @@CLIENT_INIT@@, // @@CLIENT_BUILD@@, // @@COLLECTOR_REGISTRY@@,
# single-target markers; // @@PROBE_FACTORIES@@, multi-target's own marker,
# see mains/multi/main.go.tmpl; // @@INSTANCE_FACTORIES@@, multi-instance's
# own marker, see mains/multi-instance/main.go.tmpl) with the selected
# flavor's wiring snippets, if it shipped any. Flavor snippets stage under
# code/<flavor>/wiring/
# {client_init.frag,client_build.frag,registry.frag,probe_factory.frag,
# instance_factory.frag}
# (mirror-layout, exactly like every other
# flavor file) and so land at internal/collector/wiring/ after the
# flavor-selection move earlier in this script. By this point they are also
# fully @@KEY@@-substituted, since the content-substitution pass above runs
# over every file under $dst regardless of extension, and path-renamed/
# .tmpl-stripped, since it runs after both of those steps, so cmd/*/main.go
# already sits at its final path.
#
# This is a hardcoded, fixed set of (frag basename -> marker name) pairs, not
# a discovered or growing registry, mirroring this same script's own --forge
# github|none precedent. sed's `r` command inserts the frag file's content
# immediately AFTER the matched marker line without consuming it, so the
# marker comment itself survives verbatim in the output, deliberate, so
# /add-collector can find and reuse the same marker later to insert
# additional collectors. That is also why the residual-sentinel guard below
# still needs (and already has) its CLIENT_INIT/CLIENT_BUILD/
# COLLECTOR_REGISTRY/PROBE_FACTORIES/INSTANCE_FACTORIES exemption after this
# step runs, not just before it.
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
  # body", caught empirically while implementing this, not a hypothetical.
  # A frag whose marker is absent from the SELECTED main model is skipped, not
  # fatal: each main model (mains/single/, mains/multi/, mains/multi-instance/)
  # carries only its own markers now (single has no // @@PROBE_FACTORIES@@ or
  # // @@INSTANCE_FACTORIES@@; multi has no // @@CLIENT_INIT@@ /
  # // @@CLIENT_BUILD@@ / // @@COLLECTOR_REGISTRY@@ / // @@INSTANCE_FACTORIES@@;
  # multi-instance has no // @@CLIENT_INIT@@ / // @@CLIENT_BUILD@@ /
  # // @@COLLECTOR_REGISTRY@@ / // @@PROBE_FACTORIES@@), so a flavor shipping a
  # frag the chosen main doesn't use is the expected, common case, not a
  # broken scaffold. This is still a hardcoded, fixed set of pairs, not a
  # discovered/growing registry, same precedent as --forge github|none.
  for pair in \
    "client_init.frag:@@CLIENT_INIT@@" \
    "client_build.frag:@@CLIENT_BUILD@@" \
    "registry.frag:@@COLLECTOR_REGISTRY@@" \
    "probe_factory.frag:@@PROBE_FACTORIES@@" \
    "instance_factory.frag:@@INSTANCE_FACTORIES@@"; do
    fragfile="$dst/internal/collector/wiring/${pair%%:*}"
    marker="${pair##*:}"
    [ -f "$fragfile" ] || continue
    grep -q "^[[:blank:]]*// $marker[[:blank:]]*\$" "$mainfile" || continue
    sed -e "\\|^[[:blank:]]*// $marker[[:blank:]]*\$|r $fragfile" "$mainfile" > "$mainfile.scaffoldtmp"
    mv "$mainfile.scaffoldtmp" "$mainfile"
  done

  # wiring/ is scaffold-only staging, like licenses/ below: it must never
  # ship in the generated repo now that its content has been spliced into
  # main.go above.
  rm -rf "$dst/internal/collector/wiring"
fi

# Place the chosen LICENSE, then discard the unused alternatives: the
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
# failed, e.g. a read error): treating "not 0" as a blanket "clean" (as a
# plain `if grep ...; then` does) silently turns a failed scan into a false
# success. Capture the real code and branch on all three cases explicitly.
grep_rc=0
grep -rn '@@[A-Z_]*@@' "$dst" > "$sentinels" || grep_rc=$?
case "$grep_rc" in
  0|1) ;;
  *) die "residual-sentinel scan of $dst failed (grep exit $grep_rc)" ;;
esac

# main.go's structural markers (@@CLIENT_INIT@@, @@CLIENT_BUILD@@,
# @@COLLECTOR_REGISTRY@@, single-target; @@PROBE_FACTORIES@@, multi-target;
# @@INSTANCE_FACTORIES@@, multi-instance) are deliberately left as
# literal comments for a later flavor-specific scaffold.sh step to replace:
# they are not --var data placeholders, so their survival is expected, not a
# forgotten substitution. Filter exactly these named sentinels out before
# judging the scan; anything else that matches the broad @@[A-Z_]*@@ shape
# still fails loudly below, same as before. (A hardcoded set, not a discovered
# list, mirrors --forge's own hardcoded github|none: a small, deliberately
# fixed set, not a growing registry that would justify discovery.) Same
# explicit-exit-code discipline as the scan above, even though $sentinels is a
# script-written temp file (not a traversal of arbitrary --dst content) and so
# is a far less likely source of a genuine grep-internal failure.
# Line-grained exception: grep -v drops whole physical lines, so a forgotten
# @@FOO@@ sharing a line with one of these markers would be swallowed too.
# Fine today because each marker sits alone on its own line in main.go.
filtered_rc=0
grep -v -E '@@(CLIENT_INIT|CLIENT_BUILD|COLLECTOR_REGISTRY|PROBE_FACTORIES|INSTANCE_FACTORIES)@@' "$sentinels" > "$pathlist" || filtered_rc=$?
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
