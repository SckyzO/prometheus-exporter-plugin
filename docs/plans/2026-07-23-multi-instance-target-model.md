# Multi-instance target model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third `--target-model`, `multi-instance`: one exporter process watches a list of machines declared in `--config.file`, each refreshed by its own background poller, all served through a single `/metrics` that Prometheus scrapes as one target.

**Architecture:** A shared YAML schema (`modules:` credential bundles, `instances:` machine list) parsed by `internal/config`. A new `internal/instance` seam mirrors `probe.NamedFactory` but carries the background lifecycle (`Start`/`Done`/interval) the synchronous probe seam cannot. A new `mains/multi-instance/main.go.tmpl` fans out over instances at boot, wrapping each instance's collectors in `prometheus.WrapRegistererWith` so a `target=` label distinguishes them. `scaffold.sh` gains the third target-model value and ships the background collector variant as the starter.

**Tech Stack:** Go, kingpin/v2, prometheus/client_golang, prometheus/common/config (`promconfig`), prometheus/exporter-toolkit, POSIX sh (scaffold.sh). Design doc: `docs/design/2026-07-23-multi-instance-target-model-design.md`.

**Scope of this plan:** the config foundation and volet B (the `multi-instance` model). **Volet A** (per-target credentials for the existing `multi`/`?target=` model, spec §1A) is an independent, additive change to `internal/probe` and is sequenced as a separate follow-up plan on the same epic branch. Both ship in v0.5.0.

## Global Constraints

Every task's requirements implicitly include this section.

- **No AI/automation attribution in any git artifact** (no `Co-authored-by: Claude`, no `Claude-Session:`, no "Generated with…", no claude.ai links), in commit messages OR PR bodies.
- **Commit with `git -c commit.gpgsign=false commit`**; tag with `git -c tag.gpgsign=false tag`.
- **Run `test/zero-source-grep.sh` before every commit.** It must print `PASS`. No `slurm`/`sacct` in taught content; no `sckyzo` handle under `skills/`, `commands/`, `agents/`.
- **No em/en dashes (U+2014 `—`, U+2013 `–`)** in any shipped `assets/` or `scripts/` content. Use commas, periods, colons, or parentheses.
- **English** for all shipped artifacts, commit messages, and public docs.
- **kingpin parses the flag surface exactly once** (the v0.4.0 central invariant). No per-instance flag overrides; a value never has two sources.
- **The instance label name is fixed at scaffold time** by `scaffold.sh --instance-label` (default `target`), baked into generated code, never a runtime knob.
- **`--target-model multi-instance` requires `--flavor http`**; reject `cli` fail-fast, mirroring `scaffold.sh:191-192`.
- **`multi-instance` requires `--config.file` at boot** (it lists the instances); fail-fast without it.
- **Background collector is mandatory on `multi-instance`.** The starter is the background variant; `/add-collector` refuses the synchronous variant there.
- **Instances reference a module by name, never inline auth.** Omitting `module:` means the `default` module.
- **Fail-fast at boot on any configuration error** (non-unique names, non-http address, unresolved module, unreadable CA/secret file). A single instance going down at runtime is isolated, never fatal.
- **`internal/instance` mirrors, does not reuse, `probe.NamedFactory`.** The probe seam stays untouched (zero regression to the shipped `multi` runtime).

### Testing template Go (the `.tmpl` files under `assets/`)

The Go under `assets/` carries `@@VAR@@` sentinels and only compiles after scaffolding. Two ways to run its tests, both used below:

- **End-to-end (preferred once scaffold support lands):** `test/golden-smoke.sh --flavor http --forge none --target-model multi-instance` scaffolds a demo exporter into `test/_work/`, `go build`s it, `go test ./...`s it, and smoke-tests the binary. This is how `internal/config`, `internal/instance`, and the main are verified together.
- **In isolation (before scaffold support exists, for Tasks 3):** copy the template file(s) into a scratch Go module, `sed -e 's/@@MODULE_PATH@@/example.com\/demo/g' -e 's/@@NAMESPACE@@/demo/g'` (and any other sentinels), strip `.tmpl`, then `go test ./...`. The scratch module must also contain the packages the file imports (`internal/collector`, `internal/logger`).

`internal/config` ships on **every** target model, so Tasks 1-2 are testable by scaffolding an ordinary single-target demo today (`--target-model single`) and running `go test ./internal/config/`.

---

## Phase 0: Shared configuration schema (`internal/config`)

### Task 1: Parse `modules:` and `instances:`; validate each module's client config

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/config/config.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl`

**Interfaces:**
- Produces: `config.Module{Collectors []string; HTTPClientConfig *promconfig.HTTPClientConfig}`, `config.Instance{Name, Address, Module string; Labels map[string]string}`, and `Config.Modules map[string]Module`, `Config.Instances []Instance`. Task 2 and the multi-instance main consume these.

- [ ] **Step 1: Add the two new types and fields.** In `config.go.tmpl`, add the `Modules`/`Instances` fields to the `Config` struct (immediately after the `HTTPClientConfig` field, before the closing `}` at line 45):

```go
	// Modules are named credential/TLS bundles, Blackbox-shaped. A
	// multi-instance instance references one by name for its transport. A nil
	// HTTPClientConfig means the default transport. (The multi /probe model
	// will select one per request in a later version; volet A.)
	Modules map[string]Module `yaml:"modules,omitempty"`

	// Instances is the list of machines a multi-instance exporter watches.
	// Meaningful only under the multi-instance target model; single and multi
	// reject it at boot.
	Instances []Instance `yaml:"instances,omitempty"`
```

Then add the two types immediately after the `Config` struct's closing brace:

```go
// Module is a named bundle of an optional collector subset and an optional
// outbound HTTP client config, shaped like a Blackbox exporter module.
type Module struct {
	// Collectors narrows a probe to this subset. Honoured only under the multi
	// (/probe) model; multi-instance enables collectors globally via the
	// --collector.<name> flags and refuses this key at boot (see
	// ResolveInstances).
	Collectors []string `yaml:"collectors,omitempty"`

	// HTTPClientConfig carries the authentication and TLS this module applies,
	// the same promconfig.HTTPClientConfig the top-level section uses. A nil
	// value means the default transport.
	HTTPClientConfig *promconfig.HTTPClientConfig `yaml:"http_client_config,omitempty"`
}

// Instance is one machine a multi-instance exporter watches. It references a
// module for its credentials by name and never carries inline authentication,
// keeping the "no value has two sources" rule the flags layer relies on.
type Instance struct {
	Name    string            `yaml:"name"`
	Address string            `yaml:"address"`
	Module  string            `yaml:"module,omitempty"`
	Labels  map[string]string `yaml:"labels,omitempty"`
}
```

- [ ] **Step 2: Validate each module's client config in `Load`.** Replace the top-level-only validation block (currently lines 73-86, the `if c.HTTPClientConfig != nil { dir := ...; SetDirectory; Validate }`) with a version that resolves the directory once and applies it to the top-level config AND every module's:

```go
	// Paths inside the file (ca_file, password_file, ...) are relative to the
	// file, not the process working directory. An exporter started by systemd
	// runs from /, so the difference decides whether it works. Resolve the
	// directory once and apply it to the top-level client config and to every
	// module's.
	dir, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		return nil, fmt.Errorf("resolve the directory of %s: %w", path, err)
	}

	if c.HTTPClientConfig != nil {
		c.HTTPClientConfig.SetDirectory(dir)
		if err := c.HTTPClientConfig.Validate(); err != nil {
			return nil, fmt.Errorf("invalid http_client_config in %s: %w", path, err)
		}
	}

	// Sorted so a config with two broken modules always fails on the same one.
	moduleNames := make([]string, 0, len(c.Modules))
	for name := range c.Modules {
		moduleNames = append(moduleNames, name)
	}
	sort.Strings(moduleNames)
	for _, name := range moduleNames {
		hc := c.Modules[name].HTTPClientConfig
		if hc == nil {
			continue
		}
		hc.SetDirectory(dir)
		if err := hc.Validate(); err != nil {
			return nil, fmt.Errorf("invalid http_client_config in module %q of %s: %w", name, path, err)
		}
	}
```

(`sort` and `filepath` are already imported. `hc` is a pointer, so `SetDirectory` mutates the shared pointee even though the map value is a copy.)

- [ ] **Step 3: Fix the now-stale unknown-key test.** `TestLoadRejectsUnknownTopLevelKey` (currently lines 258-263) uses `instances:` as its example of an unknown key. `instances:` is now a KNOWN key, so change its fixture to a genuinely unknown one:

```go
func TestLoadRejectsUnknownTopLevelKey(t *testing.T) {
	path := writeConfig(t, "nonsense_section: true\n")
	if _, err := Load(path); err == nil {
		t.Fatal("Load accepted an unknown top-level key; parsing must be strict")
	}
}
```

- [ ] **Step 4: Write the new parsing/validation tests.** Add these to `config_test.go.tmpl` (they need `promconfig "github.com/prometheus/common/config"` in the import block, add it):

```go
func TestLoadParsesModulesAndInstances(t *testing.T) {
	path := writeConfig(t, `
modules:
  default:
    http_client_config:
      basic_auth: { username: monitor, password: hunter2 }
instances:
  - { name: lib-a, address: https://a.example.net, labels: { site: paris } }
  - { name: lib-b, address: https://b.example.net, module: default }
`)
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(c.Modules) != 1 {
		t.Fatalf("Modules = %v, want exactly one", c.Modules)
	}
	if len(c.Instances) != 2 {
		t.Fatalf("Instances = %d, want 2", len(c.Instances))
	}
	if c.Instances[0].Name != "lib-a" || c.Instances[0].Labels["site"] != "paris" {
		t.Errorf("instance 0 = %+v, want name lib-a with site=paris", c.Instances[0])
	}
	if c.Instances[1].Module != "default" {
		t.Errorf("instance 1 module = %q, want default", c.Instances[1].Module)
	}
}

