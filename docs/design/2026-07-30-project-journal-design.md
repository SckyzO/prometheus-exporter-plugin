# A project journal that survives a cleared context

**Status:** design approved 2026-07-30 · v0.8.0. Delivers the first of the two
items opened in [`ROADMAP.md`](../../ROADMAP.md)'s v0.8 section. The second
(a child registry per watched instance) is explicitly out (§3.2). Deferred out
of v0.7, where it was listed alongside configuration reload and shared nothing
with it (see
[`2026-07-28-config-reload-and-concurrency-design.md`](2026-07-28-config-reload-and-concurrency-design.md)
§4.2).

## 1. Goal

Make every step of building an exporter resumable from a cold start.

Today exactly one hand-off is durable: `/design-exporter` writes an
architecture brief and `/new-prometheus-exporter` reads it. Everything after
that lives only in the conversation. Which collectors are left to build, the
cardinality budget, the credential convention, which collectors need the
background variant, the label vocabulary the whole exporter agreed on: a
compaction or a `/clear` between two collectors loses decisions that were
already made, while the repository sits two metres away.

This is blocking now, not later. The first real exporter to be built with this
plugin has **fifteen collectors**, so several sessions. Without memory between
them, each session rediscovers or contradicts the previous one.

The user-visible payoff, stated up front because it drives several decisions
below: after this change, `/clear` between two collectors becomes the
*recommended* move rather than a destructive one. State on disk, read back and
reconciled against the code, beats a model-written summary. Fifteen short
sessions beat one context window swelling to suffocation.

## 2. Background: what ships today

The repository already carries durable state, and one command already lives
off it. This matters, because it fixes what the journal must *not* contain.

| Fact | Where it already lives | Who reads it |
|---|---|---|
| I/O flavor | `internal/collector/client.go` vs `execute.go` | `/add-collector` §0 |
| Target model | `internal/instance/` vs `internal/probe/` vs neither | `/add-collector` §0 |
| Namespace | `const namespace = "..."` in `cmd/*/main.go` | `/add-collector` §1 |
| Collectors built, their metrics, types, labels | `docs/metrics.md`, enforced by `make docs-check` | `/add-collector` §1, `/generate-dashboard` §1 |
| Alerts proposed | `monitoring/prometheus/alerts.yml` | `/add-collector` §7 |
| Config surface demonstrated | `config.example.yml`, `docs/configuration.md` | operators |

`/generate-dashboard` runs its entire design dialogue off `docs/metrics.md`.
The precedent is established: on-disk state, verified by a gate, beats
conversation.

What has no home on disk is everything the code cannot state about itself:

- collectors **planned but not yet built**, and in what order,
- the cardinality budget as an **intention** (worst-case series, reduction
  flags) rather than an observation,
- the **credential convention** (`a`/`b`/`c`) and the **concurrency ceiling**,
  both currently written into the brief and then abandoned at scaffold time,
- which planned collectors need the **background** variant,
- the **naming convention**: metric-name shape, and the shared label
  vocabulary every collector must reuse,
- the **provenance** of the design, and the open questions discovery left,
- **why** any of the above was decided.

That list is the journal's scope, and nothing else.

## 3. Scope

### 3.1 In

1. The journal itself: one file, read on entry and completed on exit by all
   four commands.
2. `samples/`: a gitignored home in the generated repository for raw target
   output and upstream API documentation, declared at step 0, derived from
   (never emptied) afterwards.
3. A `CLAUDE.md` in the generated repository, written once at scaffold time.
4. A generated collector block in the generated repository's `README.md`,
   regenerated from `docs/metrics.md` on every `/add-collector`.
5. A twelfth reference, `project-journal.md`, holding the protocol once.

### 3.2 Out, and why

**A child registry per watched instance.** The other v0.8 roadmap item. It
reshapes how `/metrics` is assembled and shares nothing with this work. Its
own session.

**Chaining commands.** All four commands carry
`disable-model-invocation: true`: the model cannot trigger them, only the
user can type them. They name each other in prose, never in a call. All four
have real side effects, and that posture is deliberate. This design adds a
*suggestion* of the next command (§5.5), never an invocation.

