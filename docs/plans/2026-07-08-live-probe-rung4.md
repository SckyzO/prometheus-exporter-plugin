# Live-target probe (discovery rung 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un-defer discovery ladder rung 4 so `/design-exporter` can ground a design by probing a running instance of the target (HTTP `GET` or CLI exec), opt-in and consent-gated, with a deterministic secret-redaction backbone.

**Architecture:** One `bash` backbone (`skills/prometheus-exporter/scripts/probe-target.sh`) does fetch → truncate → redact and nothing "clever"; the `/design-exporter` model interprets the redacted output. Two prose edits wire the rung into the reference (`discovery-inputs.md`) and the command (`design-exporter.md`). Docs are flipped from deferred to shipped. Zero Go; the backbone lives outside `assets/` so `scaffold.sh` never ships it.

**Tech Stack:** `bash`, `curl` (native), `perl` (redaction), GNU `timeout`, POSIX `sh` test harness. Same "deterministic floor + LLM ceiling" split validated by the `generate-dashboard` epic.

**Design doc:** `docs/design/2026-07-08-live-probe-rung4-design.md`.

## Global Constraints

- **Zero Go.** Prose + one bash backbone only. No `assets/` runtime template changes; no scaffolded-exporter behaviour change.
- **Backbone lives outside `assets/`** (`skills/prometheus-exporter/scripts/`), like `generate-dashboard.sh` — never shipped by `scaffold.sh`.
- **Default walk unchanged.** With no live instance offered, discovery is byte-for-byte `1→2→3→5`. The only default-path output change is rung-4 Provenance wording (deferred → skipped/not-activated).
- **Supplements, never replaces** (`discovery-inputs.md:38-41`): rung 4 confirms/fills-gaps; live↔static *conflicts* become `## Open questions / assumptions` entries, never silent overrides.
- **Redaction fails closed:** no `perl` → exit 4, refuse to emit unredacted output.
- **Security property (testable):** no secret present in a probe fixture appears in the backbone's emitted output.
- Run `test/zero-source-grep.sh` before every commit; never `slurm`/`sacct`/`sckyzo` in `assets/`,`commands/`,`skills/`,`agents/` (docs/,test/,root .github/ exempt).
- English for all shipped artifacts and commit messages; Conventional Commits with scope; **no AI/automation attribution** in any git artifact (no `Co-authored-by`, no `Claude-Session:` trailer). Commit with `git -c commit.gpgsign=false commit`.
- RED-before-GREEN proven on the backbone; no cosmetic tests; never bundle distinct logical fixes in one commit.

---

### Task 1: `probe-target.sh` backbone + unit harness

**Files:**
- Create: `skills/prometheus-exporter/scripts/probe-target.sh`
- Create: `test/probe-target-backbone.sh`
- Create: `test/fixtures/probe/http-secrets.json`
- Create: `test/fixtures/probe/cli-help.txt`
- Create: `test/fixtures/probe/http-pem.txt`

**Interfaces:**
- Produces: `probe-target.sh --mode <http|cli> --target <url-or-cmd> [--path <p>] [--timeout <s>] [--max-bytes <n>] [--input <file>] [--print-command]`. Emits the redacted capture on stdout. Exit codes: `0` ok (and `--print-command`), `1` usage, `2` unreachable/failed, `3` timeout, `4` redactor (perl) unavailable. Tasks 2 and 3 reference this contract; do not change flag names without updating them.

- [ ] **Step 1: Write the fixtures (the secrets that must NOT leak)**

Create `test/fixtures/probe/http-secrets.json`:

```json
{
  "info": { "title": "demo api", "version": "1.0" },
  "auth": { "header": "Authorization: Bearer sk-live-ABCDEF1234567890" },
  "api_key": "topsecretkey",
  "callback_url": "https://svcuser:hunter2@hooks.example.com/cb",
  "endpoints": ["/things", "/widgets"]
}
```

Create `test/fixtures/probe/cli-help.txt`:

```
demo-tool 2.3.1
Usage: demo-tool [options]
  --listen ADDR        address to bind
  --password=hunter2   backend password (example)
  --token SECRETTOK99  API token
  --interval SECONDS   scrape interval
```

