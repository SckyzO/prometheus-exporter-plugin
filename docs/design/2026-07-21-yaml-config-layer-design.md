# YAML configuration layer

**Status:** design approved 2026-07-21 · v0.4.0. Prerequisite for the v0.5.0
`fanout` target model, which cannot express N instances with per-instance
credentials through a kingpin flag surface.

## 1. Goal

Give every scaffolded exporter an optional configuration file, selected with
`--config.file`, that can set **any** flag the binary declares, plus the
authentication and TLS settings no flag surface can express.

Two properties drive the whole design:

1. **A file that is absent changes nothing.** `--config.file` defaults to
   empty, and an empty value leaves the binary in exactly the behaviour it has
   today. No existing scaffold changes, and no default moves.
2. **`/add-collector` writes nothing extra.** A collector's flags become
   addressable in the config file from the sole fact that they exist. Nothing
   in the plugin holds a list of configurable settings.

### Non-goals

- **SIGHUP reload.** Reloading `web.listen-address` or `log.level` into a
  running process is not meaningful: the listener is already bound and the
  logger already built. Reload becomes meaningful in v0.5.0, where it applies
  to an instance list rather than to flags, and it is designed there.
- **An instance list.** `instances:` belongs to v0.5.0 together with the
  runtime that consumes it (pollers, per-instance cache, `instance` label).
  Shipping the schema without its consumer would be dead schema.
- **`cli`-flavor authentication.** `http_client_config:` is rejected at startup
  under `--flavor cli`, the same fail-fast pairing rule `--target-model multi`
  already applies to `--flavor cli`. A CLI-flavor exporter authenticates
  through the invoked binary's own mechanism, which no shared block models.
- **A scaffold-time opt-out.** The layer ships in every scaffold. It adds no
  `scaffold.sh` flag and no golden-smoke cell.
- **Replacing `--web.config.file`.** That file configures the TLS server this
  exporter *exposes*, and belongs to exporter-toolkit. `--config.file`
  configures what the exporter *queries*. They are unrelated and the
  documentation says so explicitly.

## 2. Background: the current flag-only scaffold

Every setting is a kingpin flag. `mains/single/main.go.tmpl:36-45` declares the
log, web and exporter-metrics flags; `register()` (`:75-79`) declares one
`--[no-]collector.<name>` per collector; each flavor's `client_init.frag`
declares that collector's own target and timeout flags. There is no
configuration file of any kind.

Two consequences matter here.

**There is no authentication.** `NewClient` (`code/http/client.go.tmpl:55-60`)
builds a bare `&http.Client{Timeout: timeout}`. A scaffolded exporter cannot
talk to a target behind basic auth, a bearer token, or a private CA. This is
not a format limitation being worked around: it is a capability that does not
exist.

**Secrets could not be passed safely even if it did.** A password supplied as
`--collector.example.password=hunter2` is visible in `ps(1)` to every local
user for the process lifetime.

The driving case is an IBM TS4500 tape library exporter: one process, several
libraries, each behind its own credentials and corporate CA. It needs both
halves, and the second half (N instances) is v0.5.0.

## 3. Design

### 3.1 One rule for the file format

The file has two sections, and a single rule decides which one a setting
belongs to:

> **Expressible as a flag: it goes under `flags:`. Otherwise: it goes in a
> structured section.**

Nothing is expressible in both places, so there is never a second precedence
rule to specify, document, or test.

```yaml
flags:
  log.level: debug
  web.listen-address: [":9341"]
  collector.example.target: https://lib01.example.net
  collector.example.timeout: 10s
  collector.example: false          # same as --no-collector.example

http_client_config:                 # prometheus/common/config.HTTPClientConfig
  basic_auth:
    username: monitor
    password_file: /etc/exporter/pw
  tls_config:
    ca_file: /etc/ssl/corp-ca.pem
    server_name: lib01.example.net
```

