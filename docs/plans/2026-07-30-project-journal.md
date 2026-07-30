# Project journal: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the architecture brief into a project journal that all four
commands read on entry and complete on exit, so building an exporter across
several sessions survives a compaction or a `/clear`.

**Architecture:** One committed Markdown file, `docs/exporter-journal.md`,
read by the model and never parsed by a script. The disk stays authoritative
on everything it can state (flavor, target model, namespace, collectors
built); the journal is sole authority on everything else (collectors planned,
budget as intent, conventions, why). The protocol lives once in a twelfth
reference; the four commands point at it. Three new scaffold-side artifacts
support it: a gitignored `samples/` for raw target material, a write-once
`CLAUDE.md`, and a regenerated collector block in the generated `README.md`.

**Tech Stack:** Markdown (references, commands, templates), POSIX sh for
`scaffold.sh` and the golden harness. No Go changes in this delivery.

**Spec:** [`docs/design/2026-07-30-project-journal-design.md`](../design/2026-07-30-project-journal-design.md)

## Global Constraints

- **English for every shipped artifact:** `SKILL.md`, `references/`,
  `assets/`, `commands/`, `agents/`, root `README.md` and `CLAUDE.md`.
  `docs/design/` and `docs/plans/` are working notes and may be in another
  language.
- **No em dash (U+2014) and no en dash (U+2013)** anywhere under `skills/` or
  `commands/`. Hard guard rail. Use a comma, a colon, or parentheses.
- **Conventional Commits with a scope.** **Never** a `Claude-Session:`
  trailer, a `Co-Authored-By: Claude` line, or any mention of AI assistance
  in a commit message, a command, a reference, or a template.
- **No hardcoded data source, metric prefix, endpoint path or maintainer
  identity in a template.** Those are `@@VAR@@` substitutions or explicit,
  clearly marked fill-in holes. Scaffold templates attribute the generated
  exporter to `@@OWNER@@`.
- **The [G]/[S] discipline.** A reference and a template keep only the
  **[G]eneric** shape. Anything **[S]pecific** becomes a `@@VAR@@` or a
  fill-in hole, and for this delivery lives in a project's own journal, never
  folded back into a shipped file.
- **Two-phase rule.** No load-bearing mechanism is replaced and removed in one
  commit. Everything in this plan is additive: the step-0 file keeps its name,
  no existing `@@VAR@@` changes meaning, `scaffold.sh` gains two substitutions
  and loses none.
- **No refusal added.** A journal that is absent or corrupt degrades to v0.7
  behaviour and the command completes its job. Exporters already scaffolded
  must keep working.
- **Gates, run verbatim, never a hand-assembled subset:**
  `sh test/zero-source-grep.sh`, `claude plugin validate .`, and
  `sh test/golden-smoke.sh --all`, which runs the six matrix cells
  sequentially and reports every failure rather than stopping at the first.
  There is no `--cell` flag: a single cell is run with
  `--flavor <http|cli> --forge <github|none> [--target-model <m>]`, and the
  six cells map as follows.

  | Cell | Invocation |
  |---|---|
  | `http-none` | `--flavor http --forge none` |
  | `http-github` | `--flavor http --forge github` |
  | `cli-none` | `--flavor cli --forge none` |
  | `cli-github` | `--flavor cli --forge github` |
  | `http-multi` | `--flavor http --forge none --target-model multi` |
  | `http-multi-instance` | `--flavor http --forge none --target-model multi-instance` |

  If a tool is missing from `PATH`, the Makefile routes it through a
  container image: make that path work rather than skipping the tool.
- **An assertion that cannot fail is not a test.** Every new assertion in this
  plan carries an explicit RED step that breaks what it guards and confirms
  the assertion goes red for that reason.

---

## Task 1: the twelfth reference

**Files:**
- Create: `skills/prometheus-exporter/references/project-journal.md`
- Modify: `skills/prometheus-exporter/references/discovery-inputs.md` (the
  `## The architecture brief` section, currently lines 146-200)
- Modify: `skills/prometheus-exporter/SKILL.md` (the reference index)

**Interfaces:**
- Consumes: nothing.
- Produces: the canonical section shape (`## Provenance`,
  `## Architecture decisions`, `## Scaffold inputs`, `## Collectors`,
  `## Cardinality budget`, `## Dashboards`, `## Session log`,
  `## Open questions / assumptions`), the ownership table, the reconciliation
  table, the degradation rules, and the resumption-block shape. Tasks 6 to 9
  point at this file rather than restating any of it.

- [ ] **Step 1: read what exists, so the new reference does not contradict it**

Read in full, they are the constraints this reference must fit:

```
skills/prometheus-exporter/references/discovery-inputs.md
skills/prometheus-exporter/references/collector-pattern.md   (## Fixtures)
commands/design-exporter.md
skills/prometheus-exporter/SKILL.md
```

- [ ] **Step 2: write `project-journal.md`**

Sections, in this order. Every one is [G]; no concrete endpoint, metric name
or label value appears anywhere in the file.

1. `## What the journal is for` — the durable state the four commands hand to
   each other. State the rule that fixes its scope: **the journal holds only
   what the repository cannot state about itself.** Anything derivable from
   disk is read from disk.
2. `## Lifecycle` — born as `./exporter-design-brief.md` in the working
   directory (name unchanged from today), moved to `docs/exporter-journal.md`
   and retitled `# Exporter journal: <name>` by `/new-prometheus-exporter`
   after scaffolding. Committed. Say why: an untracked file is destroyed by
   `git clean -xdf`, a routine command.
3. `## Format` — the eight frozen headers, verbatim, in order, with the
   annotated example below. State the position it inherits: consumed by the
   model, never parsed by a script, so the format optimizes for human review
   and model comprehension rather than machine parsing.
4. `## Section ownership` — the table below.
5. `## Reconciliation` — the table below, plus the rule that the tick boxes
   under `## Collectors` are a cache of disk truth, never a source, and that
   no correction is silent.
6. `## Degradation` — absent and corrupt, with the checkable definition of
   corrupt and the no-refusal rule.
7. `## The resumption block` — the shape every command ends with.

The format block to embed:

```markdown
# Exporter journal: <name>

## Provenance
- Grounded by: <rung(s) actually used>
- Skipped: <rungs skipped, and why>
- Confidence: <high | medium | low>
- Source material: <paths/URLs recorded at step 0, or "none offered">

## Architecture decisions
- Data source: <REST API | gRPC | CLI>, <base URL / command>
- I/O flavor: <http | cli>
- Target model: <single | multi | multi-instance>
- Credential convention: <a | b | c>            (multi only)
- Concurrency ceiling: <unlimited | N>          (single, multi-instance)
- Metric name shape: <namespace>_<subsystem>_<name>_<unit>
- Shared label vocabulary: <label>, <label>, <label>
- Business-alert candidates: per collector, one line each

## Scaffold inputs
- EXPORTER_NAME / NAMESPACE / DATA_SOURCE / DATA_SOURCE_PATH / DEFAULT_PORT
- Selectors actually passed: --flavor, --target-model, --forge, --instance-label

## Collectors
- [x] `<name>`  sync        built <date>
- [ ] `<name>`  background  endpoint <path>

## Cardinality budget
- `<name>`: labels <list>; worst case ~<N> series; observed <N>

## Dashboards
- <audience>, <RED | USE> because <reason>, <decomposition>, files: <paths>

## Session log
- <date> <command> <name>: <one line>

## Open questions / assumptions
- <anything discovery could not resolve>
```

