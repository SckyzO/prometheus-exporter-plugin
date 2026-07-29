---
description: Scaffold a new Prometheus exporter repository (Go, HTTP or CLI flavor) from an already-decided architecture: collects every template variable, offers a license, runs the packaged scaffolder, and proves the result builds and passes its own quality gate.
argument-hint: <name>
disable-model-invocation: true
---

Scaffold a complete, buildable, tested Go Prometheus exporter repository from
the plugin's templates. This is a side-effecting operation (it creates a new
directory tree, initializes a git repository, and runs a real build), so only
run it when the user explicitly invokes this command, and walk through every
step below in order rather than skipping ahead.

Candidate exporter name from the command argument: $ARGUMENTS

## 0. Confirm the architecture decision is already made

Look for an architecture brief before asking anything interactively: an
explicit path if the user named one, otherwise `./exporter-design-brief.md`
in the current directory (the file `/design-exporter` produces).

- **If a brief is found:** read it, then present its `## Architecture
  decisions` section back to the user for confirmation. Do not silently
  trust it; the user still owns the final call. Take its `## Scaffold
  inputs` values as the defaults for step 1. Still ask for the identity
  fields (`MODULE_PATH`, `OWNER`, `LICENSE`), which the brief never
  contains.
- **If no brief is found:** proceed with the existing interactive
  confirmation below, unchanged.

Do not scaffold a repository whose shape hasn't actually been decided. Before
collecting a single variable, confirm the architecture-design phase is done.
If you have not already, read
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/references/exporter-architecture.md`
for the full method, then confirm the following with the user (don't guess
on their behalf):

- **Data source and I/O flavor.** Preference order is REST/gRPC-style API >
  database > CLI (last resort: justify it if chosen, e.g. no API exists).
  This maps directly to `--flavor http` (the default) or `--flavor cli`.
- **Single-target vs. multi-target vs. multi-instance.** Maps to
  `--target-model single` (default), `--target-model multi` (one target per
  request via `?target=`), or `--target-model multi-instance` (a fixed list of
  instances polled in the background, from `--config.file`). Both multi models
  **require `--flavor http`**. If the design brief describes many machines with
  per-machine credentials known ahead of time, or a source that refreshes more
  slowly than Prometheus's 5-minute staleness window, that is multi-instance;
  if Prometheus should pick the target per scrape, that is multi. Reject a
  multi model with a CLI-flavored source rather than silently falling back.
  `/add-collector` works against any target model, so the choice made here
  does not close that door.
- **The collector list**: which resources/metrics this exporter will track,
  even if only the first one is built today. Later collectors are added one
  at a time with `/add-collector`.
- **A rough cardinality budget** and any business-alert candidates per
  collector (useful context for `/add-collector` later; not a template
  variable here).

If these haven't been worked out yet, stop here and point the user at the
architecture reference instead of guessing. Once they're decided, continue.

## 1. Collect the template variables

The scaffolder needs a value for every variable below, plus three directory/
layer selections (`--flavor`, `--forge`, `--target-model`) that are **not**
template variables: they choose which files get copied, not text
substituted into them.

If a brief was consumed in step 0, `DATA_SOURCE`, `DATA_SOURCE_PATH`,
`NAMESPACE`, and `DEFAULT_PORT` arrive pre-filled from its `## Scaffold
inputs` section, and the I/O flavor from its `## Architecture decisions`
section. Confirm them with the user rather than re-asking;
`MODULE_PATH`, `OWNER`, and `LICENSE` are always asked here regardless.

| Variable | Meaning | HTTP example | CLI example |
|---|---|---|---|
| `EXPORTER_NAME` | binary/repo name, validated in step 2 | `redis_exporter` | `redis_exporter` |
| `NAMESPACE` | Prometheus metric prefix (`<namespace>_up`, etc.) | `redis` | `redis` |
| `MODULE_PATH` | Go module import path | `github.com/acme/redis_exporter` | `github.com/acme/redis_exporter` |
| `DATA_SOURCE` | HTTP: base URL of the target. CLI: the command/binary the collector executes | `http://localhost:9121` | `redis-cli` |
| `DATA_SOURCE_PATH` | HTTP: the first collector's endpoint path. CLI: unused by the CLI templates, still pass a placeholder | `/api/info` | `unused` |
| `DEFAULT_PORT` | port the exporter listens on | `9121` | `9121` |
| `OWNER` | the exporter's own owner/maintainer identity (attribution: LICENSE, CODEOWNERS, OCI labels) | `acme-corp` | `acme-corp` |
| `LICENSE` | see step 1b | `apache-2.0` | `apache-2.0` |

Derive or ask for each:

- **`EXPORTER_NAME`**: from the command argument above if given, otherwise
  ask. Validate it per step 2 before deriving anything else from it.
- **`NAMESPACE`**: suggest a default by stripping a trailing
  `_exporter`/`-exporter` from `EXPORTER_NAME` (e.g. `redis_exporter` →
  `redis`) and confirm with the user: this becomes a permanent metric prefix,
  so it's worth getting right before scaffolding.
