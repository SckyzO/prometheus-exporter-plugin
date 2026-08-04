# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-08-04

### Added

- **A collector states its own scrape outcome.** `OutcomeCollector`, in
  `internal/collector/status_tracker.go`, adds
  `CollectWithOutcome(ch) error` beside `prometheus.Collector`. Returning
  `nil` is a success even with zero metrics emitted; returning an error is a
  failure even when metrics are already on the channel, and those metrics are
  still forwarded.

  `StatusTracker` used to infer the outcome from how many metrics a collector
  emitted. That proxy was wrong in both directions. A scrape that legitimately
  found nothing to report was reported as failed and paged on a healthy
  exporter. Worse, a collector that emitted part of its series and then failed
  was reported as healthy, because the count was non-zero, which is the
  direction that hides breakage; the always-emit-at-least-one rule this
  project taught made that case more likely rather than less.

  **Nothing already scaffolded changes.** A collector that does not implement
  the interface keeps the count rule, unchanged, with no edit. That fallback
  is covered by its own regression test, because it is the whole promise of
  this first phase. Removing it is a later, separate release.

  Two collectors are deliberately left on the fallback: `RequestDuration` and
  `CommandDuration` are `*prometheus.HistogramVec` values from
  `client_golang`, which cannot implement a new interface. They keep the count
  rule.

  The shipped example collectors and both background variants move to the new
  shape and carry `var _ OutcomeCollector = (*ExampleCollector)(nil)`. That
  assertion is load-bearing: without it a typo in the method signature
  compiles and the collector silently falls back to the count rule, looking
  converted without being it.

- **A staleness alert example, for background-variant collectors.** A
  background collector serves a cache and always emits at least its freshness
  gauge, so it reports `collector_success 1` by construction, even when its
  refresh has been failing for hours. `ExporterCollectorFailing` can never fire
  for it, and a whole fleet can read green on data that stopped moving. The
  new commented rule alerts on the freshness gauge's value instead, which is
  the only signal that catches this. Commented for the same reason as the
  business alert beside it: the metric name carries the collector's own name,
  so there is no generic form.

- **`@@EXPORTER_NAME@@_build_info`, the exporter's own release, on
  `/metrics`.** Registered through `client_golang`'s versioncollector, it
  carries the version, revision and branch the build injects into
  `prometheus/common/version`, which is the same package `--version` already
  prints. This is the metric that answers "which build is actually running",
  and every official Prometheus exporter exposes it. `go_build_info` stays
  alongside it and is not a substitute: it carries Go module metadata and
  reports `(devel)` for a plain local `go build`. Neither is affected by
  `--web.disable-exporter-metrics`.
- **`promhttp_metric_handler_requests_total` and
  `..._requests_in_flight`**, from wrapping the `/metrics` handler in
  `promhttp.InstrumentMetricHandler`. Without them, a Prometheus
  double-scrape or a scrape that consistently errors is invisible from the
  exporter's own side. They describe the act of serving `/metrics` rather
  than anything about the target, which is why they are registered
  unconditionally.
- **A startup warning when the exporter runs as root.** An exporter reads a
  data source and serves numbers and needs privilege for neither; running as
  root turns any parsing bug, or any command the CLI flavor spawns, into a
  root-level one. Visible, non-fatal, and it changes no default, the same
  posture as the existing exposed-and-unauthenticated warning. The packaged
  systemd unit already runs under a dedicated user, so this exists for the
  deployments that do not use it.

- **`make check` validates the alert rules a generated exporter ships.** A new
  `promtool-rules` target loads every `monitoring/prometheus/*.yml` the way
  Prometheus does (`rulefmt.ParseFile`), so annotation templates are checked
  too, not only expressions: a file whose rules all parse individually can
  still be rejected whole, leaving every alert in it dead. It resolves
  promtool itself, preferring a digest-pinned `prom/prometheus` image and
  falling back to a host binary, because promtool cannot be added to the tools
  image (`prometheus/prometheus` declares `replace` directives, which
  `go install pkg@version` refuses). It fails rather than skipping when
  neither is available, so **`make check` now needs a container engine with
  registry access, or promtool on `PATH`**.

- **A procedure for deciding a separate metric name against a label value.**
  `/prometheus-exporter:add-collector` kept re-asking whether a dimension
  becomes `<metric>_read` or `<metric>{stat="read"}`. Three steps now: the
  official `sum()`/`avg()` rule of thumb, kept as the hedged heuristic it is;
  the cases the guidance settles outright (read/write and send/receive to
  separate names, tabular data to one label, mixed units always split); and,
  for anything left, what an official exporter in the same domain does.
  `/prometheus-exporter:design-exporter` runs it once per exporter and records
  the outcome on a new `Name-vs-label arbitrations:` line in the journal, so
  later collectors inherit the answer instead of re-litigating it differently.