An endpoint stays a flag (`collector.example.target`), so it is configured
under `flags:` like everything else. In v0.5.0 the endpoint moves into
`instances:` without friction, precisely because a flag can no longer carry N
values at that point.

### 3.2 Flag resolution by name

kingpin v2.4.0 has no `Resolver`, so resolution is ours to write. It is
roughly ten lines, because kingpin exposes exactly the two primitives needed:

- `kingpin.CommandLine.Model().Flags` returns `[]*FlagModel` (`model.go:233`),
  each carrying a `Name string` and a `Value Value`.
- `Value` is `{ String() string; Set(string) error }` (`values.go`), so a
  value can be applied to any flag **without knowing its Go type**.

```go
// Flags is map[string]any because YAML supplies three shapes: a scalar
// (log.level: debug), a list for a cumulative flag (web.listen-address:
// [":9341"]), and a bool (collector.example: false). setFlagValue renders
// each to the string form Value.Set expects.
func (c *Config) ApplyFlags(app *kingpin.Application, setOnCLI map[string]bool) error {
	for _, f := range app.Model().Flags {
		v, ok := c.Flags[f.Name]
		if !ok || setOnCLI[f.Name] {
			continue
		}
		if err := setFlagValue(f, v); err != nil {
			return fmt.Errorf("config: flag %q: %w", f.Name, err)
		}
	}
	return nil
}
```

Three properties follow from resolving by name rather than through a typed
struct:

- **No central list.** `/add-collector` inserts a `kingpin.Flag(...)` call and
  is done; the flag is configurable by virtue of existing.
- **Third-party flags come for free.** exporter-toolkit's `--web.listen-address`
  and `--web.config.file`, declared by `webflag.AddFlags` (`main.go.tmpl:38`),
  are in the same model and are configurable without the scaffold knowing
  anything about exporter-toolkit.
- **Typos are fatal.** A key under `flags:` matching no declared flag aborts
  startup. Silently ignoring it would let a misspelled setting look applied.

`setFlagValue` handles the one asymmetry: for a flag whose `Value` satisfies
`repeatableFlag{ IsCumulative() bool }` (`values.go`), `Set()` **appends**
rather than replaces, so applying a YAML list naively would add to the flag's
default instead of overriding it. Cumulative flags take a list in YAML, and the
implementation resets the value before applying the elements. `--web.listen-address`
is exactly such a flag, so this is not a hypothetical.

### 3.3 Detecting a flag supplied on the command line

`ApplyFlags` must skip any flag the operator passed explicitly. kingpin offers
`IsSetByUser(*bool)` (`flags.go:259`), but it is unusable here: it must be
called on the `*FlagClause` at declaration time, which would mean touching
every flag declaration in every template and frag (defeating §3.2's second
property), and it is **impossible** for exporter-toolkit's flags since
`webflag.AddFlags` does not return its clauses.

The layer instead scans `os.Args` for long-flag **names**, ignoring types
entirely:

```go
// CLIFlagNames returns the set of long flag names present in argv.
// Values are irrelevant: only "was it supplied" matters.
func CLIFlagNames(argv []string) map[string]bool
```

It handles `--name`, `--name=value`, the `--no-` prefix of a negatable boolean
(`--no-collector.example` marks `collector.example`), and stops at a bare `--`
terminator. Short flags are not handled because no configurable flag declares
one.

Its known limit: a flag *value* that itself begins with `--` would be counted
as a flag name. This is accepted. It requires an operator to write something
like `--log.level --debug`, which kingpin itself would reject on the next
token, and the failure is loud rather than silent.

### 3.4 Precedence

    command line  >  config file  >  environment  >  Default()

The environment sitting below the file is a consequence, not a choice:
`isSetByUser` is armed only from the command-line token parser
(`flags.go:112`), while an environment value is applied through `setDefault()`
(`flags.go:168-181`), which never arms it. That inverts the usual 12-factor
reflex. It has no practical effect today, because no flag in any template
declares `.Envar()`, but the documentation states the order plainly rather than
leaving an operator to discover it.

