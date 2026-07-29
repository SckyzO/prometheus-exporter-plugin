---
description: Run the exporter architecture-design phase (step 0) with broadened discovery (ground the design in a local API spec, a docs folder or URL, or context7, in that preference order), then write a reviewable architecture brief that /new-prometheus-exporter can consume.
argument-hint: <target>
disable-model-invocation: true
---

Run the exporter architecture-design phase (step 0) grounded in whatever
real documentation is actually available for the target, instead of
guessing from memory. This command's only side effect is writing one file,
`./exporter-design-brief.md` by default: it does not create a directory,
initialize a repository, or generate any code. That is
`/new-prometheus-exporter`'s job, run afterward once the brief this command
produces has been reviewed. Even so, only run this command when the user
explicitly invokes it, and walk through every step below in order rather
than skipping ahead.

Candidate target from the command argument: $ARGUMENTS, a name (e.g.
`demo_exporter`), or a short description of what it monitors if no name is
picked yet. If empty, ask.

## 1. Read the two references this phase runs on

Read both fully before asking the user anything:

- `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/discovery-inputs.md`:
  the discovery ladder and the per-source extraction method for each rung.
- `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/exporter-architecture.md`:
  the six architecture decisions this phase must produce.

## 2. Walk the discovery ladder, top-down

Ask, in this order, moving to the next rung only when the current one is
genuinely unavailable. A higher rung is *supplemented* by a lower one where
the lower adds detail the higher left silent, never replaced by it:

1. **Local API spec** (rung 1): is an OpenAPI/Swagger document or a
   `.proto` file available, and at what path? If yes, read it directly and
   extract per `discovery-inputs.md`'s OpenAPI/gRPC rules.
2. **Docs folder or URL** (rung 2): if no spec, is there a docs folder in
   this repository, or a URL to the target's own documentation? If yes,
   read or fetch it.
3. **context7** (rung 3): if neither of the above grounded the design, try
   `resolve-library-id` against the target, then `query-docs` for its API
   surface. Treat "not installed" and "no match" as a skip, not a failure.
   Never guess a nearby library's shape instead.
4. **Live-target probe** (rung 4): **opt-in.** Only if the user has a running
   instance of the target and wants it used: ask for its endpoint (http) or
   the command to run (cli), then show the *exact* command that
   `bash "${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/scripts/probe-target.sh"
   --mode <http|cli> --target <…> [--path <…>] --print-command` prints and get
   explicit consent before running it. Run the same backbone without
   `--print-command`; it fetches/executes under a timeout and redacts secrets
   before returning. Interpret the redacted output as candidate collectors/
   metrics, **supplementing** the higher rungs: confirming what they stated,
   filling gaps they left, and recording any contradiction as an
   `## Open questions / assumptions` entry rather than overriding them. Skip
   silently in a non-interactive run (no consent possible).
5. **Dialogue** (rung 5): if nothing above grounded the design, fall back
   to the question flow in `exporter-architecture.md`. Always available,
   so the walk always has somewhere to land.

Record, for the brief's `## Provenance` section: which rung(s) actually
grounded the design, including whether the live-target probe (rung 4) was run
and what it confirmed or added, and, for every rung skipped, a one-line reason
why (rung 4's is usually "no running instance offered" or "consent declined"),
not just that it was skipped.

## 3. Confirm the six architecture decisions with the user

Whatever the ladder grounded, and whatever gaps it left, run
`exporter-architecture.md`'s question flow to fill those gaps and confirm
(explicitly, with the user, never assumed on their behalf) all six:

1. **Data source**, in preference order: REST/API > gRPC > database > CLI
   (CLI is the last resort: justify it if chosen).
2. **Single-target vs. multi-target vs. multi-instance**: state which of the
   three the real shape is. `single` reports on one fixed target. `multi` lets
   Prometheus pick the target per scrape (`?target=`, the Blackbox pattern).
   `multi-instance` polls a fixed list of machines in the background and serves
   them through one `/metrics` (the model for sources that refresh more slowly
   than Prometheus's 5-minute staleness window, or that carry per-machine
   credentials). All three are produced by `/new-prometheus-exporter`; both
   multi models require the `http` flavor.

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
4. **Collector list**, one resource per collector, in the order they will
   be built. For each collector on this list, also ask: is this backend
   slow or expensive enough (seconds per call, rate-limited, or otherwise
   not built for high-frequency polling) that it should refresh on a fixed
   background interval instead of synchronously on every scrape? Do not
   wait for the user to raise this. Ask proactively if nothing so far has
   signalled it. A "yes" is recorded here, under this same decision, and
   becomes the signal for `/add-collector --variant background <name>` once
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
   flag at all. Where it does apply, the ceiling is scoped differently by
   model: on `multi-instance` it bounds each watched *instance*
   independently, so two `instances:` entries that happen to share one
   physical address are still bounded on their own, not jointly; on
   `single` it bounds each collector's own `--collector.<name>.target`
   *address*, so two collectors pointed at the same address do share one
   ceiling. Record the answer under `## Architecture decisions` in the
   brief, as `Concurrency ceiling: unlimited` or `Concurrency ceiling: <N>`.
5. **Cardinality budget** per collector: labels, worst-case series count,
   any reduction flag.
6. **Business-alert candidates** per collector, one line each.

Where discovery already answered part of this with a high- or
medium-confidence source, read that answer back to the user for
confirmation rather than re-deriving it from scratch, but still confirm
it rather than assuming it stands. Where discovery left a gap, ask
directly; do not guess on the user's behalf.

## 4. Write the architecture brief

Write to `./exporter-design-brief.md` in the current working directory, or
to the path the user names instead. If a file already exists at that path,
confirm with the user before overwriting it.

Use the exact section shape `discovery-inputs.md` defines, verbatim
headers, in this order:

```markdown
# Exporter design brief: <target>

## Provenance
## Architecture decisions
## Scaffold inputs
## Open questions / assumptions
```

- `## Provenance`: which rung(s) grounded the design, which were skipped
  and why, and an overall Confidence of high, medium, or low.
- `## Architecture decisions`: the six decisions from step 3, in brief
  form.
- `## Scaffold inputs`: `EXPORTER_NAME`, `NAMESPACE`, `DATA_SOURCE`,
  `DATA_SOURCE_PATH`, and `DEFAULT_PORT` only. Leave `MODULE_PATH`,
  `OWNER`, and `LICENSE` out deliberately: those are the scaffolder's own
  identity questions, not the target's, and `/new-prometheus-exporter`
  always asks for them itself whether or not a brief is present.
- `## Open questions / assumptions`: anything discovery could not
  resolve, flagged here for the user instead of silently assumed.

Show the user the path of the file just written.

## 5. Hand off to scaffolding

This command's job ends with the brief. It does not scaffold anything.
Tell the user to review the brief just written, then run
`/new-prometheus-exporter <name>` in the same directory to scaffold the
repository from it.
