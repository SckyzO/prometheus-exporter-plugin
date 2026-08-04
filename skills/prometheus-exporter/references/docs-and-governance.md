# Docs and governance: lockstep metrics docs, `make docs-check`, and the Definition of Done

This is step 4 of the workflow: keeping every doc a scaffolded exporter
ships truthful against the code, and the contribution process that enforces
it (`makefile-and-tooling.md` covers the tooling gate itself; this document
is the docs half of hardening). Everything below matches
`internal/collector/docs_check_test.go.tmpl`, `CONTRIBUTING.md.tmpl`,
`SECURITY.md.tmpl`, `CHANGELOG.md.tmpl`, and the four `docs/*.md.tmpl` files
as shipped. Read those alongside this document, not instead of it.

## Template-vs-generated: not every doc is scaffolded the same way

Three different provenances sit under one `docs/` directory, and knowing
which is which matters before you edit one by hand:

- **Templated** ([G] structure, strong across every scaffolded exporter):
  `docs/development.md`, `docs/release-process.md`,
  `docs/validation-checklist.md`, `docs/configuration.md`. These come
  straight from `docs/*.md.tmpl` under this plugin's own `assets/`: the same
  `make` targets, the same release flow, the same copy-pasteable validation
  steps, for any exporter this scaffold produces. Editing one by hand in a
  generated repo is normal and expected as the exporter grows.
- **Generated, and continuously validated against the code**:
  `docs/metrics.md`. This one is *not* staged under `assets/docs/`: it lives
  at `code/<flavor>/metrics.md.tmpl`, alongside that flavor's collector
  template, because its content genuinely differs per flavor (HTTP's bundled
  collector emits `@@NAMESPACE@@_items`/ `@@NAMESPACE@@_healthy`; CLI's
  emits `@@NAMESPACE@@_example`/ `@@NAMESPACE@@_example_entries`: a single
  shared file would be a lie for whichever flavor didn't get chosen).
  `scaffold.sh` relocates it to `docs/metrics.md` at scaffold time, after
  flavor selection, specifically so it lands at the one path every other doc
  and `make docs-check` (below) expects. Past scaffold time, it is kept
  honest by a test, not by hand-editing discipline.
- **Stub**: `CHANGELOG.md`, starting at a bare `## [Unreleased]` heading,
  with content accumulating release by release from here (below).

## Docs in lockstep with `/metrics`

`docs/metrics.md`'s own header comment states the contract it lives under:
*"kept truthful by `make docs-check` ... any metric or label listed below
that the code cannot actually produce fails the build. A metric the code
emits but this file doesn't document is only a warning."* An HTML-comment
block further down documents the exact 4-cell row shape `make docs-check`'s
parser expects:

```markdown
| `metric_name` | Type | `label1`, `label2` | Description |
```

`docs/configuration.md` (flags and the collectors table),
`docs/validation-checklist.md` (a `grep`-based
`docs/metrics.md`-vs-live-scrape diff, Step 8), and the root `README.md`
(its own "Metrics" section pointing straight at `make docs-check`) all lean
on this same file rather than re-stating its content: one source of truth
for what this exporter emits, referenced from four places instead of
duplicated into four places.

## `make docs-check`: docs are a subset of code, mechanically

`internal/collector/docs_check_test.go` is `make docs-check`'s
implementation, a Go test, not a shell script, run with `-count=1`
specifically to disable `go test`'s result cache (its real input,
`docs/metrics.md`, is a plain file the Go toolchain has no build-dependency
reason to track; without `-count=1` a doc-only edit could serve a stale
cached `PASS`, exactly the failure mode a drift-detector must never have:
see `makefile-and-tooling.md`).

**Only `internal/collector/*.go` is ever scanned, non-recursively.** A
metric defined anywhere else, `internal/probe/probe.go`'s `probe_success`/
`probe_duration_seconds` or `internal/reload/reload.go`'s two
configuration-reload gauges, is invisible to this check by construction, in
both directions: it can never be flagged as undocumented, and a plain `|
\`metric_name\` | ... |` table row naming it would be flagged as a LIE
(documented, but absent from `internal/collector/*.go`), on every build,
regardless of whether that metric is actually registered somewhere else.
`docs/metrics.md`'s shipped template files document both of these as prose
bullet points instead of parseable table rows, specifically to stay outside
`parseMetricsDoc`'s table-row regex: the existing "Multi-target `/probe`
metrics" section is the original worked example of this technique, and the
"Configuration reload metrics" section added once `internal/reload/` exists
follows the identical shape. Reach for the same technique for any future
metric that lives outside `internal/collector/`; never for one that already
lives inside it, where a real table row is both possible and required.

