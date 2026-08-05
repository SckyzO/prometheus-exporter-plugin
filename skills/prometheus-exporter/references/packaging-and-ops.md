# Packaging and day-2 ops: two Dockerfiles, hardened compose, and systemd

This is step 5 of the workflow: how a scaffolded exporter actually runs once
it leaves `go build`, as a container, under `docker compose`, or as a
systemd unit (`cicd-and-release.md` covers what happens at a tagged release;
`security-and-hardening.md` and `dashboards-and-alerts.md` cover the rest of
this step). Everything below matches `Dockerfile.tmpl`, `Dockerfile.minimal.tmpl`,
`docker-compose.yml.tmpl`, `docker-compose.minimal.yml.tmpl`,
`systemd/@@EXPORTER_NAME@@.service.tmpl`, and `.dockerignore` as shipped.
Read those alongside this document, not instead of it.

## Two Dockerfiles, one build stage

Both `Dockerfile` and `Dockerfile.minimal` share an identical build stage:

```dockerfile
FROM golang:1.26.4-alpine@sha256:... AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ cmd/
COPY internal/ internal/
RUN CGO_ENABLED=0 GOOS=linux go build \
      -ldflags "-s -w \
        -X github.com/prometheus/common/version.Version=${VERSION} \
        ..." \
      -o /out/@@EXPORTER_NAME@@ ./cmd/@@EXPORTER_NAME@@
```

Three things worth naming explicitly:

- **Pinned by tag and digest**, not just a floating tag: the same
  reproducibility discipline `makefile-and-tooling.md`'s tools image applies
  to its own Go toolchain.
- **Self-contained.** Both files `COPY` this repository's own source and
  compile it in their own build stage: a bare `docker build .` works
  immediately, with no GoReleaser run and no separate cross-compile step as a
  precondition. `go.mod`/`go.sum` are cached in their own layer, invalidated
  only when they change, never by a plain source edit.
- **`CGO_ENABLED=0` produces a fully static binary** (nothing dynamically
  linked, not even libc), which is exactly what makes `Dockerfile.minimal`'s
  distroless/static runtime stage (below) possible at all: a binary that
  still links libc cannot run in an image that doesn't ship one.
- **The same five `version.*` ldflags keys** `makefile-and-tooling.md`'s
  `LDFLAGS` and `.goreleaser.yaml`'s template functions use
  (`Version`/`Revision`/`Branch`/`BuildUser`/`BuildDate`), filled here from
  `ARG`s instead of shelled-out `git` commands: the third of the three build
  paths that all report an identical `--version` shape. `make docker-build`/
  `-minimal` supply real values from `git` automatically (`DOCKER_BUILD_ARGS`
  in `Makefile.tmpl`); a bare `docker build .` with no `--build-arg` still
  works, it just reports the generic `dev`/empty defaults each `ARG`
  declares.

## Runtime stage: dedicated non-root vs. baked-in distroless nonroot

The two files diverge only in the runtime stage, a deliberate choice, not a
missed consolidation:

| | `Dockerfile` (standard) | `Dockerfile.minimal` |
|---|---|---|
| Base | `debian:13-slim` + `ca-certificates` | `gcr.io/distroless/static:nonroot` |
| Shell / package manager | Yes (`docker exec` works) | None |
| User | Dedicated, created in-image: `useradd --system --no-create-home --shell /usr/sbin/nologin --uid @@DEFAULT_PORT@@ @@EXPORTER_NAME@@`, then `USER @@EXPORTER_NAME@@` | The image's own baked-in `nonroot` (uid `65532`): no `USER` directive needed, distroless enforces it unconditionally |
| Attack surface | Small | Materially smaller: no shell to pivot from if the exporter itself is ever compromised |
| Trade-off | Easiest to debug in place | No in-container debugging at all: no `exec`, no package manager to install a troubleshooting tool on the fly |

