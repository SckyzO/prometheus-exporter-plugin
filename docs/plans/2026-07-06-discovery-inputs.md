# Discovery Inputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Broaden step-0 discovery from context7-only to a preference-ordered ladder (local API spec > docs folder/URL > context7 > dialogue), fronted by a new `/design-exporter` command that emits an architecture brief `/new-prometheus-exporter` can consume.

**Architecture:** A new reference (`discovery-inputs.md`) is the `[G]` knowledge home; a thin new command (`/design-exporter`) orchestrates it and writes a markdown *architecture brief*; `/new-prometheus-exporter` gains an optional branch that consumes a brief when present. The brief is consumed by the model executing the command prose — never parsed by `scaffold.sh`, which stays a dumb `sed` substitutor. Everything is additive: no brief present preserves today's interactive step 0 verbatim.

**Tech Stack:** Markdown (skill references + commands), POSIX `sh` (golden test in `test/golden-smoke.sh`), `claude plugin validate` (manifest gate), the plugin's existing container-first golden harness.

## Global Constraints

- **Additive & non-breaking.** A `/new-prometheus-exporter` run with no brief present must behave exactly as it does today. No default changes.
- **Zero-source gate.** `bash test/zero-source-grep.sh` must PASS before every commit. The source project name and the maintainer handle never appear in shipped files (`docs/`, `test/`, and root `.github/` are the only exempt trees). Use the harness's fictional `acme` / `demo_exporter` identity in every example.
- **No AI/automation attribution in any git artifact.** Commit with `git -c commit.gpgsign=false`; Conventional Commits with scope; no `Co-authored-by`, `Claude-Session`, `Generated with`, or `claude.ai` trailers.
- **English** for all shipped content and commit messages.
- **`[G]/[S]` discipline** in the reference: the generic *method* (how to read a spec into collectors) is `[G]`; any one target's endpoints are `[S]` and live only in that target's brief.
- **Brief default path** `./exporter-design-brief.md` (working directory), overridable by an explicit path.
- **Brief required sections**, verbatim headers: `## Provenance`, `## Architecture decisions`, `## Scaffold inputs`, `## Open questions / assumptions`. These are the contract the reference documents, the command writes, the fixture instantiates, and `/new` reads.
- **Identity fields never in the brief.** `MODULE_PATH`, `OWNER`, `LICENSE` are always asked by `/new`; the brief is purely about the target.
- **Live-target probe is out of scope** (deferred v0.2.x fast-follow) — documented as ladder rung 4, never implemented here.
- **`claude plugin validate .` must pass** after every task that touches `commands/` or `.claude-plugin/`.
- **Spec of record:** `docs/design/2026-07-06-discovery-inputs-design.md`.

---

## File Structure

**Created:**
- `skills/prometheus-exporter/references/discovery-inputs.md` — the discovery method: taxonomy, ladder, per-source extraction, degradation, the brief format. (Task 1)
- `test/fixtures/exporter-design-brief.md` — a realistic, zero-source-clean brief instance. (Task 2)
- `commands/design-exporter.md` — the front-door command. (Task 3)

**Modified:**
- `test/golden-smoke.sh` — the brief-contract structural check. (Task 2)
- `skills/prometheus-exporter/SKILL.md` — step-0 line, reference-index row, `context7-first` reframe. (Task 4)
- `skills/prometheus-exporter/references/exporter-architecture.md` — §1 lead-in + pointer; "Output of this phase" note. (Task 4)
- `commands/new-prometheus-exporter.md` — step-0 brief-consumption branch; step-1 note. (Task 5)
- `CHANGELOG.md` — `## [Unreleased]` entry. (Task 6)
- `ROADMAP.md` — moved at merge time (bookkeeping, not a task).

---

### Task 1: The `discovery-inputs.md` reference

**Files:**
- Create: `skills/prometheus-exporter/references/discovery-inputs.md`

**Interfaces:**
- Produces: the canonical **brief format** (consumed verbatim by Tasks 2, 3, 5) and the **ladder** (rungs 1–5, rung 4 deferred). Section headers of the brief are the frozen contract in Global Constraints.