- **Status tags for the journal's `## Open questions / assumptions`.** That
  section is mutable, appended to by all four commands, and had nothing ever
  taken out of it, so it accumulated resolved questions and session notes
  alongside live ones and started asserting blockers that no longer existed.
  Entries now carry `[OPEN]`, `[RESOLVED]` or `[ACCEPTED]` with an index line,
  so `grep "\[OPEN\]"` answers "what is left". No second file, no ninth
  section header, and an untagged journal is not corrupt: entries are tagged
  as they are touched.

- **Where a generated exporter's version starts, and what the number
  promises.** The scaffold taught SemVer and `v*` tags without ever answering
  `v0.1.0` or `v1.0.0`. Start at `v0.1.0`. What breaks an operator is a metric
  name, type or label key changing, since that is what their dashboards select
  on; the protection is a marked entry plus a deprecation period, not the
  major number. The ecosystem's own practice is taught rather than a stricter
  rule invented on top of it: `node_exporter` has been past 1.0 since 2020,
  has never cut a 2.0.0, and still removes metrics in minor releases behind a
  deprecation cycle.

### Changed

- **The validation checklist no longer accepts `collector_success 1` as proof
  that a background-variant collector is healthy.** It cannot be: such a
  collector is healthy at zero data by construction. The step now sends the
  reader to the freshness gauge's value, and says plainly that this is a real
  failure mode rather than a theoretical one.
- **`StatusTracker` now owns the log policy for every collector.** It logged
  panics and nothing else, so an operator seeing `collector_success 0` had no
  corresponding line to grep, and `--log.level=debug` yielded no per-collector
  timing. Three outcomes now: silent on the panic path, which the recover
  already reported with the panic value; `Error` on a collector that emitted
  nothing; `Debug` with the duration on success.
- **The security reference forbids passing a credential on a command line.**
  Rule 1 covered secrets in metric values, labels and help strings, and named
  the `Execute` call site, but only to forbid *reporting* a credential back
  through a label, never to forbid *passing* one as an argument. A process's
  command line is world-readable through `/proc/<pid>/cmdline`, so `ps`
  exposes it to every account on the host: the same disclosure the metric
  rules prevent, through a channel they did not cover. Three alternatives are
  given in order of preference, and the `Execute` doc comment points at them
  from the call site. The shipped CLI template was and remains safe by
  construction, with a fixed command and no arguments.

- **`insecure_skip_verify` is documented as an accepted risk, and `proxy_url`
  is no longer invisible.** A target certificate with no `subjectAltName`
  cannot be verified by any Go client since Go 1.15 dropped the Common Name
  fallback, and neither `ca_file` nor `server_name` addresses it: the trust
  chain was never the problem, the missing name is. Verified rather than
  asserted, against a generated SAN-less certificate: `curl` with `--cacert`
  and **no** `-k` returns 200 where Go fails, so the operator running the
  rigorous curl test is misled too. The real fix is on the target, by
  reissuing with a SAN. `http_client_config:` is a `prometheus/common`
  `HTTPClientConfig`, so `proxy_url` already worked and was merely undocumented.
  **Worth knowing even if you use no proxy**: with no `http_client_config:`
  section an exporter uses Go's default transport and honours
  `HTTP_PROXY`/`HTTPS_PROXY`; declaring that section for any reason, including
  `basic_auth` alone, replaces the transport and those variables stop being
  read, with no error.

### Fixed

- **Two shipped references contradicted each other about build info.**
  `project-scaffold.md` promised `@@EXPORTER_NAME@@_build_info`, which nothing
  emitted, while `dashboards-and-alerts.md` correctly named `go_build_info`.
  `make docs-check` sees neither file, so nothing could have caught it.
  Registering the metric makes the first true rather than requiring a
  retraction, and the dashboard reference now recommends the one that answers
  the question. Both `metrics.md` templates also claimed build info was
  disabled by `--web.disable-exporter-metrics`; it is registered outside that
  guard and always was.

## [0.8.1] - 2026-08-01

### Added

- **Every generated exporter's test suite now runs under
  `go.uber.org/goleak`.** A generated exporter starts goroutines that have to
  stop on their own: one poller per watched instance on multi-instance, a
  background-variant collector's refresh loop, `StatusTracker`'s reset
  goroutine, the detached drain a reload starts when an instance is removed,
  and the SIGHUP handler. Nothing verified that any of them exited.

  The gap is invisible to an ordinary assertion, which is what makes it worth
  closing: the test that spawned the goroutine has already passed by the time
  the goroutine fails to exit. The likeliest way to introduce one is
  `/prometheus-exporter:add-collector` adding a `--variant background`
  collector whose loop drops `ctx.Done()`, in a repository whose owner never
  touches this plugin again.

  `go.uber.org/goleak` moves from an indirect dependency already pinned in
  `go.sum` to a direct one. It is test-only: no new module enters the graph
  and nothing ships in the binary. What it found, stated plainly: nothing.
  goleak passes on all three packages as they stand, so the concurrency
  design holds. The value is the regression lock, not a bug fixed.

