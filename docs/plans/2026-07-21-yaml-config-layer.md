# YAML Configuration Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every scaffolded exporter an optional `--config.file` that can set any declared flag, plus the authentication and TLS no flag can express.

**Architecture:** A new `internal/config` package renders the YAML file back into command-line arguments and hands them to kingpin, which parses once. Authentication arrives as `NewClientWithConfig` beside the untouched `NewClient`, built at a new `// @@CLIENT_BUILD@@` marker that sits after parsing.

**Tech Stack:** Go 1.26, kingpin/v2 v2.4.0, `github.com/prometheus/common/config` v0.68.1, `go.yaml.in/yaml/v2`. POSIX sh for the scaffolder.

**Design:** `docs/design/2026-07-21-yaml-config-layer-design.md`. Read it before Task 1.

## Global Constraints

- **No AI or automation attribution in any git artifact.** No `Co-authored-by: Claude`, no `Claude-Session:` trailer, no "Generated with", no claude.ai link, in commit messages or PR bodies.
- **Commit with `git -c commit.gpgsign=false commit`.**
- **Run `bash test/zero-source-grep.sh` before every commit.** It must print `PASS`.
- **No em dashes (—) or en dashes (–)** anywhere under `skills/prometheus-exporter/assets/` or `skills/prometheus-exporter/scripts/`. Use a period, comma, colon or parentheses. ASCII `--` in flag names is unaffected.
- **English** for every shipped artifact, comment, document and commit message.
- **Never `git push`, `git tag`, or merge.** The maintainer does that.
- **The YAML parser must be `go.yaml.in/yaml/v2`, never `gopkg.in/yaml.v3`.** `HTTPClientConfig` implements the v2 unmarshaler signature (`UnmarshalYAML(unmarshal func(interface{}) error) error`); under v3 those methods are never called, so defaults and validation silently do not run.
- **`NewClient`'s signature must not change.** Ten shipped test call sites depend on it, and so do repos scaffolded before this change.
- **A binary started without `--config.file` must behave exactly as it does today**, including using `NewClient` rather than `NewClientWithConfig`.
- **No new Go module.** `prometheus/common` is already a direct dependency; `go.yaml.in/yaml/v2` only moves from indirect to direct.
- **Never run `scaffold.sh` against the plugin repo itself.** It only ever writes to a throwaway directory.

## Verification harness

The plugin has no Go module, so the compiler is a throwaway scaffold. Go 1.26.0 and Docker are available on this machine. Use this to verify any task that changes shipped Go code:

```bash
cd "$(git rev-parse --show-toplevel)"
work=$(mktemp -d)
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst "$work" \
  --flavor http --forge none \
  --var EXPORTER_NAME=demo_exporter \
  --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 \
  --var DATA_SOURCE_PATH=/api/example \
  --var DEFAULT_PORT=9999 \
  --var OWNER=acme \
  --var LICENSE=apache-2.0
( cd "$work" && go build ./... && go test ./... )
```

Add `--target-model multi` for the multi-target tasks. The full containerised gate is `bash test/golden-smoke.sh --all` (five cells, slow); run it once in Task 9, and a single cell (`--flavor http --forge none`) whenever a task changes `scaffold.sh`.

---

### Task 1: The `internal/config` package

**Files:**
- Create: `skills/prometheus-exporter/assets/internal/config/config.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces, all used by Tasks 3, 4, 5 and 6:
  - `type Config struct { Flags map[string]any; HTTPClientConfig *promconfig.HTTPClientConfig }`
  - `func Load(path string) (*Config, error)`
  - `func (c *Config) Validate(app *kingpin.Application) error`
  - `func (c *Config) ToArgs(setOnCLI map[string]bool) []string`
  - `func CLIFlagNames(argv []string) map[string]bool`
  - `func ExtractFlagValue(argv []string, name string) string`

`CLIFlagNames` and `ExtractFlagValue` take argv **without** the program name: callers pass `os.Args[1:]`.

- [ ] **Step 1: Write the failing test**

Create `skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl`:

```go
package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alecthomas/kingpin/v2"
)

// testFlags is a flag set shaped like a real exporter's: an enum, a bool, a
// duration and a repeatable flag, which is the combination ToArgs must render.
// The parsed targets are captured at declaration time, because calling
// .Strings() a second time through GetFlag would rebind the flag to a
// different target and silently observe nothing.
type testFlags struct {
	app     *kingpin.Application
	level   *string
	addrs   *[]string
	enabled *bool
	timeout *time.Duration
}

func newApp() testFlags {
	app := kingpin.New("test", "")
	return testFlags{
		app:     app,
		level:   app.Flag("log.level", "").Default("info").Enum("debug", "info", "warn", "error"),
		addrs:   app.Flag("web.listen-address", "").Default(":9999").Strings(),
		enabled: app.Flag("collector.example", "").Default("true").Bool(),
		timeout: app.Flag("collector.example.timeout", "").Default("5s").Duration(),
	}
}

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yml")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	return path
}

func TestLoadEmptyPathIsNoOp(t *testing.T) {
	c, err := Load("")
	if err != nil {
		t.Fatalf("Load(\"\") returned an error: %v", err)
	}
	if len(c.Flags) != 0 {
		t.Errorf("Flags = %v, want empty", c.Flags)
	}
	if c.HTTPClientConfig != nil {
		t.Errorf("HTTPClientConfig = %v, want nil", c.HTTPClientConfig)
	}
	if args := c.ToArgs(nil); len(args) != 0 {
		t.Errorf("ToArgs = %v, want no arguments", args)
	}
}

func TestToArgsRendersEachShape(t *testing.T) {
	path := writeConfig(t, `
flags:
  log.level: debug
  collector.example.timeout: 10s
  collector.example: false
  web.listen-address:
    - ":9341"
    - ":9342"
`)
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	got := strings.Join(c.ToArgs(nil), " ")
	for _, want := range []string{
		"--log.level=debug",
		"--collector.example.timeout=10s",
		"--no-collector.example",
		"--web.listen-address=:9341",
		"--web.listen-address=:9342",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("ToArgs = %q, missing %q", got, want)
		}
	}
}