This reference is prose, in the house style of the existing ten references under the same directory (open `exporter-architecture.md` and `collector-pattern.md` first to match tone, heading depth, and the `[G]/[S]` framing). There is no automated content test; the gates are the zero-source grep, `claude plugin validate`, and reviewer reading.

- [ ] **Step 1: Read two sibling references to match house style**

Run: read `skills/prometheus-exporter/references/exporter-architecture.md` and `skills/prometheus-exporter/references/collector-pattern.md`. Note: `##`-level sections, a short intro paragraph, `[G]`/`[S]` used inline, no first person, no source-project mention.

- [ ] **Step 2: Write the reference**

Create `skills/prometheus-exporter/references/discovery-inputs.md` with these sections, in order:

1. **Intro** (2–4 sentences): step 0's design quality is only as good as its grounding; today that grounding is context7 alone, which fails exactly for internal/proprietary targets context7 never indexed; this reference broadens grounding to a preference-ordered ladder that always degrades to a working result. Point back to `exporter-architecture.md` as the phase this feeds.

2. **`## The discovery ladder`** — introduce the ladder and include this table **verbatim**:

```markdown
| Rung | Source | Confidence | Degrades when |
|---|---|---|---|
| 1 | Local API spec (OpenAPI/Swagger/`.proto`) | High | no spec file offered |
| 2 | Docs folder or URL | Medium | none offered / URL unreachable |
| 3 | context7 (target's lib) | Medium | not installed, or no library match |
| 4 | *(deferred)* live-target probe | — | *(not shipped yet)* |
| 5 | Dialogue with the user | Low | — (always available; terminal rung) |
```

Follow it with the **degradation guarantees**: the phase never hard-fails; each unavailable rung is skipped with a one-line note recorded in the brief's Provenance; context7 absence is handled at two levels (MCP server absent → skip rung 3; installed but `resolve-library-id` returns no match → skip with a "context7 has no entry for the target" note); the walk uses the highest-confidence source available and *supplements* with lower rungs where they add detail; the brief always records which rung(s) grounded it and a resulting confidence.

3. **`## Per-source extraction`** — one short subsection per source, each giving a concrete method (never generic "analyze the docs"):
   - **OpenAPI/Swagger**: each tagged group of paths → a candidate collector; each `GET` returning a list/collection → a metric candidate; `servers[]` → `DATA_SOURCE`; the first collector's path → `DATA_SOURCE_PATH`; `securitySchemes` → the auth note; array responses → a cardinality warning.
   - **gRPC `.proto`**: each `service` → a candidate collector; each unary RPC returning a message with `repeated` fields → a metric candidate; note this is the gRPC-adapts-the-http-flavor case already described in `exporter-architecture.md` (no dedicated `grpc` flavor).
   - **Docs folder / URL**: read the files (or fetch the URL), extract documented endpoints/commands and the resources they expose; lower confidence than a machine-readable contract, so mark decisions as such.
   - **context7**: `resolve-library-id` on the target, then `query-docs` for its API surface; unchanged from today, now explicitly rung 3.
   - **Dialogue**: fall back to the `exporter-architecture.md` question flow.
   State the `[G]/[S]` rule explicitly: the extraction *method* is `[G]`; a target's actual endpoints are `[S]` and live only in that target's brief.

4. **`## The architecture brief`** — state the default path `./exporter-design-brief.md` (overridable), that it is consumed by the model running `/new-prometheus-exporter` (not parsed by `scaffold.sh`), that identity fields are deliberately excluded, and include this **exact** template:

````markdown
```markdown
# Exporter design brief: <target>

## Provenance
- Grounded by: <rung(s) actually used, e.g. "OpenAPI spec ./openapi.yaml">
- Skipped: <rungs skipped and why, e.g. "context7 — no entry for <target>">
- Confidence: <high | medium | low>

## Architecture decisions
- Data source: <REST API | gRPC | DB | CLI> — <base URL / command>
- I/O flavor: <http | cli>
- Target model: <single-target | multi-target (documented follow-up)>
- Collectors (ordered):
  1. `<name>` — <resource> — endpoint `<path>` — <one line>
  2. ...
- Cardinality budget: per collector — labels, worst-case series, reduction flag
- Business-alert candidates: per collector, one line each

## Scaffold inputs
- EXPORTER_NAME: <name>
- NAMESPACE: <suggested>
- DATA_SOURCE: <url or command>
- DATA_SOURCE_PATH: <first collector endpoint, or "unused" for CLI>
- DEFAULT_PORT: <port>

## Open questions / assumptions
- <anything discovery could not resolve — flagged for the user>
```
````

- [ ] **Step 3: Run the zero-source gate**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

- [ ] **Step 4: Validate the plugin manifest still loads**

Run: `claude plugin validate .`
Expected: validation success (no manifest errors).

- [ ] **Step 5: Commit**

```bash
git add skills/prometheus-exporter/references/discovery-inputs.md
git -c commit.gpgsign=false commit -m "docs(skill): add discovery-inputs reference for step-0 grounding"
```

---

### Task 2: Brief fixture + golden structural check (TDD)

**Files:**
- Create: `test/fixtures/exporter-design-brief.md`
- Modify: `test/golden-smoke.sh` (single-cell path, after `work=` is set at line 173, before the scaffold step)

**Interfaces:**
- Consumes: the brief format and its four required section headers from Task 1 / Global Constraints.
- Produces: a committed fixture and a tripwire that fails if any of the three format-touching artifacts renames a section.

This is the one deterministically-testable piece. The check is cell-independent (it verifies a plugin-shipped fixture, not scaffold output); it is placed **early in the single-cell path so it fails fast without a build**, matching the file's existing `$root`-scoped static-check idiom (e.g. the zero-source scan). It runs once per cell — trivially cheap — which is acceptable and consistent with the sibling `$root`-scoped checks already in the file.

- [ ] **Step 1: Write the golden check (test-first)**

In `test/golden-smoke.sh`, insert this block early in the single-cell path — after `work="$root/test/_work/$flavor-$forge"` (line 173) and before the scaffold is invoked. Match the file's three-way grep exit-code discipline is not needed here (fixed-string presence check), but reuse `command grep` and `die`:

```sh
# Brief-format contract (discovery-inputs epic): the shipped fixture must
# carry every section the discovery-inputs reference documents and
# /new-prometheus-exporter consumes. This is the tripwire for format drift
# across the reference, the command, and /new — three artifacts that must
# agree on these headers. Cell-independent (checks a committed fixture, not
# $work), placed early so it fails before any build.
echo "== brief-format contract: fixture carries every required section =="
brief_fixture="$root/test/fixtures/exporter-design-brief.md"
[ -f "$brief_fixture" ] || die "brief fixture missing: $brief_fixture"
for header in '## Provenance' '## Architecture decisions' '## Scaffold inputs' '## Open questions'; do
  if command grep -qF "$header" "$brief_fixture"; then
    echo "confirmed: fixture has section '$header'"
  else
    die "brief fixture missing required section '$header' ($brief_fixture)"
  fi
done
```

- [ ] **Step 2: Verify the check fails without the fixture**

Run the check logic in isolation (no build needed):

```sh
root=$(pwd); brief_fixture="$root/test/fixtures/exporter-design-brief.md"
[ -f "$brief_fixture" ] && echo "EXISTS" || echo "MISSING (expected at this step)"
```

Expected: `MISSING (expected at this step)` — confirming the check would `die` before the fixture exists.

- [ ] **Step 3: Write the fixture**

Create `test/fixtures/exporter-design-brief.md` (zero-source clean — `demo`/`acme` identity, no source-project or handle):

```markdown
# Exporter design brief: demo

## Provenance
- Grounded by: OpenAPI spec `./demo-openapi.yaml` (rung 1)
- Skipped: context7 (rung 3) — no library entry for this internal service; live-target probe (rung 4) — deferred capability
- Confidence: high

## Architecture decisions
- Data source: REST API — `http://localhost:9100`
- I/O flavor: http
- Target model: single-target
- Collectors (ordered):
  1. `queue` — job queue depth — endpoint `/api/v1/queues` — one gauge series per queue name
  2. `worker` — worker pool state — endpoint `/api/v1/workers` — counts by state