**In-place migration of scaffolded code.** v0.6 removed migrations from
`/add-collector`: the plugin detects an outdated seam, refuses, and points at
regeneration. Nothing here reintroduces one. The journal is a documentation
file; creating one in a v0.7 repository touches no seam and is offered, not
imposed (§4.5).

**Rewriting user-owned prose.** The generated `README.md` is edited by its
owner. The only bytes this design ever writes there sit between two explicit
markers, and are a projection of a gate-verified source (§8).

## 4. The journal file

### 4.1 Lifecycle and location

One artifact, two names, because before the repository exists it genuinely is
only a brief.

```
/design-exporter          ->  ./exporter-design-brief.md      (cwd, name unchanged)
/new-prometheus-exporter  ->  ./<name>/                        (scaffold, --dst still empty)
                          ->  docs/exporter-journal.md         (moved, retitled)
/add-collector            ->  docs/exporter-journal.md         (read, reconciled, appended)
/generate-dashboard       ->  docs/exporter-journal.md         (read, appended)
```

Keeping `exporter-design-brief.md` as the step-0 name means a brief produced
before this change is still found and consumed. The move happens after
scaffolding, so `scaffold.sh`'s refusal of a non-empty `--dst` is untouched.

The journal is **committed**, at `docs/exporter-journal.md`. Two reasons, one
decisive:

- An untracked file is destroyed by `git clean -xdf`, a routine command. A
  journal that vanishes silently at the first cleanup is worse than no
  journal, because by then it is trusted.
- `docs/` in a generated repository already hosts builder-facing material
  (`development.md`, `release-process.md`, `validation-checklist.md`)
  alongside user-facing material (`configuration.md`, `metrics.md`). The
  journal is not an intruder there.

The cost is accepted openly: a generated exporter publishes an artifact that
names this plugin's commands, exactly as the `CLAUDE.md` of §7 does.

### 4.2 Format

Markdown with frozen section headers, verbatim, in this order. This extends
the position already documented for the brief in
`discovery-inputs.md`: consumed by the **model**, never parsed by a script,
so the format optimizes for human review and model comprehension rather than
machine parsing. No parser to write, no schema to version, and a partially
damaged file leaves the rest usable.

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
                                                   (written by /design-exporter)
- Selectors actually passed: --flavor, --target-model, --forge, --instance-label
                                          (appended by /new-prometheus-exporter)

## Collectors
- [x] `pools`      sync        built 2026-07-30
- [x] `volumes`    background  built 2026-07-30, interval 15s
- [ ] `snapshots`  background  endpoint /api/v1/snapshots
- [ ] `replicas`   sync        endpoint /api/v1/replicas

## Cardinality budget
- `pools`: labels pool; worst case ~40 series; observed 12
- `snapshots`: labels pool, tier; worst case ~400 series; reduction flag planned

## Dashboards
- <audience>, <RED | USE> because <reason>, <decomposition>, files: <paths>

## Session log
- 2026-07-30 /add-collector volumes: background, 15s, fixture derived from samples/volumes-list.json

## Open questions / assumptions
- <anything discovery could not resolve>
```

`Shared label vocabulary` is the highest-value line in the file. If collector
1 emits `pool` and collector 7 emits `pool_name`, no dashboard joins them, and
nothing on disk states which is the rule: existing names can be *observed*,
the convention cannot be *derived*.

### 4.3 Section ownership

| Section | Created by | Completed by | Regime |
|---|---|---|---|
| `## Provenance` | `/design-exporter` | nobody | frozen on write |
| `## Architecture decisions` | `/design-exporter` | `/new-prometheus-exporter` (confirm or correct) | mutable |
| `## Scaffold inputs` | `/design-exporter` | `/new-prometheus-exporter` (values actually passed) | frozen after scaffold |
| `## Collectors` | `/design-exporter` (planned list) | `/add-collector` (tick, date) | mutable |
| `## Cardinality budget` | `/design-exporter` (intent) | `/add-collector` (observed) | mutable |
| `## Dashboards` | `/generate-dashboard` | `/generate-dashboard` | mutable |
| `## Session log` | `/design-exporter` (its own first entry) | all four | append-only |
| `## Open questions / assumptions` | `/design-exporter` | all four | mutable |

