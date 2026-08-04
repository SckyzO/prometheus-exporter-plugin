---
name: prometheus-exporter
description: Design, scaffold, build, harden, and audit a production-grade Prometheus exporter written in Go. Use whenever the user wants to create a new Go Prometheus exporter from scratch, add a collector to one that already exists, harden its tooling, CI, or release pipeline, or audit an exporter for Prometheus conventions, cardinality risk, and production-readiness. Routes through the full lifecycle: architecture-first design, official Prometheus conventions via context7, scaffolding, per-collector development, hardening, release and observability, and a final audit.
---

This skill is the entry point for building a Go Prometheus exporter with
this plugin: an opinionated, end-to-end path from an architecture decision
to a releasable, documented, monitored repository. It is a router: the
reasoning behind each step lives in the reference files under `references/`;
open the one a step points to before acting on it, rather than trying to
hold all twelve in context at once.

**Scope**: Go exporters only. The I/O flavor is `http` (default) or `cli`:
the only two this plugin ships, ever; database targets are out of scope (see
`references/exporter-architecture.md`). A design-led business-dashboard
command (`/prometheus-exporter:generate-dashboard`) complements this
workflow at step 5, noted below where relevant.

## When this applies

- Creating a new Prometheus exporter from scratch, whatever it monitors: an
  HTTP API or a CLI tool. (A database-only target is out of scope; see
  `references/exporter-architecture.md`.)
- Adding a collector (a new resource or metric) to an exporter this skill
  previously scaffolded.
- Hardening an existing exporter's tooling, CI, or release pipeline before a
  release.
- Auditing an exporter for Prometheus conventions, cardinality risk, or
  general production-readiness.

## Workflow

### 0. Architecture design first (API-first)

Before any code: choose the data source in order of preference: REST/API
first, then gRPC, then CLI only as a last resort when no API exists (a
database-only target is out of scope for this plugin, see
`references/exporter-architecture.md`), using context7 to confirm the
target's actual endpoints and payload shapes rather than guessing. Discovery
can also be grounded in a local API spec (OpenAPI/Swagger/ `.proto`) or a
docs folder/URL, in preference order; `/prometheus-exporter:design-exporter
<target>` runs this phase and writes an architecture brief
`/prometheus-exporter:new-prometheus-exporter` can consume. Decide the
target model, which is one of three: `single` (the default, one fixed
target), `multi` (Prometheus picks the target per scrape via
`/probe?target=`, the Blackbox pattern), or `multi-instance` (a fixed list
of machines polled in the background and served through one `/metrics`). All
three are scaffolded, opt-in, via `--target-model`; both multi models
require the http flavor, there is no cli multi-target. When a session
reaches this step without `/prometheus-exporter:design-exporter` (which asks
these questions on its own), ask them here rather than assuming: which of
the three, and, if the answer is `multi`, one follow-up, "how do your
targets authenticate?", with three answers: (a) all the same, or not at all,
so one `http_client_config:` covers every target; (b) by group, so one
module per group carries its own credentials and the scrape config names one
with `&module=`; (c) credentials and collector subsets vary independently,
so credentials-only modules combine with collector modules in one request.
The generated code is identical in all three cases; the answer only decides
which commented block of `config.example.yml` the exporter's author should
uncomment, so record it with the rest of the architecture decisions.
Decompose the target into one collector per resource, and set a cardinality
budget (which labels, how many series, what flags will cap them) before
writing a line of code. For any collector whose backend is slow or expensive
enough that a scrape should never wait on it, flag it now for
`/prometheus-exporter:add-collector --variant background` later. See
`references/exporter-architecture.md`. Output: the I/O flavor (`http`, the
default, or `cli`) and the ordered collector list step 3 works through.

→ `references/exporter-architecture.md` → `references/discovery-inputs.md`

### 1. context7-first for Prometheus conventions

Before writing anything Prometheus-facing, confirm naming, types, labels,
and OpenMetrics behavior against the current `prometheus.io` documentation
via context7, never from memory, which drifts as conventions evolve. This
covers metric naming (`namespace_subsystem_unit`, with `_total`/`_seconds`/
`_bytes` suffixes), Gauge/Counter/Histogram selection, low-cardinality
labels, and self-instrumentation (`_exporter_*`).

→ `references/prometheus-principles.md`

### 2. Scaffold

With the architecture decided, scaffold the repository:
`/prometheus-exporter:new-prometheus-exporter <name>`, passing the flavor
and collector list from step 0 and a license choice (Apache-2.0 by default).
This produces a buildable, tested, git-initialized repository in one shot,
never hand-roll the layout it would otherwise produce.

→ `references/project-scaffold.md`

### 3. Per-collector loop

Add each collector still unticked under the journal's `## Collectors` in
`docs/exporter-journal.md`, or, in a repository predating it, from the step
0 list, one at a time with `/prometheus-exporter:add-collector <name>`: a
`Data`/fetch piece that does I/O and nothing else, a pure `Parse` function
that does no I/O, and the full test triad (parser, `_Collect`, `_Describe`,
`_ErrorHandling`) before `Collect` is wired into the registry. A collector
states its own outcome through `CollectWithOutcome(ch) error`, so a scrape
that legitimately found nothing to report returns `nil` and is a success, and
one that fails after emitting part of its series returns the error and is a
failure with those metrics still forwarded. Every command
in this workflow reads `docs/exporter-journal.md` on entry and completes it
on exit, so the remaining list, the cardinality budget and the shared label
vocabulary live on disk rather than in the context window: `/clear` between
two collectors is the recommended move, not a destructive one.