Create `test/fixtures/probe/http-pem.txt`:

```
{"tls_key": "-----BEGIN RSA PRIVATE KEY-----
MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu
KUpRKfFLfRYC9AIKjbJTWit+CqvjWYzvQwECAwEAAQ==
-----END RSA PRIVATE KEY-----", "port": 8443}
```

- [ ] **Step 2: Write the failing test harness**

Create `test/probe-target-backbone.sh`:

```sh
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
out=$(sh "$BACKBONE" --mode http --input "$FIX/http-secrets.json")
assert_redacted "http bearer token" "$out" "sk-live-ABCDEF1234567890"
assert_absent   "http api_key value" "$out" "topsecretkey"
assert_absent   "http url credentials" "$out" "svcuser:hunter2@"
if ! printf '%s' "$out" | grep -qF "/widgets"; then
	printf 'FAIL: http non-secret content dropped (over-redaction)\n'; fails=$((fails+1))
else
	printf 'PASS: http non-secret content preserved\n'
fi

# T2 — CLI capture: password + token redacted
out=$(sh "$BACKBONE" --mode cli --input "$FIX/cli-help.txt")
assert_absent "cli --password value" "$out" "hunter2"
assert_absent "cli --token value" "$out" "SECRETTOK99"
if ! printf '%s' "$out" | grep -qF "--interval"; then
	printf 'FAIL: cli non-secret flags dropped (over-redaction)\n'; fails=$((fails+1))
else
	printf 'PASS: cli non-secret flags preserved\n'
fi

# T3 — PEM private key body redacted
out=$(sh "$BACKBONE" --mode http --input "$FIX/http-pem.txt")
assert_absent "pem key body" "$out" "MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX"

# T4 — --print-command emits the exact command and does not fetch
out=$(sh "$BACKBONE" --mode http --target http://localhost:9999 --path /metrics --print-command)
if [ "$out" = "curl -fsS --max-time 5 http://localhost:9999/metrics" ]; then
	printf 'PASS: print-command http\n'
else
	printf 'FAIL: print-command http — got: %s\n' "$out"; fails=$((fails+1))
fi

# T5 — unreachable target exits 2 (not a hang, not 0)
if sh "$BACKBONE" --mode http --target http://127.0.0.1:1 --path / --timeout 2 >/dev/null 2>&1; then
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
if sh "$BACKBONE" --mode bogus >/dev/null 2>&1; then
	printf 'FAIL: bad mode exited 0\n'; fails=$((fails+1))
else
	printf 'PASS: bad mode nonzero\n'
fi

if [ "$fails" -eq 0 ]; then
	printf '\nprobe-target-backbone.sh: PASS\n'; exit 0
else
	printf '\nprobe-target-backbone.sh: FAIL (%s)\n' "$fails"; exit 1
fi
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `sh test/probe-target-backbone.sh`
Expected: FAIL — `probe-target.sh` does not exist yet, so the first `sh "$BACKBONE" …` errors / all assertions fail.

- [ ] **Step 4: Write the backbone**

Create `skills/prometheus-exporter/scripts/probe-target.sh`:

```bash
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
		[ -n "$TARGET" ] || die "http mode requires --target <url>"
		url="${TARGET%/}${PROBE_PATH}"
		cmd_display="curl -fsS --max-time ${TIMEOUT} ${url}"
		;;
	cli)
		[ -n "$TARGET" ] || die "cli mode requires --target <command>"
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
```

- [ ] **Step 5: Make it executable and run the test to verify it passes**

Run: `chmod +x skills/prometheus-exporter/scripts/probe-target.sh && sh test/probe-target-backbone.sh`
Expected: all `PASS`, final `probe-target-backbone.sh: PASS`. If `perl` or `curl` is missing in the environment, install/enable them (both are standard); the backbone treats a missing `perl` as fail-closed (exit 4) by design.

- [ ] **Step 6: Verify the shell scripts parse cleanly**

Run: `bash -n skills/prometheus-exporter/scripts/probe-target.sh && sh -n test/probe-target-backbone.sh`
Expected: no output, exit 0 (guards against the single-quote/apostrophe quoting bugs seen in the previous epic).

- [ ] **Step 7: zero-source-grep + commit**

Run: `bash test/zero-source-grep.sh`
Expected: PASS.

```bash
git add skills/prometheus-exporter/scripts/probe-target.sh test/probe-target-backbone.sh test/fixtures/probe/
git -c commit.gpgsign=false commit -m "feat(discovery): live-target probe backbone with secret redaction

