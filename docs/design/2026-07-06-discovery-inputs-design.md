# Discovery inputs for the architecture phase — design

**Status:** draft, pending maintainer review.
**Milestone:** v0.2 (head of the backlog in `ROADMAP.md`).
**Supersedes/extends:** the step-0 discovery guidance in
`skills/prometheus-exporter/references/exporter-architecture.md` §1 and the
skill router's step 0.

## 1. Problem

Today the architecture phase (step 0) discovers a target's API surface through
**one** input: context7, queried against the target's own library docs
(`exporter-architecture.md:53-58`). That is a single point of failure for the
exact case this plugin most wants to serve well — an exporter for an
**internal or proprietary** program, whose docs context7 will never have. When
context7 has no match (or isn't installed at all), step 0 silently degrades to
"describe it from memory", which is precisely the guessing the skill's
`context7-first` principle exists to prevent.

The design decisions of step 0 are only as good as what they are grounded in.
Broadening the grounding is therefore the highest-leverage v0.2 change: it
strengthens needs-framing for the targets that need it most.

## 2. Goal

Broaden step-0 discovery to accept, in preference order, several kinds of
grounding — with **graceful degradation** so the phase never hard-fails and
always produces the same six-item output it produces today. Give the capability
a discoverable front door (`/design-exporter`) that emits a concrete
**architecture brief**, and make `/new-prometheus-exporter` able to consume that
brief instead of re-eliciting everything interactively.

Everything here is **additive**: a v0.1 user who runs `/new-prometheus-exporter`
with no brief gets exactly today's interactive step-0 behavior. No default
changes.

## 3. Scope

### In scope (v0.2)

- A new **reference**, `references/discovery-inputs.md`: the taxonomy of
  discovery inputs, their preference order, the per-source extraction method,
  and the degradation ladder. This is the `[G]` knowledge home.
- A new **command**, `/design-exporter <target>`: runs step 0 *with* the
  broadened discovery, then writes an architecture brief file.
- The **architecture-brief format**: a structured markdown artifact that
  captures the six step-0 decisions plus the concrete scaffold inputs derived
  from discovery.
- **Consumption wiring** in `/new-prometheus-exporter`: an optional path that
  reads a brief and pre-fills its step-0 confirmation and step-1 variables.
- **Router wiring**: SKILL.md step 0 and `exporter-architecture.md` §1 point at
  the new reference and command.
- A **fixture brief** plus a golden **structural check** that the brief
  contract stays in sync across the three places that touch it.

### Discovery sources shipped in v0.2

In preference order (highest grounding confidence first). The rung numbers here
match the degradation ladder in §5 — rung 4 (live-target probe) is deferred, so
the shipped rungs are 1, 2, 3, and the terminal rung 5:

1. **Local API spec** — OpenAPI/Swagger (`.yaml`/`.json`), gRPC (`.proto`).
   A structured contract: the most reliable source.
2. **Docs folder or URL** — local files read directly, or a URL fetched, then
   analyzed as prose.
3. **context7** — the target's library docs (today's only input; now one rung
   among several).
5. **Dialogue fallback** (terminal rung) — the user describes the target in
   conversation. Always available; this is today's degraded behavior, now
   explicit and labelled low-confidence.

### Out of scope (deferred to a v0.2.x fast-follow)

- **Live-target probe** — hitting a running instance (`curl /openapi.json`,
  `/metrics`, `--help`). It adds network + process-exec + dual-use surface, and
  rungs 1–3 already cover the core need. It appears in the degradation ladder as
  a documented, explicitly-deferred rung so the reader knows it is intentional,
  not forgotten.
- Any change to `scaffold.sh`. The brief is consumed by the model executing the
  command prose, not parsed by the scaffolder (see §7). `scaffold.sh` stays a
  dumb `sed` substitutor.

## 4. Architecture

Three artifacts, one data object:

```
/design-exporter <target>          references/discovery-inputs.md
        │  (command, model-driven)          │  (the [G] method it reads)
        │                                    │
        ├── reads inputs (spec/docs/ctx7) ◄──┘
        ├── runs the exporter-architecture.md dialogue to fill gaps
        └── writes ──► ./exporter-design-brief.md   (the architecture brief)
                                 │
                                 ▼
              /new-prometheus-exporter <name>
                 step 0: reads the brief, presents it for confirmation
                 step 1: pre-fills template variables from the brief
                 (no brief present → today's interactive path, unchanged)
```

