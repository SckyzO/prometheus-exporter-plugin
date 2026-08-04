# The project journal: format, ownership, reconciliation, and the resumption block

Building an exporter is not one session. A target with a dozen collectors
takes several, and between two of them a context window is cleared or
compacted. Exactly one hand-off across that boundary is durable today:
`/prometheus-exporter:design-exporter` writes an architecture brief and
`/prometheus-exporter:new-prometheus-exporter` reads it. Everything decided
after that (which collectors are left, in what order, which need the
background variant, what the cardinality budget was meant to be, which label
name the whole exporter agreed on) lives only in the conversation, and dies
with it, while the repository sits right there on disk.

This reference defines the one file that closes that gap, and the protocol
the four commands (`/prometheus-exporter:design-exporter`,
`/prometheus-exporter:new-prometheus-exporter`,
`/prometheus-exporter:add-collector`,
`/prometheus-exporter:generate-dashboard`) follow around it. Each of them
points here rather than restating any of it.

Everything below is `[G]`: it holds for any exporter, whatever it monitors.
The concrete values a real journal carries (a target's endpoints, its label
names, its budget) are `[S]` and live only in that project's own journal,
never folded back into this reference or into a shipped template.

## What the journal is for

The journal is the durable state the four commands hand to each other. One
rule fixes its scope, and it is the rule to apply whenever a new line is
proposed for it:

> **The journal holds only what the repository cannot state about itself.**
> Anything derivable from disk is read from disk.

A generated exporter already carries a great deal of durable state, and one
command already lives off it: `/prometheus-exporter:generate-dashboard` runs
its entire design dialogue out of `docs/metrics.md`, which `make docs-check`
keeps truthful against the registered descriptors. That precedent decides
the split. On-disk state verified by a gate beats a model-written summary of
it, so the journal never restates the flavor, the target model, the
namespace, the collectors already built, their metrics, types and labels,
the alerts already proposed, or the configuration surface already
demonstrated. It reads them (see `## Reconciliation`).

What has no home on disk, and therefore belongs here:

- collectors **planned but not yet built**, and in what order;
- the cardinality budget as an **intention** (worst-case series, reduction
  flags) rather than an observation;
- the **credential convention** (`a`/`b`/`c`) and the **concurrency
  ceiling**, both decided at design time and otherwise abandoned at scaffold
  time;
- which planned collectors need the **background** variant;
- the **naming convention**: the metric-name shape, the shared label
  vocabulary every collector must reuse, and the name-vs-label arbitrations,
  which are the least recoverable of the three since a dimension resolved
  into separate names leaves no label behind to observe;
- the **provenance** of the design, and the open questions discovery left;
- **why** any of the above was decided.

That list is the journal's scope, and nothing else. A line that duplicates
something a gate already verifies is not extra safety: it is a second copy
free to drift, and the drift is silent.

## Lifecycle

One artifact, two names, because before the repository exists it genuinely
is only a brief.

```
/prometheus-exporter:design-exporter          ->  ./exporter-design-brief.md   (cwd, name unchanged)
/prometheus-exporter:new-prometheus-exporter  ->  ./<name>/                    (scaffold, --dst still empty)
                          ->  docs/exporter-journal.md     (moved, retitled)
/prometheus-exporter:add-collector            ->  docs/exporter-journal.md     (read, reconciled, appended)
/prometheus-exporter:generate-dashboard       ->  docs/exporter-journal.md     (read, appended)
```

