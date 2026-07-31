# Configuration and reload

This describes the configuration layer a **scaffolded exporter** gets. Every
generated exporter also ships its own `docs/configuration.md`, written for
the people who run that exporter; this page is the plugin-level summary.

`--config.file` is empty by default, and an exporter started without it reads
nothing from disk. The exception is `multi-instance`, which has no instance
list without it and refuses to start.

## What the file carries

| Section | Applies to |
|---|---|
| `flags:` | every build (any flag the binary declares except `config.file` itself, keyed by its long name) |
| `http_client_config:` | HTTP flavor only (basic auth, bearer token, TLS and client certs for outbound requests) |
| `modules:` | `multi` and `multi-instance` only; a `single` build refuses the section at boot |
| `instances:` | `multi-instance` only, the machines to watch |

`modules:` are named credential bundles that a `/probe` request selects per
request on `multi`, and that each instance references by name on
`multi-instance`. A `single` build refuses the section rather than loading
something nothing would read.

Precedence, highest first: the command line, then the file, then the process
environment, then each flag's own default.

## Reload

`multi` and `multi-instance` builds re-read the file on `SIGHUP` (always
active) or on `POST /-/reload` (behind `--web.enable-lifecycle`, default
`false`, which follows Prometheus's own posture for a mutating endpoint;
`blackbox_exporter` and `snmp_exporter` both expose theirs ungated).

Everything that can fail runs before anything is mutated, so a failed reload
leaves the running configuration untouched, drives
`..._exporter_config_last_reload_successful` to `0` and logs at error.

### What a reload does and does not buy

A reload applies the **shape** of the configuration: an instance or a module
added, removed, re-addressed, re-labelled or re-pointed, plus any secret
written inline.

It is **not** what rotates a file-backed credential. `prometheus/common`
already re-reads every `_file` variant the section accepts, `password_file`
and `ca_file` among them, from disk on every outbound request, with no reload
involved. The generated `docs/configuration.md` names all nine.

That is also why a `single` build ships no reload at all: its documentation
points at those `_file` variants instead.

### Two changes are refused rather than half-applied

- **A changed `flags:` section** refuses the whole reload, naming every
  changed key. Flags are rendered into command-line arguments exactly once,
  at startup, so a running process cannot adopt a new value for one.
- **A change to the *set* of instance label *keys*** on `multi-instance` is
  refused with a restart-required error. A Prometheus registry never releases
  a metric family's label-name dimension once registered, so re-registering
  under a different key set would panic. Changing a label *value* reloads
  hot, with no poller restarted.

## Bounding outbound concurrency

`--exporter.max-requests-per-target` (default `0`, unlimited) caps in-flight
outbound work so one slow target cannot starve its siblings.

What it caps differs by build, which matters before you pick a number:

| Build | One ceiling per |
|---|---|
| `single`, HTTP flavor | distinct target address |
| `single`, CLI flavor | the whole process |
| `multi-instance` | watched instance |
| `multi` | not available |

`..._exporter_request_wait_seconds` records how long a request waited for a
slot, by `outcome`, so queuing shows up in monitoring instead of quietly
lengthening scrape times.