Add, right under the block, the sentence that explains why one line matters
more than the others: if collector 1 emits `pool` and collector 7 emits
`pool_name`, no dashboard joins them, and nothing on disk states which is the
rule. Existing names can be observed; the convention cannot be derived.

The ownership table:

| Section | Created by | Completed by | Regime |
|---|---|---|---|
| `## Provenance` | `/design-exporter` | nobody | frozen on write |
| `## Architecture decisions` | `/design-exporter` | `/new-prometheus-exporter` | mutable |
| `## Scaffold inputs` | `/design-exporter` | `/new-prometheus-exporter` | frozen after scaffold |
| `## Collectors` | `/design-exporter` | `/add-collector` | mutable |
| `## Cardinality budget` | `/design-exporter` | `/add-collector` | mutable |
| `## Dashboards` | `/generate-dashboard` | `/generate-dashboard` | mutable |
| `## Session log` | `/design-exporter` | all four | append-only |
| `## Open questions / assumptions` | `/design-exporter` | all four | mutable |

The reconciliation table:

| Read from disk | How | If the journal disagrees |
|---|---|---|
| I/O flavor | `internal/collector/client.go` vs `execute.go` | corrected, reported |
| Target model | `internal/instance/` vs `internal/probe/` vs neither | corrected, reported |
| Namespace | `const namespace = "..."` in `cmd/*/main.go` | corrected, reported |
| Collectors built | `## <Name>Collector` headers in `docs/metrics.md` | box ticked or unticked, marked `(reconciled <date>)`, reported |

The degradation rules, verbatim in intent:

> **Corrupt** has a checkable definition, not a judgement call: the file
> exists but has no `# Exporter journal:` title line, or is missing at least
> one of the required `##` headers.
>
> **Absent.** The command does exactly what it did before this file existed,
> all the way through. At the end it offers to build the journal: derivable
> facts read from disk, non-derivable ones asked.
>
> **Corrupt.** The command also does its full job, then asks: rebuild with a
> backup at `docs/exporter-journal.md.bak`, or leave it untouched. It writes
> nothing before an answer.
>
> Never a refusal. A missing documentation file is not a dangerous seam.

The resumption block shape:

```
<what this command just did>. <its gate> is green.
Journal: <N> of <M> collectors built. Next planned: `<name>` (<variant>).

Safe to /clear now: everything above is in docs/exporter-journal.md.
Then run:

    /<next-command> <argument read from the journal>
```

- [ ] **Step 3: reduce `discovery-inputs.md`'s brief section to a pointer**

Replace the whole of `## The architecture brief` (its format block and the
paragraph mapping each section to a ladder output) with a short section that
keeps only what belongs to the ladder, and points at the new reference for the
format. Two files describing one artifact diverge; that is a certainty, not a
risk.

Keep in `discovery-inputs.md`: that the ladder's output is a single Markdown
file, `./exporter-design-brief.md` by default, that identity fields
(`MODULE_PATH`, `OWNER`, `LICENSE`) are deliberately absent, and that
`## Provenance` is the ladder's own audit trail. Add one line: the ladder now
also records, under `## Provenance`, a `Source material:` entry naming the
paths or URLs it was given.

- [ ] **Step 4: index the new reference in `SKILL.md`**

Add `project-journal.md` to the reference list with a one-line description
matching the style of the eleven already there.

- [ ] **Step 5: run the documentation gates**

```sh
sh test/zero-source-grep.sh
claude plugin validate .
```

Expected: `zero-source-grep.sh: PASS`, and `✔ Validation passed`.

- [ ] **Step 6: check the dash guard rail yourself**

```sh
grep -rnP '[\x{2013}\x{2014}]' skills/ commands/
```

Expected: no output. Any hit is a violation of the global constraint and must
be fixed before committing.

- [ ] **Step 7: commit**

```bash
git add skills/prometheus-exporter/references/project-journal.md \
        skills/prometheus-exporter/references/discovery-inputs.md \
        skills/prometheus-exporter/SKILL.md
git commit -m "docs(skill): add the project-journal reference" \
  -m "Holds the journal's format, its read-on-entry / write-on-exit protocol,
the section-ownership and reconciliation tables, the absent/corrupt
degradation rules, and the resumption block, once, so the four commands
point at it instead of restating it four times.

discovery-inputs.md keeps only what belongs to the discovery ladder and
points here for the format: two files describing one artifact diverge."
```

---

## Task 2: `scaffold.sh` exposes the target model and the flavor

**Files:**
- Modify: `skills/prometheus-exporter/assets/scaffold.sh` (two `printf` lines,
  and the header comment listing what it substitutes)
- Test: `test/scaffold_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `@@TARGET_MODEL@@` (one of `single`, `multi`, `multi-instance`)
  and `@@FLAVOR@@` (one of `http`, `cli`), available to any template. Task 4
  is their only consumer today.

The precedent to copy exactly is `@@INSTANCE_LABEL@@`, which is already
registered from a selector rather than from a `--var`, immediately after its
own validation.

- [ ] **Step 1: write the failing test**

Append to `test/scaffold_test.sh`, immediately before the final
`echo "PASS"`:

```sh
# Selector-derived substitutions: --target-model and --flavor are exposed as
# @@TARGET_MODEL@@/@@FLAVOR@@ so a template can state what this repo is,
# mirroring how --instance-label already exposes @@INSTANCE_LABEL@@.
printf 'model=@@TARGET_MODEL@@ flavor=@@FLAVOR@@\n' > "$here/fixtures/mini-template/selectors.txt.tmpl"
sh "$root/skills/prometheus-exporter/assets/scaffold.sh" \
  --src "$here/fixtures/mini-template" \
  --dst "$work/sel" \
  --flavor http --forge none --target-model multi-instance \
  --var EXPORTER_NAME=redis_exporter \
  --var NAMESPACE=redis \
  --var OWNER=acme
rm -f "$here/fixtures/mini-template/selectors.txt.tmpl"
grep -q '^model=multi-instance flavor=http$' "$work/sel/selectors.txt" \
  || fail "@@TARGET_MODEL@@/@@FLAVOR@@ not substituted: $(cat "$work/sel/selectors.txt")"