// A repeatable flag must end up holding exactly what the file asked for. This
// is the behaviour that writing values in after Parse would have broken: the
// default would already have been applied and the file's values appended.
func TestRepeatableFlagReplacesDefault(t *testing.T) {
	path := writeConfig(t, "flags:\n  web.listen-address: [\":9341\", \":9342\"]\n")
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	f := newApp()
	if _, err := f.app.Parse(c.ToArgs(nil)); err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(*f.addrs) != 2 || (*f.addrs)[0] != ":9341" || (*f.addrs)[1] != ":9342" {
		t.Errorf("addresses = %v, want exactly [:9341 :9342] (the default must be replaced, not extended)", *f.addrs)
	}
}

func TestCommandLineWins(t *testing.T) {
	path := writeConfig(t, "flags:\n  log.level: debug\n")
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	cli := []string{"--log.level=warn"}
	args := append(c.ToArgs(CLIFlagNames(cli)), cli...)

	f := newApp()
	if _, err := f.app.Parse(args); err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if *f.level != "warn" {
		t.Errorf("log.level = %q, want warn (the command line must win)", *f.level)
	}
}

func TestValidateRejectsUnknownFlagKey(t *testing.T) {
	path := writeConfig(t, "flags:\n  log.levl: debug\n")
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	err = c.Validate(newApp().app)
	if err == nil {
		t.Fatal("Validate accepted an unknown flag key")
	}
	if !strings.Contains(err.Error(), "log.levl") {
		t.Errorf("error = %q, want it to name the offending key", err)
	}
}

func TestValidateRejectsNullValue(t *testing.T) {
	path := writeConfig(t, "flags:\n  log.level:\n")
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if err := c.Validate(newApp().app); err == nil {
		t.Fatal("Validate accepted a null value")
	}
}

func TestLoadRejectsUnknownTopLevelKey(t *testing.T) {
	path := writeConfig(t, "instances:\n  - name: lib01\n")
	if _, err := Load(path); err == nil {
		t.Fatal("Load accepted an unknown top-level key; parsing must be strict")
	}
}

func TestLoadResolvesRelativePathsAgainstTheFile(t *testing.T) {
	path := writeConfig(t, "http_client_config:\n  tls_config:\n    ca_file: certs/corp.pem\n")
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	want := filepath.Join(filepath.Dir(path), "certs/corp.pem")
	if got := c.HTTPClientConfig.TLSConfig.CAFile; got != want {
		t.Errorf("ca_file = %q, want %q (relative to the config file, not the working directory)", got, want)
	}
}

func TestLoadRejectsInvalidHTTPClientConfig(t *testing.T) {
	path := writeConfig(t, `
http_client_config:
  basic_auth:
    username: monitor
    password: inline
    password_file: /etc/pw
`)
	if _, err := Load(path); err == nil {
		t.Fatal("Load accepted basic_auth with both password and password_file")
	}
}

func TestSecretsAreRedacted(t *testing.T) {
	path := writeConfig(t, `
http_client_config:
  basic_auth:
    username: monitor
    password: hunter2
`)
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	rendered := c.HTTPClientConfig.String()
	if strings.Contains(rendered, "hunter2") {
		t.Error("the rendered config leaked the password")
	}
	if !strings.Contains(rendered, "<secret>") {
		t.Errorf("rendered = %q, want the redaction token", rendered)
	}
}

func TestCLIFlagNames(t *testing.T) {
	got := CLIFlagNames([]string{
		"--log.level=debug",
		"--web.listen-address", ":9341",
		"--no-collector.example",
		"--", "--not-a-flag",
	})
	for _, want := range []string{"log.level", "web.listen-address", "collector.example"} {
		if !got[want] {
			t.Errorf("CLIFlagNames missing %q, got %v", want, got)
		}
	}
	if got["not-a-flag"] {
		t.Error("a token after the -- terminator was treated as a flag name")
	}
}

func TestExtractFlagValue(t *testing.T) {
	cases := []struct {
		name string
		argv []string
		want string
	}{
		{"equals form", []string{"--config.file=/etc/c.yml"}, "/etc/c.yml"},
		{"separate form", []string{"--config.file", "/etc/c.yml"}, "/etc/c.yml"},
		{"absent", []string{"--log.level=debug"}, ""},
		{"after terminator", []string{"--", "--config.file=/etc/c.yml"}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ExtractFlagValue(tc.argv, "config.file"); got != tc.want {
				t.Errorf("ExtractFlagValue = %q, want %q", got, tc.want)
			}
		})
	}
}

