# CI/CD and release: versioning, GoReleaser, and the opt-out GitHub layer

This is step 5 of the workflow (the release half of it: `packaging-and-ops.md`,
`security-and-hardening.md`, and `dashboards-and-alerts.md` cover the rest).
Two layers, kept deliberately independent: a **versioning discipline** and a
**GoReleaser pipeline** that are always present and need no forge at all, and
a **GitHub Actions layer** that automates both but is an explicit opt-out via
`@@FORGE@@`. What this pipeline builds and packages is `project-scaffold.md`'s
and `makefile-and-tooling.md`'s subject; this document is about what happens
to that output at a tagged release, locally or in CI.

## Versioning is host-agnostic by construction

Four things hold for every generated exporter, whether or not it ever touches
a forge:

- **SemVer + git tags.** Releases are tags matching `v*`. Nothing about
  cutting one requires a hosted CI system; `git tag -a vX.Y.Z -m "..."; git
  push origin vX.Y.Z` is the whole mechanism.
- **`CHANGELOG.md`, Keep a Changelog format.** The scaffolded file's own
  header comment instructs writing every entry for the *operator*, not the
  code reviewer (a metric renamed or retyped, a flag whose default changed, a
  collector now enabled/disabled by default), with a before/after migration
  table for breaking changes and standard sub-sections (Added/Changed/
  Deprecated/Removed/Fixed/Security) included only when they have content.
- **Conventional Commits.** `feat(collector): add <name> collector`,
  `fix(<collector>): ...`, and so on. Enforced by convention and reviewed in
  the generated `CONTRIBUTING.md`/PR template, not by a commit-linting bot.
- **`version.*` ldflags.** `-X github.com/prometheus/common/version.Version=...`
  and its four siblings (Revision/Branch/BuildUser/BuildDate) are injected
  identically by `make build`, `make docker-build`/`-minimal`, and GoReleaser
  (below): three build paths, one version-metadata contract
  (`makefile-and-tooling.md` covers the first two).

None of this depends on GitHub, GitLab, or any other forge existing at all.
It's what makes a `--forge none` repository still versioned and changelogged,
not just buildable.

## `.goreleaser.yaml`: always emitted, runs locally

`.goreleaser.yaml` and `.goreleaser.dev.yaml` sit at the repository root
regardless of `@@FORGE@@`. Scaffolding's forge conditional touches exactly
one directory, `.github/` (below); GoReleaser's own config is untouched by it
either way. `goreleaser check` validates the file's schema without building
anything; `goreleaser build` compiles without publishing; and
`goreleaser release --clean --snapshot` runs the *entire* pipeline (archives,
checksums, SBOMs, Docker images, cosign signing) without ever publishing or
needing a token, confirmed against GoReleaser's own docs as the supported way
to validate a full release config locally or in a CI job that isn't cutting a
real release. The only host requirements for that full local run are a
container engine (for the Docker images) and `cosign`/`syft` on `PATH` (for
signing/SBOM); none of the three needs a forge.

### Builds, archives, checksums

```yaml
builds:
  - goos: [linux, windows, darwin]
    goarch: [amd64, "386", arm64]
    ldflags:
      - "-s -w"
      - "-X=github.com/prometheus/common/version.Version={{.Version}}"
      ...
    env:
      - CGO_ENABLED=0
```

Static binaries (`CGO_ENABLED=0`) across three OSes and three architectures,
stripped (`-s -w`), with the same five `version.*` ldflags keys the Makefile
uses, just filled from GoReleaser's own template functions
(`{{.Version}}`, `{{.Commit}}`, ...) instead of shelled-out `git` commands.
Archives bundle `README.md` and `LICENSE`; a `checksum` block produces one
`_checksums.txt` covering everything.

### Three SBOM/attestation artefacts, not one

```yaml
sboms:
  - artifacts: archive
    args: ["$artifact", "--output", "cyclonedx-json=$document"]
```

`sboms:` (the current, plural key, confirmed against GoReleaser's own
customization docs) runs `syft` against each release **archive**, producing a
CycloneDX-format SBOM per tarball/zip, automatically on every release. The
`args` override is not incidental: syft's own default output format inside
GoReleaser is SPDX, not CycloneDX. Without this override, a config that
*looks* like it standardizes on CycloneDX would silently ship SPDX instead.