- Cardinality budget:
  - `queue`: label `queue` — worst case ~50 series — no reduction flag needed
  - `worker`: label `state` (fixed small enum) — ~5 series — none
- Business-alert candidates:
  - `queue`: page when a queue's depth exceeds its documented backlog ceiling for 10m
  - `worker`: warn when zero workers are in state `ready` for 5m

## Scaffold inputs
- EXPORTER_NAME: demo_exporter
- NAMESPACE: demo
- DATA_SOURCE: http://localhost:9100
- DATA_SOURCE_PATH: /api/v1/queues
- DEFAULT_PORT: 9100

## Open questions / assumptions
- Assumed `/api/v1/queues` is unpaginated; confirm against a live instance before building the `queue` collector if a deployment can exceed ~1000 queues.
```

- [ ] **Step 4: Verify the check passes with the fixture**

Run the isolated loop against the new fixture:

```sh
root=$(pwd); brief_fixture="$root/test/fixtures/exporter-design-brief.md"
for header in '## Provenance' '## Architecture decisions' '## Scaffold inputs' '## Open questions'; do
  command grep -qF "$header" "$brief_fixture" && echo "OK: $header" || echo "FAIL: $header"
done
```

Expected: four `OK:` lines, no `FAIL:`.

- [ ] **Step 5: Run one full golden cell to confirm wiring**

Run: `bash test/golden-smoke.sh --flavor http --forge none`
Expected: the run reaches and prints `== brief-format contract: fixture carries every required section ==` with four `confirmed:` lines, and the cell completes (build + checks) without error. If no container engine and no native Go toolchain are available, the harness SKIPs the build with a logged reason — the brief-format check still runs (it precedes the build); confirm its four `confirmed:` lines appear.

- [ ] **Step 6: Run the zero-source gate**

Run: `bash test/zero-source-grep.sh`
Expected: `PASS`.

- [ ] **Step 7: Commit**

```bash
git add test/fixtures/exporter-design-brief.md test/golden-smoke.sh
git -c commit.gpgsign=false commit -m "test(golden): assert the architecture-brief format contract"
```

---

### Task 3: The `/design-exporter` command

**Files:**
- Create: `commands/design-exporter.md`

**Interfaces:**
- Consumes: `discovery-inputs.md` (the method) and `exporter-architecture.md` (the dialogue) from Task 1 and the existing tree.
- Produces: a written `./exporter-design-brief.md` in the format Task 1 defines — the input Task 5 consumes.

Read `commands/new-prometheus-exporter.md` first to match command house style (frontmatter shape, imperative numbered steps, `${CLAUDE_PLUGIN_ROOT}` references, the explicit "side-effecting, invoke explicitly" framing).

- [ ] **Step 1: Write the command with this exact frontmatter**

Create `commands/design-exporter.md` starting with:

```markdown
---
description: Run the exporter architecture-design phase (step 0) with broadened discovery — ground the design in a local API spec, a docs folder or URL, or context7, in that preference order — then write a reviewable architecture brief that /new-prometheus-exporter can consume.
argument-hint: <target>
disable-model-invocation: true
---
```

- [ ] **Step 2: Write the command body**

After the frontmatter, the body (imperative prose the model executes) must, in order:

1. State that this command runs step 0 (design) and is *not* side-effecting beyond writing one brief file; it does **not** scaffold — that is `/new-prometheus-exporter`'s job.
2. Take the target from `$ARGUMENTS` (name or short description).
3. Instruct: read `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/discovery-inputs.md` for the ladder and per-source extraction, and `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/exporter-architecture.md` for the six decisions this phase must produce.
4. Walk the discovery ladder top-down: ask the user whether a local API spec (OpenAPI/Swagger/`.proto`) is available and at what path; else a docs folder or URL; else try context7 (`resolve-library-id` then `query-docs`); else fall back to dialogue. Record which rung(s) grounded the design and which were skipped and why.
5. Run the `exporter-architecture.md` question flow to fill any gaps and confirm the six decisions with the user (do not guess on their behalf).
6. Write the brief to `./exporter-design-brief.md` (or a path the user names) in the exact format from `discovery-inputs.md`, including the Provenance and Confidence, and with identity fields (`MODULE_PATH`, `OWNER`, `LICENSE`) deliberately absent.
7. Close by telling the user to review the brief, then run `/new-prometheus-exporter <name>` in the same directory to scaffold from it.

- [ ] **Step 3: Validate the plugin manifest and command load**

Run: `claude plugin validate .`
Expected: validation success.

- [ ] **Step 4: Run the zero-source gate**

Run: `bash test/zero-source-grep.sh`
Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add commands/design-exporter.md
git -c commit.gpgsign=false commit -m "feat(command): add /design-exporter for grounded step-0 design"
```

