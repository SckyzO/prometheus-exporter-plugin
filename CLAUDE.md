# CLAUDE.md

Guidance for contributing to this plugin's own development: the
`prometheus-exporter` Claude Code plugin, maintained by SckyzO. This file
governs the plugin repository itself, not the exporters it scaffolds (each
generated exporter ships its own `CONTRIBUTING.md`).

These rules encode universal OSS engineering principles, de-personalized from
any individual's working preferences. The plugin must depend on no external
`CLAUDE.md` or personal profile: once installed by a third party, it has to
behave identically for them as it does here, with no hidden assumption about
the maintainer's own setup.

## Commit convention

Conventional Commits with a scope naming the affected area, e.g.
`feat(scaffold): …`, `fix(templates): …`, `docs(plugin): …`,
`feat(command): …`, `feat(agent): …`.

## Language

English for every shipped artifact: `SKILL.md`, `references/`, `assets/`
templates, `commands/`, `agents/`, and the root `README.md`/`CLAUDE.md`.
`docs/design/` and `docs/plans/` are the maintainer's own working and
planning history and may use another language: they are never loaded by the
plugin at runtime, so they carry no obligation to be generic or translated.

## No dead code

Do not merge a reference, template, command, or agent that nothing invokes,
or that duplicates something that already exists. Every change either fixes
a defect, adds an active and wired-in capability, or replaces existing
content. A scaffolding plugin is only as trustworthy as the fraction of its
templates that are actually exercised by the golden tests. Unused
scaffolding erodes that trust and misleads future contributors.

## Two-phase rule for risky refactors

For any change that reshapes a template's contract, a command's inputs, or
the scaffold's variable/flavor seam: land the new mechanism first, with the
old one kept as the working default, so that in-flight work and previously
scaffolded exporters keep working. Remove the old mechanism only in a later,
separate change, once the new one has proven itself. Do not collapse both
steps into a single commit for anything load-bearing: the templating engine,
the collector seam, the registry contract.

## The [G]/[S] discipline

Every reference and template keeps only the **[G]eneric** shape: the part
that holds for any exporter, regardless of what it monitors. Anything
**[S]pecific**, such as a data source, a metric prefix, a parsing format, or
an endpoint path, becomes a `@@VAR@@` substitution variable or an explicit,
clearly-marked fill-in hole. Never bake a concrete, non-generic value into a
shipped template.

## Testing this plugin

Before committing a change to a command, agent, skill, or template, confirm:

- `claude plugin validate .`: validates the manifest and marketplace.
- `claude --plugin-dir .`: loads the plugin from the working tree for a
  manual check.
- `/reload-plugins`: reloads a running session without restarting it, for
  fast iteration.

Changes under `skills/prometheus-exporter/assets/` additionally require the
scaffold and golden smoke tests in `test/` to pass. Evidence before
assertion: a template change isn't done until the test that exercises it has
actually been run and shown green.

## Zero-source-mention rule

The taught knowledge and templates stand on official Prometheus authority
(`prometheus.io`), never on "distilled from <a specific project>". So no
shipped file, including this one, may name the production reference exporter
this plugin's patterns were derived from. Before every commit, run
`test/zero-source-grep.sh` — the canonical, runnable implementation of
this gate — and confirm it passes; this is a hard gate.

The scan excludes `docs/` (the design and planning history of how the
plugin came to be, never loaded by the plugin at runtime), `.git/` and
`.superpowers/` (version control and scratch state, not shipped
artifacts), and `test/` (the harness legitimately contains the detector
word as its own search pattern, which is why it excludes itself from the
walk). This repository's own root `.github/` is excluded for the same
reason: its CI workflow calls the harness and would otherwise have to
spell out, in its own YAML, the exact word the harness is checking for.
That exemption does **not** extend to the taught templates shipped under
`skills/prometheus-exporter/assets/.github/` — those are fully scanned,
because a leak there would ship inside every generated exporter, which is
a real defect, not a self-reference artifact. See
`test/zero-source-grep.sh` for the exact exclude set and how it tells the
two `.github/` directories apart.

Scaffold templates always attribute the generated exporter to `@@OWNER@@` —
its own creator, the third party who runs `/new-prometheus-exporter` — never
a hardcoded real handle. That is why a real maintainer handle never appears
under `assets/`.

As a light hygiene check (not a hard gate), the maintainer's handle should
also stay absent from `skills/`, `commands/`, and `agents/`: generic
knowledge has no reason to credit anyone. This repository's own credited
maintainer, named above, is a separate concern — it legitimately appears in
this file, the `.claude-plugin/` manifests, and README. (The stock
Apache-2.0 `LICENSE` keeps its bracketed `[name of copyright owner]`
placeholder in the "how to apply" appendix, per Apache convention, so the
handle does not appear there.) See `docs/design/re-sync.md` for the
concrete strings and mapping.

## Re-sync rule

> Re-derive templates from a production reference exporter when practices
> evolve. Never name a specific source in shipped artifacts: the concrete
> source-to-template mapping lives only in `docs/design/re-sync.md`.

When the patterns taught under `skills/prometheus-exporter/` fall behind
real-world practice, refresh them from a (new or updated) reference exporter,
reapplying the same de-personalization and [G]/[S] split used originally,
and record what changed and why in `docs/design/re-sync.md`, not here and
not in any other shipped file.