### 3.5 Ordering inside `main()`

The application point is **immediately after `kingpin.Parse()`**, before
anything reads a flag. Two call sites make this non-negotiable in
`mains/single/main.go.tmpl`: the logger is built from `*logFormat` and
`*logLevel` at `:132-136`, and `warnIfExposedAndUnauthenticated` reads
`*toolkitFlags.WebListenAddresses` at `:142`. Both would observe pre-config
values if the layer ran later.

```go
kingpin.Parse()

cfg, err := config.Load(*configFile)          // no-op when the path is empty
if err != nil { /* fatal */ }
if err := cfg.ApplyFlags(kingpin.CommandLine, config.CLIFlagNames(os.Args)); err != nil {
	/* fatal */
}

// only now: logger, security warning, client build, collector construction
```

Fatal here means writing to stderr and exiting non-zero: the logger it would
otherwise use is not built yet, by construction.

The collector constructors registered at `// @@COLLECTOR_REGISTRY@@` are
unaffected, because `register()` stores closures that are only invoked in the
construction loop at `:162-169`, well after this point. That deferred-invocation
contract, already documented at `register()`'s doc comment (`:65-74`), is what
makes the layer fit without restructuring the registry.

### 3.6 Authentication and TLS, with no new dependency

`NewClient(target, timeout) *Client` **keeps its exact signature**. The new
capability lands beside it:

```go
func NewClientWithConfig(target string, timeout time.Duration,
	httpCfg config.HTTPClientConfig) (*Client, error) {

	hc, err := config.NewClientFromConfig(httpCfg, "@@NAMESPACE@@")
	if err != nil {
		return nil, err
	}
	hc.Timeout = timeout
	return &Client{httpClient: hc, baseURL: target}, nil
}
```

This is the two-phase rule applied literally: the new mechanism ships next to
the old one, the old one stays the fallback, and nothing existing breaks. The
alternative, adding a third parameter to `NewClient`, would break **11 call
sites in the shipped test templates** (`code/http/collector_test.go.tmpl`,
`code/http/variants/background_collector_test.go.tmpl`) plus both wiring frags.
Worse, `/add-collector` emits tests calling the current signature, so a repo
scaffolded before v0.4.0 combined with a post-v0.4.0 `/add-collector` would no
longer compile. Keeping the signature removes that entire failure class.

`config.NewClientFromConfig` (`http_config.go:605`) covers basic auth,
`authorization`, OAuth2, TLS and proxying. `github.com/prometheus/common
v0.68.1` is already a **direct** dependency (`go.mod.tmpl:10`) and its YAML
parser `go.yaml.in/yaml/v2` is already in the module graph
(`go.mod.tmpl:31`, indirect). The only `go.mod` change is promoting that parser
from indirect to direct. **No module is added.**

### 3.7 The http wiring splits into two insertion points

`NewClientWithConfig` returns an error, and the closure stored by `register()`
returns only a `prometheus.Collector`. So the client can no longer be built
inline inside `registry.frag`.

The http flavor's wiring therefore uses two markers instead of one:

| Marker | When | Content |
|---|---|---|
| `// @@CLIENT_INIT@@` | before `Parse()` | flag declarations only, unchanged |
| `// @@CLIENT_BUILD@@` | after `Parse()` and after the config is applied | client construction, fatal on error |

`registry.frag` then closes over the already-built client instead of calling
`NewClient` itself. This is the one structural change to the flavor seam, and
`/add-collector` learns the second marker the same way it learned the probe
factory seam in v0.3.0.

### 3.8 The multi-target probe seam

`--target-model multi` gets `flags:` for free through §3.2. For
`http_client_config:`, the multi entry point needs **no new marker**: its
`// @@PROBE_FACTORIES@@` marker already sits after `kingpin.Parse()`
(`mains/multi/main.go.tmpl:109` versus `:92`), unlike the single model's
`// @@COLLECTOR_REGISTRY@@`, which precedes it.