- The **reference** is the knowledge: usable both by the command and by the
  skill's inline step 0 (a user who never runs the command still benefits).
- The **command** is the discoverable front door and the thing that produces a
  reviewable artifact. It stays *thin* — it orchestrates the method taught in
  the reference and the dialogue taught in `exporter-architecture.md`; it holds
  no discovery logic of its own beyond the orchestration order.
- The **brief** is the hand-off contract between design and scaffold, making the
  existing two-phase structure (decide → scaffold) explicit.

## 5. The discovery ladder (graceful degradation)

`discovery-inputs.md` teaches this ladder. The command walks it top-down,
using the highest-confidence source available and *supplementing* (not
replacing) with lower rungs where they add detail:

| Rung | Source | Confidence | Degrades when |
|---|---|---|---|
| 1 | Local API spec (OpenAPI/Swagger/`.proto`) | High | no spec file offered |
| 2 | Docs folder or URL | Medium | none offered / URL unreachable |
| 3 | context7 (target's lib) | Medium | not installed, or no library match |
| 4 | *(deferred)* live-target probe | — | *(not shipped in v0.2)* |
| 5 | Dialogue with the user | Low | — (always available; terminal rung) |

**Guarantees:**

- The phase **never hard-fails**. Every rung that is unavailable is skipped with
  a one-line note in the brief's provenance section; the walk continues to the
  next rung.
- context7 absence is handled at two levels: MCP server not installed at all →
  skip rung 3 entirely; installed but `resolve-library-id` finds no match →
  skip with a "context7 has no entry for `<target>`" note. Neither blocks.
- The brief always records **which rung(s) actually grounded it** and a
  resulting **confidence** (high/medium/low), so the user reviewing the brief
  knows how much to trust each decision.

## 6. Per-source extraction method (what the reference teaches)

For each source, `discovery-inputs.md` gives a concrete method for turning it
into the six step-0 decisions — never generic "analyze the docs":

- **OpenAPI/Swagger** → each tagged group of paths is a candidate collector;
  each `GET` returning a list/among a resource is a metric candidate; `servers[]`
  → `DATA_SOURCE`; the first collector's path → `DATA_SOURCE_PATH`; `securitySchemes`
  → the auth note; array responses → the cardinality warning.
- **gRPC `.proto`** → each `service` is a candidate collector; each unary RPC
  returning a message with repeated fields is a metric candidate; this is the
  gRPC-adapts-the-http-flavor case already noted in `exporter-architecture.md`.
- **Docs folder / URL** → read the files (or WebFetch the URL), extract the
  documented endpoints/commands and the resources they expose; lower confidence
  than a machine-readable contract, so decisions are marked as such.
- **context7** → `resolve-library-id` on the target, then `query-docs` for its
  API surface; unchanged from today, but now explicitly one rung.
- **Dialogue** → the existing `exporter-architecture.md` question flow.

The reference keeps the `[G]/[S]` split: the *method* (how to read a spec into
collectors) is `[G]`; the specific endpoints of any one target are `[S]` and
live only in that target's brief.

## 7. The architecture brief

A single markdown file, default `./exporter-design-brief.md` in the working
directory (overridable). Consumed by the **model** executing `/new`'s prose —
**not** parsed by `scaffold.sh` — so the format optimizes for human review and
model consumption, not machine parsing. Required sections:

```markdown
# Exporter design brief: <target>

## Provenance
- Grounded by: <rung(s) actually used, e.g. "OpenAPI spec ./openapi.yaml">
- Skipped: <rungs skipped and why, e.g. "context7 — no entry for <target>">
- Confidence: <high | medium | low>

## Architecture decisions   (the six items of exporter-architecture.md)
- Data source: <REST API | gRPC | DB | CLI> — <base URL / command>
- I/O flavor: <http | cli>
- Target model: <single-target | multi-target (documented follow-up)>
- Collectors (ordered):
  1. `<name>` — <resource> — endpoint `<path>` — <one line>
  2. ...
- Cardinality budget: per collector — labels, worst-case series, reduction flag
- Business-alert candidates: per collector, one line each

## Scaffold inputs   (pre-fills /new step 1; identity fields intentionally absent)
- EXPORTER_NAME: <name>
- NAMESPACE: <suggested>
- DATA_SOURCE: <url or command>
- DATA_SOURCE_PATH: <first collector endpoint, or "unused" for CLI>
- DEFAULT_PORT: <port>

## Open questions / assumptions
- <anything discovery could not resolve — flagged for the user>
```

**Identity fields are deliberately not in the brief.** `MODULE_PATH`, `OWNER`,
and `LICENSE` are the maintainer's identity, not discoverable from the target;
`/new` always asks for them. This keeps the brief purely about the *target*, and
means a shared/example brief carries no one's identity.

## 8. Consumption by `/new-prometheus-exporter` (additive, non-breaking)

`/new` step 0 gains an optional branch, ahead of today's interactive
confirmation:

1. Look for a brief: an explicit path if the user gave one, else
   `./exporter-design-brief.md` in CWD.
2. **If found:** read it, present its Architecture-decisions section to the user
   for confirmation (not silent trust — the user still owns the final call),
   and pre-fill step-1 variables from its Scaffold-inputs section. Still ask for
   the identity fields (`MODULE_PATH`, `OWNER`, `LICENSE`).
3. **If not found:** today's interactive step-0 path, verbatim. A v0.1 user sees
   no change.

The brief is an *input*, never a requirement. `/new` never writes or requires
one; it only consumes one if present.

## 9. Router wiring

- **SKILL.md step 0** ("Architecture design first"): add one line — discovery
  can be grounded in a local spec, a docs folder/URL, or context7, and
  `/design-exporter` runs the phase and emits a brief `/new` can consume — plus
  a `→ references/discovery-inputs.md` pointer. The existing text stays.
- **SKILL.md reference index**: add an 11th row for `discovery-inputs.md`
  ("Step 0 — discovery input taxonomy, preference order, degradation ladder").
- **SKILL.md `context7-first` principle**: reframe the step-0 clause from
  "context7 (the target's own API)" to "the best available grounding for the
  target's API — a local spec, its docs, or context7", so the principle no
  longer implies context7 is the only step-0 input.
- **exporter-architecture.md §1**: the paragraph that today mandates context7
  against the target (lines 53-58) gains a lead-in — context7 is one of several
  inputs, in the ladder's order — and a `→ discovery-inputs.md` pointer for the
  full method. The existing context7 guidance is preserved as rung 3.

## 10. Testing strategy

Discovery quality (does the model read an OpenAPI spec into sensible
collectors?) is **model behavior expressed in prose**, like the rest of the
plugin's references — validated by review and dogfooding, not by the shell
golden. What *is* deterministically testable is the **brief contract**, because
three artifacts must agree on its section names (the reference documents it,
`/design-exporter` writes it, `/new` reads it):

- Ship `test/fixtures/exporter-design-brief.md` — a realistic brief for a
  fictional target (reusing the harness's existing `acme/demo_exporter` identity,
  zero-source-clean).
- Add a golden **structural check**: assert the fixture contains each required
  section header (`## Provenance`, `## Architecture decisions`,
  `## Scaffold inputs`, `## Open questions`). If any of the three artifacts
  renames a section, the fixture must change with it, and this check is the
  tripwire. It reuses the existing `command grep` idiom already in
  `golden-smoke.sh`.

This check is honestly scoped: it guards the *format contract*, not the
end-to-end discovery. The spec states that limitation plainly (per the
no-silent-caps principle) rather than implying the golden proves discovery
works.

## 11. Files

**Created:**
- `commands/design-exporter.md` — the command (`disable-model-invocation: true`,
  like `/new`; explicit user action, writes a file).
- `skills/prometheus-exporter/references/discovery-inputs.md` — the reference.
- `test/fixtures/exporter-design-brief.md` — the golden fixture brief.

**Modified:**
- `skills/prometheus-exporter/SKILL.md` — step 0 line, reference-index row,
  `context7-first` reframe.
- `skills/prometheus-exporter/references/exporter-architecture.md` — §1 lead-in
  + pointer; the "Output of this phase" checklist gains a note that the brief is
  its serialized form.
- `commands/new-prometheus-exporter.md` — step 0 optional brief-consumption
  branch; step 1 note that variables may arrive pre-filled from a brief.
- `test/golden-smoke.sh` — the brief-fixture structural check.
- `ROADMAP.md` — move discovery-inputs from "v0.2" list to done once shipped
  (bookkeeping at merge).
- `CHANGELOG.md` — a `## [Unreleased]` → `0.2.0` entry.

## 12. Follow-ups (explicitly deferred)

- **Live-target probe** (ladder rung 4) — the fast-follow after this lands.
- **End-to-end discovery test** — would need a model-in-the-loop harness; out of
  scope for the shell golden.
- Carried v0.1.1 minors unrelated to discovery remain in the SDD ledger.
