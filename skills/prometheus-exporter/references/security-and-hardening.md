# Security and hardening: no secrets in metrics, conservative defaults, optional TLS

This is step 5 of the workflow: the security posture a scaffolded exporter
ships with by default, and the levers it documents but leaves off
(`packaging-and-ops.md` covers the container/systemd hardening that
complements this; `cicd-and-release.md` covers the supply-chain signing/SBOM
pipeline this document points to rather than re-explains). Everything below
is [G]eneric: it holds for any Prometheus exporter's security posture,
regardless of what target it monitors, not a preference tied to one
deployment. Matches `SECURITY.md.tmpl` and the exporter-toolkit wiring in
`cmd/@@EXPORTER_NAME@@/main.go.tmpl` as shipped; read those alongside this
document.

## Rule 1: never a secret in a metric or a label

`/metrics` is public and unauthenticated **by default**: no
`--web.config.file` is required to run this exporter, and most deployments
never set one. That single fact is the reason this rule exists at all: a
credential that reaches a metric value, a label value, or even a help
string is exposed to anything that can reach the port, with no
authentication step in between.

No collector may place a password, API key, token, certificate or private
key *path*, connection string, or passphrase into:

- a metric's numeric value (encoding a secret as a number is still exposure);
- a label value (a target URL or command argument that happens to embed
  credentials, echoed back through a label, is exposure just as much as a
  literal password would be);
- a help string (the descriptive text passed to `prometheus.NewDesc`/
  `*Opts.Help`, easy to forget precisely because it looks like
  documentation, not data).

**Filter at parse time, not at emission time.** The pure `parse<Name>`
step (`collector-pattern.md`) is where a field that could carry a credential
gets dropped or redacted: before it ever reaches a `prometheus.Desc`, not
as an afterthought once a `MustNewConstMetric` call already has it in hand.
The same discipline applies to whatever builds an outbound request or
command: a `Client`/`Execute` call site that reads a credential-bearing flag
to *reach* the target must never turn around and *report* that value back
through a label.

### Why this needs a dedicated audit pass, not just a linter

`make lint`'s `gosec` pass (`.golangci.yml`) catches unsafe *code shapes*
(weak crypto, unsafe file inclusion, a missing request timeout), not "this
label value happens to be a credential," which is a semantic judgment about
what a piece of data *means*, not a pattern gosec's static rules can
recognize. That gap is exactly why `exporter-reviewer`'s Step 8 is dedicated
to this: grep collector source and `docs/metrics.md` for anything that could
carry a credential, read every match before reporting it
(a variable literally named `token` is very often an unrelated identifier,
not a secret), and treat a confirmed hit as high-severity regardless of how
unlikely the exposure seems. Static analysis narrows where to look; it does
not replace looking.

## Rule 2: conservatism on defaults

