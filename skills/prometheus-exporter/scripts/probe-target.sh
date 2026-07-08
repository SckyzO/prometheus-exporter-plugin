#!/usr/bin/env bash
#
# probe-target.sh — deterministic live-target probe backbone (discovery rung 4).
#
# Fetches (HTTP GET) or executes (CLI) a RUNNING target's description surface,
# truncates the capture, and REDACTS common secrets before emitting to stdout.
# Interpreting the redacted output into metric candidates is the caller's job
# (the /design-exporter model). This script does nothing "clever".
#
# Lives outside assets/ so scaffold.sh never ships it (cf. generate-dashboard.sh).
#
# Exit codes: 0 ok (and --print-command) · 1 usage · 2 unreachable/failed
#             · 3 timeout · 4 redactor (perl) unavailable
#
set -euo pipefail

MODE=""
TARGET=""
PROBE_PATH=""
TIMEOUT="5"
MAX_BYTES="65536"
INPUT=""
PRINT_COMMAND=0

die() { printf 'probe-target: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
	cat >&2 <<'EOF'
usage: probe-target.sh --mode <http|cli> --target <url-or-cmd> [options]
  --mode http|cli        probe a URL (GET) or execute a command
  --target <url-or-cmd>  http: base URL;  cli: command line to run
  --path <path>          http only: path appended to the base URL
  --timeout <seconds>    per-probe timeout (default 5)
  --max-bytes <n>        capture cap in bytes (default 65536)
  --input <file>         read capture from file, skip network/exec (test seam)
  --print-command        print the exact command that would run, then exit 0
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--mode)          MODE="${2:-}"; shift 2 ;;
		--target)        TARGET="${2:-}"; shift 2 ;;
		--path)          PROBE_PATH="${2:-}"; shift 2 ;;
		--timeout)       TIMEOUT="${2:-}"; shift 2 ;;
		--max-bytes)     MAX_BYTES="${2:-}"; shift 2 ;;
		--input)         INPUT="${2:-}"; shift 2 ;;
		--print-command) PRINT_COMMAND=1; shift ;;
		-h|--help)       usage ;;
		*)               die "unknown argument: $1" ;;
	esac
done

case "$MODE" in
	http)
		[ -n "$TARGET" ] || [ -n "$INPUT" ] || die "http mode requires --target <url>"
		url="${TARGET%/}${PROBE_PATH}"
		cmd_display="curl -fsS --max-time ${TIMEOUT} ${url}"
		;;
	cli)
		[ -n "$TARGET" ] || [ -n "$INPUT" ] || die "cli mode requires --target <command>"
		cmd_display="$TARGET"
		;;
	*)
		usage
		;;
esac

if [ "$PRINT_COMMAND" -eq 1 ]; then
	printf '%s\n' "$cmd_display"
	exit 0
fi

# Fail closed: without a redactor, refuse to emit rather than leak.
command -v perl >/dev/null 2>&1 || die "perl required for redaction; refusing to emit unredacted output" 4

# --- obtain the raw capture -------------------------------------------------
rc=0
if [ -n "$INPUT" ]; then
	[ -f "$INPUT" ] || die "input file not found: $INPUT"
	raw=$(cat "$INPUT")
else
	case "$MODE" in
		http) raw=$(curl -fsS --max-time "$TIMEOUT" "$url" 2>/dev/null) || rc=$? ;;
		cli)  raw=$(timeout "$TIMEOUT" sh -c "$TARGET" 2>&1) || rc=$? ;;
	esac
	if [ "$rc" -ne 0 ]; then
		if { [ "$MODE" = http ] && [ "$rc" -eq 28 ]; } || \
		   { [ "$MODE" = cli ]  && [ "$rc" -eq 124 ]; }; then
			die "probe timed out after ${TIMEOUT}s" 3
		fi
		die "probe failed (exit ${rc})" 2
	fi
fi

# --- redact, then truncate --------------------------------------------------
# Redact before truncating so a cap boundary can never split a secret in two.
# \x27 is a literal single quote — avoids embedding one in the bash-quoted -pe.
redacted=$(printf '%s' "$raw" | perl -0777 -pe '
	s/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+/$1 <redacted>/gi;
	s/\b(api[-_]?key|token|secret|password|passwd|passphrase|access[-_]?key)("?\s*[:=]\s*"?)[^"\x27\s,}\r\n]+/$1$2<redacted>/gi;
	s/(--(?:api[-_]?key|token|secret|password|passwd|passphrase|access[-_]?key)[= ])[^"\x27\s,}\r\n]+/$1<redacted>/gi;
	s/(:\/\/)[^:\/@\s]+:[^@\s]+\@/$1<redacted>\@/g;
	s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/<redacted PEM private key>/gs;
	s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*\z/<redacted truncated PEM key>/gs;
')

set +o pipefail
printf '%s' "$redacted" | head -c "$MAX_BYTES"
set -o pipefail
printf '\n'
