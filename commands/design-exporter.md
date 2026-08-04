---
description: Run the exporter architecture-design phase (step 0) with broadened discovery (ground the design in a local API spec, a docs folder or URL, or context7, in that preference order), then write a reviewable architecture brief that /prometheus-exporter:new-prometheus-exporter can consume.
argument-hint: <target>
disable-model-invocation: true
---

Run the exporter architecture-design phase (step 0) grounded in whatever
real documentation is actually available for the target, instead of guessing
from memory. This command's only side effect is writing one file,
`./exporter-design-brief.md` by default: it does not create a directory,
initialize a repository, or generate any code. That is
`/prometheus-exporter:new-prometheus-exporter`'s job, run afterward once the
brief this command produces has been reviewed. Even so, only run this
command when the user explicitly invokes it, and walk through every step
below in order rather than skipping ahead.

Candidate target from the command argument: $ARGUMENTS, a name (e.g.
`demo_exporter`), or a short description of what it monitors if no name is
picked yet. If empty, ask.

## 1. Read the four references this phase runs on

Read all four fully before asking the user anything:

- `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/discovery-inputs.md`:
  the discovery ladder and the per-source extraction method for each rung.
- `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/exporter-architecture.md`:
  the six architecture decisions this phase must produce.
- `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/prometheus-principles.md`:
  naming, types and labels, which decision 5b below binds every collector
  to.
- `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/project-journal.md`:
  the journal's format and the protocol every command follows.

## 2. Walk the discovery ladder, top-down

Say this to the user plainly, once, at the top of the walk:

> Put whatever you already have wherever suits you, and tell me where: an
> OpenAPI or gRPC specification, exported documentation pages, and any output
> you have captured from the target by hand. I will record the paths. If you
> have none, that is fine: nothing here is blocking, and the plugin will
> produce what it needs as we go.

Then ask, in this order, moving to the next rung only when the current one
is genuinely unavailable. A higher rung is *supplemented* by a lower one
where the lower adds detail the higher left silent, never replaced by it:

1. **Local API spec** (rung 1): is an OpenAPI/Swagger document or a `.proto`
   file available, and at what path? If yes, read it directly and extract
   per `discovery-inputs.md`'s OpenAPI/gRPC rules.
2. **Docs folder or URL** (rung 2): if no spec, is there a docs folder in
   this repository, or a URL to the target's own documentation? If yes, read
   or fetch it.
3. **context7** (rung 3): if neither of the above grounded the design, try
   `resolve-library-id` against the target, then `query-docs` for its API
   surface. Treat "not installed" and "no match" as a skip, not a failure.
   Never guess a nearby library's shape instead.
4. **Live-target probe** (rung 4): **opt-in.** Only if the user has a
   running instance of the target and wants it used: ask for its endpoint
   (http) or the command to run (cli), then show the *exact* command that
   `bash
   "${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/scripts/probe-target.sh"
   --mode <http|cli> --target <…> [--path <…>] --print-command` prints and
   get explicit consent before running it. Run the same backbone without
   `--print-command`; it fetches/executes under a timeout and redacts
   secrets before returning. Interpret the redacted output as candidate
   collectors/ metrics, **supplementing** the higher rungs: confirming what
   they stated, filling gaps they left, and recording any contradiction as
   an entry under `## Open questions / assumptions`, tagged `[OPEN]`,
   rather than overriding them.
   Skip silently in a non-interactive run (no consent possible).
5. **Dialogue** (rung 5): if nothing above grounded the design, fall back to
   the question flow in `exporter-architecture.md`. Always available, so the
   walk always has somewhere to land.

Rungs 1 and 2 already ask for a path or a URL. **Record it.** Whatever the
user names, and whatever the live probe was pointed at, goes into the
brief's `## Provenance` section as a `Source material:` line, so a later
session does not have to ask again or re-solicit a running machine.