A command writes only the sections it owns. `## Provenance` is never rewritten:
it is the discovery ladder's audit trail, and rewriting it would erase why the
design is trusted at the confidence level it claims.

### 4.4 Reconciliation: disk wins on the derivable

Authority is shared but never overlapping. **The disk decides everything it
can state. The journal is sole authority on everything else.** The tick boxes
under `## Collectors` are a *cache* of disk truth, never a source.

On entry, every command reconciles:

| Read from disk | How | If the journal disagrees |
|---|---|---|
| I/O flavor | `internal/collector/client.go` vs `execute.go` | corrected, reported |
| Target model | `internal/instance/` vs `internal/probe/` vs neither | corrected, reported |
| Namespace | `const namespace = "..."` in `cmd/*/main.go` | corrected, reported |
| Collectors built | `## <Name>Collector` headers in `docs/metrics.md` | box ticked or unticked, marked `(reconciled <date>)`, reported |

No correction is silent. Each is stated in the command's output and leaves a
`## Session log` line. A journal that asserts a false state is more harmful
than an absent one, because it has been trusted.

This also covers the ordinary case that has nothing to do with corruption: a
collector built by hand, an `/add-collector` interrupted midway, a colleague
who pushed. None of these should stop anything.

### 4.5 Degradation: absent, corrupt

"Corrupt" has a checkable definition, not a judgement call: the file exists
but has no `# Exporter journal:` title line, or is missing at least one of the
required `##` headers.

- **Absent.** The command does exactly what it does in v0.7, all the way
  through. At the end, it offers to build the journal: derivable facts read
  from disk, non-derivable ones (remaining collectors, budget, why) asked.
  This is the upgrade path for every repository scaffolded before v0.8.
- **Corrupt.** The command also does its full job, then asks: rebuild with a
  backup at `docs/exporter-journal.md.bak`, or leave it untouched. **It writes
  nothing before an answer.** A file that cannot be understood may hold
  hand-written prose worth keeping.

Never a refusal. v0.6's refusal posture exists because an in-place code
migration is dangerous; a missing documentation file is not. Applied here it
would break `/add-collector` on every exporter already generated.

## 5. Command contracts

### 5.1 `/design-exporter`

| Step | Delta |
|---|---|
| 2, ladder | Rungs 1 and 2 already ask for a path or a URL. The delta is that it is **recorded** under `## Provenance` (`Source material:`) instead of being consumed and forgotten. New sentence to the user: put your API documentation and your captured output wherever you like and tell me where; otherwise the plugin will produce them itself. |
| 3, decisions | New question: the naming convention (metric-name shape, and the shared label vocabulary). It joins `Credential convention` and `Concurrency ceiling` under `## Architecture decisions`. |
| 4, write | New sections: `## Collectors` (planned list, boxes unticked, sync/background per line), `## Cardinality budget`, and `## Session log` opened with its own design-phase entry. |
| 5, hand-off | Gains the resumption block (§5.5). |

Still one file written, still no directory created, still named
`./exporter-design-brief.md`.

### 5.2 `/new-prometheus-exporter`

| Step | Delta |
|---|---|
| 0 | Behaviour unchanged; the brief is additionally **retained** for the move. |
| 3, scaffold | **Strictly unchanged.** `--dst` stays empty, no new argument. |
| 3b, new | After scaffolding: offer to copy the material recorded at step 0 into `samples/`, move the brief to `docs/exporter-journal.md`, retitle it, freeze `## Scaffold inputs` with the selectors actually passed, append the scaffold entry to `## Session log`. |
| no brief | Build a minimal journal from what was just decided interactively. No path ends without a journal. |
| 4, hand-off | Gains the resumption block (§5.5), naming the first planned collector. |

### 5.3 `/add-collector`

