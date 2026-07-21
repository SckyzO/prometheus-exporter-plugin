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

### 3.2 Resolution through synthetic arguments

kingpin v2.4.0 has no `Resolver`, so resolution is ours to write. Rather than
writing values into parsed flags afterwards, the layer **renders the file back
into command-line arguments** and lets kingpin parse them, once:

```go
// Flags is map[string]any because YAML supplies three shapes: a scalar
// (log.level: debug), a list for a repeatable flag (web.listen-address:
// [":9341"]), and a bool (collector.example: false).
type Config struct {
	Flags            map[string]any               `yaml:"flags,omitempty"`
	HTTPClientConfig *promconfig.HTTPClientConfig `yaml:"http_client_config,omitempty"`
}

// in main(), replacing kingpin.Parse()
cfgPath := config.ExtractFlagValue(os.Args, "config.file")
cfg, err := config.Load(cfgPath)            // zero Config when the path is empty
if err != nil { /* fatal */ }
if err := cfg.Validate(kingpin.CommandLine); err != nil { /* fatal */ }

args := append(cfg.ToArgs(config.CLIFlagNames(os.Args)), os.Args[1:]...)
kingpin.MustParse(kingpin.CommandLine.Parse(args))
```

`ToArgs` emits `--name=value` per entry, repeating the flag once per element of
a list, and rendering a bool as `--name` or `--no-name`. It **omits any flag
already present on the command line**, so a value never has two sources and
precedence is structural rather than computed.

This shape was chosen over writing into `Value.Set()` after `Parse()` because
of `setDefaults` (`app.go:432-437`): kingpin applies a flag's default only when
that flag is **absent from the parsed elements**, and it does so before
`setValues` (`app.go:203` then `:207`). Writing a repeatable flag's YAML value
in afterwards would therefore append to the default already applied, yielding
`[":9341", ":9342"]` where the file asked for `[":9342"]`. Clearing it first
needs `reflect` to zero the underlying slice, and leaves map-valued flags
unsolved. Feeding kingpin arguments sidesteps the whole class: a flag carried
by the arguments never receives its default, and repeatable flags accumulate
exactly as they do on a real command line.

It also means kingpin performs every type conversion and validation itself, so
a malformed value produces kingpin's own error message rather than one we would
have to reimplement per type.

Three properties follow from addressing flags by name rather than through a
typed struct:

- **No central list.** `/add-collector` inserts a `kingpin.Flag(...)` call and
  is done; the flag is configurable by virtue of existing.
- **Third-party flags come for free.** exporter-toolkit's `--web.listen-address`
  and `--web.config.file`, declared by `webflag.AddFlags` (`main.go.tmpl:38`),
  are in the same model and are configurable without the scaffold knowing
  anything about exporter-toolkit.
- **Typos are fatal.** A key under `flags:` matching no declared flag aborts
  startup. Silently ignoring it would let a misspelled setting look applied.

`Validate` supplies the third property. It runs **before** the arguments are
built, comparing every key under `flags:` against
`kingpin.CommandLine.Model().Flags` (`model.go:233`), so an unknown key is
reported as a config-file error naming the file and the key, rather than
surfacing later as kingpin's bare `unknown long flag '--log.levl'`. Every flag
is declared by the time this runs: the `var` block, `register()` at
`// @@COLLECTOR_REGISTRY@@`, and `// @@CLIENT_INIT@@` all execute before this
point in `main()`.

### 3.3 Detecting a flag supplied on the command line

