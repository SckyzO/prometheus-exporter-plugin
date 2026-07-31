# Security Policy

This policy covers the `prometheus-exporter` Claude Code plugin itself: the
scaffolding engine (`scaffold.sh`), the commands/agents/skill that drive it,
and the templates it ships under `skills/prometheus-exporter/assets/`. It
does not cover exporters already generated from those templates — every
scaffolded repository ships its own `SECURITY.md`, tailored to what it
actually emits.

## Supported versions

| Version | Supported |
|---|---|
| 0.3.x (latest) | yes |
| Older releases | no |

Only the latest 0.3.x release receives security fixes.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on
[github.com/SckyzO/prometheus-exporter-plugin](https://github.com/SckyzO/prometheus-exporter-plugin):
the **Security** tab -> **Report a vulnerability**. Do not open a public
issue or pull request for a suspected vulnerability.

Include, where possible: the plugin version, the command or template
involved, and steps to reproduce. Reports are acknowledged and triaged on a
best-effort basis.

## Scope

In scope:

- The scaffolding engine (`skills/prometheus-exporter/assets/scaffold.sh`)
  and the `commands/`, `agents/`, and `skills/` that invoke it.
- The templates under `skills/prometheus-exporter/assets/` — a defect that
  ships an insecure default into every generated exporter (an
  unauthenticated bind with no warning, a missing hardening flag, a stale
  dependency pin) is a real vulnerability in this plugin, not only in its
  output.
- The auxiliary `bash` backbones outside `assets/`
  (`skills/prometheus-exporter/scripts/probe-target.sh`,
  `skills/prometheus-exporter/scripts/generate-dashboard.sh`) that never
  ship inside a scaffolded exporter but do run against a user's own inputs
  (a live target, a `docs/metrics.md` file).

Out of scope:

- Vulnerabilities in an already-scaffolded exporter's own dependencies —
  report those against that exporter's own repository. Every scaffolded
  exporter carries its own `govulncheck` (`make vuln`), Dependabot
  configuration, and, with `--forge github`, a Trivy scan of published
  images — its supply chain is gated independently of this plugin.
- Vulnerabilities in upstream tooling this plugin depends on at dev time
  (Docker/Podman, `jq`, GoReleaser) — report those upstream.

## Notes

The live-target probe (`/prometheus-exporter:design-exporter`, discovery
ladder rung 4) is the one place this plugin itself makes outbound requests
or runs commands against a user-supplied target. It is opt-in and
consent-gated — the exact command is shown and confirmed before it runs —
and every capture passes through a deterministic secret-redaction backbone
before reaching an architecture brief.