func TestLoadValidatesModuleHTTPClientConfig(t *testing.T) {
	path := writeConfig(t, `
modules:
  broken:
    http_client_config:
      basic_auth: { username: monitor, password: inline, password_file: /etc/pw }
`)
	if _, err := Load(path); err == nil {
		t.Fatal("Load accepted a module whose basic_auth sets both password and password_file")
	}
}

func TestLoadResolvesModulePathsAgainstTheFile(t *testing.T) {
	path := writeConfig(t, `
modules:
  tls:
    http_client_config:
      tls_config: { ca_file: certs/corp.pem }
`)
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	want := filepath.Join(filepath.Dir(path), "certs/corp.pem")
	if got := c.Modules["tls"].HTTPClientConfig.TLSConfig.CAFile; got != want {
		t.Errorf("module ca_file = %q, want %q (relative to the config file)", got, want)
	}
}
```

- [ ] **Step 5: Run the tests.** Scaffold an ordinary demo and run the config package tests. Run: `test/golden-smoke.sh --flavor http --forge none` then `cd test/_work/http-none && go test ./internal/config/ -run 'TestLoad|TestValidate' -v`
Expected: PASS, including the three new tests and the amended unknown-key test.

- [ ] **Step 6: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "feat(config): parse modules: and instances: sections"
```

### Task 2: Resolve instances and reject sections a model cannot use

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/config/config.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl`

**Interfaces:**
- Consumes: `Config.Modules`, `Config.Instances`, `Config.HTTPClientConfig` from Task 1.
- Produces: `config.ResolvedInstance{Name, Address string; Labels map[string]string; ClientConfig *promconfig.HTTPClientConfig}`; `(*Config).ResolveInstances(instanceLabel string) ([]ResolvedInstance, error)`; `(*Config).RejectModulesAndInstances() error`. The multi-instance main (Task 5) calls `ResolveInstances`; the single/multi mains (Task 7) call `RejectModulesAndInstances`.

- [ ] **Step 1: Add `net/url` to the import block** of `config.go.tmpl` (it is not imported yet).

- [ ] **Step 2: Add the resolution and rejection API.** Append to `config.go.tmpl` (after `ExtractFlagValue`):

```go
// ResolvedInstance is one validated instance ready to wire: its module
// reference resolved to a client config (nil meaning the default transport)
// and its extra labels checked against the identifying label.
type ResolvedInstance struct {
	Name         string
	Address      string
	Labels       map[string]string
	ClientConfig *promconfig.HTTPClientConfig
}

// ResolveInstances validates the instances section for the multi-instance
// target model and resolves each instance's module reference. instanceLabel is
// the identifying label scaffold.sh baked in (default "target"); an instance's
// own labels may not reuse it. It fails on the first problem, the boot posture
// the design mandates.
func (c *Config) ResolveInstances(instanceLabel string) ([]ResolvedInstance, error) {
	if len(c.Instances) == 0 {
		return nil, fmt.Errorf("the multi-instance model requires at least one instance under \"instances:\"")
	}

	// A module carrying "collectors:" is meaningless under multi-instance
	// (collector enablement is global via --collector.<name>); refuse it rather
	// than silently ignore it. Sorted for a reproducible failure.
	moduleNames := make([]string, 0, len(c.Modules))
	for name := range c.Modules {
		moduleNames = append(moduleNames, name)
	}
	sort.Strings(moduleNames)
	for _, name := range moduleNames {
		if len(c.Modules[name].Collectors) > 0 {
			return nil, fmt.Errorf("module %q sets \"collectors:\", which multi-instance does not honour (collector enablement is global via --collector.<name>); remove it", name)
		}
	}

	seen := make(map[string]bool, len(c.Instances))
	out := make([]ResolvedInstance, 0, len(c.Instances))
	for i, inst := range c.Instances {
		if inst.Name == "" {
			return nil, fmt.Errorf("instance %d has no name", i)
		}
		if seen[inst.Name] {
			return nil, fmt.Errorf("instance name %q declared twice", inst.Name)
		}
		seen[inst.Name] = true

		if err := validateInstanceAddress(inst.Address); err != nil {
			return nil, fmt.Errorf("instance %q: %w", inst.Name, err)
		}
		if _, taken := inst.Labels[instanceLabel]; taken {
			return nil, fmt.Errorf("instance %q sets label %q, which is the identifying label this exporter applies itself; rename it", inst.Name, instanceLabel)
		}

		hc, err := c.resolveModule(inst.Module)
		if err != nil {
			return nil, fmt.Errorf("instance %q: %w", inst.Name, err)
		}
		out = append(out, ResolvedInstance{
			Name:         inst.Name,
			Address:      inst.Address,
			Labels:       inst.Labels,
			ClientConfig: hc,
		})
	}
	return out, nil
}

// resolveModule resolves an instance's module reference to a client config. An
// empty reference means the "default" module. The default module is either an
// explicit modules.default or, when no modules: section is present, the
// top-level http_client_config (the v0.4.0 compatibility rule). A missing
// default resolves to nil: the default transport.
func (c *Config) resolveModule(name string) (*promconfig.HTTPClientConfig, error) {
	if name == "" {
		name = "default"
	}
	if len(c.Modules) == 0 {
		if name == "default" {
			return c.HTTPClientConfig, nil // nil when no top-level section either
		}
		return nil, fmt.Errorf("references module %q but the config declares no modules", name)
	}
	m, ok := c.Modules[name]
	if !ok {
		return nil, fmt.Errorf("references unknown module %q", name)
	}
	return m.HTTPClientConfig, nil
}