| Step | Delta |
|---|---|
| 1 | Read the journal, reconcile against disk (§4.4), report every correction. |
| 2, identity | It already reads the brief's background flag back to the user. It now also reads the **cardinality budget** and the **shared label vocabulary**, which is the mechanism that stops collector 7 inventing `pool_name` after collector 1 established `pool`. |
| 4, fixture | If `samples/` covers this collector's endpoint, derive the fixture from it (trim to the parsed shape, anonymize per `collector-pattern.md`, and **state what was anonymized**). Otherwise, today's behaviour unchanged. |
| 6, docs | After `docs/metrics.md`, regenerate the README's collector block (§8). |
| 8b, new | Tick the collector, write the observed cardinality under `## Cardinality budget`, append a `## Session log` line. **After** `make test` and `make docs-check` are green, never before. |
| 9, what's next | Read the **remaining** collectors from the journal instead of "repeat for the rest of the list", and emit the resumption block (§5.5). This is what makes session 4 of 15 possible from cold. |

### 5.4 `/generate-dashboard`

| Step | Delta |
|---|---|
| 1 | `./exporter-design-brief.md` becomes `docs/exporter-journal.md`. Doing nothing is not neutral: the move of §4.1 turns that path into a dead reference, which this plugin's `CLAUDE.md` forbids. |
| output | Write `## Dashboards`: audience, RED or USE **and why**, the decomposition chosen, and the files produced. None of that is derivable from the emitted JSON. |
| hand-off | Gains the resumption block (§5.5). |

### 5.5 The resumption contract

Every command ends, **after its verification gate is green and never before**,
with a literal, copy-pasteable block:

```
Collector `volumes` added. make test and make docs-check are green.
Journal: 2 of 15 collectors built. Next planned: `snapshots` (background).

Safe to /clear now: everything above is in docs/exporter-journal.md.
Then run:

    /add-collector snapshots
```

The next command's argument is **read from the journal** (first unticked
collector), not a template. `/design-exporter` suggests
`/new-prometheus-exporter <name>`; `/new-prometheus-exporter` suggests the
first planned collector; `/add-collector` suggests the next one, and
`/generate-dashboard` once the list is empty.

This is a suggestion printed as text. Nothing is invoked (§3.2).

## 6. `samples/`: raw material, one-way derivation

`samples/` holds everything gathered from the monitored target: raw output
(HTTP responses, CLI output) and the vendor's own API documentation
(OpenAPI/gRPC spec, doc pages).

It is **gitignored** and **never emptied**. It is working material, not a
staging area. Two artifacts are derived from it and committed; the originals
stay in place.

```
samples/                                    gitignored, permanent
  openapi.yaml                              vendor API documentation
  pools-list.json                           raw, NOT anonymized
  volumes-list.json

         |  one-way derivation, original stays
         v
internal/collector/testdata/pools.json      committed, ANONYMIZED, trimmed
docs/metrics.md                             committed
docs/exporter-journal.md                    committed
```

Three reasons the originals must stay:

1. **One capture feeds several collectors.** A single `GET /api/v1/status`
   commonly covers three or four resources. Moving it into
   `testdata/pools.json` would make it unavailable to `volumes`.
2. **It is the stated benefit.** The live-target probe (rung 4) stops having
   to re-solicit the machine every session. Collector 12, three sessions
   later, rereads `samples/`. An emptied `samples/` re-solicits.
3. **A fixture is not a capture.** `collector-pattern.md` requires every
   fixture to be anonymized before commit and forbids committing output
   copy-pasted from a production system. `testdata/pools.json` is a
   *transformed* version. Keeping the original allows re-deriving it when the
   collector's shape changes.

Upstream API documentation never lands in `docs/`. The generated repository's
`docs/` is that exporter's own documentation, for its own users. A vendor's
documentation is raw material, not a deliverable. Keeping it under a
gitignored path also neutralizes a question the plugin cannot answer on the
user's behalf: whether that documentation may be redistributed inside an
Apache-2.0 repository at all.

**Naming.** `samples/`, not `test_data/`. `collector-pattern.md` states that
fixtures live in `internal/collector/testdata/`, Go's convention, "not
`test_data`". Two names one underscore apart for two opposite roles would be a
trap. `samples/` says what it is, and collides with nothing.