The step-0 name stays `./exporter-design-brief.md`, in the working
directory, so a brief written before the journal existed is still found and
consumed. Its title line at that stage is `# Exporter design brief:
<target>`, and that is the string the move looks for: the file to be
relocated is the one whose first line matches it. The move to
`docs/exporter-journal.md`, and the retitling from `# Exporter design brief:
<target>` to `# Exporter journal: <name>`, happen **after** scaffolding, so
`scaffold.sh`'s refusal of a non-empty `--dst` is untouched: it still
scaffolds into an empty destination and the journal arrives afterward. Where
the brief already carries the eight section headers, only the title line
changes. A brief written before those headers were the brief's own carries
fewer, so the move also adds each missing header with a placeholder line, in
`## Format` order, and lifts a planned-collector or cardinality-budget
bullet out of `## Architecture decisions` into the section that owns it now:
carried across unedited, such a brief lands as a file this reference's `##
Degradation` calls corrupt.

The journal is **committed**. Two reasons, one of them decisive:

- An untracked file is destroyed by `git clean -xdf`, a routine command. A
  journal that vanishes silently at the first cleanup is worse than no
  journal, because by the time it vanishes it is trusted.
- A generated repository's `docs/` already hosts builder-facing material
  (`development.md`, `release-process.md`, `validation-checklist.md`) next
  to user-facing material (`configuration.md`, `metrics.md`). The journal is
  not an intruder there.

The cost is stated rather than hidden: a generated exporter then publishes
an artifact that names this plugin's commands, in its own public repository.

## Format

Markdown, with eight frozen section headers, verbatim, in this order. The
position is the one the architecture brief has always had and the journal
inherits: it is consumed by the **model** executing a command's prose, never
parsed by a script (`scaffold.sh` stays a plain `sed` substitutor), so the
format optimizes for human review and model comprehension rather than
machine parsing. There is no parser to write, no schema to version, and a
partially damaged file leaves the rest usable.

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
- Name-vs-label arbitrations: <dimension>: <separate names | one label>, <why>
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
- Index: <N> open, <N> resolved, <N> accepted
- [OPEN] <anything discovery could not resolve>
- [RESOLVED] <the question> -> <how it was settled>, <date>
- [ACCEPTED] <a deliberate decision, kept for its reasoning>
```

`Shared label vocabulary` is the highest-value line in the file. If
collector 1 emits `pool` and collector 7 emits `pool_name`, no dashboard
joins them, and nothing on disk states which of the two is the rule:
existing names can be *observed*, the convention cannot be *derived*. The
same holds for the metric-name shape, one line above it.

`Name-vs-label arbitrations`, directly below it, carries the same weight for
the same reason, and closes a gap the label vocabulary alone leaves open: it
records which dimensions were resolved into **separate metric names** rather
than label values, which is precisely the information a list of label names
cannot express, because the whole point of such an arbitration is that no
label was created. Without it, every new collector re-opens a question that
was already settled, and settles it differently. One line per arbitration,
with the reason attached, since the reason is what makes it reusable:

```
- Name-vs-label arbitrations: read/write: separate names, official guidance
  names this case; temp/humidity: separate names, sum() is meaningless
```

`prometheus-principles.md`'s "Deciding between a separate name and a label
value" is the procedure that produces these lines. It runs once per exporter,
in `/prometheus-exporter:design-exporter`, and its Step 3 can cost a lookup
against an official exporter, which is the other reason to write the outcome
down rather than pay for it again per collector.

Every `<...>` above is a hole, filled per project. The headers are not: a
command looking for `## Cardinality budget` must find that exact string,
which is also what makes the corruption test of `## Degradation` checkable.

### Status tags in `## Open questions / assumptions`

Every other section is either frozen, or a list whose entries stay true once
written. This one is neither: it is mutable, all four commands append to it,
and nothing ever takes anything out. Left without a convention it accumulates
three different things under one undifferentiated pile: questions that are
genuinely still open, questions that were answered but got enriched in place
instead of closed, and passing session observations that were never questions
at all.

The failure that follows is not that the list gets long. It is that the list
starts lying. An entry describing a blocker whose fix landed weeks ago still
reads as a live blocker, and the section is trusted precisely because it is
the place such things are written down. **A todo list nobody can read is
worse than no todo list**, because it asserts obstacles that no longer exist,
and a reader cannot tell which ones without re-deriving every entry.

So each entry opens with one of three tags, and the section carries an index
line first:

- **`[OPEN]`**: still unresolved. This is the only tag that means work.
- **`[RESOLVED]`**: it was a question, it has an answer. Record the answer and
  when, on the same line, and **do not delete the entry**: the reasoning is
  what makes it worth keeping, and a deleted entry gets rediscovered and
  re-asked.
- **`[ACCEPTED]`**: a deliberate decision, not a loose end. This is the quiet
  win of the three. Decisions taken on purpose accumulate here and get re-read
  as unfinished business by whoever inherits the file, and marking them says
  "settled, on purpose" in a way that no amount of prose in the entry does.

