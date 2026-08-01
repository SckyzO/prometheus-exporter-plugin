# TODO

This file is a coarse-grained pointer, not the backlog itself. The v0.1
milestone's task-by-task breakdown lived in a since-pruned implementation
plan; see
[`docs/design/2026-07-02-prometheus-exporter-plugin-design.md`](docs/design/2026-07-02-prometheus-exporter-plugin-design.md)
for the architecture it implemented. That plan broke the v0.1 milestone (see
[`ROADMAP.md`](ROADMAP.md)) into 10 implementation milestones and 23 tasks;
all of them are complete, tracked below at milestone granularity.

## Milestones toward v0.1

- [x] **Milestone 0: Plugin skeleton** (Tasks 1-2). Manifest,
      self-marketplace, and root governance files. Provable with
      `claude plugin validate .`.
- [x] **Milestone 1: Templating engine** (Task 3). `scaffold.sh` and its
      unit test. Provable with a green scaffold unit test.
- [x] **Milestone 2: Minimal HTTP exporter that builds** (Tasks 4-7). The
      flavor-agnostic core plus the HTTP flavor and its Makefile. Provable
      with a green golden HTTP build.
- [x] **Milestone 3: CLI flavor** (Tasks 8-9). Provable with a green golden
      CLI build.
- [x] **Milestone 4: Docs discipline + non-lying metrics check** (Tasks
      10-11). Templated operator docs and `make docs-check`.
- [x] **Milestone 5: Observability shipped with the exporter** (Task 12).
      Health and business alerts, recording rules, and the health
      dashboard.
- [x] **Milestone 6: Packaging + host-agnostic release** (Tasks 13-14).
      Docker, compose, systemd, GoReleaser, the opt-out GitHub layer, and
      the license set.
- [x] **Milestone 7: Executable components** (Tasks 15-17).
      `/prometheus-exporter:new-prometheus-exporter`,
      `/prometheus-exporter:add-collector`, and `exporter-reviewer`.
- [x] **Milestone 8: The skill** (Tasks 18-21). `SKILL.md` router and the
      10 reference documents.
- [x] **Milestone 9: Plugin CI, golden gate, dogfooding** (Tasks 22-23).
      The full golden matrix, this plugin's own CI, and
      `docs/design/re-sync.md` are done; the `[0.1.0]` entry landed in
      `CHANGELOG.md` and the `v0.1.0` tag and release have shipped.

## After v0.1

v0.2.0 and v0.3.0 have since shipped — see [`CHANGELOG.md`](CHANGELOG.md)
for what landed in each and [`ROADMAP.md`](ROADMAP.md) for what's still
ahead toward v1.0.