```

- [ ] **Step 2: run it to confirm it fails, and for the right reason**

```sh
sh test/scaffold_test.sh
```

Expected: non-zero exit. The failure must come from `scaffold.sh`'s own
residual-sentinel guard (exit 3, naming `@@TARGET_MODEL@@`), because an
unsubstituted sentinel is exactly what is missing. If it fails with anything
else, the test is wrong, not the implementation.

- [ ] **Step 3: register the two substitutions**

In `scaffold.sh`, immediately after the `case "$target_model" in
single|multi|multi-instance) ;; ... esac` validation block:

```sh
printf 's/@@TARGET_MODEL@@/%s/g\n' "$(sed_escape_repl "$target_model")" >> "$sedscript"
```

And immediately after the `case "$flavor" in ''|.|*/*|*..*) die ... esac`
single-path-component validation block:

```sh
printf 's/@@FLAVOR@@/%s/g\n' "$(sed_escape_repl "$flavor")" >> "$sedscript"
```

Both go **after** their own validation, never before: an unvalidated value
must never reach the sed script.

- [ ] **Step 4: document them in the script header**

In the header comment block that lists what the script substitutes, add
`@@TARGET_MODEL@@` and `@@FLAVOR@@` alongside `@@INSTANCE_LABEL@@`, with the
same one-line framing: derived from a selector, not from a `--var`.

- [ ] **Step 5: run the tests**

```sh
sh test/scaffold_test.sh
sh test/scaffold_edge_test.sh
sh test/scaffold_multitarget_test.sh
```

Expected: `PASS` from each. The edge and multitarget suites must stay green:
they are the regression net for the argument parser these two lines sit in.

- [ ] **Step 6: commit**

```bash
git add skills/prometheus-exporter/assets/scaffold.sh test/scaffold_test.sh
git commit -m "feat(scaffold): expose the target model and flavor as substitutions" \
  -m "Both are selectors today, not --var substitutions, so no template can
state what a scaffolded repo actually is. Registers @@TARGET_MODEL@@ and
@@FLAVOR@@ from the already-parsed selectors, immediately after their own
validation, exactly as --instance-label already registers
@@INSTANCE_LABEL@@.

Additive: no existing template references either sentinel, so no
substitution changes meaning."
```

---

## Task 3: `samples/`, the raw-material directory

**Files:**
- Create: `skills/prometheus-exporter/assets/samples/README.md.tmpl`
- Modify: `skills/prometheus-exporter/assets/.gitignore.tmpl`
- Test: `test/golden-smoke.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a `samples/` directory in every scaffolded repository, tracked
  only through its `README.md`. Task 8 derives fixtures from its contents;
  Task 6 records the paths that fill it.

- [ ] **Step 1: write the failing assertion**

In `test/golden-smoke.sh`, immediately after the existing
`== no master-branch assumption in generated docs/release-process.md ==`
block (the `git init` at the top of that region is what makes
`git check-ignore` work here):

```sh
# samples/ holds raw target output and the target's own API documentation.
# It must survive a clone (so its README is tracked) while its contents never
# reach git (they are not anonymized and may carry hostnames, tenants,
# credentials, or third-party documentation). Both halves are asserted:
# a directory that is fully ignored would not exist after a clone, and a
# directory that is fully tracked would leak.
echo "== samples/ survives a clone, its contents do not ($flavor/$forge) =="
[ -d "$work/samples" ] || die "samples/ missing after scaffold ($flavor/$forge)"
[ -f "$work/samples/README.md" ] || die "samples/README.md missing after scaffold ($flavor/$forge)"
if git -C "$work" check-ignore -q samples/README.md; then
  die "samples/README.md is gitignored; samples/ would not survive a clone ($flavor/$forge)"
fi
printf '{"gate": 1}\n' > "$work/samples/_gate-probe.json"
git -C "$work" check-ignore -q samples/_gate-probe.json \
  || die "a file dropped in samples/ is NOT gitignored ($flavor/$forge)"
rm -f "$work/samples/_gate-probe.json"
```

- [ ] **Step 2: run one cell to confirm it fails**

```sh
sh test/golden-smoke.sh --flavor http --forge none
```

Expected: fails at `samples/ missing after scaffold (http/none)`.

- [ ] **Step 3: write `assets/samples/README.md.tmpl`**

```markdown
# samples/

Raw material gathered from whatever `@@EXPORTER_NAME@@` monitors: captured
output (HTTP responses, command output) and the target's own API
documentation (an OpenAPI or gRPC specification, exported doc pages).

Everything in this directory is **ignored by git**, except this file. That is
deliberate, for two independent reasons:

- **It is not anonymized.** Captured output routinely carries real hostnames,
  tenant names, account names, and sometimes credentials. `CONTRIBUTING.md`
  requires every test fixture to be anonymized before it is committed, and
  forbids committing output copy-pasted from a production system.
- **It may not be yours to redistribute.** A vendor's API documentation
  carries its own terms, which this repository's license does not decide.

This file is tracked so the directory itself survives a clone. Git does not
track empty directories.

## How it is used

Material here is **derived from, never moved out of**. A collector's fixture
under `internal/collector/testdata/` is a *trimmed and anonymized* copy of
something here; the original stays, because one capture commonly covers
several resources and because a later collector should not have to go back to
the live target to get it again.

```
samples/pools-list.json          raw, NOT anonymized, stays here
        |
        v  trim to the parsed shape, anonymize per CONTRIBUTING.md
internal/collector/testdata/pools.json    committed
```

## What does not go here

The exporter's own documentation. `docs/` is written for the people who run
this exporter; a vendor's documentation is working material, not a
deliverable.
```

- [ ] **Step 4: add the two `.gitignore.tmpl` rules**

Append to `skills/prometheus-exporter/assets/.gitignore.tmpl`, before the
trailing `.DS_Store` line:

```
# Raw material gathered from the monitored target: captured output and the
# target's own API documentation. Ignored because it is NOT anonymized and
# may carry real hostnames, tenants or credentials, and because third-party
# documentation carries redistribution terms this repository does not decide.
# The README is kept tracked so the directory survives a clone: git does not
# track empty directories. See samples/README.md.
/samples/*
!/samples/README.md
```

- [ ] **Step 5: run the same cell to confirm it passes**

```sh
sh test/golden-smoke.sh --flavor http --forge none
```

Expected: the `samples/ survives a clone` line prints and the run continues.

- [ ] **Step 6: prove the assertion can fail, for each half**

This is the step that makes it a test rather than decoration.

```sh
# RED 1: remove the negation, so the README is ignored too.
sed -i 's|^!/samples/README.md$|# !/samples/README.md|' skills/prometheus-exporter/assets/.gitignore.tmpl
sh test/golden-smoke.sh --flavor http --forge none
```

Expected: fails with `samples/README.md is gitignored; samples/ would not
survive a clone`.

```sh
git checkout skills/prometheus-exporter/assets/.gitignore.tmpl
# RED 2: remove the ignore rule, so dropped captures would be committed.
sed -i 's|^/samples/\*$|# /samples/*|' skills/prometheus-exporter/assets/.gitignore.tmpl
sh test/golden-smoke.sh --flavor http --forge none
```

Expected: fails with `a file dropped in samples/ is NOT gitignored`.

```sh
git checkout skills/prometheus-exporter/assets/.gitignore.tmpl
```

Re-apply Step 4's edit before continuing (the `git checkout` above reverted
it). Confirm with `sh test/golden-smoke.sh --flavor http --forge none` going green
again.

- [ ] **Step 7: run the full matrix and the source gate**

```sh
sh test/golden-smoke.sh --all
sh test/zero-source-grep.sh
```

Expected: six green cells and `zero-source-grep.sh: PASS`. Run every cell,
not a subset: the subset you run decides what you can find.

- [ ] **Step 8: commit**

```bash
git add skills/prometheus-exporter/assets/samples/README.md.tmpl \
        skills/prometheus-exporter/assets/.gitignore.tmpl \
        test/golden-smoke.sh
git commit -m "feat(templates): ship a gitignored samples/ for raw target material" \
  -m "Captured target output and the target's own API documentation now have
a home in the generated repo, separate from internal/collector/testdata/:
one is raw and may carry hostnames, tenants or credentials, the other is
trimmed, anonymized and committed. Material is derived from, never moved
out of, so one capture can feed several collectors and a later session
does not have to go back to the live target.

Tracked through its README only, because git does not track empty
directories. Golden asserts both halves: the README survives a clone, a
dropped capture does not."
```

---

## Task 4: `CLAUDE.md` in the generated repository

**Files:**
- Create: `skills/prometheus-exporter/assets/CLAUDE.md.tmpl`
- Test: `test/golden-smoke.sh`

**Interfaces:**
- Consumes: `@@TARGET_MODEL@@` and `@@FLAVOR@@` from Task 2;
  `@@EXPORTER_NAME@@`, `@@NAMESPACE@@`, `@@DEFAULT_PORT@@` from the existing
  `--var` set.
- Produces: nothing later tasks depend on. Written once at scaffold time and
  never rewritten by any command.

- [ ] **Step 1: write the failing assertion**

In `test/golden-smoke.sh`, immediately after Task 3's `samples/` block:

```sh
# CLAUDE.md states this repository's invariants. The generic no-residual-
# sentinel scan would catch an entirely unsubstituted @@TARGET_MODEL@@, but
# not a template that hardcodes "single" in every cell, which is the failure
# this assertion exists for.
echo "== CLAUDE.md states this cell's real target model and flavor ($flavor/$forge) =="
claude_md="$work/CLAUDE.md"
[ -f "$claude_md" ] || die "CLAUDE.md missing after scaffold ($flavor/$forge)"
grep -q "^| Target model | \`$target_model\` |$" "$claude_md" \
  || die "CLAUDE.md does not state target model '$target_model' ($flavor/$forge): $(grep -n 'Target model' "$claude_md" 2>/dev/null || echo '<no Target model row>')"
grep -q "^| I/O flavor | \`$flavor\` |$" "$claude_md" \
  || die "CLAUDE.md does not state I/O flavor '$flavor' ($flavor/$forge): $(grep -n 'I/O flavor' "$claude_md" 2>/dev/null || echo '<no I/O flavor row>')"
```

- [ ] **Step 2: run one cell to confirm it fails**

```sh
sh test/golden-smoke.sh --flavor http --forge none --target-model multi-instance
```

Expected: fails at `CLAUDE.md missing after scaffold (http/none)` for that
cell's flavor/forge pair.

- [ ] **Step 3: write `assets/CLAUDE.md.tmpl`**

Short on purpose. It must not restate `CONTRIBUTING.md`, which already carries
the Definition of Done, the commit convention and the Test Data rules.

````markdown
# CLAUDE.md

Guidance for working in `@@EXPORTER_NAME@@`, a Prometheus exporter written in
Go. This file states what this repository *is*; `CONTRIBUTING.md` states how
to change it, and is the one to read in full before a first change.

## Invariants

| Fact | Value |
|---|---|
| Metric namespace | `@@NAMESPACE@@` |
| Target model | `@@TARGET_MODEL@@` |
| I/O flavor | `@@FLAVOR@@` |
| Default port | `@@DEFAULT_PORT@@` |

These four are fixed at scaffold time. Changing any of them is a regeneration,
not an edit: the target model decides how `/metrics` is assembled and the
flavor decides the collector factory signature, so a half-converted repository
compiles into a shape nothing else expects.

## Where state lives

| Question | Answer, on disk |
|---|---|
| What does this exporter emit? | `docs/metrics.md`, enforced by `make docs-check` |
| What is configurable? | `config.example.yml`, `docs/configuration.md` |
| What alerts ship? | `monitoring/prometheus/alerts.yml` |
| What is left to build, and why? | `docs/exporter-journal.md` |

`docs/exporter-journal.md` is the project journal. It carries what the code
cannot state about itself: the collectors still planned, the cardinality
budget as an intention, the naming conventions this exporter agreed on, and
the reasoning behind each decision. Read it before starting work, and treat
the code as authoritative wherever the two disagree.

## `samples/`

`samples/` holds raw output captured from the monitored target and the
target's own API documentation. Its contents are gitignored and **not
anonymized**. Nothing goes from there into `internal/collector/testdata/`
without being trimmed and anonymized first: see `CONTRIBUTING.md`, "Test
Data", and `samples/README.md`.

## The gate

```sh
make check
```

Runs vet, lint, test, vulnerability scanning, workflow linting, dead-code
detection and `docs-check`. A container engine is the only requirement; pass
`NATIVE=1` to run against a host Go toolchain instead. Do not declare work
finished on a subset of it.

## Resuming after a cleared context

This repository is designed to be built across several sessions. Everything
that must survive is on disk, so clearing the context between two collectors
loses nothing that matters: reread `docs/exporter-journal.md` and
`docs/metrics.md`, and pick up from the first unticked collector.
````

- [ ] **Step 4: run the same cell to confirm it passes**

```sh
sh test/golden-smoke.sh --flavor http --forge none --target-model multi-instance
```

Expected: the `CLAUDE.md states this cell's real target model and flavor` line
prints and the run continues.

- [ ] **Step 5: prove the assertion can fail for the reason it claims**

```sh
# RED: remove the substitution, leaving the template to be filled by nothing.
sed -i '/@@TARGET_MODEL@@/d' skills/prometheus-exporter/assets/scaffold.sh
sh test/golden-smoke.sh --flavor http --forge none --target-model multi-instance
```

Expected: fails at the CLAUDE.md assertion, or at `scaffold.sh`'s own
residual-sentinel guard. Either is acceptable evidence that the assertion is
wired to a real substitution, but read the message: if it fails at neither,
the assertion is decoration.

```sh
git checkout skills/prometheus-exporter/assets/scaffold.sh
sh test/golden-smoke.sh --flavor http --forge none --target-model multi-instance
```

Expected: green again.

- [ ] **Step 6: run the full matrix and the source gate**

```sh
sh test/golden-smoke.sh --all
sh test/zero-source-grep.sh
```

Expected: six green cells and `zero-source-grep.sh: PASS`. The six cells are
what makes this assertion meaningful: it compares against each cell's own
`$target_model` and `$flavor`, so a hardcoded value passes one cell and fails
five.

- [ ] **Step 7: commit**

```bash
git add skills/prometheus-exporter/assets/CLAUDE.md.tmpl test/golden-smoke.sh
git commit -m "feat(templates): ship a CLAUDE.md in every scaffolded exporter" \
  -m "States the repository's invariants (namespace, target model, I/O
flavor, default port), where each kind of state lives on disk, what
samples/ is and is not, and that the gate is make check. Points at
CONTRIBUTING.md rather than restating the Definition of Done or the
commit convention.

Written once at scaffold time and never rewritten: everything that
evolves belongs in the journal, which is what removes any risk of
overwriting an owner's edits here."
```

---

## Task 5: the README's generated collector block

**Files:**
- Modify: `skills/prometheus-exporter/assets/README.md.tmpl` (the `## Metrics`
  section, currently line 193)
- Test: `test/golden-smoke.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a marker pair, `<!-- BEGIN GENERATED COLLECTORS -->` and
  `<!-- END GENERATED COLLECTORS -->`, that Task 8 regenerates the contents
  of. The exact marker strings are the contract between the two tasks.

- [ ] **Step 1: write the failing assertion**

In `test/golden-smoke.sh`, immediately after Task 4's `CLAUDE.md` block:

```sh
# The README carries a generated collector list between two markers.
# /add-collector regenerates everything between them from docs/metrics.md.
# Assert the markers exist exactly once each, in the right order, and that
# the block is not empty on a fresh scaffold.
echo "== README carries the generated-collectors markers, paired and ordered ($flavor/$forge) =="
readme="$work/README.md"
[ -f "$readme" ] || die "README.md missing after scaffold ($flavor/$forge)"
n_begin=$(grep -c '^<!-- BEGIN GENERATED COLLECTORS -->$' "$readme" || true)
n_end=$(grep -c '^<!-- END GENERATED COLLECTORS -->$' "$readme" || true)
[ "$n_begin" = 1 ] || die "expected exactly 1 BEGIN GENERATED COLLECTORS marker in README.md, found $n_begin ($flavor/$forge)"
[ "$n_end" = 1 ] || die "expected exactly 1 END GENERATED COLLECTORS marker in README.md, found $n_end ($flavor/$forge)"
l_begin=$(grep -n '^<!-- BEGIN GENERATED COLLECTORS -->$' "$readme" | cut -d: -f1)
l_end=$(grep -n '^<!-- END GENERATED COLLECTORS -->$' "$readme" | cut -d: -f1)
[ "$l_begin" -lt "$l_end" ] || die "README.md collector markers out of order (BEGIN line $l_begin, END line $l_end) ($flavor/$forge)"
grep -q '^- \[`example`\](docs/metrics.md#examplecollector)$' "$readme" \
  || die "README.md generated block does not list the bundled example collector ($flavor/$forge)"
```

- [ ] **Step 2: run one cell to confirm it fails**

```sh
sh test/golden-smoke.sh --flavor cli --forge none
```

Expected: fails at `expected exactly 1 BEGIN GENERATED COLLECTORS marker in
README.md, found 0`.

- [ ] **Step 3: add the block to `README.md.tmpl`**

Insert directly under the `## Metrics` heading, **before** the existing
delegation paragraph, which stays exactly as it is:

```markdown
## Metrics

<!-- BEGIN GENERATED COLLECTORS -->
<!-- Regenerated from docs/metrics.md. Edits inside this block are overwritten. -->
- [`example`](docs/metrics.md#examplecollector)
<!-- END GENERATED COLLECTORS -->

Every metric this exporter can emit, grouped by collector, is documented in
```

Name and anchor only. No description, because `docs/metrics.md` carries none
and the journal is not verified by `make docs-check`. No metric names, because
that would be the duplication this block exists to avoid.

- [ ] **Step 4: run the same cell to confirm it passes**

```sh
sh test/golden-smoke.sh --flavor cli --forge none
```

Expected: the marker assertion line prints and the run continues.

- [ ] **Step 5: prove the assertion can fail**

```sh
# RED: remove the END marker.
sed -i '/^<!-- END GENERATED COLLECTORS -->$/d' skills/prometheus-exporter/assets/README.md.tmpl
sh test/golden-smoke.sh --flavor cli --forge none
```

Expected: fails with `expected exactly 1 END GENERATED COLLECTORS marker in
README.md, found 0`.

```sh
git checkout skills/prometheus-exporter/assets/README.md.tmpl
```

Re-apply Step 3's edit, then confirm green again with
`sh test/golden-smoke.sh --flavor cli --forge none`.

- [ ] **Step 6: run the full matrix**

```sh
sh test/golden-smoke.sh --all
```

Expected: six green cells.

- [ ] **Step 7: commit**

```bash
git add skills/prometheus-exporter/assets/README.md.tmpl test/golden-smoke.sh
git commit -m "feat(templates): add a generated collector block to the README" \
  -m "Names and anchors only, between two markers, regenerated in full from
docs/metrics.md rather than appended, so it is a projection of a source
that make docs-check already locks and cannot drift.

The rest of the README stays owner-owned: nothing else in it goes stale
when a collector is added, since its Metrics section already delegates to
docs/metrics.md and its Features and Endpoints sections describe the
exporter rather than its collectors."
```

---

## Task 6: `/design-exporter` opens the journal

**Files:**
- Modify: `commands/design-exporter.md`

**Interfaces:**
- Consumes: the format and protocol from Task 1's reference.
- Produces: `./exporter-design-brief.md` containing all eight sections, with
  `## Collectors` populated and unticked. Task 7 moves this file.

- [ ] **Step 1: point step 1 at the new reference**

In `## 1. Read the two references this phase runs on`, retitle to three and
add:

```markdown
- `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/project-journal.md`:
  the journal's format and the protocol every command follows.
```

- [ ] **Step 2: record source material in step 2**

In `## 2. Walk the discovery ladder, top-down`, after the rung list, add:

```markdown
Rungs 1 and 2 already ask for a path or a URL. **Record it.** Whatever the
user names, and whatever the live probe was pointed at, goes into the brief's
`## Provenance` section as a `Source material:` line, so a later session does
not have to ask again or re-solicit a running machine.

Say this to the user plainly, once, at the top of the walk:

> Put whatever you already have wherever suits you, and tell me where: an
> OpenAPI or gRPC specification, exported documentation pages, and any output
> you have captured from the target by hand. I will record the paths. If you
> have none, that is fine: nothing here is blocking, and the plugin will
> produce what it needs as we go.
```

- [ ] **Step 3: add the naming-convention question to step 3**

In `## 3. Confirm the six architecture decisions with the user`, after
decision 5 (cardinality budget), add a decision 5b. Keep the numbering of 6
(business-alert candidates) unchanged so nothing downstream shifts:

```markdown
5b. **Naming conventions**, asked once and binding on every collector. Two
    parts, both recorded under `## Architecture decisions`:

    - **Metric name shape**: confirm
      `<namespace>_<subsystem>_<name>_<unit>` or the variant this exporter
      will actually use, following `prometheus-principles.md`.
    - **Shared label vocabulary**: the label names that will recur across
      collectors. Ask for the exact spelling of each, and write it down.

    This is the cheapest decision to make now and the most expensive to
    discover late. If the first collector emits `pool` and the seventh emits
    `pool_name`, no dashboard can join them, and nothing on disk states which
    one is the rule: existing names can be observed, a convention cannot be
    derived. Record as:

    ```
    - Metric name shape: <namespace>_<subsystem>_<name>_<unit>
    - Shared label vocabulary: pool, node, tenant
    ```
```

- [ ] **Step 4: rewrite step 4's output shape**

Replace the four-header block in `## 4. Write the architecture brief` with the
eight-header shape, and replace the per-section prose with the additions:

```markdown
Use the exact section shape `project-journal.md` defines, verbatim headers,
in this order:

```markdown
# Exporter design brief: <target>

## Provenance
## Architecture decisions
## Scaffold inputs
## Collectors
## Cardinality budget
## Dashboards
## Session log
## Open questions / assumptions
```

The three sections beyond today's four:

- `## Collectors`: the ordered list from decision 4, as an unticked checklist,
  one line each, carrying the sync/background variant decided there and the
  endpoint or command it will read. This is the list `/add-collector` walks,
  one entry per session.
- `## Cardinality budget`: decision 5, per collector, as an **intention**
  (labels, worst-case series, any planned reduction flag). `/add-collector`
  will later append what was actually observed next to it.
- `## Dashboards`: left with a single line, `- (none yet)`.
  `/generate-dashboard` owns it.
- `## Session log`: opened with this phase's own entry, one line, dated.

`## Provenance` gains its `Source material:` line from step 2. Write the file,
then never rewrite `## Provenance` again: it is the ladder's audit trail, and
rewriting it erases why the design is trusted at the confidence it claims.
```

- [ ] **Step 5: add the resumption block to step 5**

Replace the closing paragraph of `## 5. Hand off to scaffolding` with:

```markdown
This command's job ends with the brief. It does not scaffold anything. End
with the resumption block `project-journal.md` defines, filled from what was
just written:

```
Design brief written to ./exporter-design-brief.md.
Journal: 0 of <N> collectors built. First planned: `<name>` (<variant>).

Review the brief, then it is safe to /clear: everything above is in the file.
Then run:

    /new-prometheus-exporter <name>
```

Never invoke that command yourself. Print it.
```

- [ ] **Step 6: run the gates**

```sh
sh test/zero-source-grep.sh
claude plugin validate .
grep -rnP '[\x{2013}\x{2014}]' commands/design-exporter.md
```

Expected: `PASS`, `✔ Validation passed`, and no output from the dash scan.

- [ ] **Step 7: read the command end to end**

The prose protocol has no automated gate (see the spec, §10.3). Read
`commands/design-exporter.md` from the top and confirm: step numbering is
consistent, the eight headers match `project-journal.md` character for
character, and no step promises a section that step 4 does not write.

- [ ] **Step 8: commit**

```bash
git add commands/design-exporter.md
git commit -m "feat(command): design-exporter opens the project journal" \
  -m "Writes all eight journal sections instead of four: the planned
collector checklist, the cardinality budget as an intention, an empty
dashboards section and a dated session log join the existing four.

Adds two questions. Source material (spec, docs, captured output) is now
recorded under Provenance instead of consumed and forgotten, so a later
session does not re-ask or re-solicit a running machine. Naming
conventions (metric name shape, shared label vocabulary) are settled once
and bind every collector: a convention can be observed in existing names
but never derived from them."
```

---

## Task 7: `/new-prometheus-exporter` moves the journal into the repository

**Files:**
- Modify: `commands/new-prometheus-exporter.md`

**Interfaces:**
- Consumes: `./exporter-design-brief.md` as written by Task 6; `samples/` as
  shipped by Task 3.
- Produces: `docs/exporter-journal.md` in the scaffolded repository, titled
  `# Exporter journal: <name>`, with `## Scaffold inputs` frozen. Tasks 8 and
  9 read this path.

- [ ] **Step 1: point step 0 at the new reference**

In `## 0. Confirm the architecture decision is already made`, add after the
"If a brief is found" bullet:

```markdown
Read
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/project-journal.md`
before step 3b: the brief found here becomes this repository's journal, and
that reference owns the move.
```

- [ ] **Step 2: add step 3b**

Insert a new section immediately after `## 3. Scaffold the repository`, before
whatever follows it:

````markdown
## 3b. Turn the brief into this repository's journal

The scaffold has just run and `<target-dir>` is a fresh git repository. Do
these four things, in order, and report each one.

**1. Offer to bring the source material in.** If the brief's `## Provenance`
carries a `Source material:` line naming local paths, show them and ask
whether to copy them into `<target-dir>/samples/`. Copy, never move: the
user's originals stay where they are. A URL is recorded, not fetched. If
there is no such line, say so and move on: `samples/` stays empty except for
its README, and `/add-collector` will fall back to its own fixture
generation.

**2. Move the brief.** `git mv` is wrong here (the brief was never in this
repository); copy it to `<target-dir>/docs/exporter-journal.md`, then remove
the original only after confirming the copy exists. Retitle the first line
from `# Exporter design brief: <target>` to `# Exporter journal: <name>`.

**3. Freeze `## Scaffold inputs`.** Append the selectors actually passed to
`scaffold.sh`, which the brief never contained because they are the
scaffolder's own choices:

```
- Selectors actually passed: --flavor <f>, --target-model <m>, --forge <g>[, --instance-label <l>]
```

Do not rewrite the five values already there. If any of them differ from what
was actually used (the user changed the port, say), correct the line **and**
record the change in `## Session log`, so the difference is visible rather
than silently overwritten.

**4. Append to `## Session log`.** One dated line naming the scaffold and its
selectors.

**If there was no brief**, build the journal from scratch instead, using the
same eight headers: `## Provenance` records that discovery was not run
(`Grounded by: interactive confirmation only`, `Confidence: low`),
`## Architecture decisions` and `## Scaffold inputs` record what was just
confirmed interactively, `## Collectors` lists whatever collectors the user
named with every box unticked, and the remaining sections open empty. No path
through this command ends without a journal.
````

- [ ] **Step 3: add the resumption block to the closing step**

At the end of the command, after its existing verification step, add:

```markdown
End with the resumption block `project-journal.md` defines:

```
Scaffolded <name> at <target-dir>. make build and make check are green.
Journal: 0 of <N> collectors built. First planned: `<name>` (<variant>).

Safe to /clear now: everything above is in docs/exporter-journal.md.
Then run:

    /add-collector <first planned collector>
```

Print it. Never invoke the command. If the journal lists no planned
collector, suggest `/add-collector <name>` with a name the user must choose,
and say so.
```

- [ ] **Step 4: run the gates**

```sh
sh test/zero-source-grep.sh
claude plugin validate .
grep -rnP '[\x{2013}\x{2014}]' commands/new-prometheus-exporter.md
```

Expected: `PASS`, `✔ Validation passed`, no dash output.

- [ ] **Step 5: read step 3 and step 3b together**

Confirm step 3 is byte-for-byte unchanged: `--dst` must still be required to
be empty, and no new argument may have crept into the `scaffold.sh`
invocation. Everything Task 7 adds happens strictly after the scaffolder has
returned. This is the constraint that keeps `scaffold.sh` untouched by the
whole feature.

- [ ] **Step 6: commit**

```bash
git add commands/new-prometheus-exporter.md
git commit -m "feat(command): move the brief into the scaffolded repo as its journal" \
  -m "After the scaffold returns, the brief becomes docs/exporter-journal.md:
retitled, with Scaffold inputs frozen to the selectors actually passed and
a dated session-log entry. Source material named at step 0 is offered a
copy into samples/; originals stay where the user left them.

Step 3 is untouched, so scaffold.sh still refuses a non-empty --dst and
gains no argument: everything here happens after it returns. A run with no
brief builds a minimal journal instead, so no path ends without one."
```

---

## Task 8: `/add-collector` reads, derives, and completes

**Files:**
- Modify: `commands/add-collector.md` (steps 1, 2, 4, 6, 8, 9)

**Interfaces:**
- Consumes: `docs/exporter-journal.md` from Task 7; `samples/` from Task 3;
  the README markers from Task 5, whose exact strings are
  `<!-- BEGIN GENERATED COLLECTORS -->` and
  `<!-- END GENERATED COLLECTORS -->`.
- Produces: a ticked `## Collectors` entry, an observed line under
  `## Cardinality budget`, a `## Session log` entry, and a regenerated README
  block.

This is the largest task and the one the spec names as the main
comprehension risk: `add-collector.md` is already 44.5 K. Every addition
below points at `project-journal.md` rather than restating it.

- [ ] **Step 1: add journal reading and reconciliation to step 1**

At the end of `## 1. Read this repo's real values, and parse docs/metrics.md`,
add:

````markdown
### The project journal

Read `docs/exporter-journal.md` if it exists, following
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/project-journal.md`.

**Reconcile before using any of it.** The values read above from disk win over
anything the journal claims about them:

| Journal claim | Beaten by |
|---|---|
| `I/O flavor` | the detection in step 0 |
| `Target model` | the detection in step 0 |
| `Namespace` | `const namespace` in `cmd/*/main.go` |
| A `## Collectors` box | the `## <Name>Collector` headers in `docs/metrics.md` |

