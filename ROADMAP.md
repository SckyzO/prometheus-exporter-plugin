# Roadmap

Product milestones for the `prometheus-exporter` plugin. For the day-to-day
implementation backlog, see [`TODO.md`](TODO.md) and the implementation plan
it points to.

## v0.1: MVP (released)

- The `prometheus-exporter` skill, including the architecture-first design
  phase that runs before any scaffolding.
- `/new-prometheus-exporter`: scaffolds a complete exporter repository.
- `/add-collector`: adds a collector plus its full test triad to an
  existing exporter.
- `exporter-reviewer`: the exporter-specific audit subagent.
- Two I/O flavors: **HTTP** (default) and **CLI**.
- `monitoring/` shipped with every scaffolded exporter: health alerting
  rules for Prometheus plus a health dashboard for Grafana.
- `make docs-check`: metrics documentation is validated against the code,
  not just asserted.
- A scaffolded repository builds and gates clean out of the box: `make
  build` and `make check` both pass.
- This plugin's own CI, plus a golden smoke test that scaffolds a
  throwaway exporter and proves it builds.

## v0.2 (released)

- **Discovery inputs for the architecture phase.** Step 0 grounding is
  broadened from context7 alone to a preference-ordered ladder — a local API
  spec (OpenAPI/Swagger, gRPC `.proto`), a docs folder or URL to analyze, then
  context7, degrading gracefully to dialogue when a rung is unavailable —
  fronted by the `/design-exporter` command, which emits an architecture
  brief `/new-prometheus-exporter` can consume. This strengthens
  needs-framing for exporters of internal or proprietary programs, whose docs
  context7 will not have.
- `/generate-dashboard`: a design-led command that generates 1..N business
  Grafana dashboards from a scaffolded repo's own `docs/metrics.md`, on top
  of a deterministic, golden-tested backbone that emits exportable Grafana
  JSON (one panel per documented metric, type-correct PromQL, deterministic
  `<namespace>-<slug>` uids). Complements the generic health dashboard
  shipped in v0.1; never modifies it. `context7` and the `dataviz` skill
  enrich it when present, never required.
- **Background-refresh collector variant**: `/add-collector --variant
  background` scaffolds a collector that refreshes its cache on a fixed
  interval in a background goroutine instead of on the scrape's critical
  path, so a slow or expensive backend (the driving case: a legacy device
  with a seconds-per-call interface) never blocks a scrape. The
  architecture-design phase now proactively asks whether any collector needs
  this. The lazy TTL-cache variant (refetch inline when stale, no
  goroutine — a legitimate, simpler pattern that does not give the same
  "scrape never blocks" guarantee) remains a fast-follow, not built here.

## v0.3 (released)

- **Live-target probe (discovery ladder rung 4)**: `/design-exporter` can
  now ground a design by probing a *running* instance of the target — an
  HTTP `GET` against its description surface (`/openapi.json`, `/metrics`,
  …) or a CLI `--help`/`--version`/sample invocation. Opt-in and
  consent-gated (the exact command is shown and confirmed before running);
  every capture passes through a deterministic secret-redaction backbone
  before any of it reaches the brief. It supplements the discovery walk —
  confirming and filling gaps in the higher rungs, surfacing contradictions
  as open questions — and the default walk (local spec > docs > context7 >
  dialogue) is unchanged when no live instance is offered.