- **The golden matrix covers `/prometheus-exporter:add-collector` on the
  `cli` flavor**, closing a follow-up the `http` block's own header opened
  and never closed, which left the cli splice exercised by nothing. It is a
  separate block rather than a flavor-parameterised version of the http one,
  because the two splices genuinely differ: cli touches two markers, not
  three.

  It carries two guards the http block does not have, both for failures
  `make build` cannot see. An assertion on a leftover `@@VAR@@`, which
  compiles fine inside a string literal and only surfaces later as a nonsense
  metric name. And a guard on the self-instrumentation filter itself: if
  `registry.frag` ever renames `command_exec` or `command_exec_wait`, the
  greps stop filtering in silence and a duplicate kingpin long flag ships, in
  a binary that builds clean and dies on its first run.

### Fixed

- **Every command in this plugin's documentation was named without its
  plugin namespace.** Claude Code invokes a plugin's slash commands as
  `/prometheus-exporter:add-collector`, never `/add-collector`; the bare
  form does not resolve, and there is no fallback to it. All 243 mentions
  across the references, the commands, the skill, the agent, the README,
  `docs/`, the scaffold templates and this file carried the bare form.

  The reach is what made this worse than a typo. Twenty-one mentions sat in
  documentation a reader copies from. Fifty more sat in `CHANGELOG.md`,
  `ROADMAP.md`, `TODO.md` and `SECURITY.md`. A hundred and forty-two sat in
  taught content, which a model reads and then relays to the user in its own
  prose, so the plugin was teaching an instruction that fails. The last
  twenty-seven ship inside every generated exporter, telling a third party's
  contributors to run something that does not exist for them either.

  No gate could have caught it: `claude plugin validate` checks the
  manifest, not invocations quoted in prose, and the golden matrix tests the
  scaffold, not what the documentation claims.

- **Two claims about the project journal in the 0.8.0 entry above.** "All
  four commands read it on entry" is false for two of them:
  `/prometheus-exporter:new-prometheus-exporter` has no journal to read on
  entry, and `/prometheus-exporter:design-exporter` runs before any
  repository exists. "Eight frozen section headers with one owner each"
  holds for the section-ownership table's *Created by* column only; two
  sections are completed by all four commands and one by none. Both errors
  were found by fact-checking the README against the code, corrected there,
  and left standing in the file the README had been written from.

### Changed

- **The taught-source leak gate checks a denylist rather than one word**,
  and no longer excludes `docs/` wholesale, now that `docs/` holds
  user-facing documentation as well as design history. Public exporter names
  are explicitly barred from that denylist: they are cited on purpose as
  ecosystem precedent, and denylisting one would fail the build on a correct
  citation.
- **`README.md` is a front page again**, down from 339 lines to 94, with the
  reference material moved to `docs/`. `docs/install.md` documents something
  no version of the README did: how to get back off a version pin, which
  otherwise leaves `/plugin` reporting a long-superseded release as the
  latest available.

## [0.8.0] - 2026-07-31

### Added

- **A project journal, `docs/exporter-journal.md`, in every scaffolded
  exporter.** It carries a build across several sessions, so one survives a
  compaction or a cleared context. `/prometheus-exporter:design-exporter`
  opens it as the architecture brief, in the working directory, before any
  repository exists; `/prometheus-exporter:new-prometheus-exporter` brings
  it into the repository in the initial commit and completes the decisions
  the scaffold settled; and `/prometheus-exporter:add-collector` and
  `/prometheus-exporter:generate-dashboard`, the two with a journal already
  on disk to find, each read it on entry and complete it on exit, the first
  ticking collectors off the plan and recording the cardinality it actually
  observed, the second recording each dashboard's audience and method. Eight
  frozen section headers, each created by exactly one command, and the disk
  deciding everything it can state about itself: the journal carries only
  the half no file in the repository can, such as the collectors still to
  build, the cardinality budget as an intention, the credential convention
  and the shared label vocabulary. Every command reconciles the journal
  against the repository on entry and reports each correction rather than
  trusting a stale claim. On a repository that has none,
  `/prometheus-exporter:add-collector` and
  `/prometheus-exporter:generate-dashboard` do exactly what they did before
  this release, all the way through, and only then offer to build one: from
  scratch when the file is absent, behind a `.bak` when its headers are
  damaged, and nothing is written before the user answers. Exporters
  scaffolded before this release keep working, and no migration of any kind
  is involved.
- **`samples/` in every scaffolded exporter**: a gitignored home for raw
  target output and the target's own API documentation, deliberately
  separate from `internal/collector/testdata/`, which stays trimmed,
  anonymized and committed. `/prometheus-exporter:add-collector` derives a
  fixture from it when it covers the collector's endpoint or command,
  instead of inventing one, and leaves the original in place for the next
  collector. `/prometheus-exporter:new-prometheus-exporter` offers to copy
  in whatever source material the brief recorded. Only `samples/README.md`
  is tracked.
- **`CLAUDE.md` in every scaffolded exporter**, stating the repository's
  invariants and where each kind of state lives, so a session that opens the
  generated repository cold learns its rules from the repository rather than
  from this plugin.
- **A generated collector block in the scaffolded `README.md`**, between
  `<!-- BEGIN GENERATED COLLECTORS -->` and `<!-- END GENERATED COLLECTORS
  -->`, regenerated in full from `docs/metrics.md` by
  `/prometheus-exporter:add-collector` so the front page lists every
  collector the exporter actually has.