→ `references/collector-pattern.md`, `references/project-journal.md`

### 4. Harden

All dev tooling (build, test, lint, vulnerability scanning) runs in a
container by default, with a documented native fallback for contributors
without a container engine. Two gates must be green before moving on: `make
check` (vet, lint, tests, vulnerability scan) and `make docs-check` (checks
`docs/metrics.md` against the actually-registered descriptors, so the docs
can't drift from the code).

→ `references/makefile-and-tooling.md`, `references/docs-and-governance.md`

### 5. Release, docs, and observability

Wire the release and observability layer: GoReleaser drives host-agnostic,
local-capable releases (SemVer tags, a CHANGELOG, an SBOM, cosign signing),
with the GitHub Actions layer as an explicit opt-out rather than a
requirement. Confirm the generated `CONTRIBUTING.md`'s Definition of Done is
actually met. Ship `monitoring/` with Prometheus health alerts, recording
rules, and a health Grafana dashboard; generate business dashboards from
`docs/metrics.md` with `/prometheus-exporter:generate-dashboard` once your
collectors are in place.

→ `references/cicd-and-release.md`, `references/packaging-and-ops.md`,
`references/dashboards-and-alerts.md`,
`references/security-and-hardening.md`

### 6. Audit

Always dispatch the `exporter-reviewer` subagent: it is self-sufficient and
covers the exporter-specific delta: Definition of Done, Prometheus
conventions, the collector pattern, cardinality, secrets in metrics, and
docs/alerts lockstep. If `/code-review` or the `pr-review-toolkit` plugin
happen to be installed, dispatch them too, in parallel, for generic code
review. Treat both as an optional enhancement this workflow benefits from,
never a dependency it requires.

## Checklist

- [ ] **0. Architecture**: source chosen (REST/API, gRPC, or CLI as last
      resort; database is out of scope), target model decided (`single`,
      `multi`, or `multi-instance`), collector list drafted, cardinality
      budget set.
- [ ] **1. Conventions**: naming/types/labels/OpenMetrics confirmed
      against `prometheus.io` via context7.
- [ ] **2. Scaffold**: `/prometheus-exporter:new-prometheus-exporter <name>`
  run; repository
      builds and passes its own gate.
- [ ] **3. Collectors**: `/prometheus-exporter:add-collector <name>` run
  once per collector left
      unticked under the journal's `## Collectors` in
      `docs/exporter-journal.md`, or, in a repository predating it, in the
      step 0 list; test triad green each time, `/clear` safe between two.
- [ ] **4. Harden**: `make check` green; `make docs-check` green.
- [ ] **5. Release & observability**: GoReleaser configured; Definition of
      Done met; `monitoring/` (health alerts + dashboard) in place.
- [ ] **6. Audit**: `exporter-reviewer` dispatched; `/code-review` /
      `pr-review-toolkit` dispatched too if present.

## Cross-cutting principles

### The [G]/[S] discipline

Separate two kinds of content in every collector, and in every piece of
guidance this skill gives. **[G]eneric** is whatever holds for any exporter
regardless of what it monitors: the collector shape, the registry pattern,
the Makefile targets, the test triad. **[S]pecific** is whatever is unique
to this one exporter: its data source, its metric prefix, its parsing
format, its endpoint paths. Keep [S] confined to a collector's own body and
its configuration; never let it leak into the shared, generic pattern. When
unsure whether something belongs in a `Parse` function or in shared
infrastructure, this is the question to ask.

### context7-first

Anything version-sensitive or spec-defined (a target's actual API surface,
Prometheus's current naming rules, a tool's current CLI flags) gets checked
against up-to-date documentation via context7 before code is written or a
claim is made, never assumed from memory. This applies at step 0 (the best
available grounding for the target's API: a local spec, its docs, or
context7) and step 1 (Prometheus's own conventions) every time, not just
once at project start.

## Reference index

All twelve reference files live under `references/`, alongside the templates
they document:

| Reference | Covers |
|---|---|
| `exporter-architecture.md` | Step 0: source order, the three target models (single/multi/multi-instance), collector decomposition, cardinality budget |
| `discovery-inputs.md` | Step 0: discovery input taxonomy, preference order, the degradation ladder, per-source extraction, the brief's `## Provenance` and `## Open questions / assumptions` |
| `project-journal.md` | Steps 0, 2, 3, 5: the journal that survives a cleared context, its format and lifecycle, section ownership, reconciliation against disk, the resumption block |
| `prometheus-principles.md` | Step 1: naming, types, labels, OpenMetrics, self-instrumentation |
| `collector-pattern.md` | Step 3: the mockable I/O boundary, the five-piece collector shape, the test triad |
| `project-scaffold.md` | Step 2: repository layout, registry wiring, flags, endpoints, signal-aware shutdown |
| `makefile-and-tooling.md` | Step 4: container-first tooling, engine detection, native fallback, target list |
| `cicd-and-release.md` | Step 5: universal versioning, GoReleaser, the opt-out GitHub layer |
| `packaging-and-ops.md` | Step 5: Dockerfile variants, hardened compose, systemd |
| `security-and-hardening.md` | Step 5: no secrets in metrics, conservative defaults, optional hardening |
| `dashboards-and-alerts.md` | Step 5: health and business alerting, recording rules, the health dashboard |
| `docs-and-governance.md` | Step 4: docs kept in lockstep with the code, `make docs-check`, the Definition of Done |
