# Commands

The four commands and the review subagent this plugin adds. They are meant to
be run in order the first time, then `/add-collector` on repeat for the rest
of the exporter's life.

## `/design-exporter`

The architecture-design phase, run before any code is written. It grounds the
design in a local API spec, a docs folder or URL, context7, or a live
instance of the target (opt-in, with secret redaction), then writes a
reviewable design brief.

The phase settles the data source (a REST/API, then gRPC, then a CLI wrapper
as a last resort; a database-only target is out of scope), which of the
[three target models](target-models.md) fits, the collector decomposition,
and a cardinality budget.

The brief is the journal before the repository exists:
`/new-prometheus-exporter` moves it in and retitles it. See
[the generated repository](generated-repository.md).

## `/new-prometheus-exporter`

Scaffolds a complete, buildable exporter repository with your choice of HTTP
or CLI I/O flavor, target model, and license. It includes a working example
collector with its full test triad, a container-first Makefile, and
host-agnostic release tooling (GoReleaser, with an optional GitHub Actions
layer).

## `/add-collector`

Adds a new collector plus its test triad to an existing scaffolded exporter,
the action repeated most often over an exporter's life.

On a `single` scaffold, `--variant background` refreshes the collector's
cache in a background goroutine so a slow backend never blocks a scrape;
`multi` refuses that variant, since a collector built per probe is discarded
when the probe returns, and `multi-instance` is the mirror case, where every
collector is a background poller already and the synchronous variant is
refused instead.

It derives the collector's fixture from a capture under `samples/` when one
covers the endpoint or command, ticks the collector off the journal with the
cardinality it actually observed, and regenerates the collector block in the
exporter's own `README.md` from `docs/metrics.md`.

## `/generate-dashboard`

Generates one or more business Grafana dashboards from a scaffolded
exporter's own `docs/metrics.md`, on top of a deterministic backbone that
emits exportable Grafana JSON. It complements the health dashboard every
scaffold already ships and never touches it, and records each dashboard's
audience and method in the journal.

## `exporter-reviewer`

A subagent that audits an exporter against Prometheus naming/type/label
conventions, the generic/specific template discipline, cardinality limits,
per-collector test coverage, and documentation truthfulness.

## Shipped with every scaffold

- **`monitoring/`**: health alerting rules for Prometheus and a health
  dashboard for Grafana, generated with every scaffold.
- **`make docs-check`**: a generated test wired into every scaffolded
  exporter that fails the build if its metrics documentation names a metric
  or label the code doesn't actually emit.