- **`MODULE_PATH`**: ask for the Go module path matching wherever this repo
  will actually be hosted, conventionally `github.com/<owner>/<name>`. It is
  independent of the `--forge` choice below (a repo can live on GitHub with
  `--forge none`, or elsewhere with a different host in the module path).
- **`DATA_SOURCE`** / **`DATA_SOURCE_PATH`**: meaning depends on the flavor
  chosen in step 0; see the table above. Ask accordingly.
- **`DEFAULT_PORT`**: point the user at the official allocation list,
  <https://github.com/prometheus/prometheus/wiki/Default-port-allocations>,
  and ask them to pick a free one (or confirm the target's own conventional
  port if it already has one).
- **`OWNER`**: ask. This is the generated exporter's own owner, a third
  party, never a hardcoded identity of any kind.
- **`LICENSE`**: see step 1b.
- **`--forge`** (`github` or `none`, not a `--var`): ask which. `github`
  ships the `.github/` layer (CI workflows, dependabot, CODEOWNERS, issue/PR
  templates); `none` omits it entirely. Either way the repo stays versioned
  and releasable: SemVer tags, a CHANGELOG, and GoReleaser work with no forge
  at all.
- **`--flavor`** (`http` or `cli`, not a `--var`): carried over directly
  from the step 0 decision; don't ask again.
