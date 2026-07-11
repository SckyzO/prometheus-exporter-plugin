#!/bin/sh
# Unit harness for probe-target.sh. Proves the redaction security property:
# no secret in a fixture reaches the emitted output. POSIX sh.
set -eu

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
root=$(CDPATH= cd "$here/.." && pwd)
BACKBONE="$root/skills/prometheus-exporter/scripts/probe-target.sh"
FIX="$here/fixtures/probe"
fails=0

# assert a secret string is ABSENT from output and the <redacted> marker present
assert_redacted() {
	_desc=$1; _out=$2; _secret=$3
	if printf '%s' "$_out" | grep -qF "$_secret"; then
		printf 'FAIL: %s — secret leaked: %s\n' "$_desc" "$_secret"; fails=$((fails+1)); return
	fi
	if ! printf '%s' "$_out" | grep -qF '<redacted'; then
		printf 'FAIL: %s — no <redacted> marker in output\n' "$_desc"; fails=$((fails+1)); return
	fi
	printf 'PASS: %s\n' "$_desc"
}

assert_absent() {
	_desc=$1; _out=$2; _secret=$3
	if printf '%s' "$_out" | grep -qF "$_secret"; then
		printf 'FAIL: %s — leaked: %s\n' "$_desc" "$_secret"; fails=$((fails+1)); return
	fi
	printf 'PASS: %s\n' "$_desc"
}

# T1 — HTTP capture: bearer token + api_key redacted
out=$(bash "$BACKBONE" --mode http --input "$FIX/http-secrets.json")
assert_redacted "http bearer token" "$out" "sk-live-ABCDEF1234567890"
assert_absent   "http api_key value" "$out" "topsecretkey"
assert_absent   "http url credentials" "$out" "svcuser:hunter2@"
if ! printf '%s' "$out" | grep -qF "/widgets"; then
	printf 'FAIL: http non-secret content dropped (over-redaction)\n'; fails=$((fails+1))
else
	printf 'PASS: http non-secret content preserved\n'
fi

# T2 — CLI capture: password + token redacted
out=$(bash "$BACKBONE" --mode cli --input "$FIX/cli-help.txt")
assert_absent "cli --password value" "$out" "hunter2"
assert_absent "cli --token value" "$out" "SECRETTOK99"
assert_absent "cli --client-secret compound flag" "$out" "CLISECRET111"
if ! printf '%s' "$out" | grep -qF -- "--interval"; then
	printf 'FAIL: cli non-secret flags dropped (over-redaction)\n'; fails=$((fails+1))
else
	printf 'PASS: cli non-secret flags preserved\n'
fi

# T3 — PEM private key body redacted
out=$(bash "$BACKBONE" --mode http --input "$FIX/http-pem.txt")
assert_absent "pem key body" "$out" "MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX"

# T4 — --print-command emits the exact command and does not fetch
out=$(bash "$BACKBONE" --mode http --target http://localhost:9999 --path /metrics --print-command)
if [ "$out" = "curl -fsS --max-time 5 http://localhost:9999/metrics" ]; then
	printf 'PASS: print-command http\n'
else
	printf 'FAIL: print-command http — got: %s\n' "$out"; fails=$((fails+1))
fi

# T5 — unreachable target exits 2 (not a hang, not 0)
if bash "$BACKBONE" --mode http --target http://127.0.0.1:1 --path / --timeout 2 >/dev/null 2>&1; then
	printf 'FAIL: unreachable probe exited 0\n'; fails=$((fails+1))
else
	rc=$?
	if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
		printf 'PASS: unreachable probe exit %s\n' "$rc"
	else
		printf 'FAIL: unreachable probe exit %s (want 2 or 3)\n' "$rc"; fails=$((fails+1))
	fi
fi

# T6 — usage error exits 1
if bash "$BACKBONE" --mode bogus >/dev/null 2>&1; then
	printf 'FAIL: bad mode exited 0\n'; fails=$((fails+1))
else
	printf 'PASS: bad mode nonzero\n'
fi

# T7 — compound / bare / camelCase secret NAMES redacted (not just the exact keyword)
out=$(bash "$BACKBONE" --mode http --input "$FIX/http-compound-secrets.json")
assert_absent "http client_secret"       "$out" "oauthsecret111"
assert_absent "http secret_access_key"   "$out" "awssecret222"
assert_absent "http bare key"            "$out" "barekey333"
assert_absent "http private_key"         "$out" "privkey444"
assert_absent "http authToken camelCase" "$out" "cameltoken555"
if ! printf '%s' "$out" | grep -qF -- "/metrics"; then
	printf 'FAIL: compound non-secret content dropped (over-redaction)\n'; fails=$((fails+1))
else
	printf 'PASS: compound non-secret content preserved\n'
fi

# T8 — URL creds inside a key-named field: the pair rule must not partially
# leak the userinfo past the URL rule (URL rule runs before the pair rule).
out=$(bash "$BACKBONE" --mode http --input "$FIX/http-url-in-secret-field.json")
assert_redacted "url creds in secret_url field" "$out" "pa,ss"
assert_absent   "url creds tail not stranded"   "$out" "ss@host"
if ! printf '%s' "$out" | grep -qF -- "/health"; then
	printf 'FAIL: url-field non-secret content dropped (over-redaction)\n'; fails=$((fails+1))
else
	printf 'PASS: url-field non-secret content preserved\n'
fi

if [ "$fails" -eq 0 ]; then
	printf '\nprobe-target-backbone.sh: PASS\n'; exit 0
else
	printf '\nprobe-target-backbone.sh: FAIL (%s)\n' "$fails"; exit 1
fi
