# Roadmap

Product milestones for the `prometheus-exporter` plugin. For the day-to-day
implementation backlog, see [`TODO.md`](TODO.md) and the implementation plan
it points to.

## v0.1: MVP (released)

- The `prometheus-exporter` skill, including the architecture-first design
  phase that runs before any scaffolding.
- `/prometheus-exporter:new-prometheus-exporter`: scaffolds a complete
  exporter repository.
- `/prometheus-exporter:add-collector`: adds a collector plus its full test
  triad to an existing exporter.
- `exporter-reviewer`: the exporter-specific audit subagent.
- Two I/O flavors: **HTTP** (default) and **CLI**.
- `monitoring/` shipped with every scaffolded exporter: health alerting
  rules for Prometheus plus a health dashboard for Grafana.
- `make docs-check`: metrics documentation is validated against the code,
  not just asserted.
- A scaffolded repository builds and gates clean out of the box: `make
  build` and `make check` both pass.
- This plugin's own CI, plus a golden smoke test that scaffolds a throwaway
  exporter and proves it builds.

## v0.2 (released)

- **Discovery inputs for the architecture phase.** Step 0 grounding is
  broadened from context7 alone to a preference-ordered ladder — a local API
  spec (OpenAPI/Swagger, gRPC `.proto`), a docs folder or URL to analyze,
  then context7, degrading gracefully to dialogue when a rung is unavailable
  — fronted by the `/prometheus-exporter:design-exporter` command, which
  emits an architecture brief `/prometheus-exporter:new-prometheus-exporter`
  can consume. This strengthens needs-framing for exporters of internal or
  proprietary programs, whose docs context7 will not have.
- `/prometheus-exporter:generate-dashboard`: a design-led command that
  generates 1..N business Grafana dashboards from a scaffolded repo's own
  `docs/metrics.md`, on top of a deterministic, golden-tested backbone that
  emits exportable Grafana JSON (one panel per documented metric,
  type-correct PromQL, deterministic `<namespace>-<slug>` uids). Complements
  the generic health dashboard shipped in v0.1; never modifies it.
  `context7` and the `dataviz` skill enrich it when present, never required.
- **Background-refresh collector variant**:
  `/prometheus-exporter:add-collector --variant background` scaffolds a
  collector that refreshes its cache on a fixed interval in a background
  goroutine instead of on the scrape's critical path, so a slow or expensive
  backend (the driving case: a legacy device with a seconds-per-call
  interface) never blocks a scrape. The architecture-design phase now
  proactively asks whether any collector needs this. The lazy TTL-cache
  variant (refetch inline when stale, no goroutine — a legitimate, simpler
  pattern that does not give the same "scrape never blocks" guarantee)
  remains a fast-follow, not built here.

## v0.3 (released)

- **Live-target probe (discovery ladder rung 4)**:
  `/prometheus-exporter:design-exporter` can now ground a design by probing
  a *running* instance of the target — an HTTP `GET` against its description
  surface (`/openapi.json`, `/metrics`, …) or a CLI
  `--help`/`--version`/sample invocation. Opt-in and consent-gated (the
  exact command is shown and confirmed before running); every capture passes
  through a deterministic secret-redaction backbone before any of it reaches
  the brief. It supplements the discovery walk — confirming and filling gaps
  in the higher rungs, surfacing contradictions as open questions — and the
  default walk (local spec > docs > context7 > dialogue) is unchanged when
  no live instance is offered.
- **Multi-target scaffolding** (`--target-model multi`, http flavor only):
  `/prometheus-exporter:new-prometheus-exporter --target-model multi`
  scaffolds a `/probe?target=…` exporter, a fresh registry and collector set
  built per request, scoped to the target, alongside `internal/probe/`'s
  always-on http/https floor and an opt-in `--probe.target-allowlist`
  hardening flag. `--target-model single` (still the default) is unchanged.
  The probe seam holds an ordered slice of named collectors rather than
  exactly one, each probe runs under a real deadline (`--probe.timeout`,
  `--probe.timeout-offset`), and `--probe.module` selects a subset of
  collectors per probe, mirroring Blackbox/SNMP's probe-profile selection.
  Both remaining follow-ups from the first cut are now delivered:
  `/prometheus-exporter:add-collector` works on a multi-target scaffold (it
  migrates an older scaffold's seam first when needed, then appends a
  factory), and the `module` query parameter is live. They decoupled
  cleanly, because modules are runtime flags naming collectors, so adding a
  collector can never invalidate one.

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
  series (default `target`, set once at scaffold time via `scaffold.sh
  --instance-label`), and fail-fast validation at boot (unique instance
  names, valid addresses, resolvable modules, no label collisions).