Record, for the brief's `## Provenance` section: which rung(s) actually
grounded the design, including whether the live-target probe (rung 4) was
run and what it confirmed or added, and, for every rung skipped, a one-line
reason why (rung 4's is usually "no running instance offered" or "consent
declined"), not just that it was skipped.

## 3. Confirm the six architecture decisions with the user

Whatever the ladder grounded, and whatever gaps it left, run
`exporter-architecture.md`'s question flow to fill those gaps and confirm
(explicitly, with the user, never assumed on their behalf) all six:

1. **Data source**, in preference order: REST/API > gRPC > CLI (CLI is the
   last resort: justify it if chosen). A database is not a rung on this
   ladder: a target reachable only through its own database is out of scope
   for this plugin, a deliberate non-goal rather than a deferred feature.
   Say so and point at `postgres_exporter` / `mysqld_exporter` for the
   engine itself, or the config-driven `sql_exporter` for arbitrary
   SQL-to-metrics, instead of designing a scaffold that will be refused.
2. **Single-target vs. multi-target vs. multi-instance**: state which of the
   three the real shape is. `single` reports on one fixed target. `multi`
   lets Prometheus pick the target per scrape (`?target=`, the Blackbox
   pattern). `multi-instance` polls a fixed list of machines in the
   background and serves them through one `/metrics` (the model for sources
   that refresh more slowly than Prometheus's 5-minute staleness window, or
   that carry per-machine credentials). All three are produced by
   `/prometheus-exporter:new-prometheus-exporter`; both multi models require
   the `http` flavor.

   If the answer is `multi`, ask one follow-up before moving on, because it
   decides what the generated `config.example.yml` should demonstrate, not
   what code gets produced (the code is identical either way):

   > How do your targets authenticate?
   >
   > **a.** All the same, or not at all. No `modules:` section is needed;
   > one `http_client_config:` covers every target.
   > **b.** By group: prod and staging, two sites, two tenants. One module
   > per group, each carrying its own credentials, and the scrape config
   > names one with `&module=`.
   > **c.** Credentials and collector subsets vary independently.
   > Credentials-only modules combined with collector modules in one
   > request.

   Record the answer under `## Architecture decisions` in the brief, as
   `Credential convention: a|b|c`, so it survives on disk rather than in
   this conversation.
3. **I/O flavor** (`http` or `cli`), following directly from the data
   source.
4. **Collector list**, one resource per collector, in the order they will be
   built. For each collector on this list, also ask: is this backend slow or
   expensive enough (seconds per call, rate-limited, or otherwise not built
   for high-frequency polling) that it should refresh on a fixed background
   interval instead of synchronously on every scrape? Do not wait for the
   user to raise this. Ask proactively if nothing so far has signalled it. A
   "yes" is recorded here, under this same decision, and becomes the signal
   for `/prometheus-exporter:add-collector --variant background <name>` once
   scaffolding begins.

   Once the collector list is settled, and only if the target model is
   `multi-instance`, or `single` with at least one collector marked
   background above, ask one more follow-up. Like the credential-convention
   follow-up under decision 2, it decides a `config.example.yml` setting,
   not any code:

   > Does this target tolerate several requests at once? Some devices and
   > appliances serialize internally, or degrade sharply, and this exporter
   > can hold at most N requests open against one machine at a time. Leave
   > it unlimited unless you know otherwise; a ceiling makes a slow
   > collector delay its siblings, which the freshness gauge and
   > `<namespace>_exporter_request_wait_seconds` will show.

   Never ask this for `multi`: it has no background pollers and no ceiling
   flag at all. Where it does apply, what "at most N requests open against
   one machine at a time" actually bounds depends on both the model and the
   I/O flavor, not just the model, so state the real scope rather than let
   the user assume the same shape everywhere:

   - `multi-instance` bounds each watched *instance* independently: two
     `instances:` entries that happen to share one physical address are
     still bounded on their own, not jointly.
   - `single` with the `http` flavor bounds each collector's own
     `--collector.<name>.target` *address*: two collectors pointed at the
     same address share one ceiling; collectors on different addresses do
     not.
   - `single` with the `cli` flavor has no per-target client and no
     per-address index to key by, only one shared command-execution
     boundary every collector calls through. The ceiling there is
     exporter-wide: it caps total concurrent command invocations across
     every collector combined, regardless of which machine each one
     targets.

   Record the answer under `## Architecture decisions` in the brief, as
   `Concurrency ceiling: unlimited` or `Concurrency ceiling: <N>`.
5. **Cardinality budget** per collector: labels, worst-case series count,
   any reduction flag. 5b. **Naming conventions**, asked once and binding on
   every collector. Two
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
    - Shared label vocabulary: <label>, <label>, <label>
    ```
6. **Business-alert candidates** per collector, one line each.

Where discovery already answered part of this with a high- or
medium-confidence source, read that answer back to the user for confirmation
rather than re-deriving it from scratch, but still confirm it rather than
assuming it stands. Where discovery left a gap, ask directly; do not guess
on the user's behalf.

## 4. Write the architecture brief

Write to `./exporter-design-brief.md` in the current working directory, or
to the path the user names instead. If a file already exists at that path,
confirm with the user before overwriting it.

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

Write all eight headers now, including the ones this phase has nothing to
put under yet. `project-journal.md` counts a missing header as a corrupt
file and an empty section as a healthy one, so a section with no content yet
carries a placeholder line rather than being left out.

- `## Provenance`: which rung(s) grounded the design, which were skipped and
  why, and an overall Confidence of high, medium, or low.
- `## Architecture decisions`: the decisions from step 3 that do not get a
  section of their own, in brief form: the data source, the target model and
  its credential convention, the I/O flavor, the concurrency ceiling, the
  naming conventions from 5b, and the business-alert candidates from 6.
- `## Scaffold inputs`: `EXPORTER_NAME`, `NAMESPACE`, `DATA_SOURCE`,
  `DATA_SOURCE_PATH`, and `DEFAULT_PORT` only. Leave `MODULE_PATH`, `OWNER`,
  and `LICENSE` out deliberately: those are the scaffolder's own identity
  questions, not the target's, and
  `/prometheus-exporter:new-prometheus-exporter` always asks for them itself
  whether or not a brief is present.
- `## Collectors`: the ordered list from decision 4, as an unticked
  checklist, one line each, carrying the sync/background variant decided
  there and the endpoint or command it will read. This is the list
  `/prometheus-exporter:add-collector` walks, one entry per session.
- `## Cardinality budget`: decision 5, per collector, as an **intention**
  (labels, worst-case series, any planned reduction flag).
  `/prometheus-exporter:add-collector` will later append what was actually
  observed next to it.
- `## Dashboards`: left with a single line, `- (none yet)`.
  `/prometheus-exporter:generate-dashboard` owns it.
- `## Session log`: opened with this phase's own entry, one line, dated.
- `## Open questions / assumptions`: anything discovery could not resolve,
  flagged here for the user instead of silently assumed. Every entry opens
  with a status tag, `[OPEN]` for all of them at this stage, and the section
  starts with the `Index:` line (`project-journal.md`'s status-tag
  convention). Tagging from the first write is what keeps the section
  readable later; retrofitting tags to an untagged pile is the failure this
  convention exists to prevent.

`## Provenance` gains its `Source material:` line from step 2. Write the
file, then never rewrite `## Provenance` again: it is the ladder's audit
trail, and rewriting it erases why the design is trusted at the confidence
it claims.

Show the user the path of the file just written.

## 5. Hand off to scaffolding

This command's job ends with the brief. It does not scaffold anything. End
with the resumption block `project-journal.md` defines, filled from what was
just written:

```
Design brief written to ./exporter-design-brief.md.
Journal: 0 of <N> collectors built. Next planned: `<name>` (<variant>).

Review the brief, then it is safe to /clear: everything above is in
./exporter-design-brief.md.
Then run:

    /prometheus-exporter:new-prometheus-exporter <name>
```

Never invoke that command yourself. Print it, and say it is to be run in
this same directory, where `/prometheus-exporter:new-prometheus-exporter`
looks for the brief.