// validateInstanceAddress enforces that an address parses as an http/https URL,
// the same floor a /probe target must clear.
func validateInstanceAddress(addr string) error {
	if addr == "" {
		return fmt.Errorf("has no address")
	}
	u, err := url.Parse(addr)
	if err != nil {
		return fmt.Errorf("address %q is not a valid URL: %w", addr, err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("address %q scheme %q not allowed (only http/https)", addr, u.Scheme)
	}
	if u.Hostname() == "" {
		return fmt.Errorf("address %q has no host", addr)
	}
	return nil
}

// RejectModulesAndInstances refuses a modules: or instances: section, which a
// single-target exporter cannot act on. A single-target main calls this so a
// misconfiguration fails loudly rather than being silently ignored.
func (c *Config) RejectModulesAndInstances() error {
	if len(c.Modules) > 0 {
		return fmt.Errorf("config file: \"modules:\" is only used by multi-target exporters; this is a single-target exporter")
	}
	if len(c.Instances) > 0 {
		return fmt.Errorf("config file: \"instances:\" is only used by multi-instance exporters; this is a single-target exporter")
	}
	return nil
}
```

- [ ] **Step 3: Write the tests.** Add to `config_test.go.tmpl`:

```go
func TestResolveInstancesRejectsEmptyList(t *testing.T) {
	if _, err := (&Config{}).ResolveInstances("target"); err == nil {
		t.Fatal("ResolveInstances accepted an empty instance list")
	}
}

func TestResolveInstancesRejectsDuplicateNames(t *testing.T) {
	c := &Config{Instances: []Instance{
		{Name: "a", Address: "https://a.example.net"},
		{Name: "a", Address: "https://b.example.net"},
	}}
	if _, err := c.ResolveInstances("target"); err == nil {
		t.Fatal("ResolveInstances accepted two instances named the same")
	}
}

func TestResolveInstancesRejectsNonHTTPAddress(t *testing.T) {
	c := &Config{Instances: []Instance{{Name: "a", Address: "ftp://a.example.net"}}}
	if _, err := c.ResolveInstances("target"); err == nil {
		t.Fatal("ResolveInstances accepted a non-http address")
	}
}

func TestResolveInstancesRejectsLabelCollidingWithIdentifier(t *testing.T) {
	c := &Config{Instances: []Instance{
		{Name: "a", Address: "https://a.example.net", Labels: map[string]string{"target": "x"}},
	}}
	if _, err := c.ResolveInstances("target"); err == nil {
		t.Fatal("ResolveInstances accepted an instance label reusing the identifying label")
	}
}

func TestResolveInstancesResolvesDefaultModuleFromTopLevel(t *testing.T) {
	// v0.4 compat: no modules: section, top-level http_client_config is default.
	hc := &promconfig.HTTPClientConfig{}
	c := &Config{
		HTTPClientConfig: hc,
		Instances:        []Instance{{Name: "a", Address: "https://a.example.net"}},
	}
	got, err := c.ResolveInstances("target")
	if err != nil {
		t.Fatalf("ResolveInstances: %v", err)
	}
	if got[0].ClientConfig != hc {
		t.Error("the default module did not resolve to the top-level http_client_config")
	}
}

func TestResolveInstancesRejectsUnknownModule(t *testing.T) {
	c := &Config{
		Modules:   map[string]Module{"known": {}},
		Instances: []Instance{{Name: "a", Address: "https://a.example.net", Module: "ghost"}},
	}
	if _, err := c.ResolveInstances("target"); err == nil {
		t.Fatal("ResolveInstances accepted a reference to an undeclared module")
	}
}

func TestResolveInstancesRejectsModuleCollectorsSubset(t *testing.T) {
	c := &Config{
		Modules:   map[string]Module{"m": {Collectors: []string{"example"}}},
		Instances: []Instance{{Name: "a", Address: "https://a.example.net", Module: "m"}},
	}
	if _, err := c.ResolveInstances("target"); err == nil {
		t.Fatal("ResolveInstances accepted a module with a collectors: subset under multi-instance")
	}
}

func TestRejectModulesAndInstances(t *testing.T) {
	if err := (&Config{}).RejectModulesAndInstances(); err != nil {
		t.Errorf("errored on an empty config: %v", err)
	}
	if err := (&Config{Modules: map[string]Module{"x": {}}}).RejectModulesAndInstances(); err == nil {
		t.Error("accepted a modules: section")
	}
	if err := (&Config{Instances: []Instance{{Name: "a"}}}).RejectModulesAndInstances(); err == nil {
		t.Error("accepted an instances: section")
	}
}
```

- [ ] **Step 4: Run the tests.** Run: `test/golden-smoke.sh --flavor http --forge none` then `cd test/_work/http-none && go test ./internal/config/ -run 'TestResolveInstances|TestRejectModulesAndInstances' -v`
Expected: PASS (all eight new tests).

- [ ] **Step 5: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "feat(config): resolve instances and reject unusable sections per model"
```

---

## Phase 1: Instance seam and the multi-instance runtime

### Task 3: The `internal/instance` background seam

**Files:**
- Create: `skills/prometheus-exporter/assets/internal/instance/instance.go.tmpl`
- Create: `skills/prometheus-exporter/assets/internal/instance/instance_test.go.tmpl`

**Interfaces:**
- Produces: `instance.BackgroundCollector` (interface: `prometheus.Collector` + `Start(context.Context)` + `Done() <-chan struct{}`) and `instance.Factory{Name string; Enabled *bool; New func(addr string, hcfg *promconfig.HTTPClientConfig) (BackgroundCollector, error)}`. The frag (Task 4) and main (Task 5) consume these. `*collector.ExampleCollector` (the shipped background variant) satisfies `BackgroundCollector` structurally.

- [ ] **Step 1: Write the failing test.** Create `instance_test.go.tmpl`:

```go
package instance

import (
	"context"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	promconfig "github.com/prometheus/common/config"
)

// fakeBG is a minimal BackgroundCollector that is NOT internal/collector's
// ExampleCollector, proving the seam is satisfiable independently of any one
// collector implementation.
type fakeBG struct {
	desc *prometheus.Desc
	done chan struct{}
}

func newFakeBG() *fakeBG {
	return &fakeBG{desc: prometheus.NewDesc("fake_metric", "help", nil, nil), done: make(chan struct{})}
}

func (f *fakeBG) Describe(ch chan<- *prometheus.Desc) { ch <- f.desc }
func (f *fakeBG) Collect(ch chan<- prometheus.Metric) {
	ch <- prometheus.MustNewConstMetric(f.desc, prometheus.GaugeValue, 1)
}
func (f *fakeBG) Start(ctx context.Context) { go func() { <-ctx.Done(); close(f.done) }() }
func (f *fakeBG) Done() <-chan struct{}     { return f.done }

// Compile-time proof the fake satisfies the seam.
var _ BackgroundCollector = (*fakeBG)(nil)

func TestFactoryBuildsAndStarts(t *testing.T) {
	enabled := true
	var gotAddr string
	var gotCfg *promconfig.HTTPClientConfig
	f := Factory{
		Name:    "fake",
		Enabled: &enabled,
		New: func(addr string, hcfg *promconfig.HTTPClientConfig) (BackgroundCollector, error) {
			gotAddr, gotCfg = addr, hcfg
			return newFakeBG(), nil
		},
	}

	bg, err := f.New("https://machine-a", nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if gotAddr != "https://machine-a" {
		t.Errorf("New received addr %q, want https://machine-a", gotAddr)
	}
	if gotCfg != nil {
		t.Error("New received a non-nil client config, want nil (default transport)")
	}
	if !*f.Enabled {
		t.Error("Enabled = false, want true")
	}

	ctx, cancel := context.WithCancel(context.Background())
	bg.Start(ctx)
	cancel()
	select {
	case <-bg.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("Done() did not close within 2s after cancel")
	}
}
```

- [ ] **Step 2: Run it to see it fail.** In a scratch module (see "Testing template Go"): FAIL with "undefined: BackgroundCollector, Factory".

- [ ] **Step 3: Write the seam.** Create `instance.go.tmpl`:

```go
// Package instance implements the multi-instance target model: one process
// watches a fixed list of machines declared in --config.file, each refreshed by
// its own background poller, all served through a single /metrics that
// Prometheus scrapes as one target.
//
// It mirrors internal/probe's NamedFactory pattern but carries a different
// lifecycle: a /probe factory builds a synchronous collector per request, while
// an instance factory builds a BACKGROUND collector (poller plus cache) once at
// boot, which must be Start()-ed and waited on via Done() at shutdown. Those
// lifecycles do not fit one signature, so the two seams stay separate. See the
// design doc's "Architecture" section.
package instance

import (
	"context"

	"github.com/prometheus/client_golang/prometheus"
	promconfig "github.com/prometheus/common/config"
)

// BackgroundCollector is the lifecycle a multi-instance collector must satisfy:
// a prometheus.Collector a background goroutine refreshes. Start launches that
// goroutine bound to ctx; Done closes when it has fully exited, so main can wait
// for it during shutdown. The background collector variant (internal/collector's
// ExampleCollector, code/http/variants/) already satisfies this structurally.
type BackgroundCollector interface {
	prometheus.Collector
	Start(ctx context.Context)
	Done() <-chan struct{}
}

// Factory builds one instance-bound background collector. New takes the
// instance's address and its resolved module client config (nil meaning the
// default transport) and returns the collector, or an error when the transport
// cannot be built (an unreadable CA or secret file), which fails the boot.
// Enabled is the collector's --[no-]collector.<name> toggle, checked once before
// the instance loop.
//
// The multi-instance main appends one Factory per collector at its
// // @@INSTANCE_FACTORIES@@ marker, and /add-collector appends another for each
// collector added later. There is no per-request routing as in /probe, only a
// boot-time fan-out over instances, so this is a plain slice, not a Handler.
type Factory struct {
	Name    string
	Enabled *bool
	New     func(addr string, hcfg *promconfig.HTTPClientConfig) (BackgroundCollector, error)
}
```

(Do NOT import `internal/collector` here: the seam references only `context`, `prometheus`, and `promconfig`. An unused `collector` import would fail the build. Structural satisfaction needs no import.)

- [ ] **Step 4: Run the test to verify it passes.** Scratch module: PASS.

- [ ] **Step 5: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "feat(instance): add the multi-instance background collector seam"
```

### Task 4: The `@@INSTANCE_FACTORIES@@` wiring fragment

**Files:**
- Create: `skills/prometheus-exporter/assets/code/http/wiring/instance_factory.frag`

**Interfaces:**
- Consumes: `instance.Factory`, `instance.BackgroundCollector` (Task 3); `collector.NewClient`, `collector.NewClientWithConfig`, `collector.NewExampleCollector(log, client, interval)` (existing, background variant). Relies on `log`, `factories`, `kingpin`, `promconfig`, `collector`, `instance` all being in scope where scaffold.sh splices this fragment (the multi-instance main, Task 5).
- Produces: appends one starter `instance.Factory` to `factories`, and declares the `--collector.example{,.timeout,.interval}` flags.

This fragment has no standalone test; it is exercised end-to-end at Task 6's scaffold + `go build`/`go test`. It mirrors `probe_factory.frag` for the background lifecycle.

- [ ] **Step 1: Create `instance_factory.frag`** (leading tabs match the other frags, so the spliced code sits one indent level inside `main`):

```go
	exampleTimeout := kingpin.Flag("collector.example.timeout", "Per-request timeout for the example collector.").Default("5s").Duration()
	exampleInterval := kingpin.Flag("collector.example.interval", "Background refresh interval for the example collector.").Default("5m").Duration()
	exampleEnabled := kingpin.Flag("collector.example", "Enable the example collector.").Default("true").Bool()
	// The closure defers every flag dereference and the log reference to the
	// instance loop, which runs after kingpin.Parse() and after log is built,
	// exactly like the single-target background register() closure.
	factories = append(factories, instance.Factory{
		Name:    "example",
		Enabled: exampleEnabled,
		New: func(addr string, hcfg *promconfig.HTTPClientConfig) (instance.BackgroundCollector, error) {
			var client *collector.Client
			if hcfg != nil {
				var err error
				client, err = collector.NewClientWithConfig(addr, *exampleTimeout, *hcfg)
				if err != nil {
					return nil, err
				}
			} else {
				client = collector.NewClient(addr, *exampleTimeout)
			}
			return collector.NewExampleCollector(log, client, *exampleInterval), nil
		},
	})
```

- [ ] **Step 2: Commit** (verified downstream at Task 6).

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "feat(scaffold): add the multi-instance factory wiring fragment"
```

### Task 5: The `mains/multi-instance/main.go.tmpl` entry point

**Files:**
- Create: `skills/prometheus-exporter/assets/mains/multi-instance/main.go.tmpl`

**Interfaces:**
- Consumes: `config.Load`, `config.ExtractFlagValue`, `config.CLIFlagNames`, `(*Config).Validate`, `(*Config).ToArgs`, `(*Config).ResolveInstances` (Tasks 1-2); `instance.Factory` (Task 3); `collector.NewStatusTracker`, `collector.RequestDuration` (existing); `warnIfExposedAndUnauthenticated` (existing, `cmd/*/security.go`, shipped every model). Carries the `@@INSTANCE_FACTORIES@@` marker the fragment fills and the `@@INSTANCE_LABEL@@` sentinel scaffold.sh substitutes.

Verified end-to-end at Task 6 (scaffold + `go build`/`go vet`); a bare `.tmpl` does not compile.

- [ ] **Step 1: Create the main.** Write `mains/multi-instance/main.go.tmpl`:

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/alecthomas/kingpin/v2"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	promconfig "github.com/prometheus/common/config"
	"github.com/prometheus/common/version"
	"github.com/prometheus/exporter-toolkit/web"
	webflag "github.com/prometheus/exporter-toolkit/web/kingpinflag"

	"@@MODULE_PATH@@/internal/collector"
	"@@MODULE_PATH@@/internal/config"
	"@@MODULE_PATH@@/internal/instance"
	"@@MODULE_PATH@@/internal/logger"
)