- **`--target-model`** (`single`, `multi`, or `multi-instance`, not a
  `--var`): carried over from the step 0 decision; default `single`. Both
  `multi` and `multi-instance` require `--flavor http`: reject either paired
  with `--flavor cli` yourself, with a clear message, before running
  scaffold.sh (which also rejects it, but don't rely on that alone: fail
  fast here, same posture as step 2's name validation).
- **`--instance-label`** (not a `--var`; multi-instance only): the label name
  this exporter applies to every instance's series; default `target`. Ask
  only if the design brief named a more natural dimension (e.g. `library`,
  `device`). Ignored for single/multi.

## 1b. Offer a license

Present these four, plainly, and default to Apache-2.0 if the user has no
preference:

- **Apache-2.0** (default): permissive, with an explicit patent grant; the
  norm for Prometheus exporters.
- **MIT**: minimal permissive license, no explicit patent grant.
- **GPL-3.0**, strong copyleft: derivative works must also be open-sourced
  under GPL.
- **BSD-3-Clause**: permissive, similar to MIT plus a non-endorsement
  clause.

Map the choice to the exact `--var LICENSE=` value (lowercase, matches the
scaffolder's bundled license files): `apache-2.0`, `mit`, `gpl-3.0`, or
`bsd-3`.

## 2. Validate the exporter name

Before it touches anything else (including before deriving `NAMESPACE` or
`MODULE_PATH` from it), check `EXPORTER_NAME` against these rules. Reject and
ask again (explain why) if it:

- is empty,
- contains a `/` (it must be a single path component, not a path),
- contains `..`,
- contains any whitespace, or
- starts with a leading `.`.

Any of these can corrupt the scaffolder's path renaming, break the Go module/
binary name, or produce an invalid systemd unit/user name. Do not pass an
unvalidated name through to step 3 under any circumstance. As a (non-blocking)
suggestion, a lowercase `snake_case` name ending in `_exporter` fits Go and
Prometheus convention best (e.g. `redis_exporter`), but only the five rules
above are hard rejections.

## 3. Scaffold the repository

Pick a target directory: default to `./<EXPORTER_NAME>` under the current
working directory unless the user says otherwise. Before running anything,
check whether that directory already exists and is non-empty. If it does,
stop: tell the user plainly that this command will not overwrite an existing
project, and ask them to pick a different or empty directory (the scaffolder
enforces the same refusal independently, but don't rely on it alone: fail
fast with a readable message). Never add `--force` unless the user explicitly
confirms, in this conversation, that they want to overwrite that exact
directory's contents.

Then run:

```sh
"${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/scaffold.sh" \
  --src "${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets" \
  --dst <target-dir> \
  --flavor <http|cli> \
  --forge <github|none> \
  --target-model <single|multi|multi-instance> \
  --var EXPORTER_NAME=<EXPORTER_NAME> \
  --var NAMESPACE=<NAMESPACE> \
  --var MODULE_PATH=<MODULE_PATH> \
  --var DATA_SOURCE=<DATA_SOURCE> \
  --var DATA_SOURCE_PATH=<DATA_SOURCE_PATH> \
  --var DEFAULT_PORT=<DEFAULT_PORT> \
  --instance-label <INSTANCE_LABEL, multi-instance only; omit otherwise> \
  --var COLLECTOR_HEALTH_BY=<"job,<INSTANCE_LABEL>" for multi-instance, else "job"> \
  --var COLLECTOR_LOCATION=<"<INSTANCE_LABEL>" for multi-instance, else "instance"> \
  --var OWNER=<OWNER> \
  --var LICENSE=<apache-2.0|mit|gpl-3.0|bsd-3>
```

For `single`/`multi`, pass `--var COLLECTOR_HEALTH_BY=job --var
COLLECTOR_LOCATION=instance` (the shipped rules aggregate by job and name the
exporter host). For `multi-instance`, pass `--var
COLLECTOR_HEALTH_BY=job,<instance-label> --var
COLLECTOR_LOCATION=<instance-label>` so the health rules break down per
instance.

Show its output. It prints `scaffolded <target-dir>` on success. If it fails
instead (including a residual-`@@VAR@@`-sentinel error), that means a
variable above is missing or wrong; fix the invocation and retry rather than
working around the failure.

## 3b. Apply the concurrency ceiling, if the brief recorded one

If the brief consumed in step 0 carries a `Concurrency ceiling:` line under
`## Architecture decisions` (only present when `/design-exporter` asked its
follow-up: target model `multi-instance`, or `single` with at least one
background collector), set `exporter.max-requests-per-target` in the
just-scaffolded `<target-dir>/config.example.yml`'s `flags:` section to:

- **`Concurrency ceiling: unlimited`**: commented out, e.g.
  `# exporter.max-requests-per-target: 4`, documenting the option without
  changing the shipped unlimited default.
- **`Concurrency ceiling: <N>`**: active, `exporter.max-requests-per-target:
  <N>`, using the number the user gave.

Edit in place, don't just append. Check first whether a line naming
`exporter.max-requests-per-target` (commented or not) already exists under
`flags:` (it will once `config.example.yml.tmpl` itself ships one, a change
tracked separately): if so, rewrite that line to the state above; if not,
add one, alongside the other top-level flags. Either way the file must end
up with exactly one `exporter.max-requests-per-target` line: `flags:` reads
each key once, and duplicating it would violate the file's own header
comment, which promises no setting is ever expressible in two places.

No brief, or a brief with no `Concurrency ceiling:` line: leave
`config.example.yml` exactly as scaffold.sh produced it; there is nothing to
apply. This never triggers on a `multi` scaffold: `/design-exporter` never
asks the follow-up there, and `--exporter.max-requests-per-target` does not
exist on a multi-target binary in the first place, since a probed target
arrives per request rather than accumulating a persistent per-target
limiter.

## 4. Initialize git and make the first commit

```sh
cd <target-dir>
git init
git add -A
git commit -m "feat: initial scaffold of <EXPORTER_NAME>"
```

Use a plain Conventional Commit message. Add **no** AI/automation
attribution of any kind (no `Co-authored-by: Claude`, no "Generated with…",
no `claude.ai` link). This repository belongs entirely to its new owner,
not to this tool.

## 5. Prove it builds and passes its own gate

```sh
cd <target-dir>
make build
make check
```

Run both and show the real output. Don't claim success without it. `make
check` already runs vet, lint, the full test suite, govulncheck, actionlint/
zizmor (skipped gracefully when `--forge none`), deadcode, and the
metrics-docs check. If either target fails, stop and show the failure as-is:
that means a real defect in the generated templates, not something to paper
over or silently retry past.

## 6. What's next

Point the user to:

- **`/add-collector <name>`** to add each further collector from the step 0
  list, with its full test triad and registry wiring.
- **`docs/configuration.md`** and `config.example.yml`: every scaffold ships
  `internal/config` and an unconditional `--config.file` flag, empty by
  default, so an operator can override flag values from a file instead of the
  command line and, on the http flavor, set an `http_client_config:` section
  for authentication or TLS no flag can express.
- **`docs/metrics.md`**: the metrics reference, kept truthful by `make
  docs-check`.
- **`monitoring/`**: the shipped Prometheus health alerts, recording rules,
  and health Grafana dashboard.
- **`docs/release-process.md`**: how to cut a first real release with
  GoReleaser once there's something worth releasing.

If this exporter was scaffolded with `--target-model multi`, `/add-collector`
detects that and appends a factory at `// @@PROBE_FACTORIES@@` in
`cmd/*/main.go` rather than a `register(...)` call into a single-target
registry.

If the architecture brief recorded a credential convention
(`Credential convention: a|b|c` under `## Architecture decisions`), point the
user at the matching commented block in `config.example.yml`: `a` is the
plain `http_client_config:` block (or nothing at all, if no target needs
credentials), `b` is the block marked "Convention 1", `c` is the block marked
"Convention 2". Point them at `docs/configuration.md`'s `### Selecting a
module` section either way, for the scrape config that goes with whichever
block they uncomment.

If the architecture brief recorded a concurrency ceiling
(`Concurrency ceiling: unlimited|<N>` under `## Architecture decisions`),
step 3b above already applied it to `config.example.yml`; point the user
there, and at `<namespace>_exporter_request_wait_seconds` in
`docs/metrics.md`, to see it in effect once the exporter is running.