Correct the file, mark each corrected line `(reconciled <date>)`, add one
`## Session log` line, and **tell the user what you corrected and why**. This
is the ordinary case, not an error: a collector built by hand, an interrupted
run, a colleague who pushed.

**Absent or corrupt**: apply the degradation rules in `project-journal.md`.
Continue this command to the end either way. Never refuse: a repository
scaffolded before the journal existed has none, and must keep working.
````

- [ ] **Step 2: use the journal in step 2**

In `## 2. Collect the new collector's identity`, extend the existing
brief-reading bullet under **Variant** and add two new paragraphs after
**Ask the target metrics**:

```markdown
- If the journal's `## Collectors` already lists this collector with a
  variant, read that back to the user for confirmation rather than asking
  from scratch. (This replaces the older wording that pointed at the design
  brief; the journal is where that decision now lives.)
```

```markdown
**Apply the shared label vocabulary.** If the journal's
`## Architecture decisions` carries a `Shared label vocabulary:` line, the
label keys chosen here must come from it wherever the concept matches. If
this collector genuinely needs a new label, add it to that line and say so.
Do not invent a spelling that differs from an existing one by an underscore
or a suffix: `pool` and `pool_name` cannot be joined in any query, and
nothing on disk states which one is the rule.

**Check the planned budget.** If the journal's `## Cardinality budget` carries
a line for this collector, read it back: labels, worst-case series, any
planned reduction flag. Ask whether the metrics just described still fit. If
they do not, resolve it here, before writing code, and record what changed.
```

- [ ] **Step 3: derive the fixture from `samples/` in step 4**

Replace the fixture sentence in `## 4. Materialize the full test triad +
fixture` with:

````markdown
Add a `testdata/<name>.{json,txt}` fixture (http: JSON matching your struct;
cli: whatever `parse<Name>` expects) with realistic, anonymized sample data
(see this repo's own `CONTRIBUTING.md`, "Test Data").

**Prefer deriving it from `samples/`.** If `samples/` exists and holds
material covering this collector's endpoint or command, build the fixture
from that instead of inventing one:

1. Find the file. Match on the endpoint path or command recorded in step 2.
   If several could match, show the candidates and ask; never guess.
2. **Trim** it to the shape `parse<Name>` actually reads. A capture commonly
   covers several resources; the fixture covers one.
3. **Anonymize** it per `collector-pattern.md`'s Fixtures rules: real
   hostnames become `host1`/`example.internal`, usernames become
   `user1`/`alice`/`bob`, account or tenant names become `team_a`/`org_b`,
   and anything else identifying gets a placeholder that preserves shape
   (field count, rough magnitude) without preserving content.
4. **State what you anonymized**, field by field, in your reply. The user is
   the only one who can tell you that something you left alone was actually
   sensitive.
5. **Leave the original in `samples/`.** Never move or delete it: one capture
   feeds several collectors, and a later session should not have to go back
   to the live target.

If `samples/` is absent or covers nothing relevant, say so in one line and
write the fixture as before. This is a shortcut, never a requirement.
````

- [ ] **Step 4: regenerate the README block in step 6**

At the end of `## 6. Update docs/metrics.md`, add:

````markdown
### Regenerate the README's collector block

`README.md` carries a generated block:

```
<!-- BEGIN GENERATED COLLECTORS -->
<!-- Regenerated from docs/metrics.md. Edits inside this block are overwritten. -->
- [`example`](docs/metrics.md#examplecollector)
<!-- END GENERATED COLLECTORS -->
```

Replace **everything between the two markers** with one line per
`## <Name>Collector` header now present in `docs/metrics.md`, excluding
`## Self-instrumentation`, in the order they appear:

```
- [`<name>`](docs/metrics.md#<name>collector)
```

Keep the second comment line: it is what tells the next reader the block is
not theirs to edit. Regenerate in full; never append. The block is a
projection of a file `make docs-check` already locks, which is what stops it
drifting and lets it repair itself if someone edits it by hand.

The anchor is the GitHub-flavored slug of the header: lowercase, spaces and
punctuation dropped. `## PoolsCollector` becomes `#poolscollector`.

**If either marker is missing**, skip this silently and change nothing. A
repository scaffolded before the markers existed, or an owner who removed
them, is not an error. Do not inject them.

Touch nothing else in `README.md`. Nothing else in it goes stale when a
collector is added.
````

- [ ] **Step 5: complete the journal in a new step 8b**

Insert immediately after `## 8. Verify`, before `## 9. What's next`:

