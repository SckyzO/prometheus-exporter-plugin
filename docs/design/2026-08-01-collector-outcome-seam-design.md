# A collector outcome seam: replacing count-based inference

**Status:** design proposed 2026-08-01. Not approved, not started. Implements
the two §8.2 verdicts of
[`2026-08-01-official-exporter-gap-report.md`](2026-08-01-official-exporter-gap-report.md),
which are one gap seen from two sides. Falls under the root `CLAUDE.md`'s
two-phase rule: this reshapes the collector seam, which is named there
explicitly.

## 1. The problem, stated precisely

`StatusTracker` infers a collector's outcome from **how many metrics it
emitted** (`assets/internal/collector/status_tracker.go.tmpl`, the
`len(collected) == 0` rule). The collector itself never gets to say whether it
succeeded. That proxy is wrong in both directions.

**False positive.** A collector whose scrape legitimately produced nothing, a
queue with no jobs, a device list that is empty today, emits zero metrics and is
reported `collector_success=0`. It pages. `re-sync.md` §4.6 already records this
and defers it.

**False negative, and worse.** A collector that emits some of its series and
*then* fails reports `collector_success=1`, because the count is non-zero. The
failure is invisible. This is the direction that hides breakage, and this
plugin's own doctrine widens it: `references/collector-pattern.md` tells authors
that on a successful-but-empty scrape they should always emit metrics with zero
values rather than zero metrics. Following that advice makes the false negative
more likely, not less.

Both disappear if the collector returns its own outcome instead of having one
guessed from its output.

## 2. What the references actually do, and the trap in it

The gap report's first draft got this wrong, and the correction is the reason
this document exists at all, so it is recorded here rather than left in a PR
description.

node_exporter's per-collector interface is `Update(ch chan<- prometheus.Metric)
error`, and `execute()` reads the returned error rather than counting metrics
(`collector/collector.go`). It also defines a sentinel, `ErrNoData`.

**`ErrNoData` does not mean "legitimately empty".** Every one of its ~40 use
sites means *the data source is absent*: an `os.ErrNotExist` mapping. A
legitimately empty collector takes a completely different path, it iterates an
empty result and returns `nil`, and `execute()` then reports **`success = 1`
with zero metrics emitted**. `readBondingStats` returning an empty map with a
nil error is the clearest example.

So the shape to adopt is the **error return**. `ErrNoData` is a separate,
optional question, and copying it is not obviously right: treating an absent
data source as a scrape *failure* is a debatable choice this plugin need not
inherit along with the rest.

## 3. Who consumes the seam today

Any change here has to satisfy every one of these at once. Verified by grep,
not assumed:

| Consumer | File |
|---|---|
| `register()` in all three mains | `assets/mains/{single,multi,multi-instance}/main.go.tmpl` |
| `StatusTracker.Add(name, prometheus.Collector)` | `assets/internal/collector/status_tracker.go.tmpl` |
| the probe path | `assets/internal/probe/probe.go.tmpl` |
| the multi-instance path | `assets/internal/instance/instance.go.tmpl` |
| both flavors' example collectors and their triads | `assets/code/{http,cli}/collector{,_test}.go.tmpl` |
| both background variants | `assets/code/{http,cli}/variants/background_collector.go.tmpl` |
| `/prometheus-exporter:add-collector` | `commands/add-collector.md`, which knows the exact identifiers |
| the teaching layer | `references/collector-pattern.md`, the five-piece pattern |

And, outside this repository entirely: **every exporter already scaffolded by
this plugin**, whose collectors implement `prometheus.Collector` and are
compiled against the shipped `StatusTracker`.

## 4. Why the two-phase rule is not optional here

A collector in a third party's repository is *their* code. If `StatusTracker`
stops accepting `prometheus.Collector`, their build breaks on a plugin upgrade
they did not ask for, in a file they wrote themselves. That is the exact failure
the two-phase rule exists to prevent.

### Phase 1: add the new shape, keep the old one working

Introduce an optional richer interface and have the tracker prefer it when the
collector implements it:

```go
// OutcomeCollector is a collector that reports its own scrape outcome instead
// of having one inferred from its metric count.
type OutcomeCollector interface {
    prometheus.Collector
    // CollectWithOutcome behaves like Collect and additionally reports whether
    // the scrape succeeded. Returning nil with zero metrics is a success.
    CollectWithOutcome(ch chan<- prometheus.Metric) error
}
```

`StatusTracker.Collect` type-asserts. A collector implementing the interface has
its error read; anything else keeps the current count rule, byte for byte.
`Add`'s signature does not change, so no caller changes and no scaffolded
exporter stops compiling.

The shipped example collectors and both background variants move to the new
shape, so the templates teach the right thing from the next scaffold on. The
per-collector triad gains a case for each of the three outcomes: empty and
successful, partial then failed, and populated and successful. The first two
fail before the change and pass after, which is the point.

`references/collector-pattern.md` and `commands/add-collector.md` move to
teaching the new shape, while stating that the old one still works.

### Phase 2: remove the fallback, a separate release later

Only once the new shape has shipped and been exercised. Announced as a breaking
change with the release that does it, not folded into phase 1.

## 5. Open questions, for the session that implements this

These are genuinely undecided. Deciding them in a PR description rather than
here is how the first draft of the gap report went wrong.

1. **Interface name and method name.** `CollectWithOutcome` is descriptive and
   ugly. An `Update(ch) error` that mirrors node_exporter is prettier but
   collides conceptually with `Collect`, and a collector would then have two
   methods that both emit.
2. **Whether to adopt an `ErrNoData` equivalent at all**, given §2. The default
   answer should be no: an absent data source is arguably a real failure for a
   purpose-built exporter, unlike for a host agent with ninety optional
   collectors. Adopting the error return does not commit us to the sentinel.
3. **What the background variants do.** They keep last-good data across a failed
   refresh and already emit a freshness gauge, so their outcome is not the same
   question as a synchronous collector's. Possibly they should report success
   whenever they have data to serve, and surface refresh failure through the
   freshness gauge alone, which is what they effectively do today.
4. **Whether the tracker should also stop treating a panic as total failure.**
   A collector that emits and then panics currently loses its outcome to the
   recover branch. Out of scope unless it falls out for free.
5. **Whether `Add` should gain a compile-time check** so a collector that meant
   to implement the interface but got the signature wrong fails the build
   instead of silently falling back to the count rule. This is the most likely
   source of a quiet regression in phase 1 and deserves a real answer.

## 6. Definition of done

- `sh test/golden-smoke.sh --all`, all six cells green.
- A per-collector triad case for each of the three outcomes, failing before and
  passing after.
- A test proving a plain `prometheus.Collector` still works unchanged through
  the tracker, which is the whole promise of phase 1.
- `references/collector-pattern.md` and `commands/add-collector.md` in lockstep
  with the templates.
- `re-sync.md` §4.6 updated: the wart it records is fixed, and the entry should
  say so rather than being deleted, along with the §2 correction about what
  `ErrNoData` actually means.
- `sh test/zero-source-grep.sh` and `claude plugin validate .`.