So the factory closure captures the config block from `main`'s scope, exactly
as it already captures `log`. `Factory` gains only an error return:

```go
// internal/probe/probe.go.tmpl, currently line 40
type Factory func(ctx context.Context, target string,
	timeout time.Duration) prometheus.Collector

// after
type Factory func(ctx context.Context, target string,
	timeout time.Duration) (prometheus.Collector, error)
```

Passing `httpCfg` as a fourth parameter was the first shape considered and is
rejected: `internal/probe` would import `prometheus/common/config` solely to
forward a value it never reads, coupling the probe layer to an HTTP concern
that belongs to the flavor wiring. The closure already has the value in scope.

The error is handled at the call site (`probe.go.tmpl:223`), where a factory
that fails now fails that one probe with a 500 rather than taking the process
down. A construction failure there means a bad CA path or an unreadable
credentials file, so it is a configuration error and deserves to be loud.

Semantically this matches Blackbox and SNMP: the file carries the credentials,
the URL carries the target. One `http_client_config:` block applies to every
target probed:

    /probe?target=https://lib01&module=drives
    /probe?target=https://lib02&module=drives

Both use the same credentials. Per-target credentials are the v0.5.0 instance
model, not this one.

### 3.9 Strict parsing, validation, and relative paths

**The parser must be `go.yaml.in/yaml/v2`, not yaml.v3.** `HTTPClientConfig`
and its members implement the v2 unmarshaler signature
`UnmarshalYAML(unmarshal func(interface{}) error) error`
(`http_config.go:466, 486, 1259`). Under yaml.v3, whose interface takes a
`*yaml.Node`, none of those methods would ever be called: defaults and
validation would silently not run and the block would appear to parse. This is
a correctness trap, not a style preference.

**Parsing is strict.** `prometheus/common/config`'s own package comment
instructs callers to use `yaml.UnmarshalStrict()`, and the layer does. An
unknown key anywhere in the file aborts startup, matching §3.2's treatment of
unknown flag names.

**Validation is fail-fast.** `HTTPClientConfig.Validate()` (`http_config.go:390`)
runs at load, so a file declaring both `password` and `password_file` fails at
startup rather than on the first scrape.

**Relative paths resolve against the config file.** `ca_file: certs/corp.pem`
must mean "next to the config file", not "relative to the process working
directory", or an exporter started by systemd from `/` breaks. `HTTPClientConfig`
implements `SetDirectory(dir)` (`http_config.go:363`), which the layer calls
with the config file's directory after unmarshalling. This is the behaviour
Prometheus itself has.

### 3.10 Secrets

`config.Secret` marshals as the literal `<secret>` (`config.go:36`), so the
resolved configuration can be logged at debug level for support purposes
without leaking credentials. The layer never sets `MarshalSecretValue`, never
echoes the raw file, and prefers the `*_file` variants in every documented
example so that credentials live in a file with its own permissions rather than
in the config body.

## 4. Files touched

### New (assets, shipped into scaffolds)

- `internal/config/config.go.tmpl` — `Load`, `ApplyFlags`, `CLIFlagNames`,
  `setFlagValue`, cumulative-flag handling, strict parse, `SetDirectory`.
- `internal/config/config_test.go.tmpl` — the tests in §5.
- `config.example.yml.tmpl` — a commented example, never loaded by default.
- `code/http/wiring/client_build.frag` — the second http wiring marker (§3.7).

### Modified (assets)

- `mains/single/main.go.tmpl` — `--config.file` flag, application block after
  `Parse()`, `// @@CLIENT_BUILD@@` marker.
- `mains/multi/main.go.tmpl` — same, plus passing the block to the probe handler.
- `code/http/client.go.tmpl` — `NewClientWithConfig` beside `NewClient`.
- `code/http/wiring/registry.frag` — closes over the built client.
- `code/http/wiring/probe_factory.frag` — new `Factory` signature.
- `internal/probe/probe.go.tmpl`, `internal/probe/probe_test.go.tmpl` — signature
  and error handling at the call site.