- **Sequenced follow-up: per-target credentials for `multi` (volet A).** The
  `multi` (`?target=`) model still authenticates every target through one
  shared `http_client_config:`, so it cannot probe two targets that
  authenticate differently. It gains per-request module selection
  (`/probe?target=...&module=...`), the same thing multi-instance already
  does per instance, with one rule settling the collision between combinable
  modules and credentials: at most one selected module may carry
  credentials. That single mechanism expresses both the Blackbox convention
  (a module is a complete bundle) and the SNMP one (credentials and
  collector subsets as independent axes), so the developer picks a
  convention in the configuration file rather than in code. Designed in
  [`docs/design/2026-07-27-multi-target-module-credentials-design.md`](docs/design/2026-07-27-multi-target-module-credentials-design.md).
- Also not in this drop: per-instance flag overrides (not planned unless a
  real consumer needs one).

## v0.6

- **Retire `--probe.module`.** Deprecated in v0.5 in favour of the
  configuration file's `modules:` section, removed here under the two-phase
  rule.
- **No in-place migrations before 1.0** (decided, and already applied).
  `/prometheus-exporter:add-collector` used to rewrite an older repository's
  probe seam in place. That machinery is gone: the command now detects an
  outdated seam, refuses, and points at rescaffolding. Three things drove
  the decision. It was the only part of the plugin that writes into a
  repository somebody else owns and the only part with no gate at all, so
  v0.5 found two defects in it by hand, each of which would have rewritten
  four files and left the repository not building. It cost roughly 19k
  tokens on every `/prometheus-exporter:add-collector` invocation, more than
  any other component and about four times the skill router. And pre-1.0,
  with no released version yet carrying a user, it was maintained for
  nobody. After 1.0 the calculus inverts and migrations become an
  obligation; the harness that would make them testable (a fixture
  repository per historical seam shape, run through the migration and then
  through `make build`) is the prerequisite for reintroducing them.
- **Teach `multi-instance` in the references, delivered.** The target model
  shipped in v0.5 but was missing from nine of the eleven reference
  documents that existed then, and from `SKILL.md`'s step 0 walkthrough, so
  a session that learned from `references/` alone still believed there were
  two target models. v0.5's per-module credentials work had added it to the
  other two as a side effect; the rest was an unpaid documentation debt from
  the model's own drop, paid off across v0.6 and v0.7.
- Budget the combinatorial cost in the design rather than discovering it in
  flight. Three target models against two flavors and two collector variants
  multiply both `scaffold.sh` and the `golden-smoke` matrix, now six
  containerised cells. Decide up front which combinations are supported and
  which are refused fail-fast, the way `multi` and `multi-instance` already
  require `--flavor http`.

## v0.7

Configuration reload is the ecosystem's norm, not a nicety: both
`blackbox_exporter` and `snmp_exporter` reload on `SIGHUP` and on `POST
/-/reload`, apply the new configuration atomically, and keep the old one
when the new one fails to parse (verified against their current
documentation). Delivered here for `multi` and `multi-instance`, the two
target models that read `--config.file` more than once in a process's life:
`multi` resolves it per request, `multi-instance` through pollers that own
their own lifecycle.

The milestone's original justification named credential rotation as the gap:
"since v0.5 a single exporter can hold several credential sets, and rotating
one currently costs a restart." That turned out to be **false** for every
secret held in a `_file` variant. `prometheus/common` already re-reads
`password_file`, `bearer_token_file`, `authorization.credentials_file`,
`ca_file`, `cert_file` and `key_file` from disk on every outbound request,
with no reload involved, mirroring what `exporter-toolkit` already does for
`--web.config.file` on the inbound side. What a reload actually buys is the
SHAPE of the configuration: an instance or module added, removed,
re-addressed, re-labelled, or re-pointed at another module, plus a secret
written inline instead of through a `_file` variant.