`ToArgs` must skip any flag the operator passed explicitly, and `Load` needs
`--config.file`'s own value before any parsing has happened. kingpin offers
`IsSetByUser(*bool)` (`flags.go:259`) for the first half, but it is unusable
here: it must be called on the `*FlagClause` at declaration time, which would
mean touching every flag declaration in every template and frag (defeating
§3.2's second property), and it is **impossible** for exporter-toolkit's flags
since `webflag.AddFlags` does not return its clauses. It also answers only
after `Parse()`, which is too late for a mechanism that feeds `Parse()`.

The layer instead reads `os.Args` directly, in two small functions:

```go
// CLIFlagNames returns the set of long flag names present in argv.
// Values are irrelevant: only "was it supplied" matters.
func CLIFlagNames(argv []string) map[string]bool

// ExtractFlagValue returns the value of a single long flag from argv,
// handling both --name=value and --name value. Empty when absent.
func ExtractFlagValue(argv []string, name string) string
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

The first two are structural: `ToArgs` omits anything already on the command
line, so the file can never contradict it.

The environment sitting below the file is a consequence, not a choice. An
environment value reaches a flag through `setDefault()` (`flags.go:168-181`),
which `setDefaults` calls only for flags **absent from the parsed elements**
(`app.go:432-437`). A flag the file supplies is carried by the synthetic
arguments, so it is present, so its environment value is never consulted. That
inverts the usual 12-factor reflex. It has no practical effect today, because
no flag in any template declares `.Envar()`, but the documentation states the
order plainly rather than leaving an operator to discover it.

### 3.5 Ordering inside `main()`

Feeding the file through `Parse()` rather than applying it afterwards means
there is no ordering constraint to respect: by the time `Parse()` returns,
every flag already holds its final value. The logger built from `*logLevel`
(`mains/single/main.go.tmpl:132-136`) and the
`warnIfExposedAndUnauthenticated` call reading `*toolkitFlags.WebListenAddresses`
(`:142`) need no change and cannot observe a pre-config value.

The one requirement is that **`--config.file` itself is declared like any other
flag** so that it appears in `--help`, even though its value is read from
`os.Args` before parsing. Declaring it also lets `Validate` reject a `flags:`
key naming it, which would otherwise be silently ignored.

A load or validation failure exits non-zero with a message on stderr: the
logger is not built yet, by construction, so there is nothing else to write to.

The collector constructors registered at `// @@COLLECTOR_REGISTRY@@` are
unaffected. `register()` stores closures invoked only in the construction loop
at `:162-169`, and that deferred-invocation contract is already documented at
`register()`'s doc comment (`:65-74`).

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

**A YAML 1.1 boolean on a non-boolean flag is rejected.** `go.yaml.in/yaml/v2`
implements YAML 1.1, which resolves the unquoted scalars `y`, `yes`, `on`,
`off`, `n`, `no` (and their case variants) to a Go `bool`
**unconditionally**, before the decoder considers the destination type
(`resolve.go:37-43`, `decode.go:471-484`). A string-valued flag whose
legitimate value is `on` would therefore decode to `true` and render as the
bare argument `--some.mode` instead of `--some.mode=on`, corrupting the
argument list silently.

`Validate` therefore cross-checks the decoded Go type against the flag's kind:
a `bool` on a flag that is not a boolean flag is an error naming the flag and
telling the operator to quote the value. Rejecting is the only honest option,
because the file has already lost the information about what was written. Flag
kind is read from the same model `Validate` already walks, through kingpin's
own `IsBoolFlag()` interface, redeclared locally since it is unexported.

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

- `internal/config/config.go.tmpl` — `Config`, `Load`, `Validate`, `ToArgs`,
  `CLIFlagNames`, `ExtractFlagValue`, strict parse, `SetDirectory`.
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

- `skills/prometheus-exporter/assets/scaffold.sh` — the frag-to-marker pair list
  (`:464-467`) gains `"client_build.frag:@@CLIENT_BUILD@@"`, the residual-sentinel
  exemption (`:536`) gains `CLIENT_BUILD`, and the header comment documenting the
  fixed marker set (`:52-56, 62-67`) is updated to match.
  **`internal/config/` needs no change here**: the tree is copied by one blanket
  `cp -R "$src/." "$dst/"` (`:236-237`) and then rides the three generic passes
  (sentinel substitution `:383-389`, path renaming `:391-408`, `.tmpl` stripping
  `:411-414`), exactly like `internal/logger/`. Shipping the files at their final
  repo-relative path is sufficient.
- `skills/prometheus-exporter/references/collector-pattern.md`,
  `references/project-scaffold.md` — both document `NewClient`'s signature.
- `commands/add-collector.md` — the `// @@CLIENT_BUILD@@` marker.
- `commands/new-prometheus-exporter.md`, `ROADMAP.md`, `CHANGELOG.md`.

### Plugin tests

- `test/golden-smoke.sh` — assertions inside the **existing** five cells. No new
  cell: the layer is unconditional, so there is no combination to add. The
  per-cell scaffold-correctness block (`:310-444`) gains an `internal/config/`
  presence check, and the `/add-collector` sub-check (`:1078-1081`) gains the
  third marker alongside `@@CLIENT_INIT@@` and `@@COLLECTOR_REGISTRY@@`.
- `test/scaffold_edge_test.sh` (`:229, :231`) — also enumerates the marker set.
- `test/scaffold_multitarget_test.sh` (`:54, :61-62`) — asserts `CLIENT_INIT` and
  `COLLECTOR_REGISTRY` are **absent** from multi's `main.go`. That assertion holds
  unchanged, since §3.8 keeps `CLIENT_BUILD` out of the multi model too, but the
  file is listed here because it enumerates markers and must be re-read when the
  set changes.

## 5. Testing strategy

Unit tests in the scaffolded repo, so every generated exporter carries them:

| Property | Test |
|---|---|
| Empty path is a no-op | `Load("")` returns a zero `Config` and `ToArgs` returns no arguments |
| A file value applies | `flags: {log.level: debug}` reaches the flag after `Parse` |
| The command line wins | same key plus `--log.level=warn` in argv: `ToArgs` omits it, `warn` survives |
| Unknown flag key is fatal | `flags: {log.levl: debug}` fails `Validate` with an error naming the file and the key |
| Wrong type is fatal | `flags: {log.level: nonsense}` surfaces kingpin's own enum error |
| Repeatable flags replace | a two-element `web.listen-address` list yields exactly those two, not the default plus two |
| A bool renders correctly | `true` becomes `--name`, `false` becomes `--no-name` |
| Unknown top-level key is fatal | strict parse rejects it |
| `--name=value` and `--name value` | both recognised by `CLIFlagNames` and `ExtractFlagValue` |
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
  path. `Load("")` returns early, `ToArgs` returns nothing, and the arguments
  handed to `Parse` are `os.Args[1:]` unchanged.
- When the file declares no `http_client_config:`, the flavor wiring keeps
  calling `NewClient` rather than `NewClientWithConfig`. This matters:
  `NewClientFromConfig` returns a client with its own transport settings, so
  routing the no-auth case through it would silently change connection
  behaviour (keep-alives, HTTP/2) for every existing user.
- `NewClient`'s signature is untouched, so the 11 existing test call sites and
  any repo scaffolded before v0.4.0 keep compiling.
- No default changes. No flag is removed or renamed.
- No module is added; one indirect dependency becomes direct.
- The golden matrix stays at five cells.

## 7. Open questions and assumptions

- **Assumption:** no flag in any template declares `.Envar()`. Verified across
  `mains/` and the wiring frags. If one is added later, §3.4's ordering becomes
  observable and should be revisited.
- **Assumption:** `kingpin.CommandLine.Model()` is safe to call **before**
  `Parse()`, which `Validate` requires in order to name unknown keys. The model
  is built from the already-declared clauses, so this should hold, but the
  implementation task asserts it in a test rather than trusting the reading.
- **Assumption:** a value beginning with `--` never appears in `os.Args`.
  `CLIFlagNames` would count it as a flag name, causing `ToArgs` to omit a key
  the file legitimately sets. kingpin itself rejects such a command line on the
  next token, so the failure is loud rather than silent.
- **Open:** whether `--config.file` should also accept a directory of
  fragments. Not needed by any known case; deferred until one exists.

## 8. Out of scope

Everything listed under §1's non-goals, plus the v0.5.0 `fanout` target model
this layer exists to enable: an `instances:` list, per-instance labels and
credentials, one background poller and cache per instance, and the SIGHUP
reload that becomes meaningful once there is an instance list to reload.