// namespace is this exporter's Prometheus metric prefix (used by the landing
// page and startup log). See internal/collector for how @@NAMESPACE@@ is
// substituted into each collector's own metric names.
const namespace = "@@NAMESPACE@@"

// instanceLabel is the identifying label this exporter applies to every series
// of every watched machine (see WrapRegistererWith below). It is fixed at
// scaffold time by scaffold.sh --instance-label (default "target"), never a
// runtime knob: a config edit that renamed every series at once would make
// docs/metrics.md unverifiable by make docs-check.
const instanceLabel = "@@INSTANCE_LABEL@@"

var (
	logLevel     = kingpin.Flag("log.level", "Only log messages with the given severity or above. One of: [debug, info, warn, error]").Default("info").Enum("debug", "info", "warn", "error")
	logFormat    = kingpin.Flag("log.format", "Log format. One of: [json, text]").Default("text").Enum("json", "text")
	toolkitFlags = webflag.AddFlags(kingpin.CommandLine, ":@@DEFAULT_PORT@@")

	// disableExporterMetrics removes Go runtime and process metrics from /metrics.
	disableExporterMetrics = kingpin.Flag(
		"web.disable-exporter-metrics",
		"Exclude Go runtime and process metrics from the /metrics endpoint.",
	).Default("false").Bool()

	// configFile is REQUIRED for this target model: without it there are no
	// instances to watch. Its value is read straight from os.Args below, before
	// parsing, because it decides which arguments the parser is given.
	configFile = kingpin.Flag(
		"config.file",
		"Path to the YAML configuration file listing the instances to watch (required). Unrelated to --web.config.file, which configures the TLS server this exporter exposes.",
	).Default("").String()
)

// indexHTML is the landing page served at /.
var indexHTML = fmt.Sprintf(`<html>
	<head><title>%s Exporter</title></head>
	<body>
		<h1>%s Exporter (multi-instance)</h1>
		<p>This exporter watches a fixed list of instances from its configuration file and serves them all through <a href='/metrics'>/metrics</a>.</p>
	</body>
</html>`, namespace, namespace)

func main() {
	var log *logger.Logger

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	// backgroundCollector is the shutdown-wait seam every background collector
	// satisfies. Every instance's every collector is a background poller,
	// appended here as it is built, and waited on under ONE shared budget below.
	type backgroundCollector interface{ Done() <-chan struct{} }
	var backgroundCollectors []backgroundCollector

	// factories holds one entry per collector, in declaration order. scaffold.sh
	// injects the starter at the marker below, and /add-collector appends every
	// collector added later. Leave the marker in place.
	var factories []instance.Factory

	// @@INSTANCE_FACTORIES@@

	kingpin.Version(version.Print("@@EXPORTER_NAME@@"))
	kingpin.HelpFlag.Short('h')

	// --config.file is mandatory here; read it before parsing (its value decides
	// which arguments the parser is given).
	configPath := config.ExtractFlagValue(os.Args[1:], "config.file")
	if configPath == "" {
		fmt.Fprintln(os.Stderr, "the multi-instance target model requires --config.file (it lists the instances to watch)")
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
	cfg, err := config.Load(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
	if err := cfg.Validate(kingpin.CommandLine); err != nil {
		fmt.Fprintln(os.Stderr, err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
	kingpin.MustParse(kingpin.CommandLine.Parse(
		append(cfg.ToArgs(config.CLIFlagNames(os.Args[1:])), os.Args[1:]...),
	))

	if *logFormat == "json" {
		log = logger.NewJSONLogger(*logLevel)
	} else {
		log = logger.NewTextLogger(*logLevel)
	}

	warnIfExposedAndUnauthenticated(log, *toolkitFlags.WebListenAddresses, *toolkitFlags.WebConfigFile)

	// Validate and resolve the instance list, fail-fast: at least one instance,
	// unique names, http/https addresses, resolvable module references, no
	// instance label colliding with the identifying label. Each module's
	// http_client_config was already validated by config.Load.
	instances, err := cfg.ResolveInstances(instanceLabel)
	if err != nil {
		log.Error("Invalid instance configuration", "err", err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}

	// Filter to the globally-enabled collectors once (enablement is global under
	// this model), preserving declaration order.
	var enabled []instance.Factory
	for _, f := range factories {
		if *f.Enabled {
			enabled = append(enabled, f)
			log.Info("Collector enabled", "collector", f.Name)
		} else {
			log.Info("Collector disabled", "collector", f.Name)
		}
	}

	// Custom registry (no global state or third-party metric pollution).
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewBuildInfoCollector())
	if !*disableExporterMetrics {
		reg.MustRegister(
			collectors.NewGoCollector(),
			collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		)
	}
	reg.MustRegister(collector.RequestDuration)

	// Build every instance's collectors at boot. Each instance's series carry
	// the identifying label plus the instance's own extra labels, applied by
	// WrapRegistererWith as ConstLabels. Two instances registering the same
	// collector never collide because ConstLabels are part of a Desc's identity.
	for _, inst := range instances {
		labels := prometheus.Labels{instanceLabel: inst.Name}
		for k, v := range inst.Labels {
			labels[k] = v
		}
		instReg := prometheus.WrapRegistererWith(labels, reg)

		tracker := collector.NewStatusTracker(log)
		for _, f := range enabled {
			bg, err := f.New(inst.Address, inst.ClientConfig)
			if err != nil {
				// A transport that cannot be built (unreadable CA or secret
				// file) is a configuration fault: stop at boot rather than
				// surface it on the first scrape.
				log.Error("Failed to build collector for instance", "collector", f.Name, "instance", inst.Name, "err", err)
				stop()     // release the signal handler explicitly before bypassing defer via os.Exit
				os.Exit(1) //nolint:gocritic // stop() called explicitly above
			}
			bg.Start(ctx)
			backgroundCollectors = append(backgroundCollectors, bg)
			tracker.Add(f.Name, bg)
		}
		instReg.MustRegister(tracker)
		log.Info("Watching instance", "instance", inst.Name, "address", inst.Address)
	}

	log.Info("Starting multi-instance exporter server...", "namespace", namespace, "instances", len(instances))

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(indexHTML))
	})
	http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{
		EnableOpenMetrics: true,
		ErrorHandling:     promhttp.ContinueOnError,
	}))
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	server := &http.Server{
		ReadHeaderTimeout: 5 * time.Second, // Mitigate Slowloris attacks (G112).
	}

	go func() {
		<-ctx.Done()
		log.Info("Shutdown signal received, draining in-flight requests...")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Error("Graceful shutdown failed", "err", err)
		}
	}()

	if err := web.ListenAndServe(server, toolkitFlags, log.Logger); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("Failed to start HTTP server", "err", err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}

	log.Info("Server stopped")

	// ONE shared 5s budget for ALL background collectors, not 5s each: with N
	// instances x M collectors, a per-collector wait would worst-case at
	// N*M*5s. time.After returns a single channel; once it fires, the loop
	// returns, capping the TOTAL wait at 5s.
	deadline := time.After(5 * time.Second)
	for _, bc := range backgroundCollectors { //nolint:gosec // G602: for-range over a slice never indexes out of bounds
		select {
		case <-bc.Done():
		case <-deadline:
			log.Warn("background collectors did not all stop within 5s; exiting anyway")
			return
		}
	}
}
```

- [ ] **Step 2: Sanity-check imports by eye.** Every import is used AFTER the fragment splice: `promconfig` and `collector`'s `NewClient*` are used inside the spliced fragment; `instance`, `config`, `logger`, `prometheus`, `collectors`, `promhttp`, `version`, `web`, `webflag`, `kingpin` in the body. `sort` is deliberately NOT imported (the main sorts nothing; `ResolveInstances` sorts internally). Commit; the compile is verified at Task 6.

- [ ] **Step 3: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "feat(scaffold): add the multi-instance main entry point"
```