**What it does, precisely**: parses every non-test `*.go` file directly
under `internal/collector/` via `go/ast`, statically resolving every
`prometheus.NewDesc(...)` call and every Opts-based constructor
(`NewHistogramVec`/`NewCounterVec`/`NewGaugeVec`/`NewSummaryVec` and their
non-Vec `NewHistogram`/`NewCounter`/`NewGauge`/`NewSummary` forms) it finds,
resolving a metric name built from a plain string literal exactly the same
way as one built from a `prometheus.BuildFQName(ns, sub, name)` call whose
three arguments are themselves literals (both are the idiomatic, static way
to compose a name; neither is treated as more suspect than the other). It
then parses `docs/metrics.md`'s own table rows and diffs the two sets in
**both directions, with different consequences**:

| Direction | Consequence | Why |
|---|---|---|
| Documented but the code can't produce it (a "lie") | **`t.Fatalf`: fails the build** | A lying doc is worse than no doc at all |
| Code emits it but `docs/metrics.md` doesn't mention it ("undocumented") | **`t.Logf("WARNING: ...")`: visible, non-fatal** | A quality gap, not a lie: see `CONTRIBUTING.md`'s Definition of Done, step 4 |
| A call site recognized by function name but not fully resolvable (a computed name, a package-level variable used as the label list, ...) | **Also a `t.Logf` warning, naming the file:line** | An unverifiable metric must stay *visible* as unverifiable: never silently indistinguishable from one that simply doesn't exist |

That third row is the one easiest to get wrong when adapting this pattern
elsewhere: an earlier version of this exact checker silently dropped an
unresolvable call site from its extracted set with no trace at all, which
meant a *correct*, truthfully-documented metric built from
`prometheus.BuildFQName(...)` could fail the build as a false "lie" simply
because the extractor didn't yet know how to read that call shape, not
because the doc was ever actually wrong. `docs_check_test.go`'s own
regression tests (`TestDocsCheck_BuildFQName`,
`TestDocsCheck_WarnsOnUnresolvableName`,
`TestDocsCheck_WarnsOnUnresolvableLabels`) pin exactly this down: an
unresolvable name or label list warns, it never silently vanishes and it
never fabricates a lie against a doc that was actually telling the truth.

**Metric names and label keys must be static** to be checkable at all: a
plain string literal, or a `BuildFQName` call whose three arguments are
themselves literals. A genuinely computed name (string concatenation,
`fmt.Sprintf`, a variable) is invisible to this check and surfaces as the
warning above, which is also, independently of this tool, a Prometheus
naming anti-pattern in its own right (`prometheus-principles.md`). This is
enforced the same way for a collector `/prometheus-exporter:add-collector`
adds as for the bundled example: nothing about the mechanism is aware of
which collector it is looking at.

**A completely empty extraction fails the build outright** (`t.Fatal`,
distinct from the per-metric checks above): every flavor this scaffold ships
defines at least the shared `StatusTracker`'s two metrics, so zero extracted
metrics means the extractor itself broke (a refactor changed a call shape it
used to recognize), not that this package genuinely has none. Left
unguarded, a broken extractor would make every future run vacuously pass
forever regardless of what `docs/metrics.md` claims, exactly the kind of
silent hole this test exists to close.

**This plugin proves the check actually works, not just that it exists.**
`test/golden-smoke.sh` injects a fabricated row (``
`THIS_METRIC_DOES_NOT_EXIST_lie_injection_check` ``) into a freshly
scaffolded `docs/metrics.md`, confirms `make docs-check` fails on it, then
reverts the injection and confirms `make docs-check` passes again, on every
scaffolded flavor/forge combination. A docs-check that always passes
(because it never actually runs the comparison, say) would look identical to
a working one from the outside; this round-trip is what tells the
difference.

## `CONTRIBUTING.md` is the Definition of Done

Nine steps, applying equally to an external contribution and to routine
maintainer work:

```
1. make build         -> compiles clean
2. make test          -> all pass; coverage non-decreasing vs. the previous commit
3. make lint          -> golangci-lint reports 0 issues
4. make docs-check     -> docs/metrics.md matches what the code actually emits
5. Run against a real target (not just fixture-fed unit tests)
6. Generate a representative workload
7. Validate by metric, not by eye: curl .../metrics | grep <metric_name>
8. Check logs for unexpected ERROR/WARN
9. make check          -> the full local CI mirror
```

Docs-only or comment-only changes get a documented shortcut: `make check`
(plus `make docs-check` specifically if a metric name or doc file was
touched) is enough: steps 5-8 (the live-target run) are required
specifically for any change under `internal/collector/` or
`cmd/@@EXPORTER_NAME@@/`, not for a typo fix in a comment.

The same file also carries the rules step 4's mechanical check depends on
being followed in the first place:

- **Adding a collector**: the five pieces plus the test triad
  (`collector-pattern.md`), the static-metric-name rule `docs_check_test.go`
  enforces mechanically (above), and registration at the `//
  @@COLLECTOR_REGISTRY@@` marker (`project-scaffold.md`).