- **`@@TARGET_MODEL@@` and `@@FLAVOR@@` substitutions in `scaffold.sh`**,
  derived from the selectors it already parses and validates, alongside the
  `@@INSTANCE_LABEL@@` that shipped in v0.5.0.

### Changed

- **`<namespace>_exporter_request_wait_seconds` gained an `outcome` label.**
  Deferred from v0.7.0, where the histogram conflated a request that got its
  slot with one that gave up waiting: `Acquire` observes on both paths, so a
  wait that never paid off looked identical to one that did. The label
  carries `success` and `error`, the same convention `RequestDuration` and
  `CommandDuration` already use beside it, and both values are touched once
  at package init so a build with no ceiling configured (every deployment by
  default, and `multi`'s permanent state) still reports a visible, permanent
  zero instead of the series vanishing from `/metrics`, which is a
  `HistogramVec`'s behaviour for a label combination that has never been
  observed.
- **On the CLI flavor, `Execute` refuses a context carrying no deadline once
  a concurrency ceiling is attached.** Also deferred from v0.7.0. The
  shipped collector always applied a deadline, but nothing stopped a
  collector added later from passing a bare `context.Background()` through,
  which would then block on the limiter forever. The contract is enforced
  now rather than merely documented, and
  `/prometheus-exporter:add-collector`'s CLI section states it where a
  collector author will actually see it.
- **`discovery-inputs.md` no longer describes the architecture brief's
  format.** It points at `project-journal.md`, this skill's twelfth
  reference, which owns the format, the section-ownership table, the
  reconciliation rules, and the resumption block all four commands now
  share.
- **`/prometheus-exporter:design-exporter` and
  `/prometheus-exporter:new-prometheus-exporter` no longer rank a database
  as a data source.** Both gave the preference order as `REST/API > gRPC >
  database > CLI`, placing it above the CLI last resort, while the ROADMAP's
  non-goals, `exporter-architecture.md` and `SKILL.md` all call a
  database-only target an explicit non-goal rather than a deferred feature.
  Step 0 is where the source is chosen, so the ranking invited a design this
  plugin then refuses to scaffold, with the refusal landing after the
  architecture work instead of before it. Both now state the non-goal at the
  point of choice and redirect to `postgres_exporter` / `mysqld_exporter`
  for the engine, or the config-driven `sql_exporter` for arbitrary
  SQL-to-metrics.

### Fixed

- **The generated `SECURITY.md` and `docs/configuration.md` named five of
  the nine file-backed secrets `prometheus/common` re-reads on every
  outbound request.** Missing were `username_file`, `credentials_file`,
  `client_secret_file` and `client_certificate_key_file`; the last two are
  OAuth2, where `toSecret` yields a `FileSecret`, `FileSecret.Immutable`
  reports false, and `oauth2RoundTripper.RoundTrip` re-fetches on every
  request exactly like the rest. This mattered because the `single` target
  model ships no reload *on the strength of those lists*: an operator
  reading a short one could conclude a credential needed a restart when it
  did not. Each site now states the rule once, "every `_file` variant the
  section accepts", before enumerating.

### Notes

- **What this release proves, and what it does not.** The scaffold-side
  artifacts (`samples/`, the generated `CLAUDE.md`, the `README.md` marker
  block, the two new substitutions) are covered by the six-cell golden
  matrix, which scaffolds and builds each one; what it asserts about the
  `README.md` block is that the markers are present, paired, non-empty and
  under `## Metrics`, never the `/prometheus-exporter:add-collector`
  regeneration that later rewrites what sits between them. Everything the
  commands themselves do is prose, not code: the journal protocol (reading
  on entry, reconciling against the repository, degrading when the file is
  absent or unreadable), deriving a fixture from `samples/`, and
  regenerating that collector block from `docs/metrics.md`. No test in this
  repository can exercise any of it, and none is claimed to. All of it was
  verified by review against the reference that defines it.

## [0.7.0] - 2026-07-29

### Added

- **Configuration reload for `multi` and `multi-instance`.** `SIGHUP`
  (always active) and `POST /-/reload` (behind `--web.enable-lifecycle`,
  default `false`, which is Prometheus's own posture for a mutating endpoint
  rather than `blackbox_exporter`'s and `snmp_exporter`'s, both of which
  expose theirs ungated) both re-read `--config.file` and apply it
  atomically. Everything that can fail, parsing, a changed `flags:` section,
  an unresolved module, an unreadable secret, runs before anything is
  mutated: a failed reload leaves the running configuration untouched,
  drives `..._exporter_config_last_reload_successful` to `0`, and logs the
  failure at error; a successful one sets that gauge back to `1` and
  advances `..._exporter_config_last_reload_success_timestamp_seconds`.
  Reload does not ship for `single`: its file holds only a `flags:` section
  (unreloadable for the reason below) and an `http_client_config:` whose
  file-backed secrets and TLS material (`password_file`,
  `bearer_token_file`, `authorization.credentials_file`, `ca_file`,
  `cert_file`, `key_file`) `prometheus/common` already re-reads from disk on
  every outbound request with no reload involved; a `single` build's
  documentation points at those `_file` variants instead.
- **A changed `flags:` section refuses the whole reload.** `flags:` is
  rendered into command-line arguments exactly once, at startup, so a
  running process cannot adopt a new value for one. Rather than apply the
  rest of a file and leave the process describing neither configuration, a
  reload that finds this section changed refuses outright, naming every
  changed key, and keeps running what it had.
- **On `multi-instance`, a reload cannot change the SET of label KEYS an
  instance carries.** A Prometheus registry never releases a metric family's
  label-name dimension once registered, so re-registering one under a
  different label key set (a label added, removed, or renamed across every
  instance; a labelled instance replaced by an unlabelled one) would panic.
  This is refused instead, with an error naming what moved and asking for a
  restart. A label VALUE change is unaffected and keeps reloading with no
  restart.
- **A per-target concurrency ceiling**
  (`--exporter.max-requests-per-target`, `multi-instance` and `single`,
  opt-in, default `0` meaning unlimited): bounds how many requests this
  exporter has in flight against one watched machine at a time, so a slow
  collector's background poller cannot starve its siblings polling the same
  instance. `..._exporter_request_wait_seconds` records how long a request
  waited for a slot; it is always registered on every HTTP-flavor target
  model and reports a permanent zero when no ceiling is configured. Not
  offered on `multi`: it has no background pollers, and `/probe`'s
  caller-controlled `target=` rules out a pre-populated limiter index.

### Changed

- **One shared, swappable transport per watched machine** (`multi-instance`)
  or per module (`multi`), replacing a transport built fresh on every use.
  This is what makes both the reload and the concurrency ceiling above
  possible without a connection-pool explosion.
- **`instance.Factory.New` takes a `*instance.Handle`, not an address and a
  client config.** Affects repositories scaffolded with `--target-model
  multi-instance`. The signature moves from `func(addr string, hcfg
  *promconfig.HTTPClientConfig) (BackgroundCollector, error)` to `func(h
  *instance.Handle) (BackgroundCollector, error)`: the Handle owns the
  transport every collector of that machine now shares, built once per
  machine so a reload can swap it underneath them without restarting any
  poller. `/prometheus-exporter:add-collector` detects the older, pre-Handle
  shape and refuses to append to it rather than generate code that will not
  compile; the supported route for a repository on that shape is to
  rescaffold with `/prometheus-exporter:new-prometheus-exporter` and port
  collector bodies across, the same no-migration posture v0.6.0 already
  applies to `/prometheus-exporter:add-collector`'s other seam checks.
- **The systemd unit's `ExecReload` is now per-target-model.** A
  single-target scaffold no longer ships it active: `single` installs no
  SIGHUP handler, so an active `ExecReload` there would let `systemctl
  reload` deliver SIGHUP's OS default (terminate the process) instead of the
  harmless `Job type reload is not applicable` refusal it gave before this
  exporter had any reload mechanism at all. `multi` and `multi-instance`
  keep it active: they install `internal/reload`'s own SIGHUP handler.

## [0.6.0] - 2026-07-28

### Changed

- **`multi-instance` is taught, not just shipped.** The target model landed
  in v0.5.0 but appeared in none of the reference documents and not in the
  skill's own step 0, so a session learning from `references/` alone still
  believed there were two target models and could not discover the third
  when making an architecture decision. The architecture reference now
  compares three models instead of forking on two, and the scaffold,
  collector, discovery and Prometheus-conventions references each cover what
  the model changes for them: the background-collector mandate, the shared
  shutdown budget, the per-instance identifying label and the labels an
  instance may not reuse. The argument for the model is stated where it
  belongs: it exists for Prometheus's five-minute staleness window, not for
  slow targets, and it generalises to any application API, batch job or
  nightly inventory that cannot be scraped live.

### Removed

- **`--probe.module`.** Deprecated in v0.5.0 in favour of the configuration
  file's `modules:` section, removed here under the two-phase rule announced
  at deprecation. Modules now come from `modules:` and nowhere else; the
  mutual-exclusion refusal between the flag and `modules:` is gone with it,
  since there is no longer a second source to conflict with. The refusal of
  a `modules:` section alongside a top-level `http_client_config:` is
  unrelated and stays.
- **`/prometheus-exporter:add-collector`'s in-place seam migrations.** The
  command no longer rewrites an older repository's `internal/probe/` and
  `cmd/*/main.go` to the current shape. It detects an outdated seam, stops,
  and points at rescaffolding with
  `/prometheus-exporter:new-prometheus-exporter` and porting the collector
  bodies across, which is a smaller operation than an automated rewrite no
  gate in this plugin can verify. Appending into an outdated seam is still
  refused, so nothing silently produces code that will not compile.

  This is a pre-1.0 decision. Migration was the only part of this plugin
  that writes into a repository somebody else owns, the only part with no
  test harness, and it cost about 19k tokens on every invocation, more than
  any other component. With no released version yet carrying a user, it was
  maintained for nobody. Migrations become an obligation after 1.0, and a
  migration harness is the prerequisite for bringing them back.

## [0.5.0] - 2026-07-28

### Added

- **A third target model, `multi-instance`** (`--target-model
  multi-instance`, http flavor only): one process watches a fixed list of
  machines declared in `--config.file`, each polled in the background on its
  own schedule and re-served from a cache on every scrape, so the scrape
  itself never waits on a live fetch. `--config.file` is required for this
  target model (the one place multi-instance departs from the "absent file
  changes nothing" rule); single-target and multi-target builds are
  unchanged.
- **`modules:` and `instances:` configuration schema.** `modules:` names
  reusable `http_client_config:` bundles; `instances:` lists the machines a
  multi-instance exporter watches, each with a `name`, an `address`, an
  optional `module`, and optional extra `labels`. A plain v0.4.0 config file
  (no `modules:`/`instances:`) keeps working unchanged.
- **`scaffold.sh --instance-label`** (default `target`): the identifying
  label a multi-instance scaffold applies to every series of every watched
  instance, fixed at scaffold time rather than a runtime flag.
- **Per-target credentials for the `multi` target model.** A `/probe`
  request selects credentials by name with `?module=`, so one multi-target
  exporter can probe targets that authenticate differently. Credentials
  resolve in a fixed order (the unique selected module carrying them, then a
  `default` module, then the top-level `http_client_config:`) and never
  combine: selecting two credential-bearing modules returns 400, and so does
  a probe that resolves no credentials against a configuration that declares
  some. The same mechanism expresses both ecosystem conventions, a module as
  a complete bundle or credentials as an independent axis, so the choice
  lives in the configuration file rather than in code.

### Changed

- **`probe.Factory` gains a fourth `hc *http.Client` parameter.** Affects
  repositories scaffolded with `--target-model multi`;
  `/prometheus-exporter:add-collector` detects the older shape and migrates
  it, diff first. No flag is renamed and no URL changes. Per-collector HTTP
  clients collapse into one client per module, built once at boot.

### Deprecated

- **`--probe.module`.** Superseded by the configuration file's `modules:`
  section, which can also carry credentials. Both at once is refused at
  boot. Removal no earlier than v0.6.0.

## [0.4.0] - 2026-07-22

### Changed

- **Breaking (multi-target only):** `--collector.example.timeout` is renamed
  `--probe.timeout`. The old name never configured the `example` collector:
  it bounded every probe. With one collector the two were the same thing, so
  the lie was invisible. `/prometheus-exporter:add-collector` migrates a
  v0.3.0 scaffold and shows the diff first.

### Added

- Multi-target exporters hold more than one collector.
  `/prometheus-exporter:add-collector` now works on a `--target-model multi`
  scaffold instead of refusing and handing over a manual procedure.
- `/probe?target=...&module=...` selects a subset of an exporter's
  collectors. The parameter is repeatable and comma-separated, and named
  modules combine, as in the SNMP exporter. An absent `module` runs every
  collector, so an existing scrape config keeps working.
- `--probe.timeout-offset` (default `0.5s`) is subtracted from Prometheus's
  scrape timeout so a probe answers before Prometheus abandons the scrape.
- `probe_timeout_seconds` is exported alongside `probe_success` and
  `probe_duration_seconds`.
- **Optional YAML configuration file** (`--config.file`): every scaffolded
  exporter can load a `flags:` section (any flag the binary declares,
  addressable by name) and an `http_client_config:` section (basic auth,
  bearer token, TLS/client certs) for the authentication no flag surface can
  express. `http_client_config:` is honored by the HTTP flavor only; the CLI
  flavor refuses to start if it is set, since it runs a local command and
  has nothing to authenticate against. Precedence is command-line flag, then
  the file, then environment, then the flag's own built-in default. A binary
  started without `--config.file` is unchanged: the flag defaults to empty
  and nothing is read.

- A scaffolded exporter's dependency floor moves: `golang.org/x/text` to
  v0.39.0, and `golang.org/x/sync` to v0.21.0 as a transitive requirement of
  it. `go.yaml.in/yaml/v2` also moves from the indirect block to the direct
  one, which it earned when `internal/config` started importing it.

  No released version of this plugin ever generated an exporter affected by
  GO-2026-5970, the advisory the `x/text` bump closes. Reaching the
  vulnerable code requires calling `NewClientFromConfig`, which nothing
  imported before the configuration layer above. That call and the bump that
  closes it both land in this release, so there is nothing to upgrade away
  from and no reason to rebuild an exporter generated from v0.3.0 or
  earlier.

### Fixed

- Collectors now run under a context that can actually be cancelled.
  `Collect` minted its own `context.Background()`, so the context threaded
  through the collector's I/O carried no deadline and cancellation was
  plumbed and then thrown away. In a multi-target probe this meant a hanging
  target ran until its HTTP client timeout with nothing able to interrupt
  it. Single-target behavior is unchanged: it passes `context.Background()`
  explicitly, which is exactly the value `Collect` minted for itself.

## [0.3.0] - 2026-07-11

### Added

- **Live-target probe (discovery rung 4)** —
  `/prometheus-exporter:design-exporter` can now ground a design by probing
  a *running* instance of the target: an HTTP `GET` against its description
  surface (`/openapi.json`, `/metrics`, …) or a CLI
  `--help`/`--version`/sample invocation. Opt-in and consent-gated (the
  exact command is shown and confirmed before running); every capture passes
  through a deterministic secret-redaction backbone
  (`skills/prometheus-exporter/scripts/probe-target.sh`, `bash`, outside
  `assets/` so no scaffold ships it) before any of it reaches the brief. It
  **supplements** the discovery walk — confirming and filling gaps in the
  higher rungs, surfacing contradictions as open questions — and the default
  walk (local spec > docs > context7 > dialogue) is unchanged when no live
  instance is offered.
- **Multi-target scaffolding** (`--target-model multi`, http flavor only):
  `/prometheus-exporter:new-prometheus-exporter` can now scaffold a
  Prometheus multi-target (`/probe?target=…`) exporter — a fresh registry
  and collector set per request scoped to the target,
  `probe_success`/`probe_duration_seconds`, a `--probe.target-allowlist`
  hardening flag with a startup warning when empty, and an always-on
  http/https target floor. Single-target remains the default and is
  unchanged.

### Security

- Pinned the scaffold's Go toolchain to **1.26.5**, which carries the fix
  for GO-2026-5856 (Encrypted Client Hello privacy leak in `crypto/tls`).
  Every scaffolded exporter reaches `crypto/tls` through
  `web.ListenAndServe`, so this keeps their `make check` (govulncheck)
  clean.

## [0.2.0] - 2026-07-08

### Added

- **`/prometheus-exporter:generate-dashboard [name]`** — generates 1..N
  business Grafana dashboards for an already-scaffolded exporter from its
  own `docs/metrics.md`, via a RED/USE design dialogue on top of a
  deterministic backbone
  (`skills/prometheus-exporter/scripts/generate-dashboard.sh`, `bash`+`jq`,
  container-first). Emits **exportable** JSON (`__inputs`/`__requires`,
  `${DS_PROMETHEUS}` datasource, deterministic `<namespace>-<slug>` uids),
  one panel per documented metric, PromQL chosen by `Type`
  (`rate()`/`$__rate_interval` on counters, `histogram_quantile()` with a
  synthesized `_bucket` on histograms, `avg by (job, instance)` on gauges).
  Every panel `expr` references only a metric present in `docs/metrics.md`;
  the same backbone is invoked by the golden test, and `context7`/`dataviz`
  enrich the result when present but are never required. Complements — never
  modifies — the health dashboard.
- **`/prometheus-exporter:design-exporter <target>`** — runs the step-0
  architecture-design phase with broadened discovery (a preference-ordered
  ladder: local API spec > docs folder/URL > context7 > dialogue, with
  graceful degradation) and writes a reviewable architecture brief.
- **`references/discovery-inputs.md`** — the discovery input taxonomy, the
  degradation ladder, per-source extraction methods, and the
  architecture-brief format.
- **`/prometheus-exporter:new-prometheus-exporter` consumes an architecture
  brief** when one is present (`./exporter-design-brief.md` or a named
  path), pre-filling step-0 decisions and step-1 variables; with no brief it
  stays fully interactive.
- **`/prometheus-exporter:add-collector --variant background`** — scaffolds
  a collector that refreshes its cache on a fixed interval (default `5m`) in
  a background goroutine instead of on the scrape's critical path, for a
  backend too slow or expensive to hit on every scrape (both HTTP and CLI
  flavors). Ships an always-emitted
  `<namespace>_<name>_last_refresh_timestamp_seconds` freshness gauge (`0`
  before the first successful refresh) and fails open on a refresh error
  (serves the previous cache, logs, retries next tick). `main.go` gains a
  generic, dormant `Done()`-wait shutdown seam (`backgroundCollectors`) that
  every scaffolded exporter ships from `/new` on, populated only once a
  background collector is actually added. The architecture-design phase
  (`/prometheus-exporter:design-exporter`, and the `prometheus-exporter`
  skill's step 0) now proactively asks whether any collector's backend is
  slow/expensive enough to warrant this.

### Changed

- Removed the planned DB I/O flavor from scope; database targets should use
  `postgres_exporter`/`mysqld_exporter` or the config-driven `sql_exporter`.

## [0.1.1] - 2026-07-06

Hardening tranche: prove the shipped-but-unexercised release artifacts in
the golden test, standardize on `main`, and give the container image a
canonical CycloneDX SBOM. No user-facing feature changes.

### Added

- **`make sbom-image`** — generates a CycloneDX SBOM for the container image
  via syft, so the image carries a canonical CycloneDX bill of materials
  matching the release archives. The BuildKit-native SPDX attestation is
  retained as a supplementary embedded layer.
- Golden-test coverage for three previously-unexercised templates: the
  distroless `Dockerfile.minimal` build, `docker compose config` validation
  of both compose files, and `goreleaser check` (pinned to the same
  GoReleaser version the release workflow uses).

### Changed

- The default branch is `main` throughout the release runbook and the
  dev-release workflow trigger (previously `master`).
- SBOM documentation across the templates and references now describes the
  supply-chain artifacts accurately: CycloneDX for archives and image, plus
  the supplementary SPDX buildx attestation on the image.

## [0.1.0] - 2026-07-05

Initial release: an end-to-end plugin for creating and hardening Go
Prometheus exporters, from architecture decision through a releasable,
monitored repository.

### Added

- **`prometheus-exporter` skill** — a router (`SKILL.md`) covering the full
  lifecycle (architecture design, scaffolding, per-collector development,
  hardening, release/observability, audit) plus 10 reference documents:
  architecture, official Prometheus conventions (naming/types/labels/
  OpenMetrics, context7-anchored), the collector pattern, project layout,
  container-first tooling, host-agnostic CI/release, packaging, security,
  dashboards/alerting, and docs/governance. Every reference separates
  generic guidance from exporter-specific fill-ins.
- **`/prometheus-exporter:new-prometheus-exporter <name>`** — scaffolds a
  complete, buildable, git-initialized exporter repository from an
  already-decided architecture: choice of **HTTP** (default) or **CLI** I/O
  flavor, a license (Apache-2.0, MIT, GPL-3.0, or BSD-3-Clause; Apache-2.0
  by default), and an optional GitHub Actions layer. Refuses to overwrite a
  non-empty target directory and proves the result with a real `make build`
  + `make check`.
- **`/prometheus-exporter:add-collector <name>`** — adds one new collector,
  its full test triad, registry wiring, a `docs/metrics.md` update, and a
  proposed tiered business alert to an existing scaffolded exporter.
  Idempotent: refuses to add a collector that already exists.
- **`exporter-reviewer` subagent** — a self-sufficient, read-only audit of
  the exporter-specific delta: Definition of Done, Prometheus naming/type/
  label conventions, the five-piece collector pattern, per-collector test
  coverage, cardinality, secret exposure in metrics, and docs/alerts
  lockstep with the code. Runs alongside `/code-review` and
  `pr-review-toolkit` when installed, but depends on neither.
- **Two I/O flavors, HTTP and CLI**, sharing one flavor-agnostic core:
  registry-driven collector wiring with auto-generated
  `--[no-]collector.<name>` flags, a count-based health tracker exposed as
  `<namespace>_exporter_collector_success`/`..._duration_seconds`,
  exporter-toolkit web flags (TLS/Basic Auth via `--web.config.file`), a
  startup warning when serving unauthenticated on a non-loopback address,
  and signal-aware graceful shutdown.
- **A container-first Makefile**: every dev-tooling target (`build`, `test`,
  `race`, `vet`, `lint`, `vuln`, `check`, `report`, and more) runs inside a
  pinned tools image by default, auto-detecting Docker or Podman, with a
  documented native fallback (`NATIVE=1`) for contributors without a
  container engine.
- **Host-agnostic release tooling**: SemVer tags, a Keep-a-Changelog
  `CHANGELOG.md`, Conventional Commits, and a GoReleaser configuration
  (multi-arch builds, CycloneDX SBOM, keyless cosign signing, dual-variant
  container images) that all work with no forge at all. The GitHub Actions
  layer — CI, release, dev-release, `govulncheck`, Trivy, Scorecard,
  Dependabot, CODEOWNERS, issue/PR templates — is an explicit **opt-out**
  (`--forge none` omits it entirely; the repository stays versioned and
  locally releasable either way).
- **`monitoring/` shipped with every scaffolded exporter**: Prometheus
  health alerts (exporter down, collectors failing, abnormal scrape
  duration) plus a commented business-alert example, a NaN-guarded recording
  rule, and a health dashboard for Grafana — all validated against the
  exporter's own real metrics, never an invented one.
- **`make docs-check`**: a generated test that statically extracts every
  metric name and label the code can actually produce and fails the build if
  `docs/metrics.md` documents one that doesn't exist — the metrics reference
  cannot drift from the code without the build catching it.
- **Hardened packaging**: a standard Dockerfile (dedicated non-root user)
  and a distroless-minimal variant, both building from source; a hardened
  Docker Compose stack (`no-new-privileges`, dropped capabilities, read-only
  root, `tmpfs`); and an optional systemd unit.
- **A golden smoke test and this plugin's own CI**: `test/golden-smoke.sh
  --all` scaffolds all four `{http,cli} × {none,github}` combinations and
  proves each one builds, gates clean, validates its PromQL, and catches an
  injected metrics-doc lie; `.github/workflows/plugin-ci.yml` runs it,
  `claude plugin validate .`, and the zero-source-mention grep on every push
  and pull request.
- Plugin skeleton: the plugin manifest and self-hosted marketplace
  (`.claude-plugin/`), and root governance (`CLAUDE.md`, `README.md`,
  `ROADMAP.md`, `TODO.md`, `LICENSE`).