The `--uid @@DEFAULT_PORT@@` choice on the standard image is deliberate, not
incidental: pinning the dedicated user to a stable, collision-resistant value
(this exporter's own default port) instead of `useradd`'s default of
"whatever the next free system UID happens to be" makes the UID predictable
across rebuilds and hosts. Both files inject the identical OCI labels
(`title`, `description`, `licenses`, `vendor`, `version`, `revision`,
`created`) from `@@LICENSE@@`/`@@OWNER@@` and the same build `ARG`s, `EXPOSE
@@DEFAULT_PORT@@`, and an identical `ENTRYPOINT`/`CMD` shape
(`["--web.listen-address=:@@DEFAULT_PORT@@"]`). The only thing an operator
switching between the two images needs to change is which file they built
from.

**Pick the standard image first; switch to minimal once it works.** Both
files' own header comments frame it this way: confirm the exporter behaves
correctly against your real target on the debuggable standard image, then
reach for `Dockerfile.minimal` once the smaller attack surface matters more
than being able to shell in.

### The CLI flavor needs its own binary: neither image bundles it

If this exporter's collectors shell out to an external CLI tool
(`internal/collector`'s `Execute`, on the `cli` flavor:
`collector-pattern.md`) rather than calling an HTTP API, that tool is not
installed in either image; this is a generic template and cannot hardcode a
specific vendor's client into it. The two Dockerfiles even diverge in what's
*possible* here, which is itself a reason to try the standard image first on
this flavor:

- **Standard image**: has `apt-get`; install the tool in the runtime stage
  (rebuild afterward), or bind-mount it read-only from the host via
  `docker-compose.yml` and put it on `PATH`.
- **Minimal image**: has neither a package manager nor a shell to run one
  with; bind-mounting the tool (and any shared libraries it needs) is the
  *only* option; building a custom minimal variant from a base that still has
  a package manager (the standard `Dockerfile`'s own runtime stage is a
  reasonable starting point) is the fallback if bind-mounting isn't viable.

### What's actually build-tested today

This plugin's own golden smoke test (`test/golden-smoke.sh`) runs `docker
build -f Dockerfile .` end-to-end (guarded: `docker` → `podman` → an explicit
skip if neither is present) against every scaffolded flavor/forge
combination, proving the standard image actually compiles from a fresh
scaffold, not just that its syntax parses. `Dockerfile.minimal` is **not**
part of that automated coverage today. `make docker-build-minimal &&
make docker-run-minimal` (below) is how you smoke-test it yourself before
relying on it in production.

## Hardened compose: `docker-compose.yml` / `docker-compose.minimal.yml`

Both compose files ship the same four hardening directives, on by default,
not an opt-in profile:

```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
read_only: true
tmpfs:
  - /tmp
```

The reasoning, straight from the shipped header comment: `no-new-privileges`
means the container can never gain more privileges than it started with
(for example via a setuid/setgid binary); every Linux capability is dropped
because this exporter needs none of them; the root filesystem is read-only
because a stateless HTTP exporter has no legitimate reason to write
anywhere; `/tmp` is a small in-memory `tmpfs` for the rare case something
still wants a writable path (a library that insists on a temp file).
Neither file sets a `user:` key: there's nothing to override, since both
Dockerfiles already fix the runtime identity at the image level (the
dedicated non-root user vs. distroless's baked-in `nonroot`); compose's own
hardening is entirely about capabilities, filesystem, and privilege
escalation, not identity.

**Distinct `container_name`, same default port.** `docker-compose.yml` names
its service `@@EXPORTER_NAME@@`; `docker-compose.minimal.yml` names its
`@@EXPORTER_NAME@@-minimal`, specifically so the two stacks never collide
and *can* run at the same time. They still default to the **same** host port
(`@@DEFAULT_PORT@@`), so running both together needs an explicit override on
the second one: `HOST_PORT=<free-port> make docker-run-minimal`. Both files
expose the same two environment overrides, `IMAGE` (which image to run) and
`HOST_PORT` (the host-side port for `/metrics`).

If this exporter's collectors shell out to an external CLI tool, mount it
(and any config/socket it needs) read-only under `volumes:`. Both compose
files carry a commented example of the exact shape
(`/path/on/host/to/tool:/usr/local/bin/tool:ro`).

### The make targets that drive this

```make
docker-build:          docker build $(DOCKER_BUILD_ARGS) -f Dockerfile -t $(DOCKER_REF) .
docker-build-minimal:  docker build $(DOCKER_BUILD_ARGS) -f Dockerfile.minimal -t $(DOCKER_REF_MINIMAL) .
docker-run:            IMAGE=$(DOCKER_REF) docker compose -f docker-compose.yml up -d
docker-run-minimal:    IMAGE=$(DOCKER_REF_MINIMAL) docker compose -f docker-compose.minimal.yml up -d
```

`DOCKER_REF`/`DOCKER_REF_MINIMAL` default to `@@EXPORTER_NAME@@:dev`/
`@@EXPORTER_NAME@@:dev-minimal` (override with `DOCKER_IMAGE=`/`DOCKER_TAG=`).
`DOCKER_BUILD_ARGS` derives `VERSION`/`COMMIT`/`BRANCH`/`BUILD_USER`/
`BUILD_DATE` from `git` at invocation time and passes them as `--build-arg`,
so a locally built image reports the same version-metadata shape as `make
build` and a GoReleaser-published one. All four targets fail fast with a
clear message when no container engine is detected. Unlike every other
`make` target, there is no native fallback for building or running a
container image, since that inherently needs one (`makefile-and-tooling.md`
covers the engine-detection mechanism these targets share with the rest of
the Makefile).

## `systemd/@@EXPORTER_NAME@@.service`

The non-container path: a dedicated, unprivileged system user, never root,
runs the binary directly. As rendered for a single-target build, the default:

```ini
[Service]
Type=simple
User=@@EXPORTER_NAME@@
Group=@@EXPORTER_NAME@@
ExecStart=/usr/local/bin/@@EXPORTER_NAME@@ --web.listen-address=":@@DEFAULT_PORT@@"
Restart=on-failure
RestartSec=5
# ExecReload=/bin/kill -HUP $MAINPID
NoNewPrivileges=true
```

The same two lines on a multi-instance build:

```ini
ExecStart=/usr/local/bin/@@EXPORTER_NAME@@ --web.listen-address=":@@DEFAULT_PORT@@" --config.file="/etc/@@EXPORTER_NAME@@/config.yml"
ExecReload=/bin/kill -HUP $MAINPID
```

`ExecStart` and `ExecReload` are both subject to per-target-model surgery
`scaffold.sh` performs after rendering, for the same reason
`internal/reload/` itself is conditional: what `SIGHUP` does, and whether the
binary can run at all without `--config.file`, are decided by the generated
`cmd/@@EXPORTER_NAME@@/main.go`, not by the unit file. No single model has
both lines rewritten.

`ExecStart` gains `--config.file="/etc/@@EXPORTER_NAME@@/config.yml"` on a
multi-instance build and only there. That model's `main.go` refuses to start
without the flag, because the file is what lists the instances to watch, so a
unit shipped without it is not a unit missing an option, it is a service that
never binds a port.

Worth knowing how that failure actually presents, because it is quieter than
it sounds: with `Type=simple`, systemd considers the unit started as soon as
the main process is forked off, so the start job reports success and the
binary then exits non-zero a moment later. `Restart=on-failure` and
`RestartSec=5` below turn that into a permanent five-second restart loop,
which surfaces in `systemctl status @@EXPORTER_NAME@@` and the journal rather
than in whatever `systemctl start` printed.

The path is conventional and is meant to be corrected, exactly like the
binary path already on that line. A single-target or multi-target build runs
without the flag, so its `ExecStart` is left as rendered rather than pointed
at a file that need not exist; the unit ships a commented variant showing the
flag for whoever does have a configuration file to load there.

`ExecReload` is what makes `systemctl reload @@EXPORTER_NAME@@` do anything
at all: without it, `reload` fails outright with "Job type reload is not
applicable". On a multi-target or multi-instance build,
`internal/reload` catches `SIGHUP` and reloads `--config.file` in place: no
restart, no dropped connection, so `scaffold.sh` leaves `ExecReload` active.
On a single-target build (the default, shown above), nothing in `main.go`
installs a `SIGHUP` handler at all (`internal/reload` is not shipped there,
see `exporter-architecture.md`'s three-model comparison), so a `SIGHUP`
reaching the process would fall through to its OS default and terminate it;
`Restart=on-failure` immediately above would then turn every `systemctl
reload` into a five-second outage instead of the harmless in-place reload
the other two target models get. `scaffold.sh` comments the line out for
that target model rather than deleting it, so it stays discoverable (and
correct) for anyone who copies the unit elsewhere; use `systemctl restart`
to pick up an edited `--config.file` or changed flags on a single-target
build instead.

The unit's own comment is explicit that this user must be created *before*
enabling the service (`useradd --system --no-create-home --shell
/usr/sbin/nologin @@EXPORTER_NAME@@`); systemd will not create it for you.
`Restart=on-failure` (not `always`) plus a 5-second `RestartSec` restarts the
process after a crash without restart-looping a deliberate, clean exit (for
example, a bad `--flag` causing kingpin to exit non-zero on startup, which
shouldn't be treated the same as a crash worth retrying).

`NoNewPrivileges=true` is set unconditionally, safe for this binary because
it never needs to gain privileges via a setuid/setgid/file-capability helper:
the exact same guarantee `no-new-privileges:true` already gives the
container path above, so the binary gets identical treatment whether it
runs as a container or a systemd unit.

### Three commented examples, and a large commented hardening block

The unit ships three commented `ExecStart` variants to adapt rather than
type from scratch: one adding `--config.file` (already active on a
multi-instance build, as above, and useful on the other two models once
there is a file to load; pointing at `docs/configuration.md`), one adding
`--web.config.file` for TLS/Basic Auth (pointing at exporter-toolkit's own
web-configuration docs; `security-and-hardening.md` covers this flag's
purpose), and one showing `--no-collector.<name>` for running with only
specific collectors enabled (pointing at `docs/configuration.md`).

Below `NoNewPrivileges=true` sits a longer block of stricter directives, all
commented out on purpose:

```ini
# ProtectSystem=strict        # whole OS read-only except ReadWritePaths below
# ProtectHome=true            # no access to /home, /root, /run/user
# PrivateTmp=true             # isolated /tmp, matches the compose tmpfs
# ProtectKernelTunables=true  # no writes to /proc/sys, /sys
# ProtectKernelModules=true   # cannot load/unload kernel modules
# ProtectControlGroups=true   # read-only cgroup hierarchy
# RestrictSUIDSGID=true       # cannot create setuid/setgid files
# RestrictRealtime=true       # cannot request realtime scheduling
# LockPersonality=true        # cannot change the process execution domain
# MemoryDenyWriteExecute=true # blocks W^X violations (JIT-style exploits)
# RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
# CapabilityBoundingSet=      # drop every capability; add back only what a
#                              # CLI-flavor target binary genuinely needs
# ReadWritePaths=             # this exporter writes nothing by default
```

Unlike `NoNewPrivileges`, these are commented rather than shipped active
because each one can need one-off tuning specific to a deployment: pointing
`--web.config.file` at a path, or a CLI-flavor collector's target binary,
at a location one of these would otherwise block. Uncomment progressively
and re-test after each one: `systemctl status @@EXPORTER_NAME@@` and the
journal surface a sandboxing failure clearly the moment one bites, which is
a faster feedback loop than guessing which directive was responsible after
enabling all of them at once.

## `.dockerignore`

Keeps the build context small, but not by excluding what the multi-stage
builds actually need. The file's own header comment is explicit about this:
`go.mod`, `go.sum`, `cmd/`, and `internal/` are **not** in the exclusion list,
because both Dockerfiles `COPY` and compile them from source. Everything
excluded plays no part in the build:

| Category | Excluded |
|---|---|
| Build artifacts (rebuilt from source inside the image either way) | `bin/`, `dist/`, `linux/` |
| Test fixtures (not needed to compile the binary) | `**/testdata/` |
| Docs, monitoring, packaging assets (irrelevant to the image build) | `docs/`, `monitoring/`, `scripts/`, `systemd/`, `Dockerfile*`, `docker-compose*.yml` |
| Project metadata (doesn't affect the image) | `.git/`, `.github/`, `.gitignore`, `.golangci.yml`, `.goreleaser*.yaml`, `CHANGELOG.md`, `CONTRIBUTING.md`, `README.md`, `SECURITY.md`, `LICENSE`, `Makefile` |

`Dockerfile*` and `docker-compose*.yml` excluding themselves is deliberate:
a `Dockerfile.minimal` edit shouldn't invalidate the standard image's build
cache, and neither file needs to `COPY` the other's contents into an image.

## Checklist

- [ ] `Dockerfile` and `Dockerfile.minimal` share one build stage
      (`CGO_ENABLED=0`, static, identical `version.*` ldflags); they diverge
      only in the runtime base and its user model.
- [ ] The standard image's non-root user has a stable, deliberately chosen
      UID (this exporter's own default port), not whatever `useradd` assigns
      next; the minimal image needs no `USER` directive at all.
- [ ] A CLI-flavor collector's target binary is bind-mounted (or, on the
      standard image only, `apt-get`-installed), never assumed to already
      be on `PATH` inside either image.
- [ ] Both compose files carry all four hardening directives
      (`no-new-privileges`, `cap_drop: ALL`, `read_only`, `tmpfs: /tmp`) and
      a distinct `container_name`; site-specific overrides go through
      `IMAGE`/`HOST_PORT`, not a hand-edit of the file.
- [ ] The systemd unit runs as a dedicated, pre-created, unprivileged user;
      `NoNewPrivileges=true` is active unconditionally, and the stricter
      block below it is uncommented progressively, re-testing after each
      directive.
- [ ] The active `ExecStart` carries `--config.file` on a `multi-instance`
      build, which refuses to start without it, and the path points at a file
      that exists. Reading it off a commented example does not count: a
      commented flag starts nothing.
- [ ] `ExecReload=/bin/kill -HUP $MAINPID` is active for `multi` and
      `multi-instance` builds (they ship `internal/reload` and handle
      `SIGHUP` in place) and commented out (`# ExecReload=...`) for
      `single` builds (the default), which install no `SIGHUP` handler and
      would otherwise turn every `systemctl reload` into a
      `Restart=on-failure` outage.
- [ ] `.dockerignore` excludes build artifacts, fixtures, docs, and packaging
      assets, never `go.mod`/`go.sum`/`cmd/`/`internal/`, which the
      multi-stage builds actually need in context.
- [ ] Before relying on `Dockerfile.minimal` in production, smoke-test it by
      hand (`make docker-build-minimal && make docker-run-minimal`): it
      isn't part of this plugin's own automated golden-test coverage today.
