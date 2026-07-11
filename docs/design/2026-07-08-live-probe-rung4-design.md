# Live-target probe — discovery ladder rung 4

**Status:** design approved 2026-07-08 · sub-project 3a of the v0.3.0
"multi-target + live-probe" epic. The multi-target scaffold work (3b) is a
separate, later sub-project and is out of scope here.

## 1. Goal

Un-defer **rung 4** of the discovery ladder so `/design-exporter` can ground
an exporter design by probing a *running instance* of the target — an HTTP
`GET` against its own description surface, or a CLI `--help`/`--version`/
sample invocation — instead of relying only on static sources (spec, docs,
context7). The probe is **opt-in**, **consent-gated**, and its captured
output passes through a **deterministic secret-redaction backbone** before
any of it can reach the architecture brief.

Prose plus one tested `bash` backbone. **Zero Go. Nothing new is shipped by
`scaffold.sh`** — the backbone lives outside `assets/`, exactly like
`generate-dashboard.sh`.

### Non-goals

- Multi-target `/probe?target=` scaffolding — that is sub-project 3b.
- Probing in a headless / non-interactive run: no consent can be given, so
  rung 4 is skipped and recorded as such.
- A perfect secret scrubber. Redaction catches common high-confidence
  patterns; the brief-holds-candidates-not-dumps rule (§3.3) is the primary
  containment, redaction is defense-in-depth.

## 2. Background — the current deferred rung 4

`discovery-inputs.md` today (lines 20-51) lists rung 4 as
`| 4 | *(deferred)* live-target probe | — | *(not shipped yet)* |` and
explains its absence is "a decision, not an oversight," citing the "network
and process-exec surface this scaffold doesn't take on lightly."
`design-exporter.md` (step 2, lines 42-54) walks `1→2→3→5`, jumping over
rung 4, and its Provenance instruction names rung 4 as "a deferred
capability this plugin doesn't ship yet." `ROADMAP.md:34-35` files it as a
"v0.2.x fast-follow." This sub-project ships it.

## 3. Design

### 3.1 Integration semantics — default unchanged, supplement-not-replace

The existing ladder model (`discovery-inputs.md:38-41`) is *"favors the
highest-confidence source actually available, and supplements — never
replaces — it with lower rungs where they add detail the higher rung didn't
cover."* Rung 4 obeys that model rather than overriding it:

- **Default (no live instance offered):** the walk is `1→2→3→5`, byte-for-
  byte unchanged. No non-configured user sees any difference. Provenance
  records rung 4 as skipped, with the reason (not activated / no instance /
  consent declined / non-interactive).
- **Opt-in (user offers a running instance and consents):** rung 4 runs as a
  **supplement** to whatever the walk already grounded — it *confirms* what
  higher rungs stated and *fills gaps* they left silent (real response
  shapes, endpoints that actually respond, a flag a doc omitted).
- **Conflict handling:** where the live probe *contradicts* a higher rung
  (spec names a field the live instance lacks, or vice-versa), that is
  neither supplement nor replace — it is surfaced as a
  `## Open questions / assumptions` entry, never silently resolved in either
  direction. A dev instance can be mis-configured or an old version;
  the design phase flags the discrepancy for the user rather than picking a
  winner.

Rung 4's data confidence is high (it is the real instance), but its ladder
*position* stays low because it is conditional on a running instance +
explicit consent. That mismatch — high confidence, low position — is exactly
why it supplements and flags conflicts rather than leading the walk.

### 3.2 Probe modes (flavor-aware)

- **HTTP target** → `GET` one description surface: `/openapi.json`,
  `/swagger.json`, an existing `/metrics`, or a sample API response the
  exporter will parse. The user names the path; a small set of conventional
  defaults may be offered.
- **CLI target** → execute one discovery invocation: `<cmd> --help`,
  `<cmd> --version`, or a named sample sub-command, capturing stdout+stderr.