- `docs/configuration.md.tmpl` — the format, the precedence order, the
  `--config.file` versus `--web.config.file` distinction.
- `go.mod.tmpl` — `go.yaml.in/yaml/v2` promoted to a direct require.

`code/http/wiring/client_init.frag` is unchanged: it still declares flags only.

### Modified (plugin knowledge, never shipped)

- `skills/prometheus-exporter/assets/scaffold.sh` — copy `internal/config/`,
  handle the second http wiring frag.
- `skills/prometheus-exporter/references/collector-pattern.md`,
  `references/project-scaffold.md` — both document `NewClient`'s signature.
- `commands/add-collector.md` — the `// @@CLIENT_BUILD@@` marker.
- `commands/new-prometheus-exporter.md`, `ROADMAP.md`, `CHANGELOG.md`.

### Plugin tests

- `test/golden-smoke.sh` — assertions inside the **existing** five cells. No
  new cell: the layer is unconditional, so there is no combination to add.

## 5. Testing strategy

Unit tests in the scaffolded repo, so every generated exporter carries them:

| Property | Test |
|---|---|
| Empty path is a no-op | `Load("")` returns a zero config, `ApplyFlags` changes nothing |
| A file value applies | `flags: {log.level: debug}` reaches the flag |
| The command line wins | same key, `--log.level=warn` in argv, `warn` survives |
| Unknown flag key is fatal | `flags: {log.levl: debug}` returns an error naming the key |
| Wrong type is fatal | `flags: {log.level: nonsense}` surfaces kingpin's own enum error |
| Cumulative flags replace | a two-element `web.listen-address` list yields two addresses, not two plus the default |
| Unknown top-level key is fatal | strict parse rejects it |
| `--name=value` and `--name value` | both recognised by `CLIFlagNames` |
| `--no-x` marks `x` | negated boolean detection |
| `--` terminator | tokens after it are not flag names |
| Relative paths resolve | `ca_file: certs/x.pem` becomes `<dir>/certs/x.pem` |
| Invalid auth is fatal | `password` plus `password_file` fails `Validate()` at load |
| Secrets are redacted | the marshalled config contains `<secret>`, never the value |
| `http_client_config` under cli | rejected with a message naming the flavor |

At plugin level, golden-smoke's existing cells additionally assert that
`internal/config/` is present and that `make check` still passes in all five.
A scaffold with no config file must produce a binary whose `--help` and startup
behaviour are unchanged.

## 6. Non-regression guarantees

- A binary started without `--config.file` follows exactly the current code
  path. `Load("")` returns early and `ApplyFlags` iterates an empty map.
- `NewClient`'s signature is untouched, so the 11 existing test call sites and
  any repo scaffolded before v0.4.0 keep compiling.
- No default changes. No flag is removed or renamed.
- No module is added; one indirect dependency becomes direct.
- The golden matrix stays at five cells.

## 7. Open questions and assumptions

- **Assumption:** no flag in any template declares `.Envar()`. Verified across
  `mains/` and the wiring frags. If one is added later, §3.4's ordering becomes
  observable and should be revisited.
- **Assumption:** kingpin's `Value.Set` is safe to call after `Parse()`. It is
  the same method the parser itself calls, on the same value, so this holds;
  the implementation task should still assert it in a test rather than trust
  the reading.
- **Open:** whether `--config.file` should also accept a directory of
  fragments. Not needed by any known case; deferred until one exists.

## 8. Out of scope

Everything listed under §1's non-goals, plus the v0.5.0 `fanout` target model
this layer exists to enable: an `instances:` list, per-instance labels and
credentials, one background poller and cache per instance, and the SIGHUP
reload that becomes meaningful once there is an instance list to reload.
