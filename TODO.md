# TODO

This file is a coarse-grained pointer, not the backlog itself. The source of
truth for implementation work is the plan:

**[`docs/plans/2026-07-03-prometheus-exporter-plugin-v0.1.md`](docs/plans/2026-07-03-prometheus-exporter-plugin-v0.1.md)**

That plan breaks the v0.1 milestone (see [`ROADMAP.md`](ROADMAP.md)) into 10
implementation milestones and 23 tasks, each with step-by-step instructions,
file lists, and a provable exit condition. Update checkboxes *there* as
tasks complete; this file only tracks milestone-level progress so a
contributor can see where the build stands without reading all 23 tasks.

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
      `/new-prometheus-exporter`, `/add-collector`, and `exporter-reviewer`.
- [x] **Milestone 8: The skill** (Tasks 18-21). `SKILL.md` router and the
      10 reference documents.
- [ ] **Milestone 9: Plugin CI, golden gate, dogfooding** (Tasks 22-23).
      The full golden matrix, this plugin's own CI, and
      `docs/design/re-sync.md` are done, and the `[0.1.0]` entry is in
      `CHANGELOG.md`; the `v0.1.0` tag and release are a maintainer action
      taken separately from this checklist.

## After v0.1

v0.2 and v1.0 scope lives in [`ROADMAP.md`](ROADMAP.md); no task breakdown
exists for them yet.