GoReleaser **cannot** run that same `sboms:` mechanism against a container
image it builds: `artifacts:` only ever accepts archive-shaped values, a
documented upstream limitation, not a missing config knob. So the image's
own CycloneDX SBOM comes from a separate, maintainer-run step instead:
`make sbom-image` (`Makefile.tmpl`) runs `syft` directly against the
built/published image and writes `@@EXPORTER_NAME@@.image.cdx.json` on
demand, not wired into the release workflow itself. This is the image's
*canonical* SBOM: same tool, same CycloneDX format as the archives, just a
separate invocation because GoReleaser can't do it for you.

Separately again, each `dockers_v2` entry (below) sets its own
`sbom: "true"`, `docker buildx`'s own **native SPDX attestation**,
produced automatically on every release and embedded directly in the image
manifest, so registry-native tooling (`docker sbom`, `docker buildx
imagetools inspect`) can read it with no extra step. This is a real, useful,
always-there SBOM layer, but it is SPDX, not CycloneDX, and it is
**supplementary** to `make sbom-image`'s CycloneDX artefact, never a
substitute for it. Verifying "this release's SBOM story is uniform
CycloneDX" means checking archive (automatic) and image (`make sbom-image`,
on demand). The embedded SPDX attestation is a bonus third layer, not
either of those two.

### Signing: cosign, keyless, two independent targets

```yaml
signs:
  - cmd: cosign
    args: [sign-blob, "--bundle=${signature}", "${artifact}", "--yes"]
    artifacts: checksum
docker_signs:
  - cmd: cosign
    artifacts: manifests
    args: [sign, "--yes", "${artifact}@${digest}"]
```

`signs` produces a Sigstore bundle for the checksums file (so every binary's
integrity is verifiable offline via `cosign verify-blob`); `docker_signs`
(`artifacts: manifests`, a documented, valid value alongside `images`/`all`/
`none`) signs the multi-arch image manifests `dockers_v2` builds. Both are
**keyless**: the signing identity is the CI workflow itself, attested by its
own OIDC token via Sigstore/Fulcio, never a long-lived private key checked in
anywhere. Consumers verify with `cosign verify`/`cosign verify-blob` and a
certificate-identity regexp pointed at the release workflow, no public key
distribution required.

### `dockers_v2`: dual variant, gated floating tags, and a deliberate deviation

```yaml
dockers_v2:
  - id: standard
    dockerfile: Dockerfile
    extra_files: [go.mod, go.sum, cmd, internal]
    tags:
      - "{{ .Version }}"
      - '{{ if eq .Prerelease "" }}{{ .Major }}.{{ .Minor }}{{ end }}'
      - '{{ if eq .Prerelease "" }}{{ .Major }}{{ end }}'
      - '{{ if eq .Prerelease "" }}latest{{ end }}'
    platforms: [linux/amd64, linux/arm64]
  - id: minimal
    dockerfile: Dockerfile.minimal
    ...
```