probe-target.sh fetches (http GET) or execs (cli) a running target and
redacts common secrets (auth headers, key/token/secret/password pairs, URL
credentials, PEM keys) before emitting. Fails closed if perl is absent.
--input seam + fixtures drive the redaction unit test."
```

---

### Task 2: Wire rung 4 into `discovery-inputs.md`

**Files:**
- Modify: `skills/prometheus-exporter/references/discovery-inputs.md`

**Interfaces:**
- Consumes: the Task 1 backbone path (`scripts/probe-target.sh`) and its fetch-redact contract, referenced in prose.

- [ ] **Step 1: Replace the ladder table row 4**

Change (line 25):

```
| 4 | *(deferred)* live-target probe | — | *(not shipped yet)* |
```

to:

```
| 4 | Live-target probe *(opt-in)* | High | no live instance offered / consent declined / non-interactive run |
```

- [ ] **Step 2: Replace the rung-4 paragraph (lines 46-51)**

Replace the whole paragraph beginning "Rung 4 is named in the table for one reason…" with:

```
Rung 4 is **opt-in**: it runs only when the user offers a running instance of
the target and consents to it being probed. When it is not activated the walk
is exactly `1→2→3→5` and nothing changes for anyone. Its data confidence is
high — it is the real instance — but its position stays low because it is
conditional on that instance existing and on explicit consent, so it
**supplements** the walk rather than leading it: it confirms what a higher
rung already stated and fills gaps a higher rung left silent. Where a live
probe *contradicts* a higher rung, that discrepancy is recorded as an
`## Open questions / assumptions` entry, never silently resolved — a running
instance can be mis-configured or an old build, so the design phase flags the
conflict for the user instead of picking a winner. The probe never runs
silently: `/design-exporter` shows the exact URL or command and gets explicit
consent first, and every capture passes through the redaction backbone
(`scripts/probe-target.sh`) before any of it can reach the brief.
```

- [ ] **Step 3: Add the rung-4 extraction subsection**

Under `## Per-source extraction`, insert a new subsection immediately after `### context7` (and before `### Dialogue`):

```
### Live-target probe

Opt-in, and only after the user names a running instance and consents to the
exact command shown. Two modes, matching the two I/O flavors:

- **HTTP target** — `GET` one description surface: `/openapi.json`,
  `/swagger.json`, an existing `/metrics`, or a sample response the exporter
  will parse. Extract candidate collectors/metrics from it exactly as the
  OpenAPI or docs rules above would, marked in Provenance as live-probed
  (highest fidelity: it is what the instance actually serves).
- **CLI target** — run one discovery invocation (`<cmd> --help`,
  `<cmd> --version`, or a named sample sub-command) and read the captured
  output for the sub-commands and fields that become collectors.

Both modes go through `scripts/probe-target.sh`, which fetches or executes
under a timeout, truncates the capture, and **redacts** common secrets (auth
headers, `key`/`token`/`secret`/`password` pairs, URL credentials, PEM private
keys) before emitting — the raw response never reaches the model or the brief.
Interpreting the redacted capture into candidates is the model's job; the
backbone does only fetch-truncate-redact. In a non-interactive run no consent
is possible, so the rung is skipped.

The extraction *method* here is `[G]` (fetch-redact-interpret holds for any
target); the instance's actual endpoints, flags, and response shapes are `[S]`
and live only in that target's brief, never folded back into this reference.
```

- [ ] **Step 4: Update the Provenance example (lines 125-126)**

Change the `Grounded by` / `Skipped` example lines to include live-probe cases:

```
- Grounded by: <rung(s) actually used, e.g. "OpenAPI spec ./openapi.yaml,
  corroborated by live probe of http://localhost:9100/metrics">
- Skipped: <rungs skipped and why, e.g. "context7 — no entry for <target>;
  live probe — no running instance offered">
```

- [ ] **Step 5: Verify + commit**

Run: `bash test/zero-source-grep.sh && grep -n "deferred\|not shipped yet" skills/prometheus-exporter/references/discovery-inputs.md`
Expected: grep PASS; the second grep returns **no rung-4 "deferred/not shipped" lines** (any remaining hit must not refer to the live-target probe).

```bash
git add skills/prometheus-exporter/references/discovery-inputs.md
git -c commit.gpgsign=false commit -m "docs(discovery): ship rung 4 (live-target probe) in the reference

Table row, rung-4 paragraph, a per-source extraction subsection, and a
Provenance example. Opt-in; supplements the walk, surfaces conflicts as open
questions; default 1->2->3->5 walk unchanged."
```

---

### Task 3: Wire the rung-4 step into `design-exporter.md`

**Files:**
- Modify: `commands/design-exporter.md`

**Interfaces:**
- Consumes: `probe-target.sh --print-command` (consent) and the fetch-redact run (Task 1).

- [ ] **Step 1: Replace walk items 3-4 (lines 42-48) with items 3-4-5**

Replace list item 3 (context7) and item 4 (Dialogue, currently labeled rung 5) with:

```
3. **context7** (rung 3) — if neither of the above grounded the design, try
   `resolve-library-id` against the target, then `query-docs` for its API
   surface. Treat "not installed" and "no match" as a skip, not a failure —
   never guess a nearby library's shape instead.
4. **Live-target probe** (rung 4) — **opt-in.** Only if the user has a running
   instance of the target and wants it used: ask for its endpoint (http) or
   the command to run (cli), then show the *exact* command that
   `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/scripts/probe-target.sh
   --mode <http|cli> --target <…> [--path <…>] --print-command` prints and get
   explicit consent before running it. Run the same backbone without
   `--print-command`; it fetches/executes under a timeout and redacts secrets
   before returning. Interpret the redacted output as candidate collectors/
   metrics, **supplementing** the higher rungs — confirming what they stated,
   filling gaps they left, and recording any contradiction as an
   `## Open questions / assumptions` entry rather than overriding them. Skip
   silently in a non-interactive run (no consent possible).
5. **Dialogue** (rung 5) — if nothing above grounded the design, fall back to
   the question flow in `exporter-architecture.md`. Always available, so the
   walk always has somewhere to land.
```

- [ ] **Step 2: Update the Provenance instruction (lines 50-54)**

Replace the paragraph beginning "Record, for the brief's `## Provenance`…" with:

```
Record, for the brief's `## Provenance` section: which rung(s) actually
grounded the design — including whether the live-target probe (rung 4) was run
and what it confirmed or added — and, for every rung skipped, a one-line reason
why (rung 4's is usually "no running instance offered" or "consent declined"),
not just that it was skipped.
```

- [ ] **Step 3: Verify the referenced backbone exists + consistency**

Run:
```bash
test -f skills/prometheus-exporter/scripts/probe-target.sh && echo "backbone present"
grep -n "rung 5" commands/design-exporter.md
grep -c "probe-target.sh" commands/design-exporter.md
```
Expected: "backbone present"; the Dialogue step is now labeled rung 5 (not the old 3→5 jump with no rung 4); `probe-target.sh` referenced at least once.

- [ ] **Step 4: zero-source-grep + commit**

Run: `bash test/zero-source-grep.sh`
Expected: PASS.

```bash
git add commands/design-exporter.md
git -c commit.gpgsign=false commit -m "feat(design-exporter): walk rung 4 (live-target probe)

Turn the 3->5 jump into a real opt-in rung-4 step: show the exact
probe-target.sh command, get consent, run it, interpret the redacted output
as a supplement to the higher rungs. Update the Provenance instruction."
```

---

### Task 4: Mark shipped — ROADMAP, CHANGELOG, SKILL audit

**Files:**
- Modify: `ROADMAP.md`
- Modify: `CHANGELOG.md`
- Modify: `skills/prometheus-exporter/SKILL.md` (only if it carries stale live-probe "deferred" wording)

- [ ] **Step 1: ROADMAP — flip live-probe to shipped**

In `ROADMAP.md`, find the v0.2 "Discovery inputs" bullet's tail (around line 34-35): "A **live-target probe** rung is deferred to a v0.2.x fast-follow." Replace with a shipped statement, e.g.: "A **live-target probe** rung (rung 4) ships in v0.2.x — opt-in, consent-gated, with deterministic secret redaction." Read the surrounding lines first and keep the bullet's existing style.

- [ ] **Step 2: CHANGELOG — add the `[Unreleased]` entry**

Under the empty `## [Unreleased]` (line 8), add:

```
### Added

- **Live-target probe (discovery rung 4)** — `/design-exporter` can now ground
  a design by probing a *running* instance of the target: an HTTP `GET` against
  its description surface (`/openapi.json`, `/metrics`, …) or a CLI
  `--help`/`--version`/sample invocation. Opt-in and consent-gated (the exact
  command is shown and confirmed before running); every capture passes through
  a deterministic secret-redaction backbone
  (`skills/prometheus-exporter/scripts/probe-target.sh`, `bash`, outside
  `assets/` so no scaffold ships it) before any of it reaches the brief. It
  **supplements** the discovery walk — confirming and filling gaps in the
  higher rungs, surfacing contradictions as open questions — and the default
  walk (local spec > docs > context7 > dialogue) is unchanged when no live
  instance is offered.
```

- [ ] **Step 3: SKILL.md audit**

Run: `grep -n "live-target\|rung 4\|live probe\|probe" skills/prometheus-exporter/SKILL.md`
Read each hit. Update any wording that calls the **live-target probe** deferred/not-shipped to reflect it now ships. **Leave multi-target "documented follow-up" wording untouched** — that is still true until sub-project 3b. If no stale live-probe wording exists, make no change and note it in the report.

- [ ] **Step 4: Verify + commit**

Run: `bash test/zero-source-grep.sh`
Expected: PASS.

```bash
git add ROADMAP.md CHANGELOG.md skills/prometheus-exporter/SKILL.md
git -c commit.gpgsign=false commit -m "docs: mark live-target probe (rung 4) shipped

ROADMAP fast-follow -> shipped, CHANGELOG [Unreleased] entry, SKILL audit.
Multi-target remains documented follow-up (sub-project 3b)."
```

*(If SKILL.md needed no change, drop it from the `git add`.)*

---

## Self-Review

**Spec coverage:** §3.1 semantics → Task 2 (paragraph) + Task 3 (walk step). §3.2 probe modes → Task 2 (extraction subsection) + Task 1 (http/cli modes). §3.3 security (consent/redaction/timeout/brief-holds-candidates) → Task 3 (consent) + Task 1 (redaction/timeout/fail-closed). §3.4 backbone contract → Task 1. §4 files → all four tasks. §5 testing → Task 1 harness. §6 non-regression → Global Constraints + Task 2/3 default-walk wording. Covered.

**Placeholder scan:** Task 1 ships complete backbone + test + fixtures. Tasks 2-3 give exact replacement text. Task 4 gives exact CHANGELOG text and read-then-edit instructions for ROADMAP/SKILL (whose exact current lines vary) — deliberately a read-first edit, not a placeholder.

**Type/contract consistency:** the flag set and exit codes in Task 1's Interfaces match the backbone code and the `--print-command` string asserted in the test (`curl -fsS --max-time 5 …`) and referenced in Task 3. Redaction patterns in the backbone match the fixtures' secrets in Task 1 Step 1.

**Model tiers (for the SDD controller):** Task 1 standard (security-critical bash + TDD); Tasks 2-3 standard (prose + interface wiring); Task 4 cheap (mechanical). Task 1 review on the most capable model (redaction is the security control); Tasks 2-3 reviews standard; Task 4 review cheap. Final whole-branch review on the most capable model.
