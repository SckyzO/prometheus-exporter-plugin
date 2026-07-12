# The Makefile and its tooling: container-first, target by target

This is step 4 of the workflow: hardening. Every quality gate this scaffold
ships (compiling, testing, linting, scanning for vulnerabilities, grading the
result) runs inside one pinned container image by default. This document
explains why the Makefile is built the way it is, and what to check on any
Makefile shaped like it; `Makefile.tmpl` and the image it drives
(`scripts/docker/tools/Dockerfile.tmpl`) are the actual artifact. Read this
alongside them, not instead of them. What this tooling builds and tests is
`project-scaffold.md`'s subject; what happens at a tagged release is
`cicd-and-release.md`'s: a related but distinct pipeline that reuses the same
version-metadata convention (below) without reusing this container. Keeping
`docs/metrics.md` itself truthful (`docs-check`, below) and the rest of the
Definition of Done is `docs-and-governance.md`'s deeper subject; this
document only covers the target that enforces it.

## The tools image

`scripts/docker/tools/Dockerfile` is a single image bundling everything the
Makefile's quality-gate targets need: a **pinned** Go toolchain
(`golang:1.26.4-alpine`, pinned by tag *and* digest) plus a set of
intentionally **floating** auxiliary tools. The Go-based linters and scanners
(golangci-lint, govulncheck, actionlint, gitleaks, osv-scanner, gocyclo,
misspell, ineffassign, deadcode) are installed via `go install ...@latest`
to stay current; zizmor (static analysis for GitHub Actions) is installed via
the Alpine package manager (`apk`) and is not pinned. The split is deliberate:
the Go toolchain is pinned for reproducible builds (the same source always
produces the same binary), while the linters and scanners are kept current on
every image rebuild so contributors always run the newest checks against the
newest vulnerability data: pinning a security scanner would mean shipping
stale CVE coverage on purpose.

A `git config --system --add safe.directory '*'` line in that Dockerfile is
worth understanding on its own. This image always runs as root against a
bind-mounted repository owned by whatever host UID invoked `make`
(`-v $(CURDIR):/repo`), and Git's own "dubious ownership" hardening
(CVE-2022-24765) refuses by default to operate on a repository owned by a
different user. That check exists to stop one local user trusting a
repository planted by another local user or process; it doesn't apply to a
container that only ever touches the single repository its caller explicitly
bind-mounted. Disabling it here isn't only for `actionlint` (which
independently requires running inside a git repository to find its own
project root): Go's own `-buildvcs` auto-detection shells out to
`git status --porcelain` on every `go build`/`go test` once the module sits
under any `.git` tree, so without this line a bare `git init`, the very
first thing a freshly scaffolded repository gets, would break plain
`make build` too, not only `actionlint`.

## Engine detection and the `IN_TOOLS` indirection

```make
CONTAINER_ENGINE ?= $(shell command -v docker >/dev/null 2>&1 && echo docker || (command -v podman >/dev/null 2>&1 && echo podman || echo none))
CONTAINER_ENGINE := $(CONTAINER_ENGINE)
NATIVE ?= 0
```

Detection tries `docker`, falls back to `podman`, and lands on `none` if
neither is on `PATH`. The second line (reassigning `CONTAINER_ENGINE` to
itself) matters more than it looks: without it, `CONTAINER_ENGINE` stays a
recursively-expanded Make variable, so its `$(shell ...)` probe would re-run
on *every* later reference (the `ifeq` below, every `docker-build`/`docker-run`
recipe, `IN_TOOLS` itself) instead of once. Harmless in practice, since
detection is deterministic within a single invocation, but it's the kind of
detail worth getting right by construction rather than by luck.

```make
ifeq ($(NATIVE),1)
RUN_NATIVE := 1
else ifeq ($(CONTAINER_ENGINE),none)
RUN_NATIVE := 1
else
RUN_NATIVE := 0
endif

ifeq ($(RUN_NATIVE),1)
IN_TOOLS := sh
else
IN_TOOLS := $(CONTAINER_ENGINE) run --rm -v "$(CURDIR):/repo" -w /repo $(TOOLS_IMG)
endif
```