---

### Task 4: Router wiring (SKILL.md + exporter-architecture.md)

**Files:**
- Modify: `skills/prometheus-exporter/SKILL.md` (step 0 ~lines 31-46; `context7-first` ~lines 148-155; reference index ~lines 162-173)
- Modify: `skills/prometheus-exporter/references/exporter-architecture.md` (§1 ~lines 53-58; "Output of this phase" ~lines 200-220)

**Interfaces:**
- Consumes: the reference and command names from Tasks 1 and 3.
- Produces: nothing downstream depends on; this makes the capability discoverable from the router.

All edits are additive — existing guidance is preserved, not replaced.

- [ ] **Step 1: SKILL.md — extend step 0**

In the "### 0. Architecture design first (API-first)" section, after the existing sentence about using context7 to confirm the target's endpoints, add: discovery can also be grounded in a local API spec (OpenAPI/Swagger/`.proto`) or a docs folder/URL, in preference order; `/design-exporter <target>` runs this phase and writes an architecture brief `/new-prometheus-exporter` can consume. Then add a second pointer line under the existing `→ references/exporter-architecture.md`:

```markdown
→ `references/discovery-inputs.md`
```

- [ ] **Step 2: SKILL.md — reframe the `context7-first` principle**

In the `### context7-first` subsection, change the step-0 clause so context7 is no longer implied to be the only step-0 input. Replace the phrase describing step 0 (currently "This applies at step 0 (the target's own API) and step 1 …") so step 0 reads as "the best available grounding for the target's API — a local spec, its docs, or context7". Keep the step-1 clause unchanged.

- [ ] **Step 3: SKILL.md — add the reference-index row**

In the "## Reference index" table, add one row (and update the "All ten reference files" lead-in to "eleven"):

```markdown
| `discovery-inputs.md` | Step 0 — discovery input taxonomy, preference order, the degradation ladder, the architecture-brief format |
```

- [ ] **Step 4: exporter-architecture.md — §1 lead-in + pointer**

In §1, at the paragraph beginning "Whichever rung you land on, use context7 against the **target's own** documentation…" (line 53), add a lead-in sentence: context7 is one of several grounding inputs, used in the ladder's preference order (local spec first, then docs, then context7). Append a pointer at the end of that paragraph:

```markdown
See `discovery-inputs.md` for the full input ladder and per-source extraction method.
```

- [ ] **Step 5: exporter-architecture.md — "Output of this phase" note**

At the end of the "## Output of this phase" section (after the six-item checklist, ~line 220), add one sentence: when produced via `/design-exporter`, these six items are serialized into an architecture brief (`./exporter-design-brief.md`) that `/new-prometheus-exporter` consumes; see `discovery-inputs.md` for the format.

- [ ] **Step 6: Validate + zero-source gate**

Run: `claude plugin validate . && bash test/zero-source-grep.sh`
Expected: validation success and `PASS`.

- [ ] **Step 7: Commit**

```bash
git add skills/prometheus-exporter/SKILL.md skills/prometheus-exporter/references/exporter-architecture.md
git -c commit.gpgsign=false commit -m "docs(skill): wire discovery-inputs into the router and architecture reference"
```

---

### Task 5: `/new-prometheus-exporter` brief consumption