- **Reload for `multi` and `multi-instance`.** `SIGHUP` (always active) and
  `POST /-/reload` (behind `--web.enable-lifecycle`, default off, which is
  Prometheus's own posture for a mutating endpoint and not
  `blackbox_exporter`'s or `snmp_exporter`'s, both of which expose theirs
  ungated) both re-read `--config.file`. Prepare-then-commit: everything
  that can fail, parsing, a changed `flags:` section, an unresolved module,
  an unreadable secret, runs before anything is mutated, so a bad file
  leaves the running configuration untouched and drives
  `..._exporter_config_last_reload_successful` to `0`. Two edits are refused
  outright rather than half-applied: a changed `flags:` section (rendered
  into command-line arguments exactly once, at startup, and impossible to
  re-apply without re-running that parse) and, on `multi-instance` only, a
  reload that would change the SET of label KEYS an instance carries (a
  Prometheus registry never releases a metric family's label-name dimension
  once registered, so re-registering one under a different key set panics;
  refused with a restart-required error instead of risking it).
- **A per-target concurrency ceiling**
  (`--exporter.max-requests-per-target`, `multi-instance` and `single`,
  opt-in, default unlimited): bounds how many requests this exporter has in
  flight against one watched machine at a time, so a slow collector's
  background poller cannot starve its siblings polling the same instance.
  Not offered on `multi`: it has no background pollers, and `/probe`'s
  `target=` is caller-controlled and unbounded, which rules out a
  pre-populated index.
- **One shared, swappable transport per watched machine** (`multi-instance`)
  or per module (`multi`), replacing a transport built fresh on every use.
  This is what makes both the reload and the ceiling above possible without
  a connection-pool explosion.

`single` is not part of this delivery: its file holds only a `flags:`
section (unreloadable by construction, above) and an `http_client_config:`
whose file-backed parts are already hot, per the corrected justification
above. The documentation points a `single` build at `password_file` and its
siblings instead of a reload.

## v0.8

- **A project journal that survives a cleared context, delivered.**
  Originally scoped into v0.7 alongside configuration reload; unrelated to
  it, so it moved out to its own design session rather than share this one.
  Until now only step 0 handed anything durable to a later step:
  `/prometheus-exporter:design-exporter` wrote an architecture brief that
  `/prometheus-exporter:new-prometheus-exporter` read. Everything after that
  (which collectors are left to build, the cardinality budget, which ones
  need the background variant, the credential convention chosen) lived only
  in the conversation, so a compaction or a `/clear` between two collectors
  lost decisions that were already recorded on disk two metres away. The
  brief is now promoted into `docs/exporter-journal.md`, which all four
  commands read on entry and complete on exit, so each step is resumable
  from a cold start and `/clear` between two collectors becomes the
  recommended move rather than a destructive one. Eight frozen sections with
  one owner each, and the disk deciding everything it can state about
  itself, so the journal carries only the half no file in the repository
  can. Delivered alongside it: a gitignored `samples/` for raw target
  output, a generated `CLAUDE.md`, and a collector block in the scaffolded
  `README.md` that `/prometheus-exporter:add-collector` regenerates from
  `docs/metrics.md`. It reshaped the contract of all four commands at once,
  which is why it got its own design in
  [`docs/design/2026-07-30-project-journal-design.md`](docs/design/2026-07-30-project-journal-design.md).
- **A child registry per watched instance, so every label change becomes
  reloadable.** v0.7 refuses a reload that changes the SET of label keys an
  instance carries, because a Prometheus registry never releases a metric
  family's label-name dimension once registered, so re-registering under a
  different key set panics. Giving each instance its own
  `prometheus.Registry`, aggregated for `/metrics` through
  `prometheus.Gatherers`, releases the dimension when a child is dropped and
  would turn that refusal back into a normal reload. Considered during v0.7
  and declined there: it reshapes how `/metrics` is assembled, which did not
  belong in a release already eight tasks deep, and it needs confirming that
  `Gatherers` tolerates differing label sets across children for one metric
  name. Refusing was the honest interim answer, not the intended end state.

## v0.9 (released 2026-08-04)

Four defect groups found by using the plugin to build a real exporter against
real hardware, plus the versioning question that use exposed.