---

## Phase 2: Scaffold integration

### Task 6: Teach `scaffold.sh` the `multi-instance` target model

**Files:**
- Create: `skills/prometheus-exporter/assets/code/http/variants/collector_shared_test.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/scaffold.sh`

**Interfaces:**
- Consumes: `mains/multi-instance/main.go.tmpl` (Task 5), `internal/instance/` (Task 3), `code/http/wiring/instance_factory.frag` (Task 4).
- Produces: `scaffold.sh --target-model multi-instance --instance-label <name>` yields a buildable, tested multi-instance exporter. The `@@INSTANCE_LABEL@@` sentinel and the `@@INSTANCE_FACTORIES@@` marker are handled.

The background test template (`background_collector_test.go.tmpl`, shipped as `collector_test.go` on a multi-instance scaffold) references `statusTrackerSuccessMetric`, which the synchronous `collector_test.go.tmpl` declares. Since multi-instance does not ship the synchronous test, that const (and the client-level tests) must come from a dedicated shared file.

- [ ] **Step 1: Create the shared test file.** Write `code/http/variants/collector_shared_test.go.tmpl`. This carries the declarations the background-starter tree needs but the background test file does not itself declare, all testing `client.go` (variant-agnostic shared infrastructure):

```go
package collector

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	promconfig "github.com/prometheus/common/config"
)

// statusTrackerSuccessMetric is the collector_success metric family name,
// referenced by the background collector's own StatusTracker test. On a
// multi-instance scaffold the background collector is the starter, so this
// shared declaration lives here rather than in the synchronous collector test
// (which such a scaffold does not ship).
const statusTrackerSuccessMetric = "@@NAMESPACE@@_exporter_collector_success"

// TestRequestDuration_CustomRegistryReachable locks that RequestDuration is a
// plain, exported *prometheus.HistogramVec this exporter's own custom registry
// can register directly, not a promauto value reachable only from
// prometheus.DefaultRegisterer.
func TestRequestDuration_CustomRegistryReachable(t *testing.T) {
	RequestDuration.WithLabelValues("success").Observe(0.01)

	reg := prometheus.NewRegistry()
	if err := reg.Register(RequestDuration); err != nil {
		t.Fatalf("Register(RequestDuration) on a fresh custom registry: %v", err)
	}
	count, err := testutil.GatherAndCount(reg, "@@NAMESPACE@@_exporter_request_duration_seconds")
	if err != nil {
		t.Fatalf("GatherAndCount(custom registry): %v", err)
	}
	if count == 0 {
		t.Fatal("GatherAndCount(custom registry) = 0, want >= 1: RequestDuration did not reach a registry it was explicitly registered on")
	}

	dcount, err := testutil.GatherAndCount(prometheus.DefaultGatherer, "@@NAMESPACE@@_exporter_request_duration_seconds")
	if err != nil {
		t.Fatalf("GatherAndCount(DefaultGatherer): %v", err)
	}
	if dcount != 0 {
		t.Fatalf("GatherAndCount(DefaultGatherer) = %d, want 0: RequestDuration must not self-register into the process-wide default registerer", dcount)
	}
}

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

// TestNewClientForSharesOneTransport proves NewClientFor binds two targets to
// the SAME *http.Client instead of building a private one per target.
func TestNewClientForSharesOneTransport(t *testing.T) {
	hc, err := NewHTTPClient(promconfig.HTTPClientConfig{}, 5*time.Second)
	if err != nil {
		t.Fatalf("NewHTTPClient: %v", err)
	}

	a := NewClientFor("http://a.example", hc)
	b := NewClientFor("http://b.example", hc)

	if a.httpClient != b.httpClient {
		t.Error("two targets built their own http.Client; the transport must be shared")
	}
	if a.baseURL == b.baseURL {
		t.Errorf("both clients bound to %s; each target must keep its own base URL", a.baseURL)
	}
}
```

- [ ] **Step 1b: Create the background-variant `metrics.md`.** The multi-instance starter is the background collector, which emits a third metric (`_example_last_refresh_timestamp_seconds`) and has no `/probe` endpoint, so the synchronous `metrics.md` (two metrics, plus a `/probe` prose section) is wrong for it. Write `code/http/variants/metrics.md.tmpl`:

```markdown
# Metrics

> Back to [README](../README.md)

Every metric `@@EXPORTER_NAME@@` can emit, grouped by collector. This file is kept
truthful by `make docs-check` (part of `make check`, see
[CONTRIBUTING.md](../CONTRIBUTING.md)'s Definition of Done): any metric or label
listed below that the code cannot actually produce fails the build. A metric the
code emits but this file doesn't document is only a warning: see
`internal/collector/docs_check_test.go`.

<!--
docs-check parses this file as a sequence of markdown tables, one metric per
row, in this exact 4-cell shape:

| `metric_name` | Type | `label1`, `label2` | Description |

- Metric name: backtick-quoted, matching the fqName passed to
  prometheus.NewDesc / HistogramOpts.Name in internal/collector/*.go.
- Type: Gauge, Counter, Histogram, or Summary (informational only, not
  itself verified by docs-check).
- Labels: each backtick-quoted, comma-separated; a literal `-` when the
  metric has none.
- Description: free text. Avoid a literal `|` character in this cell (it
  breaks table parsing).

Standard Go runtime, process, and build-info metrics (from
`prometheus/client_golang/prometheus/collectors`, registered in
`cmd/@@EXPORTER_NAME@@/main.go`, disable with `--web.disable-exporter-metrics`)
are intentionally not listed here.
-->

## ExampleCollector

Defined in `internal/collector/collector.go`, the background-refresh variant: a
goroutine polls the target on `--collector.example.interval` and every scrape
serves the last cached result. Replace this section's rows when you adapt
`ExampleCollector` into your real collector.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `@@NAMESPACE@@_items` | Gauge | - | Number of items reported by the example target. |
| `@@NAMESPACE@@_healthy` | Gauge | - | Whether the example target reports itself healthy (1) or not (0). |
| `@@NAMESPACE@@_example_last_refresh_timestamp_seconds` | Gauge | - | Unix time of the last successful example refresh. Alert if time() minus this exceeds 2x the collector's configured interval. |

## Self-instrumentation

Emitted regardless of which `--collector.*` flags are set: see
[docs/configuration.md](configuration.md).

| Metric | Type | Labels | Description |
|---|---|---|---|
| `@@NAMESPACE@@_exporter_request_duration_seconds` | Histogram | `outcome` | Duration in seconds of HTTP requests issued by this exporter's collectors, by outcome (`success` or `error`). Defined in `internal/collector/client.go`. |
| `@@NAMESPACE@@_exporter_collector_success` | Gauge | `collector` | Whether the last scrape of the collector succeeded (1=success, 0=failure). Defined in `internal/collector/status_tracker.go`. |
| `@@NAMESPACE@@_exporter_collector_duration_seconds` | Gauge | `collector` | Duration of the last scrape for the collector, in seconds. Defined in `internal/collector/status_tracker.go`. |

## The instance label

This exporter watches every instance listed in its `--config.file` and serves
them all through one `/metrics`. Every metric above additionally carries the
`@@INSTANCE_LABEL@@` label (plus any per-instance labels you declare), applied by
the exporter per instance rather than by the collector, so it is not part of the
collector's own descriptor and `make docs-check` does not see it. See
[docs/configuration.md](configuration.md).
```

- [ ] **Step 2: Add the `--instance-label` flag to `scaffold.sh`.** Add the default near the other defaults (after `target_model="single"`, line 89):

```sh
instance_label="target"
```

Add its case to the argument loop, immediately after the `--target-model)` case (after line 135):

```sh
    --instance-label)
      [ $# -ge 2 ] || die "--instance-label requires a value"
      instance_label=$2
      shift 2
      ;;
```

- [ ] **Step 3: Accept `multi-instance` in the target-model validation.** Replace the `case "$target_model"` block and the cli-rejection (lines 187-193):