// Validate reads the flag model before Parse has run. Assert that is legal
// rather than trusting it: the whole layer depends on it.
func TestModelIsReadableBeforeParse(t *testing.T) {
	f := newApp()
	if len(f.app.Model().Flags) == 0 {
		t.Fatal("Model() returned no flags before Parse")
	}
	if _, err := f.app.Parse([]string{"--log.level=debug"}); err != nil {
		t.Fatalf("Parse after Model failed: %v", err)
	}
	if *f.level != "debug" {
		t.Errorf("log.level = %q, want debug: reading Model() must not disturb parsing", *f.level)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Scaffold per the Verification harness, then:

Run: `( cd "$work" && go test ./internal/config/... )`
Expected: FAIL, the package does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `skills/prometheus-exporter/assets/internal/config/config.go.tmpl`:

```go
// Package config loads this exporter's optional YAML configuration file,
// selected with --config.file.
//
// The file has two sections and one rule decides which a setting belongs to:
// anything a flag can express goes under "flags:", keyed by the flag's own
// name; anything a flag cannot express (authentication, TLS) gets its own
// section. Nothing is expressible in both, so no value ever has two sources.
//
// Resolution works by rendering "flags:" back into command-line arguments and
// letting kingpin parse them once, rather than writing values into flags after
// parsing. kingpin applies a flag's default only when that flag is absent from
// the parsed arguments, so a value written in afterwards would ADD to the
// default of a repeatable flag such as --web.listen-address instead of
// replacing it. Feeding kingpin arguments also means it performs every type
// conversion and validation itself.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alecthomas/kingpin/v2"
	promconfig "github.com/prometheus/common/config"
	"go.yaml.in/yaml/v2"
)

// Config is the parsed content of --config.file.
type Config struct {
	// Flags maps a declared flag name to the value the file gives it. The
	// value stays untyped because YAML supplies three shapes: a scalar
	// (log.level: debug), a list for a repeatable flag
	// (web.listen-address: [":9341"]), and a bool (collector.example:
	// false). kingpin converts when it parses the rendered arguments.
	Flags map[string]interface{} `yaml:"flags,omitempty"`

	// HTTPClientConfig carries the authentication and TLS no flag can
	// express. It is a pointer so an absent section is distinguishable from
	// an empty one: with no section the flavor wiring keeps calling
	// NewClient, whose transport is the one every existing deployment
	// already runs.
	HTTPClientConfig *promconfig.HTTPClientConfig `yaml:"http_client_config,omitempty"`
}

// Load reads and validates path. An empty path yields a zero Config that
// renders no arguments: that is the "no --config.file" path, and it stays
// behaviourally identical to this package not existing.
func Load(path string) (*Config, error) {
	if path == "" {
		return &Config{}, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config file: %w", err)
	}

	var c Config
	// UnmarshalStrict, not Unmarshal: prometheus/common/config's own package
	// documentation instructs callers to use it, and an unknown key is a typo
	// the operator wants to hear about rather than a setting silently dropped.
	if err := yaml.UnmarshalStrict(data, &c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}

	if c.HTTPClientConfig != nil {
		// Paths inside the file (ca_file, password_file, ...) are relative to
		// the file, not to the process working directory. An exporter started
		// by systemd runs from /, so the difference decides whether it works.
		dir, err := filepath.Abs(filepath.Dir(path))
		if err != nil {
			return nil, fmt.Errorf("resolve the directory of %s: %w", path, err)
		}
		c.HTTPClientConfig.SetDirectory(dir)

		if err := c.HTTPClientConfig.Validate(); err != nil {
			return nil, fmt.Errorf("invalid http_client_config in %s: %w", path, err)
		}
	}

	return &c, nil
}

// Validate reports any key under "flags:" that names no declared flag, or that
// carries no value. It runs before the arguments are rendered so the operator
// reads "unknown flag in the config file" instead of kingpin's bare "unknown
// long flag", which would not say where the name came from.
//
// Every flag is declared by the time this runs: main declares its own in a var
// block, the flavor wiring declares the collector's at // @@CLIENT_INIT@@, and
// register declares one --[no-]collector.<name> per collector, all before the
// call site.
func (c *Config) Validate(app *kingpin.Application) error {
	if len(c.Flags) == 0 {
		return nil
	}

	declared := make(map[string]bool)
	for _, f := range app.Model().Flags {
		declared[f.Name] = true
	}

	var unknown, empty []string
	for name, v := range c.Flags {
		if !declared[name] {
			unknown = append(unknown, name)
			continue
		}
		if v == nil {
			empty = append(empty, name)
		}
	}

	// Map iteration order is randomised; sort so the message is reproducible.
	sort.Strings(unknown)
	sort.Strings(empty)

	switch {
	case len(unknown) > 0 && len(empty) > 0:
		return fmt.Errorf("config file: unknown flag(s) under \"flags:\": %s; flag(s) with no value: %s",
			strings.Join(unknown, ", "), strings.Join(empty, ", "))
	case len(unknown) > 0:
		return fmt.Errorf("config file: unknown flag(s) under \"flags:\": %s", strings.Join(unknown, ", "))
	case len(empty) > 0:
		return fmt.Errorf("config file: flag(s) with no value under \"flags:\": %s", strings.Join(empty, ", "))
	}
	return nil
}

// ToArgs renders "flags:" as command-line arguments, omitting any flag already
// present on the real command line so a value never has two sources. The
// result is meant to be prepended to os.Args[1:], which is what makes the
// command line win without any precedence being computed.
//
// Call Validate first: ToArgs assumes every key names a declared flag and
// carries a value.
func (c *Config) ToArgs(setOnCLI map[string]bool) []string {
	if len(c.Flags) == 0 {
		return nil
	}

	names := make([]string, 0, len(c.Flags))
	for name := range c.Flags {
		names = append(names, name)
	}
	// Deterministic output: a reproducible argument list makes a failure
	// reproducible too.
	sort.Strings(names)

	var args []string
	for _, name := range names {
		if setOnCLI[name] {
			continue
		}
		args = append(args, renderFlag(name, c.Flags[name])...)
	}
	return args
}

// renderFlag turns one key and value into zero or more arguments. A bool
// becomes --name or --no-name, kingpin's own negation form. A list repeats the
// flag, which is exactly how a repeatable flag accumulates on a real command
// line.
func renderFlag(name string, v interface{}) []string {
	switch t := v.(type) {
	case bool:
		if t {
			return []string{"--" + name}
		}
		return []string{"--no-" + name}
	case []interface{}:
		args := make([]string, 0, len(t))
		for _, item := range t {
			args = append(args, fmt.Sprintf("--%s=%v", name, item))
		}
		return args
	default:
		return []string{fmt.Sprintf("--%s=%v", name, v)}
	}
}

// CLIFlagNames returns the set of long flag names present in argv, which must
// not include the program name (pass os.Args[1:]). Only presence matters, so
// values are ignored and no type information is needed.
//
// kingpin's own IsSetByUser cannot serve here. It has to be attached when a
// flag is declared, so every template and fragment would have to change; it is
// impossible for the flags exporter-toolkit declares through webflag.AddFlags,
// which does not return its clauses; and it only answers after Parse, which is
// too late to decide what Parse is given.
//
// Known limit: a flag VALUE that itself begins with "--" is counted as a flag
// name, which would drop a key the file legitimately sets. kingpin rejects such
// a command line on the following token, so the failure is loud, not silent.
func CLIFlagNames(argv []string) map[string]bool {
	names := make(map[string]bool)
	for _, tok := range argv {
		if tok == "--" {
			break // everything after the terminator is positional
		}
		if !strings.HasPrefix(tok, "--") {
			continue
		}
		name := strings.TrimPrefix(tok, "--")
		if i := strings.IndexByte(name, '='); i >= 0 {
			name = name[:i]
		}
		if name == "" {
			continue
		}
		names[name] = true
		// --no-collector.example negates the flag named collector.example.
		// Record both spellings rather than guessing which one is declared:
		// this set is only ever used to omit a key, so recording one name too
		// many is safe, while missing one would let a value have two sources.
		names[strings.TrimPrefix(name, "no-")] = true
	}
	return names
}

// ExtractFlagValue returns the value of one long flag from argv (again without
// the program name), handling both --name=value and --name value. It exists
// because --config.file has to be read before kingpin parses anything: its
// value decides which arguments kingpin is given.
func ExtractFlagValue(argv []string, name string) string {
	for i, tok := range argv {
		if tok == "--" {
			return ""
		}
		switch {
		case tok == "--"+name:
			if i+1 < len(argv) {
				return argv[i+1]
			}
			return ""
		case strings.HasPrefix(tok, "--"+name+"="):
			return strings.TrimPrefix(tok, "--"+name+"=")
		}
	}
	return ""
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `( cd "$work" && go test ./internal/config/... -v )`
Expected: PASS, every test.

If `go.yaml.in/yaml/v2` is reported as missing from `go.mod`, do **not** run `go get`. Task 7 promotes it to a direct require; for now confirm the failure is only that, and note it in your report.

- [ ] **Step 5: Verify the dash gate and commit**

Run: `grep -rn $'—\|–' skills/prometheus-exporter/assets/internal/config/`
Expected: no output.

Run: `bash test/zero-source-grep.sh`
Expected: `PASS`.

```bash
git add skills/prometheus-exporter/assets/internal/config/
git -c commit.gpgsign=false commit -m "feat(assets): add internal/config, the YAML configuration layer

Renders the flags: section back into command-line arguments so kingpin
parses once and performs every conversion itself. Writing values in after
Parse would append to a repeatable flag's already-applied default."
```

---

### Task 2: `NewClientWithConfig`

**Files:**
- Modify: `skills/prometheus-exporter/assets/code/http/client.go.tmpl:44-60`
- Test: `skills/prometheus-exporter/assets/code/http/collector_test.go.tmpl` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `func NewClientWithConfig(target string, timeout time.Duration, httpCfg promconfig.HTTPClientConfig) (*Client, error)`, used by Tasks 4 and 6.

**`NewClient` must keep its exact current signature.** Ten call sites in shipped test templates depend on it.

- [ ] **Step 1: Write the failing test**

Append to `skills/prometheus-exporter/assets/code/http/collector_test.go.tmpl`:

```go
func TestNewClientWithConfigAppliesBasicAuth(t *testing.T) {
	var gotUser, gotPass string
	var gotOK bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotUser, gotPass, gotOK = r.BasicAuth()
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("{}"))
	}))
	defer srv.Close()

	cfg := promconfig.HTTPClientConfig{
		BasicAuth: &promconfig.BasicAuth{Username: "monitor", Password: "hunter2"},
	}
	c, err := NewClientWithConfig(srv.URL, time.Second, cfg)
	if err != nil {
		t.Fatalf("NewClientWithConfig: %v", err)
	}
	if _, err := c.Fetch(context.Background(), "/"); err != nil {
		t.Fatalf("Fetch: %v", err)
	}

	if !gotOK {
		t.Fatal("the request carried no basic auth header")
	}
	if gotUser != "monitor" || gotPass != "hunter2" {
		t.Errorf("credentials = %q/%q, want monitor/hunter2", gotUser, gotPass)
	}
}