`grep "\[OPEN\]" docs/exporter-journal.md` then answers "what is actually
left" without reading the section, which is the whole point. The tags are the
source of truth; the index is a summary of them for a human reading from the
top.

**The index has an owner, and it is whoever last touched a tag.** A count
nobody is responsible for is a derived value free to drift, which is the
failure this whole section is about, so it is not left to a later tidying
pass: any command that adds an entry or retags one updates the count in the
same edit. That is the entire maintenance rule, and it is why the index is
one line of three numbers rather than anything richer. If it is ever found
disagreeing with the tags, the tags win and the count is corrected on the
spot.

This section is also the one place where the journal's usual
`- (none yet)` placeholder does not apply: an empty section carries
`- Index: 0 open, 0 resolved, 0 accepted` instead, which says the same thing
and is already in the shape later entries need.

**Retagging is part of doing the work, not a separate tidying pass.** Any of
the four commands that settles a question while doing its own job retags that
entry in the same edit, and says so in its output like any other journal
correction. This is deliberately not part of `## Reconciliation`: that table
covers only what the disk can state on its own, and whether a question was
answered is a judgment, not something `docs/metrics.md` can be consulted
about. Nothing scans the section looking for entries to close, because a
command that retagged on a guess would produce exactly the false state this
convention exists to remove.

**No second file.** A separate open-questions file was the obvious
alternative and is the wrong one: two places to keep in sync is exactly how a
derivative drifts from its source, and the journal has to stay the single
place a command reads. Tags cost one token per line and keep the entry next
to its own history.

**On a journal written before this convention**, entries carry no tag. Treat
an untagged entry as `[OPEN]`, and tag entries as you touch them rather than
rewriting the section in one pass: an untagged section is not corrupt (`##
Degradation` tests headers, never their contents), so there is nothing to
repair and no reason for a command to rewrite prose it did not write.

## Section ownership

| Section | Created by | Completed by | Regime |
|---|---|---|---|
| `## Provenance` | `/prometheus-exporter:design-exporter` | nobody | frozen on write |
| `## Architecture decisions` | `/prometheus-exporter:design-exporter` | `/prometheus-exporter:new-prometheus-exporter` | mutable |
| `## Scaffold inputs` | `/prometheus-exporter:design-exporter` | `/prometheus-exporter:new-prometheus-exporter` | frozen after scaffold |
| `## Collectors` | `/prometheus-exporter:design-exporter` | `/prometheus-exporter:add-collector` | mutable |
| `## Cardinality budget` | `/prometheus-exporter:design-exporter` | `/prometheus-exporter:add-collector` | mutable |
| `## Dashboards` | `/prometheus-exporter:generate-dashboard` | `/prometheus-exporter:generate-dashboard` | mutable |
| `## Session log` | `/prometheus-exporter:design-exporter` | all four | append-only |
| `## Open questions / assumptions` | `/prometheus-exporter:design-exporter` | all four | mutable |

**"Created by" means first *content*, not first header.** Whichever command
creates the file writes all eight headers at once, in the order `## Format`
gives, and every section a command has nothing to put in yet gets a
placeholder line rather than being left out: `- (none yet)` under `##
Dashboards` on a journal born at design time, and the same for any other
section still empty. Only `## Dashboards` is routinely in that state on the
main path, since `/prometheus-exporter:generate-dashboard` runs late or not
at all, but the rule is the same for all eight and does not depend on which
one happens to be empty.

One section spells its placeholder differently, and only that: `## Open
questions / assumptions` opens with `- Index: 0 open, 0 resolved, 0 accepted`
instead of `- (none yet)`, per the status-tag convention above. The rule it
is obeying is identical, a header is never emitted bare, and only the wording
of the line differs.

This is not a formatting preference. An empty section and a missing header
are two different states, and only one of them is a defect: `## Degradation`
declares a file corrupt when a header is *absent*, so a command that omitted
`## Dashboards` until the first dashboard existed would make every healthy
journal fail that test and offer to rebuild itself on the happy path.
Emitting the header with a placeholder keeps the corruption test meaning
what it says.