````markdown
## 8b. Complete the journal

Only once `make test` and `make docs-check` have both printed green in step 8.
Never before: a journal that records a collector the build rejects is exactly
the lie this file exists to prevent.

If `docs/exporter-journal.md` is absent, offer to create it now, per
`project-journal.md`'s degradation rules, then continue. If it is corrupt, ask
before writing anything.

Three edits:

1. **Tick the collector** under `## Collectors`, appending the date:

   ```
   - [x] `<name>`  <variant>  built <date>
   ```

   If it was not on the list at all (a collector nobody planned), add it,
   already ticked, and say so.

2. **Record the observed cardinality** under `## Cardinality budget`, next to
   the planned figure rather than replacing it. The gap between intent and
   observation is the interesting part:

   ```
   - `<name>`: labels <list>; worst case ~<N> series; observed <N>
   ```

   Count from the fixture: one series per fixed-shape metric, plus one per
   label combination the variable-label metrics actually emit. That is the
   same count step 4's `GatherAndCount` assertion already uses.

3. **Append one `## Session log` line**, dated, naming the collector, its
   variant, and where the fixture came from.
````

- [ ] **Step 6: rewrite step 9 around the journal**

Replace the second bullet of `## 9. What's next` and add the resumption
block:

````markdown
- Read the remaining unticked entries from the journal's `## Collectors` and
  name the next one explicitly. Do not say "repeat for the rest of the list":
  the point of the journal is that the list is on disk and can be named.