func TestNewClientWithConfigRejectsAnUnreadableCA(t *testing.T) {
	cfg := promconfig.HTTPClientConfig{
		TLSConfig: promconfig.TLSConfig{CAFile: "/nonexistent/ca.pem"},
	}
	if _, err := NewClientWithConfig("https://example.invalid", time.Second, cfg); err == nil {
		t.Fatal("NewClientWithConfig accepted a CA file that cannot be read")
	}
}
```

Add `promconfig "github.com/prometheus/common/config"` to that file's imports (and `net/http`, `net/http/httptest`, `context`, `time` if not already present).

- [ ] **Step 2: Run the test to verify it fails**

Run: `( cd "$work" && go test ./internal/collector/... -run NewClientWithConfig )`
Expected: FAIL, `undefined: NewClientWithConfig`.

- [ ] **Step 3: Write the implementation**

In `skills/prometheus-exporter/assets/code/http/client.go.tmpl`, add `promconfig "github.com/prometheus/common/config"` to the imports and append after `NewClient`:

```go
// NewClientWithConfig builds a Client whose transport carries the
// authentication and TLS declared in --config.file's http_client_config
// section. It sits beside NewClient rather than replacing it: NewClient's
// signature is depended on by every collector test this scaffold ships and by
// any repo scaffolded before the configuration layer existed.
//
// Use it only when the operator actually supplied that section. With no
// section, keep calling NewClient: NewClientFromConfig returns a client with
// its own transport settings, so routing the no-authentication case through
// here would quietly change connection behaviour (keep-alives, HTTP/2) for
// every existing deployment.
func NewClientWithConfig(target string, timeout time.Duration, httpCfg promconfig.HTTPClientConfig) (*Client, error) {
	hc, err := promconfig.NewClientFromConfig(httpCfg, "@@NAMESPACE@@")
	if err != nil {
		return nil, fmt.Errorf("build HTTP client from http_client_config: %w", err)
	}
	// NewClientFromConfig sets no overall deadline, so apply the same
	// per-request timeout NewClient applies.
	hc.Timeout = timeout
	return &Client{httpClient: hc, baseURL: target}, nil
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `( cd "$work" && go test ./internal/collector/... )`
Expected: PASS, including the 10 pre-existing `NewClient` call sites, untouched.

- [ ] **Step 5: Gate and commit**

Run: `grep -rn $'—\|–' skills/prometheus-exporter/assets/code/http/` (expect no output), then `bash test/zero-source-grep.sh` (expect `PASS`).

```bash
git add skills/prometheus-exporter/assets/code/http/
git -c commit.gpgsign=false commit -m "feat(assets): add NewClientWithConfig beside NewClient

Delegates authentication and TLS to prometheus/common/config, already a
direct dependency. NewClient keeps its signature so the shipped tests and
pre-existing scaffolds keep compiling."
```

---

### Task 3: Wire `--config.file` into the single-target main

**Files:**
- Modify: `skills/prometheus-exporter/assets/mains/single/main.go.tmpl:34-46` (flag), `:128-130` (parse)

**Interfaces:**
- Consumes: Task 1's `Load`, `Validate`, `ToArgs`, `CLIFlagNames`, `ExtractFlagValue`.
- Produces: a `cfg` variable in scope for the rest of `main()`, consumed by Task 4's `client_build.frag`.

- [ ] **Step 1: Declare the flag**

In the `var` block, after `disableExporterMetrics`, add:

```go
	// configFile is declared like any other flag so it appears in --help and
	// so Validate can reject a "flags:" key naming it. Its VALUE is read
	// straight from os.Args below, before parsing, because it decides which
	// arguments the parser is given.
	configFile = kingpin.Flag(
		"config.file",
		"Path to a YAML configuration file. Unrelated to --web.config.file, which configures the TLS server this exporter exposes.",
	).Default("").String()
```

Add `"@@MODULE_PATH@@/internal/config"` to the imports.

- [ ] **Step 2: Replace the parse call**

Replace `kingpin.Parse()` (currently line 130) with:

```go
	kingpin.Parse()
```

becomes

```go
	// The configuration file is resolved by rendering its "flags:" section
	// back into arguments and letting kingpin parse them once, ahead of the
	// real command line so the command line wins. See internal/config for why
	// values are not written into flags after parsing.
	cfg, err := config.Load(config.ExtractFlagValue(os.Args[1:], "config.file"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := cfg.Validate(kingpin.CommandLine); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// The logger does not exist yet (it is built from flags, below), so a
	// failure here goes to stderr.
	kingpin.MustParse(kingpin.CommandLine.Parse(
		append(cfg.ToArgs(config.CLIFlagNames(os.Args[1:])), os.Args[1:]...),
	))
```

Keep the `kingpin.Version(...)` and `kingpin.HelpFlag.Short('h')` lines immediately above, unchanged.

`configFile` is declared but its parsed value is deliberately unused; add `_ = configFile` next to the declaration only if the linter complains, with a comment saying the value is read from `os.Args` before parsing.

- [ ] **Step 3: Verify a file actually changes behaviour**

Scaffold per the harness, then:

```bash
( cd "$work" && go build -o /tmp/demo ./cmd/demo_exporter )
printf 'flags:\n  log.level: debug\n' > /tmp/demo-config.yml
/tmp/demo --config.file=/tmp/demo-config.yml --web.listen-address=:19999 2>&1 | head -3
```
Expected: the startup log is emitted at debug level.

```bash
/tmp/demo --config.file=/tmp/demo-config.yml --log.level=error --web.listen-address=:19999 2>&1 | head -3
```
Expected: no debug lines. The command line wins.

```bash
printf 'flags:\n  log.levl: debug\n' > /tmp/demo-bad.yml
/tmp/demo --config.file=/tmp/demo-bad.yml; echo "exit=$?"
```
Expected: an error naming `log.levl`, `exit=1`.

```bash
/tmp/demo --help | grep -c 'config.file'
```
Expected: at least `1`.

- [ ] **Step 4: Verify the no-file path is unchanged**

Run: `( cd "$work" && make build && make check )`
Expected: both pass.

- [ ] **Step 5: Gate and commit**

Run the dash grep over `skills/prometheus-exporter/assets/mains/` and `bash test/zero-source-grep.sh`.

```bash
git add skills/prometheus-exporter/assets/mains/single/
git -c commit.gpgsign=false commit -m "feat(assets): wire --config.file into the single-target main

The file's flags: section is rendered into arguments and parsed ahead of
the real command line, so the command line wins structurally and no
ordering constraint remains inside main()."
```

---

### Task 4: The three-marker http wiring seam

**Files:**
- Modify: `skills/prometheus-exporter/assets/mains/single/main.go.tmpl` (add the `// @@CLIENT_BUILD@@` marker after the parse block from Task 3)
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/client_init.frag`
- Create: `skills/prometheus-exporter/assets/code/http/wiring/client_build.frag`
- Create: `skills/prometheus-exporter/assets/code/cli/wiring/client_build.frag`
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/registry.frag`
- Modify: `skills/prometheus-exporter/assets/scaffold.sh:52-56, 62-67, 464-467, 536`

**Interfaces:**
- Consumes: Task 2's `NewClientWithConfig`, Task 3's `cfg`.
- Produces: the `// @@CLIENT_BUILD@@` marker, consumed by Task 8's `/add-collector` documentation.

**Why a third marker:** `NewClientWithConfig` returns an error, and `register()`'s closure returns only a `prometheus.Collector`. The client therefore cannot be built inside `registry.frag`. It also cannot be built at `// @@CLIENT_INIT@@`, which runs before `Parse()`. So the client is **declared** before parsing and **assigned** after, the same deferred-capture pattern `register()`'s doc comment already describes for `log`.

- [ ] **Step 1: Add the marker to the single main**

Immediately after the `kingpin.MustParse(...)` block from Task 3, add:

```go
	// @@CLIENT_BUILD@@
```

- [ ] **Step 2: Declare the client in `client_init.frag`**

Replace the contents of `code/http/wiring/client_init.frag` with:

```
	exampleTarget := kingpin.Flag("collector.example.target", "Base URL the example collector scrapes.").Default("@@DATA_SOURCE@@").String()
	exampleTimeout := kingpin.Flag("collector.example.timeout", "Per-request timeout for the example collector.").Default("5s").Duration()
	// Declared here, assigned at // @@CLIENT_BUILD@@ once flags are parsed.
	// The registry closure below captures it by reference and only
	// dereferences it later, in main's construction loop.
	var exampleClient *collector.Client
```

- [ ] **Step 3: Create `client_build.frag`**

```
	if cfg.HTTPClientConfig != nil {
		exampleClient, err = collector.NewClientWithConfig(*exampleTarget, *exampleTimeout, *cfg.HTTPClientConfig)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	} else {
		// No http_client_config section: keep the transport every existing
		// deployment already runs.
		exampleClient = collector.NewClient(*exampleTarget, *exampleTimeout)
	}
```

`err` is already in scope from Task 3's `cfg, err := config.Load(...)`.

- [ ] **Step 4: Point `registry.frag` at the built client**

```
	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, exampleClient)
	}, true)
	register("http_client_requests", func() prometheus.Collector { return collector.RequestDuration }, true)
```

- [ ] **Step 5: Refuse `http_client_config:` in the cli flavor**

The design makes `http_client_config:` an http-flavor capability. A cli-flavor exporter invokes a local binary, so there is no HTTP request to authenticate and the block would be silently ignored. Refuse it instead.

Create `skills/prometheus-exporter/assets/code/cli/wiring/client_build.frag`:

```
	if cfg.HTTPClientConfig != nil {
		fmt.Fprintln(os.Stderr, "config file: http_client_config is not supported by this exporter. "+
			"It runs a local command rather than issuing HTTP requests, so there is nothing to authenticate.")
		os.Exit(1)
	}
```

This reuses the same `// @@CLIENT_BUILD@@` marker, so the flavors stay symmetric: each supplies its own fragment and `scaffold.sh` needs no flavor-specific branch. `code/cli/wiring/client_init.frag` and the cli `registry.frag` are unchanged.

- [ ] **Step 6: Teach `scaffold.sh` the third pair**

At `:464-467`, extend the pair list:

```sh
    for pair in \
      "client_init.frag:@@CLIENT_INIT@@" \
      "client_build.frag:@@CLIENT_BUILD@@" \
      "registry.frag:@@COLLECTOR_REGISTRY@@" \
      "probe_factory.frag:@@PROBE_FACTORIES@@"; do
```

At `:536`, add `CLIENT_BUILD` to the residual-sentinel exemption:

```sh
grep -v -E '@@(CLIENT_INIT|CLIENT_BUILD|COLLECTOR_REGISTRY|PROBE_FACTORIES)@@' "$sentinels"
```

Update the header comment at `:52-56` and `:62-67` to list the four markers, keeping its existing wording style. **No em dashes.**

- [ ] **Step 7: Verify**

Run the harness scaffold, then:

```bash
grep -n 'CLIENT_BUILD' "$work/cmd/demo_exporter/main.go"; echo "exit=$?"
```
Expected: no output and a non-zero exit. The marker must have been consumed, not left behind.

```bash
grep -n 'exampleClient' "$work/cmd/demo_exporter/main.go"
```
Expected: three lines, the declaration, the assignment branch and the registry closure.

Run: `( cd "$work" && make build && make check )`
Expected: both pass.

Then prove authentication reaches the wire. `monitor:hunter2` base64-encodes to `bW9uaXRvcjpodW50ZXIy`:

```bash
printf 'flags:\n  collector.example.target: http://127.0.0.1:19998\nhttp_client_config:\n  basic_auth:\n    username: monitor\n    password: hunter2\n' > /tmp/demo-auth.yml
( cd "$work" && go build -o /tmp/demo ./cmd/demo_exporter )
( printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}' | timeout 20 nc -l 127.0.0.1 19998 > /tmp/demo-req.txt ) &
/tmp/demo --config.file=/tmp/demo-auth.yml --web.listen-address=:19996 &
sleep 1; curl -s -o /dev/null http://127.0.0.1:19996/metrics; sleep 1
kill %1 %2 2>/dev/null
grep -i '^Authorization:' /tmp/demo-req.txt
```
Expected: `Authorization: Basic bW9uaXRvcjpodW50ZXIy`. Paste the observed line into your report. If `nc` is unavailable, substitute any one-shot listener that dumps the request headers and say which you used.

Now verify the cli refusal:

```bash
cliwork=$(mktemp -d)
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst "$cliwork" \
  --flavor cli --forge none \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter --var DATA_SOURCE=demo_cli \
  --var DATA_SOURCE_PATH=unused --var DEFAULT_PORT=9999 \
  --var OWNER=acme --var LICENSE=apache-2.0
( cd "$cliwork" && go build -o /tmp/democli ./cmd/demo_exporter && make check )
printf 'http_client_config:\n  basic_auth:\n    username: monitor\n    password: x\n' > /tmp/demo-cli.yml
/tmp/democli --config.file=/tmp/demo-cli.yml; echo "exit=$?"
```
Expected: a message saying the block is unsupported, and `exit=1`.

Finally, confirm both cells still pass end to end:

Run: `bash test/golden-smoke.sh --flavor http --forge none && bash test/golden-smoke.sh --flavor cli --forge none`
Expected: both cells pass.

- [ ] **Step 8: Gate and commit**

Dash grep over `skills/prometheus-exporter/assets/`, then `bash test/zero-source-grep.sh`.

```bash
git add skills/prometheus-exporter/assets/
git -c commit.gpgsign=false commit -m "feat(assets): build the http client at a new @@CLIENT_BUILD@@ marker

NewClientWithConfig returns an error and register's closure cannot, so
the client is declared before parsing and assigned after it, the same
deferred-capture pattern register already documents for log. With no
http_client_config section the wiring still calls NewClient, so the
transport is unchanged for every existing deployment."
```

---

### Task 5: Wire `--config.file` into the multi-target main

**Files:**
- Modify: `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl:31-49` (flag), `:90-92` (parse)

**Interfaces:**
- Consumes: Task 1's package.
- Produces: `cfg` in scope at the `// @@PROBE_FACTORIES@@` marker (`:109`), consumed by Task 6.

The multi main needs **no new marker**: `// @@PROBE_FACTORIES@@` already sits after `kingpin.Parse()`.

- [ ] **Step 1: Apply the same flag and parse change as Task 3**

Add the identical `configFile` flag declaration to the `var` block, add the `internal/config` import, and replace `kingpin.Parse()` (`:92`) with the same `Load` / `Validate` / `MustParse` block. Use the same comments: the two mains are read side by side by anyone comparing target models, and divergent wording reads as a divergent mechanism.

Leave `modules, err := probe.ParseModules(...)` at `:111` **exactly as it is**. Go's short variable declaration is legal whenever at least one variable on the left is new: `modules` is new, so `err` is reassigned rather than redeclared, in the same scope. Nothing there needs to change (verified by compiling the equivalent shape).

- [ ] **Step 2: Verify**

Scaffold with `--target-model multi` added to the harness command, then:

Run: `( cd "$work" && make build && make check )`
Expected: both pass.

```bash
printf 'flags:\n  probe.timeout: 12s\n' > /tmp/demo-multi.yml
( cd "$work" && go run ./cmd/demo_exporter --config.file=/tmp/demo-multi.yml --web.listen-address=:19997 ) &
sleep 2
curl -s 'http://127.0.0.1:19997/probe?target=http://127.0.0.1:1' | grep probe_timeout_seconds
kill %1
```
Expected: `probe_timeout_seconds 12`.

- [ ] **Step 3: Gate and commit**

```bash
git add skills/prometheus-exporter/assets/mains/multi/
git -c commit.gpgsign=false commit -m "feat(assets): wire --config.file into the multi-target main

Its // @@PROBE_FACTORIES@@ marker already sits after Parse, so the multi
model needs no new marker: only the parse call changes."
```

---

### Task 6: The probe factory seam

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl:34-49` (Factory), `:222-224` (call site)
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl:42` and `:200-205`
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag`

**Interfaces:**
- Consumes: Task 2's `NewClientWithConfig`, Task 5's `cfg`.
- Produces: `type Factory func(ctx context.Context, target string, timeout time.Duration) (prometheus.Collector, error)`.

`Factory` gains **only an error return**, not a config parameter. The frag's closure captures `cfg` from `main`'s scope, exactly as it already captures `log`, so `internal/probe` never imports `prometheus/common/config`.

- [ ] **Step 1: Change the signature**

`probe.go.tmpl:40` becomes:

```go
type Factory func(ctx context.Context, target string, timeout time.Duration) (prometheus.Collector, error)
```

Extend its doc comment with: a factory may now fail, which happens when the configured authentication or TLS cannot be turned into a client (an unreadable CA file, for example). That is a configuration error, so it fails the probe loudly rather than being reported as an unreachable target.

- [ ] **Step 2: Handle the error at the call site**

`probe.go.tmpl:222-224` becomes:

```go
	for _, nf := range factories {
		c, err := nf.New(ctx, target, timeout)
		if err != nil {
			// A construction failure is a configuration fault, not a target
			// fault: reporting it as probe_success 0 would blame the target.
			h.log.Error("Failed to build collector for probe", "collector", nf.Name, "target", target, "err", err)
			http.Error(w, fmt.Sprintf("collector %s: %v", nf.Name, err), http.StatusInternalServerError)
			return
		}
		tracker.Add(nf.Name, c)
	}
```

Ensure `fmt` is imported.

- [ ] **Step 3: Update the two test factories**

At `probe_test.go.tmpl:42`, `recordingFactory.make` must return `(prometheus.Collector, error)`, returning `nil` as the error. At `:200-205`, the inline `hang` factory literal gains the same return.

Then add a test proving a failing factory produces 500 rather than `probe_success 0`:

```go
func TestProbeFailsLoudlyWhenAFactoryFails(t *testing.T) {
	bad := NamedFactory{
		Name: "bad",
		New: func(ctx context.Context, target string, timeout time.Duration) (prometheus.Collector, error) {
			return nil, errors.New("unreadable CA file")
		},
	}
	h := NewHandler(logger.NewTextLogger("error"), []NamedFactory{bad}, nil, 5*time.Second, 0, nil)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/probe?target=http://example.invalid", nil))

	if rec.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "probe_success") {
		t.Error("a construction failure was reported as a probe result; it must not blame the target")
	}
}
```

- [ ] **Step 4: Update `probe_factory.frag`**

```
	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(ctx context.Context, target string, timeout time.Duration) (prometheus.Collector, error) {
			if cfg.HTTPClientConfig != nil {
				c, err := collector.NewClientWithConfig(target, timeout, *cfg.HTTPClientConfig)
				if err != nil {
					return nil, err
				}
				return collector.NewExampleCollector(ctx, log, c), nil
			}
			return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
```

- [ ] **Step 5: Verify**

Run: `( cd "$work" && go test ./internal/probe/... -v )` (multi scaffold)
Expected: PASS, including the new test.

Run: `( cd "$work" && make build && make check )`
Expected: both pass.

Run: `bash test/golden-smoke.sh --flavor http --forge none --target-model multi`
Expected: the cell passes, including its live `/probe` round-trip.

- [ ] **Step 6: Gate and commit**

```bash
git add skills/prometheus-exporter/assets/internal/probe/ skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag
git -c commit.gpgsign=false commit -m "feat(assets): let a probe factory fail

Building a client from http_client_config can fail on an unreadable CA
or credentials file. Factory gains an error return and the handler
answers 500, so a configuration fault is never reported as a failed
probe of an innocent target. The config block is captured by the frag's
closure, so internal/probe imports no HTTP client configuration."
```

---

### Task 7: Shipped documentation and `go.mod`

**Files:**
- Modify: `skills/prometheus-exporter/assets/docs/configuration.md.tmpl` (`:7` is now false; new section before `:91`)
- Create: `skills/prometheus-exporter/assets/config.example.yml.tmpl`
- Modify: `skills/prometheus-exporter/assets/go.mod.tmpl:31`

- [ ] **Step 1: Promote the YAML parser to a direct require**

Move `go.yaml.in/yaml/v2 v2.4.4` from the indirect block (`:31`) into the direct `require` block, dropping the `// indirect` comment. Do not change any version. Do not add any module.

- [ ] **Step 2: Write `config.example.yml.tmpl`**

A commented example, never loaded by default. Cover: the one rule (flag-expressible goes under `flags:`), the precedence order, at least one repeatable flag, one bool, a `basic_auth` block using `password_file` rather than an inline password, and a `tls_config` block.  State that paths are relative to this file.

**The `http_client_config:` block must be commented out**, and the `flags:` entries must reference only flags a default scaffold declares. The file is checked in Step 4 by feeding it to a real binary: an active block pointing at `/etc/exporter/pw` would fail to load on any machine, which would make the example untestable and therefore untrustworthy. A commented block still teaches the shape.

- [ ] **Step 3: Correct and extend `configuration.md.tmpl`**

Line 7 currently reads "The exporter is configured entirely through command-line flags." That is now false. Rewrite it and the "Basic execution" framing that follows.

Add a `## Configuration file` section before `### The /probe?target= endpoint` (`:91`) covering:
- `--config.file`, and that it is **empty by default**, so nothing changes unless you pass it.
- The two sections and the single rule.
- The precedence order: command line, then the file, then the environment, then defaults. Say plainly that the environment sits below the file.
- A prominent statement that `--config.file` is **not** `--web.config.file`: the first configures what the exporter queries, the second the TLS server it exposes.
- That `http_client_config:` is http-flavor only.
- That paths inside the file resolve relative to the file.
- That secrets are better given as `*_file` than inline.

- [ ] **Step 4: Verify**

Run the harness scaffold and confirm `config.example.yml` exists at the repo root with no `@@` sentinel left:

```bash
[ -f "$work/config.example.yml" ] && ! grep -q '@@' "$work/config.example.yml" && echo ok
```
Expected: `ok`.

Feed the example to the built binary to prove it is valid, not just prose:

```bash
( cd "$work" && go build -o /tmp/demo ./cmd/demo_exporter && /tmp/demo --config.file=config.example.yml --help >/dev/null ) && echo "example parses"
```
Expected: `example parses`. If the example intentionally references files that do not exist, use a trimmed copy for this check and say so in your report.

Run: `( cd "$work" && make check )`
Expected: pass.

- [ ] **Step 5: Gate and commit**

```bash
git add skills/prometheus-exporter/assets/
git -c commit.gpgsign=false commit -m "docs(assets): document the configuration file

configuration.md claimed the exporter is configured entirely through
flags, which is no longer true. Adds the file's format, the precedence
order, and the distinction from --web.config.file."
```

---

### Task 8: Plugin knowledge

**Files:**
- Modify: `commands/add-collector.md:386-496` (the http variants at `:393-408` and `:426-446`)
- Modify: `skills/prometheus-exporter/references/collector-pattern.md`
- Modify: `skills/prometheus-exporter/references/project-scaffold.md`
- Modify: `commands/new-prometheus-exporter.md`

- [ ] **Step 1: Teach `/add-collector` the third marker**

`:388` says "Both markers already exist verbatim in `cmd/*/main.go`". Update it for three. Add a `// @@CLIENT_BUILD@@` insertion step to the **http** variants only (`:393-408` sync, `:426-446` background); the cli variants (`:410-424`, `:448-466`) are unaffected, since `client_build.frag` is http only.

Extend the explanatory block at `:468-496` with where each marker sits relative to `kingpin.Parse()`: `@@CLIENT_INIT@@` and `@@COLLECTOR_REGISTRY@@` before it, `@@CLIENT_BUILD@@` after it.

The multi-target section (`:75-133`) needs only the `Factory` signature update from Task 6, not a new marker.

- [ ] **Step 2: Update the references**

Both reference files document `NewClient`'s signature. Add `NewClientWithConfig` beside it and state the rule for choosing: with an `http_client_config:` section, use the new one; without, keep `NewClient`, because its transport is what existing deployments run.

- [ ] **Step 3: Mention the layer in `new-prometheus-exporter.md`**

One short passage: every scaffold ships `internal/config` and an unconditional `--config.file`, empty by default.

- [ ] **Step 4: Verify**

Run: `bash test/zero-source-grep.sh`
Expected: `PASS`. (These files live under `commands/` and `skills/`, so the handle rule applies to them.)

Re-read each edited passage against the actual shipped code and confirm every marker name, function signature and file path you wrote matches. Quote in your report the exact `grep -n` output proving `@@CLIENT_BUILD@@` exists in `mains/single/main.go.tmpl` and in `scaffold.sh`'s pair list.

- [ ] **Step 5: Commit**

```bash
git add commands/ skills/prometheus-exporter/references/
git -c commit.gpgsign=false commit -m "docs(plugin): teach /add-collector the @@CLIENT_BUILD@@ marker"
```

---

### Task 9: Plugin tests, CHANGELOG, ROADMAP

**Files:**
- Modify: `test/golden-smoke.sh` (per-cell block ends `:322`; add-collector sub-check `:1078-1081`)
- Modify: `test/scaffold_edge_test.sh:229, :231`
- Modify: `test/scaffold_multitarget_test.sh:54, :61-62`
- Modify: `CHANGELOG.md`, `ROADMAP.md`

- [ ] **Step 1: Assert the layer ships in every cell**

After the `.github/` presence block ends (`:322`) and before `git init` (`:339`), following the existing idiom exactly:

```sh
echo "== internal/config/ present ($flavor/$forge) =="
[ -f "$work/internal/config/config.go" ] || die "internal/config/config.go missing after scaffold ($flavor/$forge)"
[ -f "$work/config.example.yml" ] || die "config.example.yml missing after scaffold ($flavor/$forge)"
echo "confirmed: configuration layer present ($flavor/$forge)"
```

- [ ] **Step 2: Assert the third marker in the add-collector sub-check**

Extend `:1078-1081` with a `@@CLIENT_BUILD@@` pair, mirroring the two existing `grep -q` plus `sed` lines exactly.

- [ ] **Step 3: Update the two marker-enumerating test scripts**

`test/scaffold_edge_test.sh:229, :231` enumerate the marker set: add `CLIENT_BUILD`.

`test/scaffold_multitarget_test.sh:54, :61-62` assert `CLIENT_INIT` and `COLLECTOR_REGISTRY` are **absent** from multi's `main.go`. That assertion stays true, since `CLIENT_BUILD` is not in the multi model either. Add `CLIENT_BUILD` to the same absence assertion and confirm it passes rather than assuming it.

- [ ] **Step 4: Run the full gate**

Run: `bash test/golden-smoke.sh --all`
Expected: five cells, all passing. **Paste the final summary lines into your report.** This is the only complete proof the change is safe.

Run: `bash test/scaffold_edge_test.sh && bash test/scaffold_multitarget_test.sh && bash test/scaffold_test.sh`
Expected: all pass.

- [ ] **Step 5: CHANGELOG and ROADMAP**

Add to `CHANGELOG.md`'s existing `[Unreleased]` section, under `### Added`. Do **not** create a version heading and do **not** tag: the maintainer decides the version. Cover the file, the two sections, the precedence order, the authentication capability, and that a binary without `--config.file` is unchanged.

Add a `## v0.4` section to `ROADMAP.md` between `## v0.3 (released)` and `## v1.0`, in the same voice as the existing entries. State plainly that the instance list and the fan-out target model are v0.5 and are not in this release.

- [ ] **Step 6: Gate and commit**

Run: `bash test/zero-source-grep.sh`
Expected: `PASS`.

```bash
git add test/ CHANGELOG.md ROADMAP.md
git -c commit.gpgsign=false commit -m "test(plugin): assert the configuration layer ships in every cell

Adds the internal/config presence check to the per-cell block and the
third marker to the add-collector sub-check and the two marker-
enumerating scaffold tests. No new cell: the layer is unconditional."
```

---

## Done criteria

- `bash test/golden-smoke.sh --all` passes all five cells.
- `bash test/zero-source-grep.sh` prints `PASS`.
- No em or en dash under `skills/prometheus-exporter/assets/` or `skills/prometheus-exporter/scripts/`.
- A scaffold with no `--config.file` builds and behaves exactly as before, and still calls `NewClient`.
- `NewClient`'s signature is unchanged, and the 10 pre-existing test call sites are untouched.
- `go.mod` gained no module; only `go.yaml.in/yaml/v2` moved from indirect to direct.
- Nothing pushed, nothing tagged.