`NATIVE=1` forces the host path even when an engine is available (useful for
debugging a container-specific failure); no engine detected forces the same
path automatically. Either way, every tooling target calls
`$(IN_TOOLS) -c '<command>'`: the identical call-site shape whichever path is
active, because the container image's own `ENTRYPOINT ["/bin/bash"]` turns
`-c '<command>'` into `bash -c '<command>'`, mirroring plain `sh -c '<command>'`
on the native path. A `native-warning` prerequisite prints an "unpinned tool
versions" banner exactly once per `make` invocation whenever `RUN_NATIVE=1`
(whether that's because no engine was found or because `NATIVE=1` forced it),
so nobody mistakes a host run for a reproducible one.

## Target list

| Category | Target | What it does |
|---|---|---|
| Build | `build` | Compiles `bin/@@EXPORTER_NAME@@`, containerized |
| | `clean` | Removes `bin/` |
| Test | `test` | Full unit-test suite |
| | `race` | Same, with the race detector (needs `CGO_ENABLED=1`; the tools image bundles a C toolchain for it) |
| Quality | `vet` | `go vet ./...` |
| | `lint` | `golangci-lint run ./...`: same tool and config as CI |
| | `vuln` | `govulncheck ./...`: reachable-vulnerability, call-graph based |
| | `check` | `vet` + `lint` + `test` + `vuln` + `actionlint` + `zizmor` + `deadcode` + `docs-check`: the pre-merge/pre-release gate, mirrors CI exactly |
| | `report` | Offline goreportcard-equivalent grade; fails below `B` |
| | `report-deps` | Tabular dependency status (direct/indirect, patch/minor/major); read-only, never runs `go get` |
| Security | `actionlint` | Lints `.github/workflows/`; skips gracefully if there is none |
| | `zizmor` | Static security analysis for GitHub Actions; same skip behavior |
| | `secrets` | `gitleaks` secret scan over the working tree |
| | `osv` | Dependency scan against the OSV database |
| | `deadcode` | Fails if any unreachable Go function is found |
| | `docs-check` | `docs/metrics.md` documents no metric/label the code doesn't emit |
| Docker | `docker-build[-minimal]` | Builds a local debug image (standard / distroless) |
| | `docker-run[-minimal]` | Starts the matching compose stack |

`secrets` and `osv` are deliberately **not** part of `check`: both need
network access (gitleaks' own ruleset, the live OSV database), so folding
them into the gate every contributor runs on every commit would make `check`
flaky on a disconnected machine. They're prevention tools to run before
committing or on a schedule, not a build gate: same reasoning as keeping
`race` a separate target rather than adding it to `check` (it's slower and
answers a different question than the rest of the gate).

The Docker targets have **no** native fallback: building or running a
container image inherently needs a container engine, so all four fail fast
with a clear message when `CONTAINER_ENGINE` is `none`, regardless of
`NATIVE`. They're for local debugging outside the release pipeline; release
images are GoReleaser's job (`cicd-and-release.md`), built from the same
`Dockerfile`/`Dockerfile.minimal` but through a different mechanism.

### Two guards worth understanding, not just copying

`actionlint` and `zizmor` both skip (rather than fail) when
`.github/workflows/` doesn't exist, the normal state of a repository
scaffolded with `--forge none`. That's one guard. `actionlint` additionally
requires running inside a git repository at all: a *different*
"no project was found" failure, from its own project-root detection, that
fires even with `.github/workflows/` present, on a freshly scaffolded
repository that hasn't run `git init` yet. Conflating the two into a single
skip condition would silently swallow the second, real failure mode behind
the first's message; the target guards each with its own check and its own
distinct message instead. The general lesson: when a tool can fail the same
surface-level way for two structurally different reasons, one "skip if X"
guard covering only one of them will eventually misreport the other, worth
checking explicitly, not assumed, whenever a new tool joins a gate like this
one.

`docs-check` runs with `-count=1`, which disables `go test`'s result cache.
Its real input, `docs/metrics.md`, is a plain file the Go toolchain has no
reason to track as a build dependency: without `-count=1`, a second run
could serve a stale cached PASS after only that file changed, exactly the
failure mode a doc/code drift-detector must never have.

## Version metadata: one set of ldflags, three build paths

```make
LDFLAGS = \
	-X 'github.com/prometheus/common/version.Version=$(VERSION)' \
	-X 'github.com/prometheus/common/version.Revision=$(REVISION)' \
	-X 'github.com/prometheus/common/version.Branch=$(BRANCH)' \
	-X 'github.com/prometheus/common/version.BuildUser=$(BUILD_USER)' \
	-X 'github.com/prometheus/common/version.BuildDate=$(BUILD_DATE)'
```

`VERSION`/`REVISION`/`BRANCH`/`BUILD_USER`/`BUILD_DATE` are all derived from
`git` at build time (`git describe`, `git rev-parse`, `git config`, `date`)
and injected into `prometheus/common/version`, the same package every
Prometheus exporter uses to back `--version` and the `_build_info` metric.
`make docker-build`/`-minimal` inject the identical five keys via
`--build-arg`, and `.goreleaser.yaml` injects them again via its own template
functions (`cicd-and-release.md`), three different build paths, one set of
keys, so `--version` reports the same shape no matter which one produced the
binary.

## `.golangci.yml`

golangci-lint v2, `linters.default: none` plus an explicit `enable:` list:
opting in to every linter by name rather than trusting whatever a future
version's bundled defaults happen to be, so a golangci-lint upgrade can't
silently change what this repository's gate checks for. Grouped by intent in
the file's own comments: correctness (`errcheck`, `govet`, `staticcheck`,
`ineffassign`), security (`gosec`), robustness (`bodyclose`, `noctx`), and
style (`revive`, `gocritic`, `misspell`, `whitespace`). Test files relax
`errcheck`/`gosec` (an unchecked `io.ReadAll` error reading a test fixture
isn't the same risk as one in production code), and `goimports.local-prefixes`
is set to `@@MODULE_PATH@@` so this module's own imports group separately
from stdlib and third-party ones.

## `report` / `report-deps`: two read-only scripts, not gates

`scripts/docker/tools/goreport.sh` reproduces the six checks
goreportcard.com performs: `gofmt -s`, `go vet`, `gocyclo` (functions over
complexity 15), `ineffassign`, `misspell`, and LICENSE-file presence, scores
each as a percentage of files passing, and assigns an overall letter grade
(`A+` at 95%, down through `B` at 80%, `F` below 60%), exiting non-zero below
`B`. `scripts/docker/tools/deps-report.sh` lists every direct dependency (from
`go.mod`) plus any indirect one with an upgrade available, classifying each
pending bump as patch/minor/major. It's read-only: it never runs `go get`
itself; that's left to a maintainer running `go get -u ./... && go mod tidy`
deliberately, not to a script.

## Four things worth checking on any container-first Makefile

A Makefile that claims "a container engine is the only requirement" is making
a specific, checkable promise. These four are where that promise (or a
parallel one, like a single source of truth for a pinned version) most often
quietly breaks, and what this scaffold's Makefile does about each:

1. **Every target claiming container-only actually has to run in the
   container, `build` included.** A `build` target that still shells out to
   a host Go toolchain while every other target is containerized breaks the
   "container engine only" promise at the one target most people run first.
   This scaffold's `build` goes through the same `$(IN_TOOLS)` indirection as
   every other tooling target, so the claim holds by construction rather than
   by convention.
2. **A parallel host-install target undermines container-first outright.** A
   target that downloads and unpacks a language toolchain onto the host
   competes with the pinned image as a second, unpinned installation path:
   an extra maintenance and security surface (a script fetching and executing
   an archive) for something the image already provides reproducibly. This
   Makefile has no such target: the tools image is the only toolchain
   installation path it offers.
3. **One pinned version, never two.** A host-side version variable sitting
   next to the tools image's own pin is redundant the moment both exist:
   nothing keeps the two in sync, and whichever one a reader doesn't check is
   the one that silently lies about what actually built the binary. This
   scaffold pins the Go version in exactly one place,
   `scripts/docker/tools/Dockerfile`, and the Makefile carries no
   `GO_VERSION` of its own.
4. **A deliberate tool overlap needs to say so, or it reads as a mistake.**
   `lint` (golangci-lint) and `report` (the offline goreportcard script) both
   run `gofmt`, `go vet`, `ineffassign`, and `misspell` under the hood. A
   reviewer skimming the target list could reasonably flag that as
   duplicated tooling to prune. It isn't: `lint` is a pass/fail **gate** (part
   of `check`, mirrors CI, any finding fails the build); `report` is a
   tolerant **grade** (a percentage per check, exits non-zero only below
   `B`). A clean `check` doesn't guarantee an `A` on `report`, and a passing
   `report` grade can still hide findings `check` would fail on. Both stay,
   for different questions. The Makefile says so in a comment at the exact
   point the overlap would otherwise look like an oversight; a lesson like
   this one doesn't survive a refactor if it only lives in the head of
   whoever wrote it.

## The native fallback, documented where a contributor actually looks

The `NATIVE=1` escape hatch and the "no engine, falling back to host tools"
warning are only useful if a contributor without Docker or Podman can find
them: this scaffold documents both in `docs/development.md` and the
generated `README.md`'s own prerequisites section, not only in the Makefile's
comments, since a contributor deciding whether they can even build the
project shouldn't have to read the Makefile first to find out.

## Checklist

- [ ] Every quality-gate target, `build` included, goes through
      `$(IN_TOOLS)`; none of them assumes a host Go toolchain.
- [ ] There is no host-toolchain-install target competing with the tools
      image.
- [ ] The Go version is pinned in exactly one file
      (`scripts/docker/tools/Dockerfile`); nothing else claims to pin it.
- [ ] Any deliberate overlap between two tools/targets (like `lint`/`report`
      here) is explained in a comment at the point it would otherwise look
      redundant.
- [ ] `check` stays limited to what needs no network access; anything that
      does (`secrets`, `osv`) stays a separate, explicitly-run target.
- [ ] The native fallback and `NATIVE=1` are documented somewhere a
      contributor reads before they try to build, not only in Makefile
      comments.