A command writes only the sections it owns, and leaves the rest
byte-identical. `## Provenance` is never rewritten by anything: it is the
discovery ladder's own audit trail (`discovery-inputs.md`), and rewriting it
would erase why the design is trusted at the confidence level it claims. `##
Scaffold inputs` is completed once, with the selectors actually passed, and
is then a historical record of how the repository was produced, not a live
setting to edit. `## Session log` is only ever appended to; an entry is
never edited or removed, for the same reason.

> Reconciliation is the one exception, and it applies to every command.
> `## Reconciliation`'s corrections copy a fact disk has already proved, so
> they are not authorship and two commands cannot disagree about them: the
> value comes from the tree, not from the command's judgement. A command that
> finds a stale line therefore corrects it wherever it sits, including the
> namespace under the otherwise-frozen `## Scaffold inputs`, marks it
> `(reconciled <date>)`, logs it and reports it. Ownership settles who *fills*
> a section; it never licenses leaving a line disk has falsified. That binds
> `/prometheus-exporter:generate-dashboard` like the rest, and most of all: it runs last, so a
> correction it declines to write is one nothing later repairs.

### Read on entry, write on exit

The protocol is the same in all four commands, and the timing is not
negotiable:

- **On entry**, before asking the user anything: read the journal, reconcile
  it against disk (`## Reconciliation`), and report every correction. What
  the journal states about the non-derivable half (the budget, the label
  vocabulary, the remaining collectors, the credential convention) is read
  back to the user rather than re-derived or re-asked.
- **On exit**, *after* the command's own verification gate is green and
  never before: write the sections it owns, append one `## Session log`
  line, then print the resumption block (`## The resumption block`). A
  journal entry written before the gate records an outcome that has not
  happened yet.

> The two creating commands are exceptions, each on a different half.
> `/prometheus-exporter:design-exporter` runs no gate, so its resumption block simply omits the
> gate clause; the same block also names `./exporter-design-brief.md` where
> every other command names `docs/exporter-journal.md`, and asks for the brief
> to be reviewed before clearing rather than calling the clear safe outright.
> Both deviations follow from `## Lifecycle`: at that point no journal exists
> under either name, and nothing has verified the file the user is about to
> clear their context on except their own reading of it.
> `/prometheus-exporter:new-prometheus-exporter` has no journal to read on entry,
> and its only commit is the initial one, so it writes the journal after the
> scaffold and **before** that commit, leaving the file tracked rather than
> destroyed by the first `git clean -xdf`. Only its resumption block waits
> for the gate. Nothing either command writes before its commit records a
> gate outcome, so the rule's reason still holds where the rule's letter
> cannot.

> Reconciliation is a further exception, on the timing rather than on the
> authorship (`## Section ownership` carves out the authorship half). A
> correction copies a state the disk has already proved, so it records no
> outcome that has not happened yet, which is the entire reason "never before"
> exists. Corrections are therefore written where they are found, on entry,
> together with the `## Session log` line naming them: `/prometheus-exporter:add-collector` writes
> at its first step and `/prometheus-exporter:generate-dashboard` at its own, both long before
> their gates run. What still waits for the gate is everything a command
> *authors*: the sections it owns, its own outcome line, and the resumption
> block.

## Reconciliation

Authority is shared but never overlapping. **The disk decides everything it
can state. The journal is sole authority on everything else.** The tick
boxes under `## Collectors` are a *cache* of disk truth, never a source of
it.

On entry, every command reconciles:

| Read from disk | How | If the journal disagrees |
|---|---|---|
| I/O flavor | `internal/collector/client.go` vs `execute.go` | corrected, reported |
| Target model | `internal/instance/` vs `internal/probe/` vs neither | corrected, reported |
| Namespace | `const namespace = "..."` in `cmd/*/main.go` | corrected, reported |
| Collectors built | `## <Name>Collector` headers in `docs/metrics.md` | box ticked or unticked, marked `(reconciled <date>)`, reported |
| A collector with no box at all | a `## <Name>Collector` header no `## Collectors` line names | a box is added, ticked, marked `(reconciled <date>)`, reported |