- **The TLS/proxy gaps.** `insecure_skip_verify` documented as an accepted
  risk rather than a bare commented default, the SAN-less certificate trap
  named with the two reflexes that do not fix it (`ca_file`, `server_name`),
  and `proxy_url` made visible along with the fact that declaring an
  `http_client_config:` section silently stops `HTTP_PROXY` being honoured.
- **The name-vs-label procedure**, replacing an exception clause that had no
  test, plus a journal line so the arbitration is made once per exporter.
- **Status tags in the journal's open questions**, so the section stops
  asserting blockers that are already resolved.
- **`promtool-rules` in `make check`**, so a generated exporter can validate
  the alert rules it is told to uncomment and adapt.
- **Where a generated exporter's version starts**, and what the number does
  and does not promise.

## v0.10: what the first real deployment found

Everything below came from running a scaffolded exporter against real
hardware, and none of it is visible from the templates alone. The bugs and the
missing knowledge are tracked together because the first item is both.

**Bugs, verified against the current templates:**

- **A refresh succeeding and the data advancing are different claims.** The
  staleness alert v0.8 shipped reads the collector's own freshness gauge,
  which stays perfectly current while the source stops publishing and the data
  behind it freezes. A collector exposing a source-side timestamp needs two
  gauges, never one, and the staleness threshold is N missed publications
  **plus that collector's own interval**, not a constant copied between
  collectors. This is the next layer of the defect v0.8 fixed, and it gives
  false assurance on exactly the case it claims to cover.
- **`--version` and `--help` exit non-zero on a multi-instance build.**
  `config.Load` runs before `kingpin.Parse`, so a binary asked to describe
  itself refuses for want of a configuration file. Packaging, CI and container
  healthchecks all call `--version` on a binary they have no configuration
  for. The gate missed it because `golden-smoke.sh` always passes
  `--config.file`; closing the test hole is part of the fix.
- **The concurrency ceiling is unusable at 1**, which is the right value for a
  target that serializes internally. One deadline covered the queue wait and
  the request together, so a collector queued behind its siblings burned its
  whole budget waiting. Measured in the field: 14 of 19 collectors starved on
  every sweep, permanently, because same-interval tickers fire together and
  the alignment never breaks up.

  **Phase 1 is done** (http flavor): `Client.Fetch` acquires its slot before
  applying the request deadline, so the wait is bounded by `acquireTimeout`
  and the request gets its own full budget. That does not change the count.
  Measured on the same 19-collector sweep afterwards: 5 succeed and 14 still
  starve, because every constructor still sets `acquireTimeout` to the
  request timeout. What it changes is the failure: the 14 now fail on the
  wait, fast and named, instead of on a request they had no time to finish,
  which was indistinguishable from a slow target.

  **Phase 2 is what makes the ceiling serviceable**: let the wait budget be
  sized independently of the request budget, minutes against seconds, and
  decide whether its default should stop tracking the request timeout. That
  is a configuration-surface change and a default move, so it is its own
  release under the two-phase rule.
- **The CLI flavor shares one budget the same way the HTTP one did**, found
  while fixing the HTTP client and not by the field: `Execute` receives a
  `ctx` whose per-command deadline the caller has already applied, so the wait
  for a `CommandLimiter` slot is charged against the command's own budget. The
  HTTP fix does not transfer, because reordering is not available here: the
  deadline arrives already on `ctx`. Closing it means reading the remaining
  budget off `ctx.Deadline()` and re-arming two budgets from it, on a context
  stripped of that deadline but still cancelable by its parent, which the
  standard library does not express directly. Doable, not a reordering, and
  its own item.
- **The shipped systemd unit does not start a multi-instance build**: its
  `ExecStart` carries no `--config.file`, which that model requires.
- **Neither does the shipped container path**, found while fixing the unit
  above and not by the field: `docker-compose.yml`, `docker-compose.minimal.yml`
  and both Dockerfile `CMD`s pass `--web.listen-address` and nothing else, so
  `make docker-run` on a multi-instance build starts a container that exits
  immediately, and `restart: unless-stopped` makes that a permanent crash
  loop rather than a single visible failure. Bigger than the unit fix, and
  deliberately not folded into it: the file has to be mounted into the
  container as well as named on the command line, which is a compose change,
  not a flag.