**Mechanics.** Git does not track empty directories, so a gitignored
`samples/` would not exist after a clone. `.gitignore.tmpl` therefore gains
`/samples/*` followed by `!/samples/README.md`, and `assets/samples/README.md`
ships as a committed template file explaining what the directory is for,
restating that its contents are **not** anonymized and must pass the
`CONTRIBUTING.md` anonymization rule before reaching `testdata/`, and noting
the redistribution caveat.

## 7. The generated repository's `CLAUDE.md`

New file, written once at scaffold time, never rewritten. It holds
**invariants**, and duplicates nothing:

- identity: exporter name, namespace, target model, I/O flavor;
- pointers: read `CONTRIBUTING.md` in full, the journal is at
  `docs/exporter-journal.md`, `samples/` is gitignored and not anonymized,
  the gate is `make check`;
- the resumption contract (§5.5), so a future session knows `/clear` is safe.

It must not restate `CONTRIBUTING.md`, which already carries the Definition of
Done, the commit convention and the Test Data section. This plugin's own
`CLAUDE.md` forbids merging anything that duplicates what exists.

Because it holds only invariants, no command rewrites it. Everything that
evolves lives in the journal. That is what dissolves the overwrite trap: there
is no recurring write to protect against.

**One scaffolder change.** Target model and I/O flavor are `scaffold.sh`
selectors today, not `--var` substitutions, so `CLAUDE.md.tmpl` cannot state
them. `scaffold.sh` gains `@@TARGET_MODEL@@` and `@@FLAVOR@@`, derived from
the selectors it already parses. This is **additive**: no existing template
references either, so it is not a reshape of the variable seam in the sense of
the two-phase rule. The golden harness catches a missed substitution
immediately, since no `@@VAR@@` sentinel may survive a scaffold.

## 8. The README's generated collector block

Placed under `## Metrics`, before the existing delegation sentence:

```markdown
<!-- BEGIN GENERATED COLLECTORS -->
<!-- Regenerated from docs/metrics.md. Edits inside this block are overwritten. -->
- [`pools`](docs/metrics.md#poolscollector)
- [`volumes`](docs/metrics.md#volumescollector)
<!-- END GENERATED COLLECTORS -->
```

Collector name and anchor, nothing else. No description: `docs/metrics.md`
carries none, and fetching one from the journal would make the block a
projection of two sources, one of them not verified by `make docs-check`. No
metric names either: that would be the real duplication.

**Regenerated in full, never appended.** The block is a projection of a
gate-verified source, so it cannot drift, and it repairs itself if someone
breaks it by hand.

**Markers absent** (a v0.7 repository, or an owner who removed them): skip
silently, inject nothing. Same posture as §4.5.

The rest of the generated `README.md` is untouched by `/add-collector`,
because nothing else in it goes stale: its `## Metrics` section already
delegates to `docs/metrics.md`, `## Features` describes exporter capabilities
rather than collectors, and `## Endpoints` describes `/metrics`, `/healthz`
and `/probe`, which are fixed by the target model.

This block is a fourth copy of the collector list (code, `metrics.md`,
journal, README), accepted deliberately for reader convenience, and made
drift-proof by regeneration rather than by discipline.

## 9. The twelfth reference

`skills/prometheus-exporter/references/project-journal.md` holds, once: the
format, the read-on-entry / write-on-exit protocol, the ownership table, the
reconciliation table, the degradation rules, and the brief-to-journal move.
Each command gains a short section pointing at it.

Everything in it is **[G]**. Concrete values (a target's endpoints, its label
names, its budget) are **[S]** and live only in a given project's journal,
never folded back into the reference.

`discovery-inputs.md`'s `## The architecture brief` section, which describes
the format today, is **reduced to a pointer**. Two files describing one
artifact diverge; that is a certainty, not a risk.

## 10. Proving it

### 10.1 New golden assertions

Each must be proven by deliberately breaking what it guards, per v0.7's
second lesson: an assertion that cannot fail is not a test.