Two entries, standard and minimal (distroless), each multi-arch
(`linux/amd64`+`linux/arm64`), published to GHCR only by default (the
ambient `GITHUB_TOKEN` a release workflow already has is enough; no extra
registry secret). Every floating tag (`X.Y`, `X`, `latest`, and their
`-minimal` counterparts) is gated on `Prerelease == ""`: an RC tag like
`v1.2.0-rc1` publishes *only* its own exact, immutable version tag, never
moving `latest` or `X.Y`, so nothing tracking the floating tags grabs a
release candidate by accident. `dockers_v2` itself is GoReleaser's
streamlined, buildx-native multi-platform builder (current as of GoReleaser
2.12+, confirmed via GoReleaser's own docs), collapsing what used to be
several `dockers` + `docker_manifests` entries into one per variant.

One explicit, commented deviation from GoReleaser's own recommended
`dockers_v2` usage is worth knowing before touching this file: the documented
default pattern is to `COPY` a binary GoReleaser already cross-compiled in its
`builds:` step: fast, since nothing recompiles inside the Docker build.
`Dockerfile`/`Dockerfile.minimal` here are instead self-contained multi-stage
builds that compile from source in their own build stage (so a bare
`docker build .` works immediately, with no GoReleaser run as a precondition:
the same Dockerfile `make docker-build` uses locally). `extra_files` stages
exactly the source tree those Dockerfiles `COPY` (`go.mod`, `go.sum`, `cmd`,
`internal`) into `dockers_v2`'s otherwise-empty build context, so the *same*
Dockerfile serves both paths, at the cost of a slower, QEMU-emulated build
for the non-native architecture during release, a cost the infrequent release
pipeline absorbs so the everyday local-debug loop (`makefile-and-tooling.md`'s
`docker-build`/`docker-run` targets) never has to.

### Changelog grouping

```yaml
changelog:
  use: github
  filters:
    exclude: ["^docs:", "^test:", "^ci:", "^chore:", ...]
  groups:
    - {title: "Features", regexp: "^.*feat[(\\w)]*:+.*$"}
    - {title: "Bug Fixes", regexp: "^.*fix[(\\w)]*:+.*$"}
```

The auto-generated GitHub release body groups commits by Conventional Commit
prefix and excludes the purely internal ones (docs/test/ci/chore/style/
refactor/perf/build) from the visible list. A maintainer-facing `CHANGELOG.md`
entry (above) still gets written by hand for anything operator-visible; this
block only shapes the release note GoReleaser auto-generates from commit
history, a separate, secondary surface.

### `.goreleaser.dev.yaml`: the fast snapshot

A second, minimal config: single-platform (`linux/amd64`), no Docker images,
no signing, no SBOM: just a binary and an archive, so CI (or a maintainer)
can confirm HEAD still builds and packages without waiting on the full
release matrix. Always run with `--snapshot`, so it never publishes or needs
a tag.

## The GitHub layer: opt-out via `@@FORGE@@`

Scaffolding's forge conditional is a single directory drop: when
`--forge none`, the entire `.github/` tree (every workflow, `dependabot.yml`,
`CODEOWNERS`, both issue templates and the PR template) disappears as one
atomic unit, not through per-file conditionals scattered across the template
tree. That mirror-layout choice (`.github/...` in the template tree already
sits at its final `.github/...` path) is what keeps this a one-line `rm -rf`
instead of a hardcoded per-file mapping to maintain.

### Six workflows, one shared discipline

| Workflow | Trigger | Job permissions beyond the read-only default |
|---|---|---|
| `ci.yml` | push to main/master, every PR | none: `make check` and `make race` both only need to read |
| `release.yml` | push of tag `v*` | `contents: write`, `id-token: write`, `packages: write` (release job only, after a `check` job re-runs the CI gate) |
| `dev-release.yml` | push to main/master | none: `--snapshot` never publishes |
| `govulncheck.yml` | push/PR + weekly | none |
| `trivy-scan.yml` | PR touching Dockerfiles/`go.mod`/`go.sum` + weekly | none: scans use `load: true`, never push |
| `scorecard.yml` | push to main/master, branch-protection changes, weekly | `security-events: write`, `id-token: write` (analysis job only) |

Every `uses:` step across all six is pinned to a full 40-character commit SHA
with a trailing `# vX.Y.Z` comment for human readability, for example
`actions/checkout@df4cb1c...  # v6.0.3`. This isn't a style preference:
GitHub's own security-hardening guidance states plainly that pinning to a
full-length commit SHA is the only way to use a third-party action as an
immutable reference, since a floating tag (even a major-version one like
`@v6`) can be repointed by whoever controls it. Every workflow also sets a
top-level `permissions: contents: read` and elevates only the specific job
that needs more: `release.yml`'s publish job is the widest grant in the set,
and even that is scoped to exactly the three permissions GoReleaser's signing,
publishing, and release-creation steps individually need, nothing broader.

A few of these workflows are deliberately redundant with each other in what
they trigger on, and that redundancy is intentional rather than accidental:
`govulncheck.yml` runs on every push/PR even though `make vuln` is already
part of `make check` in `ci.yml`, specifically so a security-specific check
stays independently visible in the Checks UI: its weekly schedule is the
part `ci.yml` can't provide on its own, catching a CVE disclosed after the
last commit with no new push required. The four weekly schedules across
these workflows are staggered by design (dependabot Monday 05:00 UTC, Trivy
06:00, govulncheck 07:00, Scorecard 07:30) rather than all firing at once.
`release.yml` itself re-runs the exact same `check` gate `ci.yml` does before
anything is published: a green PR at merge time doesn't guarantee the tagged
commit is still green, so it re-verifies rather than trusting a stale result.

### `dependabot.yml` and `CODEOWNERS`

Four `dependabot.yml` update streams (`gomod`, `github-actions`, `docker` at
the repo root, `docker` again for `scripts/docker/tools/`), all weekly on
Monday morning UTC with a 7-day cooldown before a brand-new release is even
proposed (long enough for a compromised release to get yanked upstream first)
and grouped updates for `golang.org/x/*` and `github.com/prometheus/*` so a
maintainer reviews one PR instead of several. `CODEOWNERS` sets a catch-all
owner plus explicit entries for the supply-chain-sensitive paths
(`.github/`, `Dockerfile*`, `.goreleaser*`, `scripts/docker/`) so ownership of
the release/signing/CI plumbing stays unambiguous even as other owners are
added to the catch-all later: this only wires the automatic review request;
enforcing it is a separate, opt-in branch-protection setting.

### Issue and PR templates

Three YAML issue forms (bug report, feature request, question) plus one
Markdown PR template whose checklist mirrors the generated `CONTRIBUTING.md`'s
Definition of Done almost line for line (`make check`, `make report` grade,
new behavior covered by a test, `docs/metrics.md`/`CHANGELOG.md` updated if
touched, manual validation against a real target), so a contributor opening
a PR is walked through the same bar a maintainer would otherwise have to spell
out by hand on every review.

## The local-release path when `--forge none`

Nothing about being releasable requires a forge. Only the *automation* of it
does. `goreleaser build`/`release --clean --snapshot` (above) prove the full
pipeline still works with zero forge involvement at all. A genuine, publishing
release still needs *somewhere* to publish to: `.goreleaser.yaml`'s
`release.github.owner: @@OWNER@@` block is always present (host-agnostic,
never forge-stripped: `@@OWNER@@` is the same generic attribution variable
used in `CODEOWNERS` and OCI image labels, not a GitHub-only concept), so a
maintainer who keeps it pointed at a real repository they own can still run
`goreleaser release --clean` with a token supplied by hand. A maintainer with
genuinely no forge at all instead distributes GoReleaser's `dist/` output
(binaries, checksums, signatures, SBOMs, and locally-built images pushed to
whatever registry they choose, or none) manually, exactly as
`docs/release-process.md`'s own "tag the final release" step documents for
this case. Either way, the tag, the CHANGELOG entry, and the artifacts all
exist before any forge automation would have touched them.

## Checklist

- [ ] A release is a `v*` git tag, a `CHANGELOG.md` entry written for the
      operator, and Conventional Commit history, true with or without a
      forge.
- [ ] `.goreleaser.yaml`/`.goreleaser.dev.yaml` are always present; only
      `.github/` is `@@FORGE@@`-conditional.
- [ ] `sboms:` explicitly overrides `args` to CycloneDX for archives; the
      container image's own CycloneDX SBOM comes from `make sbom-image`
      (GoReleaser cannot produce one); `dockers_v2`'s own `sbom:` field is a
      third, separate, supplementary SPDX attestation: all three are part
      of "the release has an SBOM", not just one.
- [ ] `signs`/`docker_signs` are keyless (OIDC/Sigstore): no private key
      ever checked into the repository.
- [ ] Every floating Docker tag (`latest`, `X`, `X.Y`, and their `-minimal`
      counterparts) is gated on `Prerelease == ""`; only the exact version
      tag ever publishes for a pre-release.
- [ ] Every `uses:` in every workflow is pinned to a full commit SHA, with a
      version comment for readability; `permissions:` defaults to
      `contents: read` at the top level and is elevated only per job, only to
      what that job needs.
- [ ] A `--forge none` repository is still versioned, changelogged, and
      releasable: via `goreleaser release --clean` (with a manually-supplied
      token, if `release.github` still points somewhere real) or by
      distributing `dist/`'s output by hand.