End with the resumption block `project-journal.md` defines:

```
Collector `<name>` added. make test and make docs-check are green.
Journal: <N> of <M> collectors built. Next planned: `<next>` (<variant>).

Safe to /clear now: everything above is in docs/exporter-journal.md.
Then run:

    /add-collector <next>
```

When no unticked collector remains, suggest `/generate-dashboard` instead.
Print the block; never invoke the command.
````

- [ ] **Step 7: run the gates**

```sh
sh test/zero-source-grep.sh
claude plugin validate .
grep -rnP '[\x{2013}\x{2014}]' commands/add-collector.md
```

Expected: `PASS`, `✔ Validation passed`, no dash output.

- [ ] **Step 8: read the command end to end**

Six touch points in one 44.5 K file is this task's stated risk. Read it top to
bottom and confirm: the step numbering runs 0, multi-target block, 1 through
8, 8b, 9 with no gap or duplicate; the marker strings in step 6 match Task 5's
template character for character; step 8b's gate precondition names the same
two commands step 8 runs; and no addition restates a rule that
`project-journal.md` already owns.

- [ ] **Step 9: commit**

```bash
git add commands/add-collector.md
git commit -m "feat(command): add-collector reads and completes the journal" \
  -m "Reads docs/exporter-journal.md on entry and reconciles it against the
repository, with the disk winning on everything it can state and every
correction reported rather than applied silently. Uses what only the
journal holds: the planned variant, the cardinality budget, and the shared
label vocabulary that stops a seventh collector spelling pool_name after
the first established pool.

Derives the fixture from samples/ when it covers the endpoint, trimming
and anonymizing it and stating what was anonymized, instead of emitting a
placeholder for the user to replace by hand. Regenerates the README's
collector block from docs/metrics.md. Ticks the collector and records the
observed cardinality only after make test and make docs-check are green,
then names the next planned collector."
```

---

## Task 9: `/generate-dashboard` reads and writes the journal

**Files:**
- Modify: `commands/generate-dashboard.md` (line 52 and the closing step)

**Interfaces:**
- Consumes: `docs/exporter-journal.md` from Task 7.
- Produces: a `## Dashboards` section in the journal.

- [ ] **Step 1: fix the dead reference**

In `## 1. Read this repo's real values, and parse docs/metrics.md`, replace
the brief paragraph (currently line 52) with:

```markdown
If `docs/exporter-journal.md` is present, read it too, following
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/project-journal.md`:
its audience, business-alert candidates and cardinality-budget sections seed
steps 2, 5 and 6 below instead of asking cold. Reconcile it against
`docs/metrics.md` first, as that reference describes: the documented metrics
win over anything the journal claims about which collectors exist.
```

This is not optional polish. `./exporter-design-brief.md` no longer exists at
that path once Task 7 has moved it, so leaving the line alone would ship a
dead reference.

- [ ] **Step 2: write `## Dashboards` at the end**