Don't harden an existing default unless a critical vulnerability, exploitable
without any action from the operator, justifies it. Any change to a
security-relevant default (enabling authentication that used to be off,
changing what a flag defaults to) is a **breaking change**, documented as
one in `CHANGELOG.md` with the same operator-impact framing every other
breaking change gets (`docs-and-governance.md`'s CHANGELOG convention),
never slipped into a patch release as an unannounced improvement.

Concretely, in this scaffold: `/metrics` ships unauthenticated by default,
and stays that way. TLS and Basic Auth are available (Rule 4, below) but
never forced on. `POST /-/reload` (`multi` and `multi-instance` builds,
`internal/reload`) follows the identical pattern: a mutating endpoint gated
behind `--web.enable-lifecycle`, default `false`, so a build that never sets
the flag gets no new mutating surface at all; `SIGHUP` needs no flag,
because sending it already requires being on the machine. `SECURITY.md.tmpl`
states the reasoning plainly: *"the
exporter itself does not force a particular hardening posture by default:
the right one depends on your network, and an unannounced change to a
security-relevant default would be a breaking change."* The right posture
for an exporter reachable only from a private, already-firewalled scrape
network is not the right posture for one reachable from anywhere. This
scaffold cannot know which situation a given deployment is in, so it
documents both the risk and the opt-in fix (Rule 4) instead of guessing.

## Rule 3: warn at startup when running exposed

A fresh, unmodified exporter is already more exposed than it looks: the
default `--web.listen-address` is `:@@DEFAULT_PORT@@` (Go's `net/http`
binds an address with no host part to *every* interface, not just loopback),
so the moment anything else on the network can reach that port, an
operator who never touched `--web.listen-address` at all is already running
"exposed" in the sense this rule cares about.

The principle: an exporter should log a **visible, non-fatal warning** at
startup when it detects it is bound to a non-loopback address with no
`--web.config.file` set: never refuse to start, never downgrade to a
fail-closed default (Rule 2 already rules that out), just make the operator
aware of the posture they're running with instead of leaving it silent. This
is the same category of guidance as the "unpinned tool versions" banner
`makefile-and-tooling.md`'s native fallback prints: warn plainly, then keep
going, so the choice stays the operator's and not this scaffold's to make
for them.

**Shipped behavior:** `cmd/@@EXPORTER_NAME@@/main.go.tmpl` implements this
check, right after `kingpin.Parse()` and logger construction and before
`web.ListenAndServe` starts the server. `warnIfExposedAndUnauthenticated`
walks every `--web.listen-address` value and calls `isLoopbackHost` on each
one's host part: empty (a bare `:@@DEFAULT_PORT@@` binds every interface),
anything outside `127.0.0.0/8`/`::1`, and anything other than the literal
string `localhost` all count as non-loopback. If at least one configured
address is non-loopback and `--web.config.file` is unset, it logs a single
`log.Warn(...)` naming the offending address and pointing at
`--web.config.file` for TLS/Basic Auth, then startup continues exactly as
before. Nothing here refuses to start or changes a default; it only makes
an already-exposed posture visible, per Rule 2.

## Rule 4: optional hardening via `--web.config.file`

TLS and Basic Authentication are available, opt-in, through
`prometheus/exporter-toolkit`, the same library Prometheus's own server
uses for its web configuration:

```go
toolkitFlags = webflag.AddFlags(kingpin.CommandLine, ":@@DEFAULT_PORT@@")
...
web.ListenAndServe(server, toolkitFlags, log.Logger)
```

`webflag.AddFlags` declares `--web.config.file` (default: none, see
`docs/configuration.md`'s flag table); `web.ListenAndServe` is what makes it
meaningful, serving the exporter over HTTPS and/or behind a password from a
YAML file in [Prometheus's own TLS/Basic Auth configuration
format](https://prometheus.io/docs/prometheus/latest/configuration/https/),
with zero application code of this exporter's own involved. The systemd
unit's commented `ExecStart` example (`packaging-and-ops.md`) and
`docs/configuration.md` both point at the same flag; the point is that it is
**documented, not imposed**: an operator who needs it turns it on
explicitly, on their own schedule.

## Rule 5: per-target credentials fail closed, never silently unauthenticated

Two target models let credentials vary by target instead of one
`http_client_config:` section covering every request: `multi`'s `modules:`
section, selected per probe with `&module=`, and `multi-instance`'s
per-instance `module:` reference, resolved once at boot. In both, a
module's credentials live only in the configuration file, never inline on a
request or on an instance's own entry, and are turned into an
`*http.Client` once, at boot, never rebuilt per scrape.

The failure mode this closes is a target that was meant to carry
credentials ending up probed, or watched, without them: a typo in
`&module=`, two modules both claiming the same probe, a `default` module
that doesn't exist. Neither model lets that happen quietly. `multi` refuses
the individual probe with `400` when it cannot resolve credentials
unambiguously against a configuration that declares some, rather than
returning `200` with metrics nobody questions
(`internal/probe/probe.go`'s `selectFactories`); `multi-instance` refuses to
start at all when an instance's `module:` reference doesn't resolve
(`internal/config/config.go`'s `ResolveInstances`), the same fail-fast
posture it already applies to every other malformed instance. Single-target
builds have nothing to resolve here: a `modules:` section is refused at boot
as meaningless for one fixed target.

## What `make lint`'s `gosec` pass covers here, concretely

Two gosec-caught patterns are worth knowing by name, because they're the
part of "hardening" that *is* mechanically enforced, unlike Rules 1 and 3
above:

- **G112 (Slowloris).** `cmd/@@EXPORTER_NAME@@/main.go.tmpl`'s
  `http.Server` sets `ReadHeaderTimeout: 5 * time.Second` specifically to
  satisfy this check: a server with no read-header timeout can be tied up
  indefinitely by a client that sends headers one byte at a time.
- **G304 (file path from a variable).** Excluded in `.golangci.yml`,
  deliberately, but only for test files: a test helper reading a
  `testdata/` fixture by a variable path is expected; the same pattern in
  non-test collector code is not excluded and still flags.

Neither of these is a substitute for Rule 1's dedicated audit pass: they
catch code *shapes*, not the meaning of a particular label value.

## Supply-chain pointers

The rest of "is this exporter's supply chain trustworthy" lives in the two
documents this one doesn't duplicate:

- **`cicd-and-release.md`**: keyless `cosign` signing of both binaries
  (`signs`, via a Sigstore bundle over the checksums file) and container
  image manifests (`docker_signs`), a CycloneDX SBOM per release archive, a
  CycloneDX SBOM for the container image via `make sbom-image`, plus a
  supplementary buildx-native SPDX attestation embedded in the image
  manifest, and the weekly `govulncheck`/Trivy/Scorecard workflows when the
  GitHub layer is in use.
- **`packaging-and-ops.md`**: non-root by default on both image variants,
  with the minimal variant additionally removing the shell and package
  manager a compromised process could otherwise pivot from.
- **Local, always-available prevention tools** (not part of `make check`,
  `makefile-and-tooling.md` explains why): `make secrets` (a `gitleaks` scan
  of the working tree) and `make osv` (a dependency scan against the OSV
  database), both network-dependent and meant to run before a commit or on
  a schedule, not on every contributor's disconnected machine.

## Checklist

- [ ] No collector's parser lets a password, token, API key, certificate/key
      path, connection string, or passphrase reach a metric value, a label
      value, or a help string: filtered out in `parse<Name>`, not patched
      up after the fact.
- [ ] An outbound `Client`/`Execute` call site never echoes a
      credential-bearing flag's value back through a label.
- [ ] No existing default was hardened without a critical,
      no-user-action-required vulnerability behind the change, and if one
      was, it's documented in `CHANGELOG.md` as a breaking change.
- [ ] `/metrics` stays unauthenticated by default; `--web.config.file`
      (TLS/Basic Auth) stays opt-in, documented in `docs/configuration.md`,
      never forced.
- [ ] On a target model that supports per-target credentials (`multi`,
      `multi-instance`), an unresolved module reference refuses the probe or
      the boot rather than falling back to an unauthenticated request.
- [ ] Anything that could carry a secret gets a dedicated read-the-match
      audit pass (`exporter-reviewer`'s Step 8): gosec's static rules are
      not expected to catch this class of finding on their own.
- [ ] `make secrets`/`make osv` run before a release, even though neither is
      part of the everyday `make check` gate.