- **The outcome rule**: a collector states its own scrape outcome through
  `CollectWithOutcome(ch) error`, with a compile-time assertion so a
  signature typo fails the build rather than silently reverting to the
  metric-count fallback.
- **Test-data anonymization**: real hostnames, usernames, and account/tenant
  names never reach a committed fixture, replaced with a placeholder that
  preserves shape (field count, rough magnitude) without preserving content.
- **Common Pitfalls**, named explicitly rather than left to be rediscovered:
  zero metrics vs. zero-valued metrics (above), two `MustNewConstMetric`
  calls sharing one descriptor and label set breaking the *entire* scrape at
  `Gather` time (not just the offending collector's own output), and a flag
  dereferenced inside a `register()` closure at declaration time instead of
  construction time always reading its zero value, never the parsed default.
- **Reviewing contributions**: name the blocking concern, not a judgment on
  the contributor; *"I'm not closing the PR. I just want to make sure we get
  this right together"* over silence or a cold rejection.

`CONTRIBUTING.md` hands off to `docs/release-process.md` (the maintainer
workflow for actually cutting a release: branching, integrating community
PRs with credit, the defensive audit, validating continuously) and
`docs/validation-checklist.md` (the same end-to-end validation as a
copy-pasteable, numbered command/expected/if-it-fails procedure, written so
a human or an AI agent can run it without prior context) for everything past
"the change itself is done."

## `SECURITY.md` and `CHANGELOG.md`

`SECURITY.md` documents the reporting channel (a forge's private
vulnerability reporting if available, otherwise `@@OWNER@@` through a
private channel, never a public issue) and the supported-versions policy
(latest release only), then points at the concrete security practices this
skill teaches in depth elsewhere: `security-and-hardening.md` for the
never-a-secret-in-a-metric rule and the conservative-defaults posture,
`cicd-and-release.md`/`packaging-and-ops.md` for signing, SBOMs, and
non-root/distroless images. `SECURITY.md` is the front door; those two
documents are where the reasoning actually lives.

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/), and
its own HTML-comment header is explicit about *who* an entry is for: write
every entry for the **operator** running this exporter, not for a code
reviewer: a metric renamed or retyped, a flag whose default changed, a
collector now enabled or disabled by default, a label newly added to an
existing metric. The same header also carries the version-number guidance
(`cicd-and-release.md` has the reasoning): start at `v0.1.0`, and deprecate
in a minor rather than treating every rename as a major. A breaking change
gets a before/after migration table:

```markdown
| Old | New |
| --- | --- |
| `@@NAMESPACE@@_foo_total` (Counter) | `@@NAMESPACE@@_foo` (Gauge) |
```

Sub-sections (`Added`/`Changed`/`Deprecated`/`Removed`/`Fixed`/`Security`)
appear only when they have content: an empty `### Removed` heading with
nothing under it is noise, not rigor. `docs/release-process.md`'s own
"Update documentation" step ties this back to the rest of `docs/`: any
operator-visible change updates `CHANGELOG.md` always, plus whichever of
`docs/metrics.md`, `docs/configuration.md`, `README.md`, or
`monitoring/prometheus/*.yml`/`monitoring/grafana/*.json` that change
actually touches.

## The audit-time backstop

`make docs-check` runs on every `make check` (so, continuously, in
`ci.yml.tmpl` on every pull request if the GitHub layer is in use, but note
it's the code/metrics-docs check specifically, not the alerting-rules
validation `dashboards-and-alerts.md` covers, which stays a manual or
CI-you-add-yourself step). `exporter-reviewer`'s own Step 9 ("Docs and
alerts in lockstep with the code") re-derives the same conclusion at audit
time from a different angle (cross-referencing `make docs-check`'s real
output rather than re-parsing `docs/metrics.md` by hand), so a repository
that skipped step 4 of the Definition of Done before merging still gets
caught before a release.

## Checklist

- [ ] `docs/metrics.md` is the one file every metric/label claim traces
      back to: `docs/configuration.md`, `docs/validation-checklist.md`,
      and `README.md` reference it, never restate its content.
- [ ] `make docs-check` fails the build on a documented metric/label the
      code can't produce; it only warns on the reverse gap and on anything
      it couldn't statically resolve, never silently drops the latter.
- [ ] Every metric name and label key reaching `docs_check_test.go` is a
      string literal or a `BuildFQName(literal, literal, literal)` call,
      never computed.
- [ ] `CONTRIBUTING.md`'s nine-step Definition of Done is followed for
      every change; steps 5-8 (live-target validation) specifically for
      anything touching `internal/collector/` or `cmd/@@EXPORTER_NAME@@/`.
- [ ] Every `CHANGELOG.md` entry is written for the operator, with a
      migration table for anything breaking, never just "what the diff
      changed."
- [ ] `SECURITY.md` points at `security-and-hardening.md`/
      `cicd-and-release.md`/`packaging-and-ops.md` for the reasoning rather
      than duplicating it.