At the end of the command, after the dashboards have been written and
validated, add:

````markdown
## Record the design in the journal

If `docs/exporter-journal.md` is present, replace its `## Dashboards` section
with one line per dashboard produced:

```
- <audience>, <RED | USE> because <reason>, <decomposition>, files: <paths>
```

Everything on that line is chosen in the dialogue above and **cannot be read
back from the JSON**: the emitted panels show what was built, never why RED
was chosen over USE, nor why the set was split into an overview plus
drill-downs rather than one dashboard. A second session that extends or
regenerates a dashboard reads this and stays consistent with the first.

Append one dated `## Session log` line naming the dashboards written.

If the journal is absent, say so in one line and skip this: the dashboards
themselves are already on disk. Follow `project-journal.md`'s degradation
rules if it is present but corrupt.
````

- [ ] **Step 3: add the resumption block**

```markdown
End with the resumption block `project-journal.md` defines:

```
Dashboards written to <paths>. promtool and the backbone validation are green.
Journal: <N> of <M> collectors built.

Safe to /clear now: everything above is in docs/exporter-journal.md.
```

When unticked collectors remain, add a `Then run: /add-collector <next>` line
naming the first of them. Print it; never invoke the command.
```

- [ ] **Step 4: run the gates**

```sh
sh test/zero-source-grep.sh
claude plugin validate .
grep -rnP '[\x{2013}\x{2014}]' commands/generate-dashboard.md
grep -rn 'exporter-design-brief' commands/
```

Expected: `PASS`, `✔ Validation passed`, no dash output, and the last grep
returning only `commands/design-exporter.md` and
`commands/new-prometheus-exporter.md`, which legitimately name the pre-scaffold
file. Any hit in `generate-dashboard.md` or `add-collector.md` is the dead
reference this task exists to remove.

- [ ] **Step 5: commit**

```bash
git add commands/generate-dashboard.md
git commit -m "feat(command): generate-dashboard reads and writes the journal" \
  -m "Reads docs/exporter-journal.md where it read ./exporter-design-brief.md,
a path that stops existing once the brief moves into the scaffolded repo,
so leaving it alone would ship a dead reference.

Writes back the Dashboards section: audience, RED or USE and why, the
decomposition chosen and the files produced. None of that is readable
back from the emitted JSON, which shows what was built and never why."
```

---

## Task 10: roadmap, changelog, and the deferred v0.7 note

**Files:**
- Modify: `ROADMAP.md` (the v0.8 section)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: everything Tasks 1 to 9 shipped.
- Produces: nothing.

- [ ] **Step 1: mark the roadmap item delivered**

In `ROADMAP.md`'s `## v0.8` section, move the project-journal bullet into the
released-work form the earlier sections use, and leave the child-registry
bullet where it is: it remains open.

- [ ] **Step 2: write the changelog entry**

Under a new `## [Unreleased]` heading (or the existing one), with these three
groups:

```markdown
### Added

- A project journal, `docs/exporter-journal.md`, in every scaffolded
  exporter. All four commands read it on entry and complete it on exit, so a
  build spanning several sessions survives a compaction or a cleared context.
  `/design-exporter` opens it, `/new-prometheus-exporter` moves it into the
  repository, `/add-collector` ticks collectors and records observed
  cardinality, `/generate-dashboard` records each dashboard's audience and
  method. Absent or unreadable, every command degrades to its previous
  behaviour and completes: exporters scaffolded before this release keep
  working.
- `samples/` in every scaffolded exporter: a gitignored home for raw target
  output and the target's own API documentation, separate from
  `internal/collector/testdata/`, which stays trimmed, anonymized and
  committed. `/add-collector` derives a fixture from it when it covers the
  collector's endpoint, instead of emitting a placeholder.
- `CLAUDE.md` in every scaffolded exporter, stating the repository's
  invariants and where each kind of state lives.
- A generated collector block in the scaffolded `README.md`, regenerated in
  full from `docs/metrics.md` by `/add-collector`.
- `@@TARGET_MODEL@@` and `@@FLAVOR@@` substitutions in `scaffold.sh`, derived
  from the selectors it already parses.

### Changed

- `<namespace>_exporter_request_wait_seconds` gained an `outcome` label after
  the v0.7.0 tag.
- `discovery-inputs.md` no longer describes the brief's format; it points at
  the new `project-journal.md` reference, which owns it.

### Notes

- The scaffold-side artifacts of this release are covered by the golden
  matrix. The journal protocol itself (reading on entry, reconciling against
  the repository, degrading when absent or unreadable) is command prose, which
  no test in this repository can exercise. It was verified by review.
```

The `request_wait_seconds` line is a deferred v0.7 item, unrelated to this
work, that has been waiting for the next `chore(release)`. Do not drop it.

- [ ] **Step 3: run every gate, verbatim, one last time**

```sh
sh test/zero-source-grep.sh
claude plugin validate .
sh test/scaffold_test.sh
sh test/scaffold_edge_test.sh
sh test/scaffold_multitarget_test.sh
sh test/golden-smoke.sh --all
grep -rnP '[\x{2013}\x{2014}]' skills/ commands/
```

Expected: every one green, and no dash output. Run the six cells even though
five of them exercised nothing new since Task 5: the cell you skip is the one
that could have seen the problem.

- [ ] **Step 4: commit**

```bash
git add ROADMAP.md CHANGELOG.md
git commit -m "docs(release): record the project journal in the roadmap and changelog" \
  -m "Also carries the deferred v0.7 note that
<namespace>_exporter_request_wait_seconds gained an outcome label after
the v0.7.0 tag, and states plainly which half of this release is covered
by the golden matrix and which was verified by review."
```

---

## Self-review

**Spec coverage.**

| Spec section | Task |
|---|---|
| §4.1 lifecycle and location | 6 (birth), 7 (move) |
| §4.2 format | 1 (canonical), 6 (written) |
| §4.3 section ownership | 1 (table), 6, 7, 8, 9 (applied) |
| §4.4 reconciliation | 1 (table), 8 (applied), 9 (applied) |
| §4.5 degradation | 1 (rules), 8, 9 (applied) |
| §5.1 `/design-exporter` | 6 |
| §5.2 `/new-prometheus-exporter` | 7 |
| §5.3 `/add-collector` | 8 |
| §5.4 `/generate-dashboard` | 9 |
| §5.5 resumption contract | 1 (shape), 6, 7, 8, 9 (emitted) |
| §6 `samples/` | 3 (directory), 6 (paths recorded), 7 (copy), 8 (derivation) |
| §7 generated `CLAUDE.md` | 2 (substitutions), 4 (template) |
| §8 README block | 5 (markers), 8 (regeneration) |
| §9 twelfth reference | 1 |
| §10.1 new golden assertions | 3, 4, 5 |
| §10.2 unchanged gates | every task |
| §10.3 what no test proves | 10 (stated in the changelog) |

**Interface consistency.** The marker strings
`<!-- BEGIN GENERATED COLLECTORS -->` and `<!-- END GENERATED COLLECTORS -->`
appear identically in Task 3's assertion, Task 5's template and Task 8's
regeneration step. The eight `##` headers appear identically in Task 1's
reference, Task 6's write step and Task 7's fallback. `@@TARGET_MODEL@@` and
`@@FLAVOR@@` are produced in Task 2 and consumed only in Task 4.

**Known gap, stated rather than hidden.** Tasks 6 to 9 have no automated
gate beyond the source, manifest and dash scans. Each carries an explicit
read-the-file-end-to-end step in place of a test, and Task 10's changelog says
so in the release notes. That is a limitation of this repository's harness, not
an oversight in the plan.