The two modes map 1:1 onto the two exporter flavors, so CLI-flavor targets
(the plugin's own origin shape) are covered, not left behind.

### 3.3 Security model (the crux)

Responsibilities are split so the security-critical step is deterministic
and testable:

- **Consent = command layer (`design-exporter.md`).** Before any probe, the
  command shows the *exact* URL or command that will run (obtained via the
  backbone's `--print-command`), and requires an explicit "yes" from the
  user. No probe is ever run silently. In a non-interactive run, consent is
  impossible, so rung 4 is skipped.
- **Redaction + bounds + timeout = backbone (`probe-target.sh`).** Captured
  output is truncated to a byte cap and passed through a fixed set of
  secret-redaction rules (bearer/basic auth headers, `key|token|secret|
  password|passphrase = value` pairs, PEM private-key blocks, `://user:pass@`
  URL credentials) — each match replaced with `<redacted>` — *before* the
  content is emitted. The probe runs under a bounded timeout.
- **The brief holds candidates, not dumps.** Even post-redaction, the raw
  response body never lands in the brief. The LLM ceiling (§3.4) reads the
  redacted capture and writes *metric candidates* (names, types, shapes)
  into the brief; `## Provenance` records only the endpoint/command probed,
  never its response. This is the primary containment; redaction is
  defense-in-depth behind it.

Testable security property (anti-lie analog): *no secret present in a probe
fixture appears in the backbone's emitted output.*

### 3.4 Deterministic floor + LLM ceiling

Same split validated by the `generate-dashboard` epic. The backbone is the
floor and does nothing "clever"; interpretation is the ceiling.

**Backbone — `skills/prometheus-exporter/scripts/probe-target.sh`** (outside
`assets/`; not shipped by scaffold):

- Inputs: `--mode <http|cli>`, `--target <url-or-cmd>`,
  `--path <probe-path>` (http), `--timeout <dur>` (default bounded),
  `--max-bytes <n>` (capture cap), `--print-command` (emit the exact command
  that would run, then exit 0 without running — feeds the consent prompt),
  `--input <file>` (read capture from a file instead of fetching/exec'ing —
  the unit-test seam, mirroring how `Execute` is overridden in slurm_exporter
  tests).
- Behaviour: fetch (native `curl` for http) or exec (`<cmd>` for cli) under
  the timeout → capture (stdout, plus stderr for cli) → **redact** →
  truncate to `--max-bytes` → emit the redacted capture to stdout.
- Exit codes: `0` ok · `1` usage error · `2` probe unreachable/failed ·
  `3` timeout · `4` redactor (perl) unavailable. (`--print-command` always
  exits `0`.)
- No `jq`, no container: fetch + redact + emit only. Parsing/interpretation
  is the ceiling's job, so the backbone stays a minimal, dependency-light,
  universally-runnable filter (`curl` + POSIX text tools).

**Ceiling — the `/design-exporter` command.** Reads the redacted capture,
interprets it into candidate collectors/metrics per the rung-4 extraction
method, supplements the walk (§3.1), and records Provenance. Understanding a
novel API's shape is judgment — it stays with the model.

`curl` native (not container-first): the target is on the user's own
network/localhost; a container adds a useless network hop. Container-first
`jq` remains the convention for JSON *parsing* elsewhere — it just is not
needed in this backbone.

## 4. Files touched

1. **`skills/prometheus-exporter/references/discovery-inputs.md`**
   - Ladder table row 4: drop `*(deferred)*`/`*(not shipped yet)*`; set
     Confidence (high, conditional) and a real Degrades cell (no live
     instance / consent declined / non-interactive).
   - Rewrite the rung-4 paragraph (lines 46-51): from "deferred, not
     shipped" to the actual capability, the supplement-not-replace +
     conflict-as-open-question semantics, and the security posture.
   - Add a **rung-4 per-source extraction subsection** under
     `## Per-source extraction`, alongside the sibling rungs: the HTTP-GET
     method, the CLI-exec method, the consent + redaction guardrails, and the
     `[G]`/`[S]` split (method is generic; the target's real endpoints/output
     are target-specific and live only in that target's brief).
   - Provenance example (lines 124-127): show a live-probe grounded line and
     a skipped line.
2. **`commands/design-exporter.md`**
   - Turn the `3→5` jump into a real **rung-4 step** between context7 and
     dialogue: offer the probe only if the user has a running instance;
     show the exact command (`--print-command`) and get explicit consent;
     call the backbone; interpret the redacted output; supplement + surface
     conflicts.
   - Update the Provenance instruction (lines 50-54): rung 4 is no longer
     "a deferred capability this plugin doesn't ship yet" — record whether it
     was activated (and what it grounded/corroborated) or skipped and why.
3. **`skills/prometheus-exporter/scripts/probe-target.sh`** — new backbone
   (§3.4).
4. **`test/probe-target-backbone.sh`** + **`test/fixtures/probe/`** — new
   POSIX-sh unit harness (same shape as `generate-dashboard-backbone.sh`).
5. **`ROADMAP.md`** (move live-probe from "deferred v0.2.x fast-follow" to
   shipped), **`CHANGELOG.md`** (`[Unreleased]` entry), and an audit of
   **`SKILL.md`** for any stale "rung 4 / live-probe deferred" wording —
   leaving multi-target "documented follow-up" language intact (still true
   until 3b).

## 5. Testing strategy

Redaction is the non-regression: it is the security control, so it gets a
failing-first test.

- **Redaction (HTTP):** a fixture API/OpenAPI response containing
  `Authorization: Bearer …`, an `"api_key": "…"` field, and a `://user:pass@`
  URL → run `probe-target.sh --mode http --input <fixture>` → assert every
  secret string is **absent** and `<redacted>` is present, candidates still
  extractable. RED first: without the redaction pass the secret leaks and the
  test fails.
- **Redaction (CLI):** a `--help` fixture containing `--password=hunter2` →
  `--input` → assert redacted.
- **Failure/timeout:** http mode against a closed port, and a cli mode
  against a command that hangs → assert exit `2`/`3` and that the timeout is
  honoured (bounded wall-clock).
- **`--print-command`:** asserts the exact command is emitted and nothing is
  fetched/executed (exit `0`).
- Golden-smoke: rung 4 is design-time, not part of a scaffolded exporter, so
  the dedicated backbone harness is its home; no golden-smoke cell is added
  (noted, not silently omitted).

## 6. Non-regression guarantees

- Default discovery walk (`1→2→3→5`) unchanged when no live instance is
  offered; the only default-path output change is the Provenance wording for
  rung 4 (from "deferred" to "skipped — not activated"), which is the
  intended correction, not a regression.
- Backbone outside `assets/` → `scaffold.sh` ships nothing new;
  `test/zero-source-grep.sh` stays clean (no `slurm`/`sacct`/`sckyzo` in
  shipped surfaces) and is run before every commit.
- No Go touched → no scaffolded-exporter runtime behaviour changes at all.

## 7. Open questions / assumptions

- Final redaction pattern set is finalized in the plan; bias toward
  over-redaction (a false `<redacted>` is cheap; a leaked token is not).
- `curl` assumed present for http mode; if absent, the mode fails with a
  clear message and rung 4 is recorded as skipped (no `wget` fallback in v1).
- Conventional HTTP probe-path defaults (`/openapi.json`, `/metrics`, …) are
  *offered*, never auto-probed without the user naming/confirming one.

## 8. Out of scope

Sub-project 3b — multi-target `/probe?target=` runtime scaffolding — is a
separate spec/plan/SDD cycle after this lands.