- **Multi-target scaffolding** (`--target-model multi`, http flavor only):
  `/new-prometheus-exporter --target-model multi` scaffolds a
  `/probe?target=…` exporter, a fresh registry and collector set built per
  request, scoped to the target, alongside `internal/probe/`'s always-on
  http/https floor and an opt-in `--probe.target-allowlist` hardening flag.
  `--target-model single` (still the default) is unchanged. The probe seam
  holds an ordered slice of named collectors rather than exactly one, each
  probe runs under a real deadline (`--probe.timeout`,
  `--probe.timeout-offset`), and `--probe.module` selects a subset of
  collectors per probe, mirroring Blackbox/SNMP's probe-profile selection.
  Both remaining follow-ups from the first cut are now delivered:
  `/add-collector` works on a multi-target scaffold (it migrates an older
  scaffold's seam first when needed, then appends a factory), and the
  `module` query parameter is live. They decoupled cleanly, because modules
  are runtime flags naming collectors, so adding a collector can never
  invalidate one.

## v0.4 (released)

- **Optional YAML configuration file** (`--config.file`): a `flags:` section
  addressable by any flag the binary declares, and an `http_client_config:`
  section for the authentication and TLS no flag surface can express,
  honored by the HTTP flavor only (the CLI flavor refuses to start if it is
  set, since it has nothing to authenticate against). Absent
  `--config.file`, a scaffolded exporter behaves exactly as before: no
  default moves and no existing scaffold changes. Prerequisite for v0.5's
  `multi-instance` target model, which cannot express N instances with
  per-instance credentials through a kingpin flag surface. The instance list
  (`instances:`) and the multi-instance target model itself are v0.5, not
  this release.

## v0.5

- **A third target model, `multi-instance`, delivered.** Single-target
  watches one instance fixed at scaffold time; multi-target takes its
  instance per request on `/probe`. Neither fits a target whose data is only
  worth refreshing every fifteen minutes or once a night: Prometheus only
  keeps a sample queryable for a staleness window that defaults to five
  minutes, so slowing down `scrape_interval` just makes the series flicker
  in and out of existence instead of settling anything, and `/probe` cannot
  host a background poller because a poller needs its target at startup, not
  per request. Multi-instance is the fix: one process watches a list of
  instances declared in the configuration file (`instances:`), each polled
  in the background on its own schedule and re-served from a cache on every
  scrape, so the scrape itself stays fast no matter how slow the underlying
  fetch is. This isn't specific to tape libraries or any one slow device;
  the same argument applies to any application API, batch job, or nightly
  inventory that can't be scraped live.
- Delivered as part of this: the `instances:` list, per-instance labels,
  module-based credential and TLS selection (`modules:`, building on v0.4's
  configuration file), a fixed identifying label applied to every instance's
  series (default `target`, set once at scaffold time via
  `scaffold.sh --instance-label`), and fail-fast validation at boot (unique
  instance names, valid addresses, resolvable modules, no label collisions).
- **Sequenced follow-up: per-target credentials for `multi` (volet A).** The
  `multi` (`?target=`) model still authenticates every target through one
  shared `http_client_config:`, so it cannot probe two targets that
  authenticate differently. It gains per-request module selection
  (`/probe?target=...&module=...`), the same thing multi-instance already
  does per instance, with one rule settling the collision between
  combinable modules and credentials: at most one selected module may carry
  credentials. That single mechanism expresses both the Blackbox convention
  (a module is a complete bundle) and the SNMP one (credentials and
  collector subsets as independent axes), so the developer picks a
  convention in the configuration file rather than in code. Designed in
  [`docs/design/2026-07-27-multi-target-module-credentials-design.md`](docs/design/2026-07-27-multi-target-module-credentials-design.md).
- Also not in this drop: per-instance flag overrides (not planned unless a
  real consumer needs one).

## v0.6

- **Reload on SIGHUP.** Deferred from v0.5: reloading the instance list into
  a running process, while its pollers are mid-flight, is a concurrency
  problem worth its own version. Per-module credentials inherit the same
  deferral, so a credential rotation currently needs a restart.
- **Retire `--probe.module`.** Deprecated in v0.5 in favour of the
  configuration file's `modules:` section, removed here under the two-phase
  rule.
- **A project journal that survives a cleared context.** Today only step 0
  hands anything durable to a later step: `/design-exporter` writes an
  architecture brief that `/new-prometheus-exporter` reads. Everything after
  that (which collectors are left to build, the cardinality budget, which
  ones need the background variant, the credential convention chosen) lives
  only in the conversation, so a compaction or a `/clear` between two
  collectors loses decisions that are already recorded on disk two metres
  away. Promote the brief into a journal every command reads on entry and
  appends to on exit, making each step resumable from a cold start and
  turning the file into the reference base for building a complete exporter.
  Sequenced after v0.5 because it reshapes the contract of all four commands
  at once and deserves its own design.
- **A migration harness for `/add-collector`.** That command is the only part
  of this plugin that writes into a repository somebody else already owns,
  and it is the only part with no gate at all. `golden-smoke`'s
  second-collector splice exercises the *append* path onto an already-current
  seam; no gate has ever executed a *migration* path. v0.5 found two defects
  of that exact class by hand, both of which would have rewritten four files
  in a user's repository and left it not building: a migration describing a
  six-argument call against a seam that had become seven, and a chain into
  wiring that referenced a configuration package the older repository does
  not contain. Both were invisible to every gate. The fix is a fixture
  repository per historical seam shape, run through the migration and then
  through `make build`. Until that exists, every seam change obliges a manual
  re-audit of every migration that points at it, which is a discipline, not a
  guarantee.
- **Teach `multi-instance` in the references.** The target model shipped in
  v0.5 but appears in none of the eleven reference documents and not in
  `SKILL.md`'s step 0 walkthrough, so a session that learns from
  `references/` alone still believes there are two target models. v0.5's
  per-module credentials work added it in two places as a side effect; the
  rest is an unpaid documentation debt from the model's own drop.
- Budget the combinatorial cost in the design rather than discovering it in
  flight. Three target models against two flavors and two collector variants
  multiply both `scaffold.sh` and the `golden-smoke` matrix, now six
  containerised cells. Decide up front which combinations are supported and
  which are refused fail-fast, the way `multi` and `multi-instance` already
  require `--flavor http`.

## v1.0

- Marketplace polish.
- A complete documentation set.

## Non-goals

- **Database monitoring.** This plugin does not scaffold a way to query a
  target's database directly, now or ever. The database engine itself is
  already well served by `postgres_exporter` / `mysqld_exporter`; arbitrary
  SQL-to-metrics is served by the config-driven `sql_exporter` (a YAML
  mapping from query to metric, no Go to write). This plugin exists for
  programs that have **no existing exporter**, reached through their HTTP
  API, gRPC, or CLI.