**Files:**
- Modify: `commands/new-prometheus-exporter.md` (step 0 ~lines 15-41; step 1 ~lines 43-59)

**Interfaces:**
- Consumes: the brief format (Task 1) and the fixture as a worked example (Task 2).
- Produces: nothing downstream; this is the terminal consumer.

Additive branch only. The no-brief path must remain today's interactive confirmation, verbatim. There is no shell test for this (the golden drives `scaffold.sh` directly, not the model-driven command); the gates are `claude plugin validate`, the zero-source grep, review, and a manual trace against the Task 2 fixture.

- [ ] **Step 1: Step 0 — add the optional brief-consumption branch**

In "## 0. Confirm the architecture decision is already made", before the existing interactive confirmation bullets, add a branch:

- Look for an architecture brief: an explicit path if the user named one, else `./exporter-design-brief.md` in the current directory.
- **If a brief is found:** read it; present its `## Architecture decisions` section to the user for confirmation (do not silently trust it — the user still owns the final call); take the `## Scaffold inputs` values as the defaults for step 1. Still ask for the identity fields (`MODULE_PATH`, `OWNER`, `LICENSE`), which the brief never contains.
- **If no brief is found:** proceed with the existing interactive confirmation below (unchanged).

Keep every existing bullet in this section intact as the no-brief path.

- [ ] **Step 2: Step 1 — note pre-filled variables**

In "## 1. Collect the template variables", after the sentence introducing the variable table, add one sentence: if a brief was consumed in step 0, `DATA_SOURCE`, `DATA_SOURCE_PATH`, `NAMESPACE`, `DEFAULT_PORT`, and the flavor arrive pre-filled from its `## Scaffold inputs` — confirm rather than re-ask them; `MODULE_PATH`, `OWNER`, and `LICENSE` are always asked here.

- [ ] **Step 3: Manual trace against the fixture**

Read `test/fixtures/exporter-design-brief.md` and confirm every `## Scaffold inputs` key it lists maps to a variable in step 1's table (`EXPORTER_NAME`, `NAMESPACE`, `DATA_SOURCE`, `DATA_SOURCE_PATH`, `DEFAULT_PORT`) and that the flavor (`http`) is derivable from `## Architecture decisions`. Record the mapping in the task report. Expected: every key maps; no orphan keys.

- [ ] **Step 4: Validate + zero-source gate**

Run: `claude plugin validate . && bash test/zero-source-grep.sh`
Expected: validation success and `PASS`.

- [ ] **Step 5: Commit**

```bash
git add commands/new-prometheus-exporter.md
git -c commit.gpgsign=false commit -m "feat(command): consume an architecture brief in /new-prometheus-exporter"
```

---

### Task 6: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md` (the `## [Unreleased]` section near the top)

**Interfaces:** none.

- [ ] **Step 1: Add the Unreleased entry**

Under `## [Unreleased]`, add:

```markdown
### Added

- **`/design-exporter <target>`** — runs the step-0 architecture-design phase
  with broadened discovery (a preference-ordered ladder: local API spec >
  docs folder/URL > context7 > dialogue, with graceful degradation) and writes
  a reviewable architecture brief.
- **`references/discovery-inputs.md`** — the discovery input taxonomy, the
  degradation ladder, per-source extraction methods, and the architecture-brief
  format.
- **`/new-prometheus-exporter` consumes an architecture brief** when one is
  present (`./exporter-design-brief.md` or a named path), pre-filling step-0
  decisions and step-1 variables; with no brief it stays fully interactive.
```

- [ ] **Step 2: Zero-source gate**

Run: `bash test/zero-source-grep.sh`
Expected: `PASS`.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git -c commit.gpgsign=false commit -m "docs(changelog): record the discovery-inputs epic"
```

---

## Post-plan (at merge, not a task)

- Move the discovery-inputs bullet in `ROADMAP.md` from the v0.2 list to reflect it as shipped.
- The final whole-branch review + `superpowers:finishing-a-development-branch` handle merge and tag (local; nothing pushed).
- Carried v0.1.1 minors remain in the SDD ledger, unrelated to this epic.
