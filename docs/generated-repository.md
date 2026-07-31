# What a scaffolded repository carries

Alongside the buildable Go exporter, four artifacts let a build survive a
compaction or a cleared context between sessions. The scaffold ships three
of them; `/prometheus-exporter:new-prometheus-exporter` writes the fourth,
the journal, straight after scaffolding.

## `docs/exporter-journal.md`

Committed. Eight frozen sections, each created by exactly one command.

It carries only the half no file in the repository can state about itself:
the collectors still to build, the cardinality budget as an intention, the
credential convention, the shared label vocabulary. Each command reconciles
it against the repository on entry and reports every correction rather than
trusting a stale claim.

It is tracked by git because an untracked file is destroyed by `git clean
-xdf`, and a journal that vanishes silently is worse than no journal,
because by then it is trusted.

## `samples/`

Gitignored except its own `README.md`. Raw material captured from the
monitored target, plus the target's own API documentation.

It is ignored on two independent grounds: captured output is not anonymized
and routinely carries real hostnames, tenants and credentials, and vendor
documentation carries redistribution terms the generated repository does not
get to decide.

Nothing moves out of it. A fixture under `internal/collector/testdata/` is a
trimmed, anonymized copy and the original stays, because one capture
commonly covers several collectors.

## `CLAUDE.md`

Written once at scaffold time. It states the four invariants fixed at
scaffold (namespace, target model, flavor, default port), where each kind of
state lives, and the one gate that decides whether a change is finished.

## A collector block in the exporter's own `README.md`

Between `<!-- BEGIN GENERATED COLLECTORS -->` and `<!-- END GENERATED
COLLECTORS -->`, regenerated in full from `docs/metrics.md` so the front
page lists every collector the exporter actually has.

## The journal never refuses anything

When it is absent or unreadable, every command still runs its full job end
to end, and only then offers to build one: from scratch when the file is
missing, behind a `.bak` when its headers are damaged, and nothing is
written before you answer. Exporters scaffolded before the journal keep
working, with no migration of any kind.

## What is tested, and what is not

The three scaffold-side artifacts above, `samples/`, `CLAUDE.md` and the
collector-block markers, are covered by the six-cell golden matrix, which
scaffolds and builds every cell.

The journal is not: it is written by
`/prometheus-exporter:new-prometheus-exporter` rather than by the scaffold
script, and no test in this repository touches it. Neither does anything
cover what the commands do with it afterwards, reading it on entry,
reconciling it against the repository, degrading when it is absent, deriving
a fixture from `samples/`, and regenerating that collector block. All of
that is prose executed by a model, no test in this repository exercises any
of it, and none is claimed to.