```sh
case "$target_model" in
  single|multi|multi-instance) ;;
  *) die "invalid --target-model '$target_model'; must be single, multi, or multi-instance" ;;
esac
if { [ "$target_model" = multi ] || [ "$target_model" = multi-instance ]; } && [ "$flavor" != http ]; then
  die "--target-model $target_model requires --flavor http (no cli multi-target)"
fi

# Validate the instance label (a Prometheus label name) and register its
# substitution. It appears only in the multi-instance main; the sed rule is a
# harmless no-op for every other model.
case "$instance_label" in
  ''|[!a-zA-Z_]*|*[!a-zA-Z0-9_]*) die "invalid --instance-label '$instance_label'; must be a valid Prometheus label name (letters, digits, underscore; not starting with a digit)" ;;
esac
printf 's/@@INSTANCE_LABEL@@/%s/g\n' "$(sed_escape_repl "$instance_label")" >> "$sedscript"
```

- [ ] **Step 4: Drop `internal/instance/` for every model but multi-instance.** Immediately after the `internal/probe/` drop block (lines 280-283):

```sh
# internal/instance/ is multi-instance-only: no other model ships it.
if [ "$target_model" != multi-instance ]; then
  rm -rf "$dst/internal/instance"
fi
```

- [ ] **Step 5: Ship the background collector as the multi-instance starter.** Immediately BEFORE the `variants/` removal block (before line 329's comment, after the client_model block ends at line 327):

```sh
# Multi-instance requires the BACKGROUND collector as its starter: a scrape must
# never block on a slow or dead machine (see the design doc's background
# mandate). Swap the synchronous starter for the background variant, and ship
# the shared test declarations the background test file relies on. Runs BEFORE
# the variants/ removal below (which drops the staging dir for every model) and
# before the @@VAR@@ substitution pass (so these files are templated like any
# other).
if [ "$target_model" = multi-instance ] && [ -d "$dst/internal/collector/variants" ]; then
  if [ -f "$dst/internal/collector/variants/background_collector.go.tmpl" ]; then
    mv "$dst/internal/collector/variants/background_collector.go.tmpl" "$dst/internal/collector/collector.go.tmpl"
  fi
  if [ -f "$dst/internal/collector/variants/background_collector_test.go.tmpl" ]; then
    mv "$dst/internal/collector/variants/background_collector_test.go.tmpl" "$dst/internal/collector/collector_test.go.tmpl"
  fi
  if [ -f "$dst/internal/collector/variants/collector_shared_test.go.tmpl" ]; then
    mv "$dst/internal/collector/variants/collector_shared_test.go.tmpl" "$dst/internal/collector/collector_shared_test.go.tmpl"
  fi
  if [ -f "$dst/internal/collector/variants/metrics.md.tmpl" ]; then
    mv "$dst/internal/collector/variants/metrics.md.tmpl" "$dst/internal/collector/metrics.md.tmpl"
  fi
fi
```

(The `metrics.md.tmpl` swap must precede the existing metrics.md relocation step in scaffold.sh, which moves `internal/collector/metrics.md.tmpl` to `docs/metrics.md.tmpl`. Since this swap block sits before both the `variants/` removal and that relocation, the background `metrics.md` lands at `docs/metrics.md` for a multi-instance scaffold.)

- [ ] **Step 6: Register the `instance_factory.frag` -> `@@INSTANCE_FACTORIES@@` pair.** In the wiring-injection pair list (lines 468-472), add a fourth line:

```sh
  for pair in \
    "client_init.frag:@@CLIENT_INIT@@" \
    "client_build.frag:@@CLIENT_BUILD@@" \
    "registry.frag:@@COLLECTOR_REGISTRY@@" \
    "probe_factory.frag:@@PROBE_FACTORIES@@" \
    "instance_factory.frag:@@INSTANCE_FACTORIES@@"; do
```

- [ ] **Step 7: Exempt `@@INSTANCE_FACTORIES@@` from the residual-sentinel check.** The marker survives the frag splice (like the others), so it must be filtered before the residual scan judges. Replace the filter (line 542):

```sh
  grep -v -E '@@(CLIENT_INIT|CLIENT_BUILD|COLLECTOR_REGISTRY|PROBE_FACTORIES|INSTANCE_FACTORIES)@@' "$sentinels" > "$pathlist" || filtered_rc=$?
```

(Also add `INSTANCE_FACTORIES` to the marker enumerations in the header comment near lines 52-56, 63-68 and the exemption comment near 525-540, keeping the documentation truthful. These are comment-only edits.)

- [ ] **Step 8: Scaffold and verify end-to-end.** This is where Tasks 3-6 are verified together.

```bash
rm -rf /tmp/mi-demo
skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst /tmp/mi-demo \
  --flavor http --forge none --target-model multi-instance --instance-label target \
  --var EXPORTER_NAME=demo --var NAMESPACE=demo --var MODULE_PATH=example.com/demo \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example \
  --var DEFAULT_PORT=9999 --var LICENSE=apache-2.0 --var OWNER=demo \
  --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/mi-demo && go build ./... && go vet ./... && go test ./...
```

Expected: scaffold prints `scaffolded /tmp/mi-demo`; `go build`/`go vet` clean; `go test ./...` PASS (config, instance, collector including the background tests + shared client tests, and `make docs-check`'s `TestDocsCheck`). Verify `internal/instance/instance.go` exists, `internal/probe/` does NOT, `cmd/demo/main.go` contains `WrapRegistererWith` and `instance.Factory`, `internal/collector/collector.go` is the background variant (`func (c *ExampleCollector) Start(`), and `docs/metrics.md` documents `demo_example_last_refresh_timestamp_seconds` and carries no `/probe` section (`grep -q last_refresh_timestamp_seconds docs/metrics.md && ! grep -q '/probe' docs/metrics.md`).

(Note: the `--var COLLECTOR_HEALTH_BY`/`COLLECTOR_LOCATION` are required here because Task 11 will add those sentinels to the monitoring templates. If running this step BEFORE Task 11 has landed, omit those two `--var` flags; the monitoring templates carry no such sentinel yet.)

- [ ] **Step 9: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "feat(scaffold): support --target-model multi-instance"
```

### Task 7: Single and multi mains reject sections they cannot use

**Files:**
- Modify: `skills/prometheus-exporter/assets/mains/single/main.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl`

**Interfaces:**
- Consumes: `(*config.Config).RejectModulesAndInstances()` (Task 2), `config.Config.Instances` (Task 1).

Rule 6: a single-target exporter refuses `modules:`/`instances:`. A multi-target exporter refuses `instances:` (multi-instance-only); its `modules:` handling is volet A's concern and untouched here.

- [ ] **Step 1: Single main rejection.** In `mains/single/main.go.tmpl`, immediately after the `cfg.Validate(kingpin.CommandLine)` error block (after line 156), add:

```go
	if err := cfg.RejectModulesAndInstances(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
```

- [ ] **Step 2: Multi main rejection.** In `mains/multi/main.go.tmpl`, immediately after its `cfg.Validate(kingpin.CommandLine)` error block (after line 118), add:

```go
	if len(cfg.Instances) > 0 {
		fmt.Fprintln(os.Stderr, "config file: \"instances:\" is only used by the multi-instance target model; this is a multi-target (/probe) exporter")
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
```

- [ ] **Step 3: Verify both scaffolds still build and reject correctly.**

```bash
test/scaffold_multitarget_test.sh   # must still PASS (existing assertions unaffected)
# Manual: scaffold single, drop a config.yml with "instances: [{name: x}]", run the binary, expect a non-zero exit naming instances:.
```

- [ ] **Step 4: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "feat(scaffold): reject modules:/instances: on models that cannot use them"
```

### Task 8: Scaffold-level assertions for `multi-instance`

**Files:**
- Modify: `skills/prometheus-exporter/assets/../../test/scaffold_multitarget_test.sh` (repo path: `test/scaffold_multitarget_test.sh`)

**Interfaces:**
- Consumes: the Task 6 scaffold behaviour.

- [ ] **Step 1: Add a multi-instance section.** Insert a new numbered section after section 2 (after line 86, before the cli-multi rejection section), mirroring section 1's structure:

```sh
# ---------------------------------------------------------------------------
# 2b. --target-model multi-instance (http/none): ships internal/instance/, no
#     internal/probe/, wires WrapRegistererWith, and ships the BACKGROUND
#     collector as its starter.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
run --src "$assets" --dst "$work/mi" --flavor http --forge none --target-model multi-instance --instance-label target $commonvars
[ "$rc" -eq 0 ] || fail "multi-instance scaffold exited $rc, expected 0 (stderr: $(cat "$err"))"

[ -f "$work/mi/internal/instance/instance.go" ] || fail "multi-instance scaffold did not ship internal/instance/instance.go"
[ ! -d "$work/mi/internal/probe" ] || fail "multi-instance scaffold shipped internal/probe/ (should be multi-only)"

mi_main=$(find "$work/mi/cmd" -maxdepth 2 -name main.go)
[ -n "$mi_main" ] || fail "multi-instance scaffold has no cmd/*/main.go"
grep -q 'WrapRegistererWith' "$mi_main" || fail "multi-instance main.go does not wrap per-instance labels"
grep -q 'var factories \[\]instance.Factory' "$mi_main" || fail "multi-instance main.go does not declare the instance factories slice"
grep -q '// @@INSTANCE_FACTORIES@@' "$mi_main" || fail "multi-instance main.go lost the // @@INSTANCE_FACTORIES@@ marker (/add-collector appends there)"
grep -q '/probe' "$mi_main" && fail "multi-instance main.go registers /probe (should be multi-only)"

# The starter collector must be the background variant (has Start/Done), not the
# synchronous one.
grep -q 'func (c \*ExampleCollector) Start(' "$work/mi/internal/collector/collector.go" || fail "multi-instance starter collector is not the background variant"

echo "PASS: --target-model multi-instance ships internal/instance and the background starter"

# ---------------------------------------------------------------------------
# 2c. --target-model multi-instance --flavor cli must be rejected.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
run --src "$assets" --dst "$work/bad-cli-mi" --flavor cli --forge none --target-model multi-instance $commonvars
[ "$rc" -ne 0 ] || fail "--target-model multi-instance --flavor cli was accepted, expected rejection"
grep -q 'target-model multi-instance requires --flavor http' "$err" || fail "expected a clear cli-rejection message, got: $(cat "$err")"

echo "PASS: --target-model multi-instance --flavor cli is rejected"
```

- [ ] **Step 2: Run the test.** Run: `test/scaffold_multitarget_test.sh`
Expected: `PASS` (all sections, including the two new ones).

- [ ] **Step 3: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "test(scaffold): assert the multi-instance target model"
```

---

## Phase 3: Commands, monitoring, tests, docs

**Var contract for Tasks 9 and 11** (fix these exact names and values):
- `@@COLLECTOR_HEALTH_BY@@`: `job` for single/multi, `job,target` for multi-instance (no spaces: the value must survive the test harnesses' unquoted word-splitting). The literal `target` here is the default instance label; if `--instance-label` differs, it is that value.
- `@@COLLECTOR_LOCATION@@`: `instance` for single/multi, `target` for multi-instance (the bare label name substituted into `{{ $labels.@@COLLECTOR_LOCATION@@ }}`; again the instance label value when non-default).

### Task 9: `/new-prometheus-exporter` carries the third value

**Files:**
- Modify: `commands/new-prometheus-exporter.md`

**Interfaces:**
- Produces: the command passes `--target-model multi-instance`, `--instance-label <name>`, and the two monitoring `--var`s to `scaffold.sh`.

- [ ] **Step 1: Make the single/multi choice three-valued.** Rewrite the `--target-model` mapping bullet (lines 40-46 and 111-116) to include `multi-instance`. At lines 40-46:

```markdown
- **Single-target vs. multi-target vs. multi-instance.** Maps to
  `--target-model single` (default), `--target-model multi` (one target per
  request via `?target=`), or `--target-model multi-instance` (a fixed list of
  instances polled in the background, from `--config.file`). Both multi models
  **require `--flavor http`**. If the design brief describes many machines with
  per-machine credentials known ahead of time, or a source that refreshes more
  slowly than Prometheus's 5-minute staleness window, that is multi-instance;
  if Prometheus should pick the target per scrape, that is multi. Reject a
  multi model with a CLI-flavored source rather than silently falling back.
```

At line 111-116, extend the `--target-model` passthrough to accept `multi-instance` and add the instance-label passthrough:

```markdown
- **`--target-model`** (`single`, `multi`, or `multi-instance`, not a `--var`):
  carried over from the step 0 decision; default `single`. Both `multi` and
  `multi-instance` require `--flavor http`: reject either paired with
  `--flavor cli` yourself, with a clear message, before running scaffold.sh.
- **`--instance-label`** (not a `--var`; multi-instance only): the label name
  this exporter applies to every instance's series; default `target`. Ask only
  if the design brief named a more natural dimension (e.g. `library`, `device`).
  Ignored for single/multi.
```

- [ ] **Step 2: Compute and pass the two monitoring vars.** In the scaffold.sh invocation block (lines 170-183), add `--target-model` already present; add the instance label and the two computed vars. Insert after the `--var DEFAULT_PORT=...` line:

```markdown
--instance-label <INSTANCE_LABEL, multi-instance only; omit otherwise> \
--var COLLECTOR_HEALTH_BY=<"job,<INSTANCE_LABEL>" for multi-instance, else "job"> \
--var COLLECTOR_LOCATION=<"<INSTANCE_LABEL>" for multi-instance, else "instance"> \
```

Add a sentence right below the command block: "For `single`/`multi`, pass `--var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance` (the shipped rules aggregate by job and name the exporter host). For `multi-instance`, pass `--var COLLECTOR_HEALTH_BY=job,<instance-label> --var COLLECTOR_LOCATION=<instance-label>` so the health rules break down per instance."

- [ ] **Step 3: Verify the doc is internally consistent** (no leftover "single or multi" that excludes the third value). Grep: `grep -n 'single or multi\|single, multi' commands/new-prometheus-exporter.md` and fix any that now read as exhaustive-of-two.

- [ ] **Step 4: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "docs(command): carry multi-instance through /new-prometheus-exporter"
```

### Task 10: `/add-collector` gains a multi-instance branch

**Files:**
- Modify: `commands/add-collector.md`

**Interfaces:**
- Consumes: `instance.Factory` (Task 3), the `@@INSTANCE_FACTORIES@@` marker (Task 5).

The seam-shape detection at line 39 (`[ -d internal/probe ] && echo multi || echo single`) is now two-way but there are three models. Multi-instance ships `internal/instance/`, not `internal/probe/`.

- [ ] **Step 1: Make the detection three-way.** Replace the detection at line 39:

```sh
if [ -d internal/instance ]; then echo multi-instance
elif [ -d internal/probe ]; then echo multi
else echo single; fi
```

- [ ] **Step 2: Add the multi-instance refusal-and-branch.** Extend the "Refuse `--variant background` on a multi-target scaffold" note (lines 191-196) with the mirror rule, and add a multi-instance wiring section. After the existing refusal block, add:

```markdown
**On a multi-instance scaffold, the mirror rule holds: refuse the SYNCHRONOUS
variant.** Every collector there is a background poller by construction (a
scrape serves N instances through one /metrics and must never block on a dead
machine). A synchronous collector would reintroduce exactly that coupling. Say
so and use the background variant.

**Multi-instance wiring.** Read the collector's identity (step 2) and
materialize the BACKGROUND collector file and its test (step 3-4, background
templates) exactly as for a single-target background collector. Then, at the
`// @@INSTANCE_FACTORIES@@` marker in `cmd/*/main.go`, append (after the last
existing `factories = append(...)` block, never replacing the marker):

​```go
	<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-request timeout for the <name> collector.").Default("5s").Duration()
	<name>Interval := kingpin.Flag("collector.<name>.interval", "Background refresh interval for the <name> collector.").Default("5m").Duration()
	<name>Enabled := kingpin.Flag("collector.<name>", "Enable the <name> collector.").Default("true").Bool()
	factories = append(factories, instance.Factory{
		Name:    "<name>",
		Enabled: <name>Enabled,
		New: func(addr string, hcfg *promconfig.HTTPClientConfig) (instance.BackgroundCollector, error) {
			var client *collector.Client
			if hcfg != nil {
				var err error
				client, err = collector.NewClientWithConfig(addr, *<name>Timeout, *hcfg)
				if err != nil {
					return nil, err
				}
			} else {
				client = collector.NewClient(addr, *<name>Timeout)
			}
			return collector.New<Name>Collector(log, client, *<name>Interval), nil
		},
	})
​```

There is no `@@CLIENT_INIT@@`/`@@CLIENT_BUILD@@`/`@@COLLECTOR_REGISTRY@@` in a
multi-instance main (it carries only `@@INSTANCE_FACTORIES@@`), and no
`--collector.<name>.target` flag (the target is each instance's address).
```

- [ ] **Step 3: Verify the doc's own idempotence/skip checks account for the third model** (step 2 "Idempotent refusal" greps `cmd/*/main.go` for `register("<name>"` which multi-instance does not use; note that on multi-instance the check is `grep -q 'Name: *"<name>"' cmd/*/main.go` instead). Add that note.

- [ ] **Step 4: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "docs(command): teach /add-collector the multi-instance branch"
```

### Task 11: Instance-aware health rules (scaffold-time divergence)

**Files:**
- Modify: `skills/prometheus-exporter/assets/monitoring/prometheus/rules.yml.tmpl`
- Modify: `skills/prometheus-exporter/assets/monitoring/prometheus/alerts.yml.tmpl`
- Modify: `test/scaffold_multitarget_test.sh` (commonvars)
- Modify: `test/golden-smoke.sh` (its scaffold-invocation vars)

Adding these sentinels means EVERY real-assets scaffold must now pass the two vars, so the harnesses are updated in the same task to keep them green.

- [ ] **Step 1: Recording rule aggregates by the instance dimension.** In `rules.yml.tmpl`, replace both `sum by (job)` in the `avg_healthy` record (lines 38-39) with `sum by (@@COLLECTOR_HEALTH_BY@@)`:

```yaml
      - record: job:@@NAMESPACE@@_exporter_collector_duration_seconds:avg_healthy
        expr: >
          sum by (@@COLLECTOR_HEALTH_BY@@) (@@NAMESPACE@@_exporter_collector_duration_seconds * @@NAMESPACE@@_exporter_collector_success)
          / (sum by (@@COLLECTOR_HEALTH_BY@@) (@@NAMESPACE@@_exporter_collector_success) > 0)
```

- [ ] **Step 2: Collector alerts name the failing machine.** In `alerts.yml.tmpl`, in the THREE collector-level alert descriptions ONLY (ExporterCollectorFailing line 99, and both ExporterCollectorDurationHigh at lines 114 and 124), replace `{{ $labels.instance }}` with `{{ $labels.@@COLLECTOR_LOCATION@@ }}`. Leave `ExporterDown` (line 58) and `ExporterMetricsMissing` (line 82) unchanged: those are exporter-process-level, where `instance` (the exporter host) is correct.

- [ ] **Step 3: Update the real-assets harness vars.** In `test/scaffold_multitarget_test.sh`, append to `commonvars` (line 35): ` --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance`. In `test/golden-smoke.sh`, find the `--var` list it passes to `scaffold.sh` (the per-cell scaffold invocation) and add the same two vars for every cell; for the multi-instance cell (Task 12) use `--var COLLECTOR_HEALTH_BY=job,target --var COLLECTOR_LOCATION=target`.

- [ ] **Step 4: Verify.**

```bash
test/scaffold_multitarget_test.sh   # PASS (no residual @@COLLECTOR_*@@ sentinel)
# Scaffold a single demo and confirm rules.yml has "sum by (job)" and alerts.yml "$labels.instance";
# scaffold a multi-instance demo (--var COLLECTOR_HEALTH_BY=job,target --var COLLECTOR_LOCATION=target)
# and confirm "sum by (job,target)" and "$labels.target". Run: promtool check rules on both if promtool is available.
```

- [ ] **Step 5: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "feat(monitoring): make health rules instance-aware on multi-instance scaffolds"
```

### Task 12: Golden-smoke cell for `multi-instance`

**Files:**
- Modify: `test/golden-smoke.sh`

**Interfaces:**
- Consumes: Task 6 scaffold, Task 11 vars.

- [ ] **Step 1: Accept `multi-instance` in golden-smoke's own target-model validation.** Replace its `case "$target_model"` (lines 133-135) and the cli restriction (line 137-138) to mirror scaffold.sh's three-value form:

```sh
case "$target_model" in
  single|multi|multi-instance) ;;
  *) die "invalid --target-model '$target_model'; must be single, multi, or multi-instance" ;;
esac
if { [ "$target_model" = multi ] || [ "$target_model" = multi-instance ]; } && [ -n "$flavor" ] && [ "$flavor" != http ]; then
  die "--target-model $target_model requires --flavor http (no cli multi-target)"
fi
```

- [ ] **Step 2: Add a 6th `--all` cell.** Read the existing http-multi 5th cell (the extra cell described at lines 48-49, `flavor=http, forge=none, target-model=multi`) and mirror it for `multi-instance`: same flavor/forge, `--target-model multi-instance`, plus the two monitoring vars (`COLLECTOR_HEALTH_BY=job,target`, `COLLECTOR_LOCATION=target`). For the cell's runtime smoke check, write a `--config.file` with two instances pointed at unreachable local addresses (the background pollers fail-open; the health series still appear immediately from the always-emitted freshness gauge):

```yaml
instances:
  - { name: alpha, address: http://127.0.0.1:1 }
  - { name: beta,  address: http://127.0.0.1:1 }
```

Start the binary with `--config.file`, scrape `/metrics`, and assert both `target="alpha"` and `target="beta"` appear on `demo_exporter_collector_success` (the WrapRegistererWith label). Mirror the http-multi cell's own `promtool check metrics` step.

- [ ] **Step 3: Update the `--all` header comment** (lines 48-49) to say the matrix now runs 4 base cells plus a 5th http-multi cell plus a 6th http-multi-instance cell (six total).

- [ ] **Step 4: Run the new cell.** Run: `test/golden-smoke.sh --flavor http --forge none --target-model multi-instance`
Expected: scaffolds, `go build`/`go test` PASS, binary starts, `/metrics` carries `target="alpha"` and `target="beta"`, promtool clean.

- [ ] **Step 5: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "test(golden-smoke): add the http/none/multi-instance cell"
```

### Task 13: `/design-exporter` decision 2 becomes a three-value choice

**Files:**
- Modify: `commands/design-exporter.md`

- [ ] **Step 1: Rewrite decision 2** (lines 76-78). The current text ("state plainly if the real shape is multi-target; that stays documented follow-up work, not something this command or `/new-prometheus-exporter` produces") has been false since v0.3. Replace with:

```markdown
2. **Single-target vs. multi-target vs. multi-instance**: state which of the
   three the real shape is. `single` reports on one fixed target. `multi` lets
   Prometheus pick the target per scrape (`?target=`, the Blackbox pattern).
   `multi-instance` polls a fixed list of machines in the background and serves
   them through one `/metrics` (the model for sources that refresh more slowly
   than Prometheus's 5-minute staleness window, or that carry per-machine
   credentials). All three are produced by `/new-prometheus-exporter`; both
   multi models require the `http` flavor.
```

- [ ] **Step 2: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "docs(command): make /design-exporter's target-model decision three-valued"
```

### Task 14: Documentation

**Files:**
- Modify: `skills/prometheus-exporter/assets/docs/configuration.md.tmpl`
- Modify: `skills/prometheus-exporter/assets/README.md.tmpl`
- Modify: `skills/prometheus-exporter/references/project-scaffold.md`
- Modify: `ROADMAP.md`
- Modify: `CHANGELOG.md` (if an `## [Unreleased]` section exists)

Follow the writing-docs Iron Rule: every documented flag/section/path is verified against the code written in Tasks 1-13. No em/en dashes in shipped `assets/`.

- [ ] **Step 1: `configuration.md.tmpl`.** Add a "multi-instance" subsection documenting: `--config.file` is required; the `modules:` and `instances:` schema (mirror the design doc §3 example, but as generated-repo docs, not plugin internals); the instance label (`@@INSTANCE_LABEL@@`, fixed at scaffold time); and the Prometheus scrape config (scraped like single, one static target, `scrape_timeout` covers the process not N live fetches, because `/metrics` reads caches). This file is `@@VAR@@`-templated; reference `@@INSTANCE_LABEL@@` where the label name appears.

- [ ] **Step 2: `README.md.tmpl`.** Add one line to the model list / features noting the exporter watches a fixed instance list via `--config.file` when scaffolded `multi-instance`. Only if the README enumerates the target models; otherwise skip (verify first).

- [ ] **Step 3: `references/project-scaffold.md`.** Add `internal/instance/` to the repository-layout tree, described as "multi-instance seam: the background collector Factory the multi-instance main fans out over instances". Verify the tree's existing entries first so the addition matches its format.

- [ ] **Step 4: `ROADMAP.md`.** Rejustify the v0.5 entry by the five-minute staleness window (design doc §4), not "slow targets": the argument generalises to any application API, batch, or nightly inventory, not only tape libraries. Mark the multi-instance model delivered; note volet A (multi per-target credentials) as the sequenced follow-up.

- [ ] **Step 5: `CHANGELOG.md`.** If an `## [Unreleased]` section exists, add entries under `### Added`: the `multi-instance` target model, the `modules:`/`instances:` config schema, `scaffold.sh --instance-label`. Verify the file's existing entry style first.

- [ ] **Step 6: Voice pass.** Run the `humanizer` skill over the new prose in `configuration.md.tmpl` and `ROADMAP.md`. Re-scan for em/en dashes: `grep -rnP '[\x{2014}\x{2013}]' skills/prometheus-exporter/assets/docs/configuration.md.tmpl skills/prometheus-exporter/assets/README.md.tmpl` must be empty.

- [ ] **Step 7: Commit.**

```bash
test/zero-source-grep.sh
git -c commit.gpgsign=false commit -am "docs: document the multi-instance target model"
```

---

## Deferred (out of scope for this plan)

- **Volet A: per-target credentials for the `multi` (`?target=`) model** (spec §1A). An additive change to `internal/probe` (select a module's `http_client_config` per request via `?module=`), the `probe_factory.frag`, the multi main, and `/add-collector`'s multi branch, plus the `--probe.module` + `modules:` collision rule (spec §"The `--probe.module` flag collision"). Independent of everything above; sequenced as the next plan on this epic branch. Until it lands, the multi main leaves a config `modules:` section parsed but unconsumed (a `multi` scaffold's credentials still come from the single top-level `http_client_config`, unchanged from v0.4).
- **SIGHUP reload** of the instance list -> v0.6.0 (spec Non-goals, §15).
- **Per-instance flag overrides** -> not planned (spec Non-goals).