That last row is ordinary, not exotic. Any journal not born under this
release is missing at least one box: a repository scaffolded before the
journal shipped has every collector on disk and none in a journal it does
not have, and the collector every scaffold ships built and documented was
planned by no design brief. A collector added by hand, or an
`/prometheus-exporter:add-collector` interrupted between the code and the
docs, lands in the same state.
`/prometheus-exporter:new-prometheus-exporter` writes that scaffolded
collector's box itself, so a journal this release produced starts complete
and the row is what keeps it so afterwards. It is also why `## Collectors`
is a section the create-offer below **fills from disk** rather than
placeholders: the `## <Name>Collector` headers state exactly which
collectors exist, so a repository predating this file recovers all of them
as ticked boxes, where a placeholder line would strand them (nothing
reconciles a box that was never written).

**No correction is silent.** Each one is stated in the command's output to
the user and leaves a `## Session log` line. A journal that asserts a false
state is more harmful than an absent one, precisely because it has been
trusted: the whole point of writing it down was to stop re-deriving it.

Reconciliation is not a corruption check. It covers the ordinary case far
more often than the pathological one: a collector added by hand, an
`/prometheus-exporter:add-collector` interrupted between the code and the
docs, a colleague who pushed while the journal sat in a local branch. None
of those should stop anything. The box is brought in line with
`docs/metrics.md`, the correction is reported, and the command carries on.

## Degradation

**Corrupt** has a checkable definition, not a judgement call: the file
exists but has no `# Exporter journal:` title line, or is missing at least
one of the required `##` headers listed under `## Format`.

The test is on the header, never on what sits under it. An empty section, or
one holding only a placeholder line, is a normal journal: sections are
created all eight at a time and filled later (`## Section ownership`). A
journal whose `## Dashboards` reads `- (none yet)` is healthy, and a command
that treats it as corrupt is raising a false alarm on the main path.

- **Absent.** The command does exactly what it did before this file existed,
  all the way through. At the end it offers to build the journal: derivable
  facts read from disk, non-derivable ones asked. This is the upgrade path
  for every repository scaffolded before the journal shipped, and it needs
  no migration of any kind, because a documentation file touches no code
  seam.
- **Corrupt.** The command also does its full job, then asks: rebuild with a
  backup at `docs/exporter-journal.md.bak`, or leave it untouched. **It
  writes nothing before an answer.** A file that cannot be understood may
  hold hand-written prose worth keeping, and overwriting it to restore a
  format is the wrong trade.

**Never a refusal.** A command refuses when proceeding would be dangerous,
such as an outdated code seam it would have to migrate in place. A missing
or malformed documentation file is not that: refusing there would break the
command on every exporter generated before the journal existed, to protect
nothing.

## The resumption block

Every command ends, **after its verification gate is green and never
before** where it has one (`### Read on entry, write on exit` carves out
`/prometheus-exporter:design-exporter`, the one command that runs no gate),
with a literal, copy-pasteable block:

```
<what this command just did>. <its gate> is green.
Journal: <N> of <M> collectors built. Next planned: `<name>` (<variant>).

Safe to /clear now: everything above is in docs/exporter-journal.md.
Then run:

    /<next-command> <argument read from the journal>
```

Three things make it work:

- **The argument is read from the journal**, not templated: the first
  unticked entry under `## Collectors`, with its variant.
  `/prometheus-exporter:design-exporter` suggests
  `/prometheus-exporter:new-prometheus-exporter <name>`;
  `/prometheus-exporter:new-prometheus-exporter` suggests the first planned
  collector; `/prometheus-exporter:add-collector` suggests the next one, and
  `/prometheus-exporter:generate-dashboard` once the list is empty.
- **The gate is named, and it has already run**, wherever there is one to
  name. "Safe to `/clear`" is a claim about state on disk, so it is only
  honest once the state on disk has been verified and written. That binds
  `/prometheus-exporter:new-prometheus-exporter`,
  `/prometheus-exporter:add-collector` and
  `/prometheus-exporter:generate-dashboard` without exception.
  `/prometheus-exporter:design-exporter` omits the clause rather than
  inventing a gate to name, and points at the brief rather than at the
  journal, for the reasons `### Read on entry, write on exit` gives.
- **Nothing is invoked.** All four commands carry `disable-model-invocation:
  true`: the model cannot trigger them, only the user can type them. The
  block is a suggestion printed as text, which is why it is copy-pasteable
  rather than automatic.

The payoff is the reason the whole file exists: with the block printed and
the journal written, `/clear` between two collectors becomes the
*recommended* move rather than a destructive one. Several short sessions
beat one context window swelling to suffocation.