1. **`samples/` survives a clone, its contents do not.** `samples/README.md`
   is tracked; a file dropped in `samples/` is ignored. Proven with
   `git check-ignore`; broken by removing the `!/samples/README.md` line.
2. **`CLAUDE.md` states this cell's real target model and flavor.** Broken by
   removing the `@@TARGET_MODEL@@` substitution from `scaffold.sh` and
   confirming the assertion goes red, not merely that the sentinel scan does.
3. **The README carries both markers, correctly paired and ordered.** Broken
   by removing one.

Run on **the whole matrix**, not a subset. `@@TARGET_MODEL@@` and `@@FLAVOR@@`
differ per cell, and v0.7's third lesson is that the subset you run decides
what you can find: a Critical survived because the one cell that could see it
had not been run.

### 10.2 Unchanged gates

- `sh test/zero-source-grep.sh`: `assets/samples/README.md` and
  `assets/CLAUDE.md.tmpl` are scanned like all of `assets/`.
- `claude plugin validate .`: after adding the twelfth reference.
- `sh test/golden-smoke.sh --all`: `make build` then `make check` per cell,
  plus the existing no-surviving-`@@VAR@@` scan, which covers the two new
  substitutions for free.

### 10.3 What no test proves

The prose protocol: read-on-entry, reconciliation, absent/corrupt degradation,
and the resumption contract. That is model behaviour, outside the harness.
v0.8 therefore has a test-verified part and a review-verified part, and the
release notes should say so rather than imply a coverage that does not exist.

## 11. Implementation tranches

Ordered so each is independently verifiable, and so a stop between any two
leaves a working tree.

1. **The reference.** `project-journal.md`, and `discovery-inputs.md` reduced
   to a pointer. Documentation only; gate is `claude plugin validate .` and
   the zero-source scan.
2. **Scaffold-side artifacts.** `@@TARGET_MODEL@@`/`@@FLAVOR@@` in
   `scaffold.sh`, `assets/CLAUDE.md.tmpl`, `assets/samples/README.md`, the two
   `.gitignore.tmpl` lines, the README markers. Gate is the full golden matrix
   plus the three new assertions of §10.1.
3. **`/design-exporter` and `/new-prometheus-exporter`.** The journal's birth
   and its move. Prose only.
4. **`/add-collector`.** Reconciliation, fixture derivation from `samples/`,
   the README block regeneration, the exit write, the resumption block.
5. **`/generate-dashboard`.** The dead reference, and `## Dashboards`.
6. **`ROADMAP.md`, `CHANGELOG.md`.** The v0.8 entry, and the deferred
   `### Changed` note that
   `..._exporter_request_wait_seconds` gained an `outcome` label after v0.7.0.

## 12. Risks

**A journal that lies is worse than no journal.** Mitigated by §4.4: the disk
wins on everything it can state, corrections are never silent, and tick boxes
are a cache. The residual risk is the non-derivable half, which nothing can
verify. That is why `## Provenance` is frozen and `## Session log` is
append-only: the parts that record history cannot be quietly rewritten.

**Four copies of the collector list.** Code, `metrics.md`, journal, README.
`make docs-check` only locks two of them. The README block is regenerated
rather than maintained, which removes it from the risk. The journal's copy is
reconciled on every entry. Neither is free, and both were chosen with the
duplication understood.

**The prose protocol is long, and `add-collector.md` is already 44.5 K.**
Adding six touch points to one command file is the largest single risk to
comprehension. Mitigated by keeping the protocol in the reference and leaving
short pointers in the command, but the file grows either way and should be
watched.

**A generated repository now publishes plugin-shaped artifacts.**
`docs/exporter-journal.md` and `CLAUDE.md` name this plugin's commands in a
third party's public repository. Accepted deliberately, and the reason
`samples/` went the other way: it can carry secrets and third-party
documentation, so it stays out of git.

**`samples/` invites committing production output.** The directory exists
precisely to hold un-anonymized data. Mitigated by the gitignore rules, by
`samples/README.md` restating the anonymization rule, and by
`/add-collector` stating what it anonymized when it derives a fixture. Not
eliminated: an owner who forces a commit can still leak.