- **The boot storm, and the lifecycle that blocks the obvious fix.** Every
  background collector fires its first refresh at once. Delaying `Start` is
  unsafe as the variant is written: `done` is created in the constructor and
  closed by `Start`'s goroutine, so a `Start` that never runs leaves `Done()`
  open and hangs shutdown.

  **Done**, in that order. The lifecycle first: `done` is now closed exactly
  once through a `sync.Once`, with the close armed before anything that can
  return early, and `Start` is idempotent. Then the spreading:
  `instance.StaggeredCollector`, an optional interface a collector may ignore,
  lets `Registry.Commit` tell each collector it is the `i`-th of `n` starting
  together, and the http background variant delays its first refresh by `i/n`
  of its own interval. Deterministic, not randomized, so the pattern is
  reproducible across restarts and testable by value.

  Not staggered: single-target builds, whose background collectors are wired
  one at a time by `/prometheus-exporter:add-collector` with no `n` available
  at the call site, and the cli flavor, which has no multi-instance model to
  start `n` collectors in one pass.

**Knowledge the templates never taught, each found by meeting it:**

- A documented state table is a floor, not a ceiling: emit an observed state
  that is not in the list as its own series, with a warning naming the field,
  rather than leaving every documented series at `0` and making the device
  look stateless.
- Derive a cardinality budget from the unit the source's own counter counts,
  not from the one the endpoint appears to return.
- Summing a device counter across a population that can shrink reads as a
  counter reset when it does; say so in the help text.
- A source counter that saturates (a value at its type's ceiling, repeatedly)
  is a floor, not a measurement, and it changes what an averaging rule means.

## v0.11

- **A Prometheus alerting command, the counterpart to
  `/prometheus-exporter:generate-dashboard`.**
  `/prometheus-exporter:add-collector` already proposes one business alert
  per collector, at the moment it has the most context: it has just written
  the metric and knows whether it has a natural "too high" or "too low"
  direction. Three things it cannot do by construction, because it only ever
  looks at one collector: propose **cross-collector** alerts (the exporter
  answers but every collector is failing; a business SLO spanning three
  resources); review the **coherence** of the whole set, since fifteen
  collectors added across fifteen sessions produce fifteen independently
  chosen thresholds, divergent `for:` durations, an inconsistent severity
  ladder, and rules still referencing metrics that no longer exist (the
  alerting equivalent of `docs-check`, which does not exist); and feed
  `monitoring/prometheus/rules.yml`, which every scaffold ships and
  **nothing ever writes to**. That last one is the sharpest: a scaffolding
  plugin is only as trustworthy as the fraction of its templates that are
  actually exercised. Deliberately scheduled after the project journal, not
  before: like `/prometheus-exporter:generate-dashboard` reading
  `docs/metrics.md`, this command should read the journal's `Business-alert
  candidates` and `Cardinality budget` sections instead of asking cold.
  Moved from v0.9 to make room for what the first real deployment found; the
  reasoning is unchanged.

## Ongoing: widening the reference base to the official exporters

Everything this plugin teaches was originally derived from a single reference
exporter. That basis is being widened to the ecosystem's official ones, which
have a decade of production behind them: `node_exporter`, `blackbox_exporter`,
`snmp_exporter` and `ipmi_exporter`.

This is not a version. It runs alongside the numbered milestones and lands one
verdict at a time.
`docs/design/2026-08-01-official-exporter-gap-report.md` holds the comparison:
25 entries, 10 adopted, 11 rejected, 4 already covered, each sourced to a file
and a line on both sides. `docs/design/re-sync.md` §1 now distinguishes the
**origin** reference, whose files were copied, from the **corroborating** ones,
which are read and compared but never copied, and §8 is the register of
verdicts.

A rejected verdict is a result, not a gap left open: five became numbered
deliberate deviations in `re-sync.md` §4, two of which are places where this
plugin is deliberately stricter than the majority of the references
(`/-/reload` gated behind `--web.enable-lifecycle`, and no `net/http/pprof` on
the exporter port).

The largest adopted verdict, replacing `StatusTracker`'s count-based outcome
inference with an outcome the collector declares, has its own design at
`docs/design/2026-08-01-collector-outcome-seam-design.md` and falls under the
two-phase rule.

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
