# Per-module credentials for `multi` (volet A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a `/probe?target=...&module=...` request select its credentials by
name, so one multi-target exporter can probe targets that authenticate
differently.

**Architecture:** `internal/config` gains `ResolveModules`, the mirror of
volet B's `ResolveInstances`, and stays free of I/O. `mains/multi/main.go.tmpl`
builds one `*http.Client` per credential-bearing module, once, at boot.
`internal/probe`'s `Factory` gains a fourth `hc *http.Client` parameter and its
module map becomes `map[string]Module` carrying both a collector subset and a
client. `selectFactories` resolves credentials in a fixed order and refuses the
two ambiguous cases with a 400.

**Tech Stack:** Go 1.26.5, `prometheus/common/config` (`HTTPClientConfig`),
`kingpin/v2`, `go.yaml.in/yaml/v2`. The plugin's own tooling is POSIX sh
(`scaffold.sh`) and the containerised `test/golden-smoke.sh`.

**Spec:** [`docs/design/2026-07-27-multi-target-module-credentials-design.md`](../design/2026-07-27-multi-target-module-credentials-design.md).
Rule numbers below refer to its §3.2.

**Branch:** `feat/multi-target-module-credentials`, already created, already
carrying the spec (`d392714`) and its amendment (`84053b8`).

## Global Constraints

- **Nothing under `skills/prometheus-exporter/assets/` may name the source
  project or the maintainer.** `test/zero-source-grep.sh` is a hard gate; run
  it before every commit.
- **Templates use `@@VAR@@` sentinels**, substituted by `scaffold.sh`. Never
  bake a concrete namespace, module path or exporter name into a template.
- **No em dashes or en dashes (U+2014, U+2013) anywhere under `assets/` or
  `skills/.../scripts/`.** Use `.`, `,`, `:` or parentheses. ASCII `--` is
  fine. This was a deliberate 46-file sweep; do not reintroduce them.
- **`single` and `multi-instance` scaffolds must come out byte-identical.**
  Only `mains/multi/`, `code/http/wiring/probe_factory.frag`,
  `internal/probe/` and the shared `internal/config/` are in scope, and the
  `internal/config` change must be additive.
- **The `--probe.module` flag keeps working.** It is deprecated by this
  change, removed no earlier than v0.6.0 (two-phase rule).
- **Evidence before assertion.** No task is done until the command that proves
  it has been run and its real output shown. `make check` (not just
  `go build`) is what the golden runs; a task that only ran `go vet` has not
  been verified.

---

## File Structure

| File | Responsibility after this change |
|---|---|
| `skills/prometheus-exporter/assets/internal/config/config.go.tmpl` | adds `ResolvedModule` + `ResolveModules`; parsing and validation only, no `*http.Client` |
| `skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl` | `ResolveModules` unit tests |
| `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl` | `Module` type, 4-parameter `Factory`, credential resolution in `selectFactories` |
| `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl` | updated call sites + the new selection tests |
| `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl` | boot-time refusals (rules 8, 9) and the module-to-client map |
| `skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag` | loses its boot-time client build, gains the fourth parameter |
| `test/golden-smoke.sh` | the second-collector snippet gains the fourth parameter; a new modules sub-check |
| `commands/add-collector.md` | third seam shape, its migration, one unified append block |
| `assets/config.example.yml.tmpl`, `assets/docs/configuration.md.tmpl`, `assets/SECURITY.md.tmpl` | operator-facing documentation shipped in every generated exporter |
| `references/*.md`, `commands/design-exporter.md`, `commands/new-prometheus-exporter.md` | taught content and the design-time question |

---

## Task 1: `config.ResolveModules`

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/config/config.go.tmpl` (append after `resolveModule`, around `:477`)
- Test: `skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl`

**Interfaces:**
- Consumes: the existing `Config.Modules map[string]Module` and
  `Config.HTTPClientConfig *promconfig.HTTPClientConfig`, both already parsed
  and validated by `Load`.
- Produces: `type ResolvedModule struct { Collectors []string; ClientConfig *promconfig.HTTPClientConfig }`
  and `func (c *Config) ResolveModules() (map[string]ResolvedModule, error)`.
  Task 3 calls it from `mains/multi/main.go.tmpl`.

**Working directory for the test run:** scaffold a throwaway multi tree first,
because these are `.tmpl` files that only compile once substituted:

```sh
rm -rf /tmp/vA && skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst /tmp/vA \
  --flavor http --forge none --target-model multi \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo --var DEFAULT_PORT=9999 \
  --var OWNER=demo --var LICENSE=apache-2.0 --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
```

Re-run that command after every template edit in this task; it is how the
`.tmpl` becomes compilable Go.

- [ ] **Step 1: Write the failing tests**

Append to `skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl`:

```go
func TestResolveModulesReturnsNilWithNoSection(t *testing.T) {
	got, err := (&Config{}).ResolveModules()
	if err != nil {
		t.Fatalf("ResolveModules: %v", err)
	}
	if got != nil {
		t.Errorf("ResolveModules() = %v, want nil when no modules: section is declared", got)
	}
}

func TestResolveModulesKeepsCollectorsAndClientConfig(t *testing.T) {
	hc := &promconfig.HTTPClientConfig{}
	c := &Config{Modules: map[string]Module{
		"prod": {HTTPClientConfig: hc},
		"disks": {Collectors: []string{"disks"}},
	}}
	got, err := c.ResolveModules()
	if err != nil {
		t.Fatalf("ResolveModules: %v", err)
	}
	if got["prod"].ClientConfig != hc {
		t.Errorf("module prod lost its client config")
	}
	if len(got["disks"].Collectors) != 1 || got["disks"].Collectors[0] != "disks" {
		t.Errorf("module disks collectors = %v, want [disks]", got["disks"].Collectors)
	}
	if got["disks"].ClientConfig != nil {
		t.Errorf("module disks invented a client config")
	}
}

// Rule 9: with modules declared, nothing reads the top-level section, so
// accepting both would silently ignore one of two places an operator wrote
// credentials.
func TestResolveModulesRejectsTopLevelClientConfigAlongsideModules(t *testing.T) {
	c := &Config{
		HTTPClientConfig: &promconfig.HTTPClientConfig{},
		Modules:          map[string]Module{"prod": {}},
	}
	_, err := c.ResolveModules()
	if err == nil {
		t.Fatal("ResolveModules accepted a modules: section alongside a top-level http_client_config:")
	}
	if !strings.Contains(err.Error(), "http_client_config") {
		t.Errorf("error does not name the offending section: %v", err)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```sh
rm -rf /tmp/vA && skills/prometheus-exporter/assets/scaffold.sh --src skills/prometheus-exporter/assets --dst /tmp/vA --flavor http --forge none --target-model multi --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DEFAULT_PORT=9999 --var OWNER=demo --var LICENSE=apache-2.0 --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/vA && go test ./internal/config/ -run TestResolveModules -v
```

Expected: FAIL, `c.ResolveModules undefined`.

- [ ] **Step 3: Implement**

Append to `config.go.tmpl`, after `resolveModule` ends:

```go
// ResolvedModule is one validated module: the collector subset it selects and
// the client config its probes authenticate with, nil meaning the default
// transport.
type ResolvedModule struct {
	Collectors   []string
	ClientConfig *promconfig.HTTPClientConfig
}

// ResolveModules validates the modules section for the multi target model.
// Unlike multi-instance, multi HONOURS a module's "collectors:" key: there it
// selects the probe's collector subset, which is the job the deprecated
// --probe.module flag does today.
//
// A modules: section alongside a top-level http_client_config: is refused.
// With modules declared, nothing reads the top-level section, so accepting
// both would silently ignore one of the two places an operator wrote
// credentials. That refusal is also what makes credential resolution
// unambiguous in internal/probe: the top-level client is reachable only when
// no module is.
//
// It builds no *http.Client. This package stays a parsing and validation
// layer with no I/O, exactly as ResolveInstances leaves it; the caller builds
// the clients so a failure there can name the module it came from.
func (c *Config) ResolveModules() (map[string]ResolvedModule, error) {
	if len(c.Modules) == 0 {
		return nil, nil
	}
	if c.HTTPClientConfig != nil {
		return nil, fmt.Errorf("config file: \"modules:\" and a top-level \"http_client_config:\" cannot both be set; with modules declared the top-level section has no reader, so move it into a module (a module named \"default\" is the one a probe gets when it names none)")
	}

	out := make(map[string]ResolvedModule, len(c.Modules))
	for name, m := range c.Modules {
		out[name] = ResolvedModule{
			Collectors:   m.Collectors,
			ClientConfig: m.HTTPClientConfig,
		}
	}
	return out, nil
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```sh
rm -rf /tmp/vA && skills/prometheus-exporter/assets/scaffold.sh --src skills/prometheus-exporter/assets --dst /tmp/vA --flavor http --forge none --target-model multi --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DEFAULT_PORT=9999 --var OWNER=demo --var LICENSE=apache-2.0 --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/vA && go test ./internal/config/ -v
```

Expected: PASS, including every pre-existing test in the file.

- [ ] **Step 5: Prove single and multi-instance are untouched**

```sh
cd /home/sckyzo/Dev/work/apps_repo/exporters/prometheus-exporter-plugin
test/zero-source-grep.sh
```

Expected: `PASS`.

- [ ] **Step 6: Commit**

```sh
git add skills/prometheus-exporter/assets/internal/config/
git commit -m "feat(templates): resolve the modules section for the multi target model

ResolveModules mirrors ResolveInstances: it validates the modules section
and hands back each module's collector subset and client config, building
no client of its own so this package keeps doing no I/O.

It refuses a modules: section alongside a top-level http_client_config:.
With modules declared nothing reads the top-level section, so accepting
both would silently drop one of two places an operator wrote credentials,
and the refusal is what lets the probe resolve credentials in one
unambiguous order."
```

---

## Task 2: the probe seam

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl`

**Interfaces:**
- Consumes: nothing from Task 1 directly (the wiring is Task 3).
- Produces, all used by Task 3 and Task 5:
  - `type Module struct { Collectors []string; Client *http.Client }`
  - `type Factory func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error)`
  - `func ParseModules(vals []string) (map[string]Module, error)`
  - `func ValidateModules(factories []NamedFactory, modules map[string]Module) error`
  - `func NewHandler(log *logger.Logger, factories []NamedFactory, allowlist []string, maxTimeout, timeoutOffset time.Duration, modules map[string]Module, defaultClient *http.Client) *Handler`

- [ ] **Step 1: Write the failing tests**

First update every existing call site in `probe_test.go.tmpl`, because the
signature change breaks them all. Three mechanical edits:

```go
// :26 recordingFactory.make gains the parameter and records it.
type recordingFactory struct {
	calls   int
	target  string
	timeout time.Duration
	client  *http.Client // the client the handler resolved for this probe
	panics  bool
	metric  string
}

func (f *recordingFactory) make(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
	f.calls++
	f.target = target
	f.timeout = timeout
	f.client = hc
	if f.panics {
		return panicCollector{}, nil
	}
	metric := f.metric
	if metric == "" {
		metric = "stub_up"
	}
	return &stubCollector{desc: prometheus.NewDesc(metric, "stub", nil, nil)}, nil
}
```

```go
// :85 newTestHandler and every other NewHandler call gain a trailing nil.
func newTestHandler(f *recordingFactory, allowlist []string) *Handler {
	return NewHandler(logger.NewTextLogger("error"), []NamedFactory{f.named("example")}, allowlist, 5*time.Second, 0, nil, nil)
}
```

Apply the same trailing `, nil` to the `NewHandler` calls at `:176`, `:206`,
`:230`, `:245`, `:283` and `:365`, and add the fourth parameter to the two
inline factory literals at `:202` and `:226`:

```go
		New: func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
```

Then convert the three module maps from `map[string][]string` to
`map[string]Module`:

```go
// :334 and :338, inside TestValidateModulesRejectsUnknownCollector
	if err := ValidateModules(factories, map[string]Module{"basic": {Collectors: []string{"disks"}}}); err != nil {
		t.Fatalf("a module naming a registered collector was rejected: %v", err)
	}

	err := ValidateModules(factories, map[string]Module{"basic": {Collectors: []string{"disks", "typo"}}})
```

```go
// :361, inside threeFactoryHandler
	modules := map[string]Module{
		"ab": {Collectors: []string{"alpha", "beta"}},
		"bc": {Collectors: []string{"beta", "gamma"}},
	}
	h := NewHandler(logger.NewTextLogger("error"), factories, nil, 5*time.Second, 0, modules, nil)
```

```go
// :305-310, inside TestParseModules: the return type changed.
	if got := mods["basic"].Collectors; len(got) != 2 || got[0] != "disks" || got[1] != "pools" {
		t.Errorf("basic = %v, want [disks pools]", got)
	}
	if got := mods["full"].Collectors; len(got) != 3 {
		t.Errorf("full = %v, want 3 collectors", got)
	}
```

Now append the new tests:

```go
// credModuleHandler registers alpha and beta, with prod and staging each
// carrying their own client, and disks selecting a collector subset with no
// credentials of its own.
func credModuleHandler(t *testing.T, defaultModuleClient *http.Client) (*Handler, map[string]*recordingFactory) {
	t.Helper()
	fs := map[string]*recordingFactory{
		"alpha": {metric: "stub_alpha"},
		"beta":  {metric: "stub_beta"},
	}
	factories := []NamedFactory{fs["alpha"].named("alpha"), fs["beta"].named("beta")}
	modules := map[string]Module{
		"prod":    {Client: &http.Client{}},
		"staging": {Client: &http.Client{}},
		"disks":   {Collectors: []string{"alpha"}},
	}
	if defaultModuleClient != nil {
		modules["default"] = Module{Client: defaultModuleClient}
	}
	h := NewHandler(logger.NewTextLogger("error"), factories, nil, 5*time.Second, 0, modules, nil)
	return h, fs
}

// Rule 2 step 1: the selected module's client is the one the factory gets.
func TestSelectedModuleSuppliesItsClient(t *testing.T) {
	h, fs := credModuleHandler(t, nil)
	want := h.modules["prod"].Client

	rec := serve(h, "/probe?target=http://n:9100&module=prod")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	if fs["alpha"].client != want {
		t.Errorf("factory received client %p, want prod's %p", fs["alpha"].client, want)
	}
}

// Rule 3: two credential-bearing modules in one request is ambiguous.
func TestTwoCredentialBearingModulesRejected(t *testing.T) {
	h, fs := credModuleHandler(t, nil)

	rec := serve(h, "/probe?target=http://n:9100&module=prod,staging")

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("two credential-bearing modules: got %d, want 400", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "both carry credentials") {
		t.Errorf("body does not explain the ambiguity: %s", rec.Body.String())
	}
	for name, f := range fs {
		if f.calls != 0 {
			t.Errorf("collector %q ran %d times for a rejected probe, want 0", name, f.calls)
		}
	}
}

// Rule 1: a module carrying only credentials must not widen the selection,
// which is what makes the SNMP convention (credential module combined with
// collector modules) expressible.
func TestCredentialsOnlyModuleDoesNotWidenSelection(t *testing.T) {
	h, fs := credModuleHandler(t, nil)

	rec := serve(h, "/probe?target=http://n:9100&module=prod,disks")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	if fs["alpha"].calls != 1 {
		t.Errorf("alpha ran %d times, want 1", fs["alpha"].calls)
	}
	if fs["beta"].calls != 0 {
		t.Errorf("beta ran %d times: a credentials-only module widened the selection", fs["beta"].calls)
	}
	if fs["alpha"].client != h.modules["prod"].Client {
		t.Errorf("alpha did not receive prod's client")
	}
}

// Rule 2 step 2: a request naming only a collector module falls back to the
// default module's credentials.
func TestCollectorOnlyModuleFallsBackToDefaultCredentials(t *testing.T) {
	def := &http.Client{}
	h, fs := credModuleHandler(t, def)

	rec := serve(h, "/probe?target=http://n:9100&module=disks")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	if fs["alpha"].client != def {
		t.Errorf("factory received %p, want the default module's client %p", fs["alpha"].client, def)
	}
}

// Rule 5: probing in the clear against a configuration that declares
// credentials is refused, both when the request names no module at all and
// when it names only a collector module.
func TestUnresolvedCredentialsRejected(t *testing.T) {
	for _, rawurl := range []string{
		"/probe?target=http://n:9100",              // forgot &module= entirely
		"/probe?target=http://n:9100&module=disks", // named only a collector module
	} {
		t.Run(rawurl, func(t *testing.T) {
			h, fs := credModuleHandler(t, nil) // no default module
			rec := serve(h, rawurl)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("got %d, want 400", rec.Code)
			}
			if !strings.Contains(rec.Body.String(), "no credentials selected") {
				t.Errorf("body does not explain what is missing: %s", rec.Body.String())
			}
			for name, f := range fs {
				if f.calls != 0 {
					t.Errorf("collector %q ran %d times for a rejected probe, want 0", name, f.calls)
				}
			}
		})
	}
}

// Rule 5's other half: a configuration that declares no credentials anywhere
// keeps probing on the default transport, which is what it already does.
func TestNoCredentialsAnywhereStillProbes(t *testing.T) {
	h, fs := threeFactoryHandler(t)

	rec := serve(h, "/probe?target=http://n:9100&module=ab")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	if fs["alpha"].client != nil {
		t.Errorf("factory received a client %p, want nil (default transport)", fs["alpha"].client)
	}
}

// Rule 2 step 3, the v0.4.0 path: flag-declared modules carry no credentials,
// so the top-level http_client_config still applies to every request. This is
// the guarantee that an existing deployment behaves identically.
func TestFlagModulesFallBackToTopLevelClient(t *testing.T) {
	top := &http.Client{}
	f := &recordingFactory{metric: "stub_alpha"}
	h := NewHandler(logger.NewTextLogger("error"), []NamedFactory{f.named("alpha")}, nil,
		5*time.Second, 0, map[string]Module{"basic": {Collectors: []string{"alpha"}}}, top)

	rec := serve(h, "/probe?target=http://n:9100&module=basic")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	if f.client != top {
		t.Errorf("factory received %p, want the top-level client %p", f.client, top)
	}
}

// A repeated module name must not look like two credential-bearing modules.
func TestRepeatedModuleNameIsNotAnAmbiguity(t *testing.T) {
	h, _ := credModuleHandler(t, nil)

	rec := serve(h, "/probe?target=http://n:9100&module=prod,prod")

	if rec.Code != http.StatusOK {
		t.Fatalf("module=prod,prod: got %d, want 200", rec.Code)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```sh
rm -rf /tmp/vA && skills/prometheus-exporter/assets/scaffold.sh --src skills/prometheus-exporter/assets --dst /tmp/vA --flavor http --forge none --target-model multi --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DEFAULT_PORT=9999 --var OWNER=demo --var LICENSE=apache-2.0 --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/vA && go test ./internal/probe/ 2>&1 | head -30
```

Expected: FAIL to compile, `too many arguments in call to NewHandler` and
`unknown field Client in struct literal`.

- [ ] **Step 3: Implement the type changes**

In `probe.go.tmpl`, replace the `Factory` type comment block and declaration
(`:36-54`) with:

```go
// Factory builds one collector scoped to one probe target, bounded by the
// probe's deadline. ctx is what makes that deadline real: prometheus.Collector's
// Collect(ch) takes no context, so the collector receives it at construction
// (see the collector template's ctx field). The multi main.go appends one
// NamedFactory per collector at its // @@PROBE_FACTORIES@@ marker, and
// /add-collector appends another every time it adds a collector.
//
// hc is the *http.Client the handler resolved for THIS request, from the
// module the request selected, or nil for the default transport. It is
// resolved per request and built once at boot, never per probe: building a
// client per probe would give each request a private connection pool and
// re-read the CA and credential files from disk (see NewHTTPClient in
// internal/collector).
//
// A factory may fail, which happens when the configured authentication or
// TLS cannot be turned into a client (an unreadable CA file, for example).
// That is a configuration error, so it fails the probe loudly rather than
// being reported as an unreachable target.
type Factory func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error)

// NamedFactory pairs a Factory with the collector name that the StatusTracker
// keys its health metric on. Handler holds these in an ordered slice, not a
// map: Go randomizes map iteration, which would make collector ordering and
// error messages nondeterministic for no benefit.
type NamedFactory struct {
	Name string
	New  Factory
}

// Module is one named bundle a probe can select with ?module=. Collectors
// narrows the probe to a subset; a module that lists none contributes only its
// credentials and does not widen the selection, which is what lets a
// credentials module be combined with collector modules in one request.
// Client is nil for a module that carries no authentication of its own.
type Module struct {
	Collectors []string
	Client     *http.Client
}
```

Replace the `Handler` struct and `NewHandler` (`:56-77`) with:

```go
// Handler serves /probe?target=… .
type Handler struct {
	log           *logger.Logger
	factories     []NamedFactory
	allowlist     []string      // empty => allow-any (ecosystem default; see SECURITY.md)
	maxTimeout    time.Duration // --probe.timeout: ceiling on each probe's deadline
	timeoutOffset time.Duration // --probe.timeout-offset: answer before Prometheus gives up
	modules       map[string]Module
	defaultClient *http.Client // top-level http_client_config; nil unless it was set
	credentialed  []string     // sorted names of modules carrying credentials
}

// NewHandler builds a /probe handler. An empty allowlist accepts any target
// that clears the http/https floor (the Blackbox/SNMP default).
//
// defaultClient is the client built from the top-level http_client_config
// section. It is non-nil only when that section was set, which the
// configuration layer allows only when no modules: section exists: that is
// what keeps credential resolution unambiguous.
func NewHandler(log *logger.Logger, factories []NamedFactory, allowlist []string, maxTimeout, timeoutOffset time.Duration, modules map[string]Module, defaultClient *http.Client) *Handler {
	// Precomputed for the message rule 5 emits, and sorted so a probe that
	// resolves no credentials names the candidates in the same order every
	// time.
	var credentialed []string
	for name, m := range modules {
		if m.Client != nil {
			credentialed = append(credentialed, name)
		}
	}
	sort.Strings(credentialed)

	return &Handler{
		log:           log,
		factories:     factories,
		allowlist:     allowlist,
		maxTimeout:    maxTimeout,
		timeoutOffset: timeoutOffset,
		modules:       modules,
		defaultClient: defaultClient,
		credentialed:  credentialed,
	}
}
```

- [ ] **Step 4: Implement `ParseModules` and `ValidateModules`**

In `ParseModules` (`:86-115`), change the map type and the assignment; every
other line stays:

```go
func ParseModules(vals []string) (map[string]Module, error) {
	modules := make(map[string]Module, len(vals))
```

```go
		modules[name] = Module{Collectors: cols}
	}
	return modules, nil
}
```

In `ValidateModules` (`:171-193`), change the parameter type and the inner
loop:

```go
func ValidateModules(factories []NamedFactory, modules map[string]Module) error {
```

```go
	for _, name := range names {
		for _, c := range modules[name].Collectors {
			if !known[c] {
				return fmt.Errorf("module %q names unknown collector %q", name, c)
			}
		}
	}
```

- [ ] **Step 5: Implement the selection rules**

Replace `moduleNames` (`:117-130`) so it deduplicates, and replace
`selectFactories` (`:132-166`) wholesale:

```go
// moduleNames flattens the module parameter, which is both repeatable and
// comma-separated: ?module=a&module=b,c selects a, b and c. This is SNMP's
// grammar, and a scrape config should not have to care which spelling it used.
// Names are deduplicated in first-seen order, so ?module=a,a selects one
// module rather than looking like two.
func moduleNames(vals []string) []string {
	seen := make(map[string]bool)
	var out []string
	for _, v := range vals {
		for _, part := range strings.Split(v, ",") {
			part = strings.TrimSpace(part)
			if part == "" || seen[part] {
				continue
			}
			seen[part] = true
			out = append(out, part)
		}
	}
	return out
}

// selectFactories resolves a request's module parameter to the collectors that
// will run and the client they authenticate with.
//
// Collectors COMBINE: the result is the union of the selected modules'
// collectors, deduplicated, emitted in the handler's declared factory order
// rather than the order the modules were listed, so a probe's output is stable
// regardless of how the scrape config spells its module list. A module that
// lists no collectors contributes none, which is what lets a credentials-only
// module be combined with collector modules. An empty selection runs every
// registered collector, which is also what an absent module parameter does.
//
// Credentials do NOT combine, because a request has one connection to make.
// They resolve in a fixed order, first hit wins: the unique selected module
// carrying a client, then the "default" module, then the top-level
// http_client_config. Two selected modules carrying credentials is refused
// rather than resolved by precedence nobody documented.
func (h *Handler) selectFactories(vals []string) ([]NamedFactory, *http.Client, error) {
	names := moduleNames(vals)

	wanted := make(map[string]bool)
	var client *http.Client
	credsFrom := ""
	for _, name := range names {
		m, ok := h.modules[name]
		if !ok {
			return nil, nil, fmt.Errorf("unknown module %q", name)
		}
		for _, c := range m.Collectors {
			wanted[c] = true
		}
		if m.Client == nil {
			continue
		}
		if credsFrom != "" {
			return nil, nil, fmt.Errorf("modules %q and %q both carry credentials; a probe can only use one", credsFrom, name)
		}
		credsFrom, client = name, m.Client
	}

	if client == nil {
		client = h.modules["default"].Client // zero Module when absent: nil client
	}
	if client == nil {
		client = h.defaultClient
	}
	// The anti-silent-unauthenticated guard: probing in the clear against a
	// target the operator gave credentials for returns 200 with series nobody
	// questions, while this 400 drives up to 0 and shows in the monitoring.
	if client == nil && len(h.credentialed) > 0 {
		return nil, nil, fmt.Errorf(
			"no credentials selected: module(s) %s declare credentials but this request selected none; name one with &module=, or declare a \"default\" module",
			strings.Join(h.credentialed, ", "))
	}

	if len(wanted) == 0 {
		return h.factories, client, nil
	}

	// Declared order, and deduplicated by construction: each factory is
	// considered exactly once, however many selected modules named it.
	var out []NamedFactory
	for _, nf := range h.factories {
		if wanted[nf.Name] {
			out = append(out, nf)
		}
	}
	return out, client, nil
}
```

- [ ] **Step 6: Wire the client through `ServeHTTP`**

At `:209-213` and `:228`:

```go
	factories, hc, err := h.selectFactories(r.URL.Query()["module"])
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
```

```go
		c, err := nf.New(ctx, target, timeout, hc)
```

- [ ] **Step 7: Run the tests to verify they pass**

```sh
rm -rf /tmp/vA && skills/prometheus-exporter/assets/scaffold.sh --src skills/prometheus-exporter/assets --dst /tmp/vA --flavor http --forge none --target-model multi --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DEFAULT_PORT=9999 --var OWNER=demo --var LICENSE=apache-2.0 --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/vA && go test ./internal/probe/ -v
```

Expected: PASS, all tests, old and new. If `sort` is reported unused or
missing, note that `probe.go.tmpl` already imports it (`:15`) for
`ValidateModules`.

- [ ] **Step 8: Commit**

```sh
cd /home/sckyzo/Dev/work/apps_repo/exporters/prometheus-exporter-plugin
test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/internal/probe/
git commit -m "feat(templates): resolve per-request credentials in the probe seam

Factory gains a fourth *http.Client parameter, the client the handler
resolved for that request, and the handler's module map carries a client
alongside the collector subset.

Credentials resolve in a fixed order (the unique selected module carrying
one, then the default module, then the top-level section) and never
combine, because a request has one connection to make. Two selected
modules carrying credentials is a 400 rather than an undocumented
precedence, and a request that resolves no credentials against a
configuration that declares some is refused too: probing in the clear
returns 200 with series nobody questions, while the 400 drives up to 0.

A module that lists no collectors contributes only its credentials, which
is what lets a credentials module be combined with collector modules in
one request."
```

---

## Task 3: multi main wiring and the flavor fragment

**Files:**
- Modify: `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag`

**Interfaces:**
- Consumes: `config.ResolveModules` (Task 1), `probe.Module`,
  `probe.ParseModules`, `probe.ValidateModules`, `probe.NewHandler` (Task 2),
  and the already-shipped `collector.NewHTTPClient(httpCfg, timeout)`
  (`code/http/client.go.tmpl:72`).
- Produces: a `multi` scaffold that builds, and the fragment shape Task 5
  teaches `/add-collector` to append.

- [ ] **Step 1: Simplify the fragment**

Replace the whole of `code/http/wiring/probe_factory.frag` with:

```go
	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
			// hc is the client the handler resolved from the module this
			// request named, or nil when no module carries credentials. It is
			// built once at boot, in main, and shared by every collector: see
			// NewHTTPClient on why a client per probe would defeat connection
			// reuse.
			if hc != nil {
				return collector.NewExampleCollector(ctx, log, collector.NewClientFor(target, hc)), nil
			}
			return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
```

The boot-time `var exampleHTTP *http.Client` block and its `os.Exit(1)` are
deleted: main builds every client now, so N collectors stop producing N
identical clients.

- [ ] **Step 2: Add the boot refusals and the client map to main**

In `mains/multi/main.go.tmpl`, add `"sort"` to the import block (alphabetically
after `"os/signal"`).

Replace the module block at `:147-159` with:

```go
	// Modules come from exactly one source. --probe.module is the deprecated
	// flag form, which can only express collector subsets; the configuration
	// file's modules: section can also carry per-module authentication. Both at
	// once would give one module name two definitions, so it is refused rather
	// than resolved by a precedence nobody documented.
	if len(cfg.Modules) > 0 && len(*probeModules) > 0 {
		log.Error("--probe.module and a \"modules:\" section in the config file cannot both be used; --probe.module is deprecated, prefer the configuration file")
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}

	modules, err := probe.ParseModules(*probeModules)
	if err != nil {
		log.Error("Invalid --probe.module", "err", err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}

	resolved, err := cfg.ResolveModules()
	if err != nil {
		log.Error("Invalid \"modules:\" section", "err", err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}

	// One client per credential-bearing module, built ONCE here rather than per
	// probe or per collector: NewClientFromConfig mints a fresh transport on
	// every call and caches nothing. An unreadable CA or credentials file is a
	// configuration fault, so it stops the exporter here rather than surfacing
	// on the first probe. Sorted so a file with two broken modules always fails
	// on the same one.
	moduleNames := make([]string, 0, len(resolved))
	for name := range resolved {
		moduleNames = append(moduleNames, name)
	}
	sort.Strings(moduleNames)
	for _, name := range moduleNames {
		rm := resolved[name]
		m := probe.Module{Collectors: rm.Collectors}
		if rm.ClientConfig != nil {
			hc, cerr := collector.NewHTTPClient(*rm.ClientConfig, *probeTimeout)
			if cerr != nil {
				log.Error("Failed to build HTTP client for module", "module", name, "err", cerr)
				stop()     // release the signal handler explicitly before bypassing defer via os.Exit
				os.Exit(1) //nolint:gocritic // stop() called explicitly above
			}
			m.Client = hc
		}
		modules[name] = m
	}

	// The top-level http_client_config, which the configuration layer accepts
	// only when no modules: section exists. It is what a probe falls back to,
	// and it is what keeps a pre-modules configuration behaving identically.
	var defaultClient *http.Client
	if cfg.HTTPClientConfig != nil {
		defaultClient, err = collector.NewHTTPClient(*cfg.HTTPClientConfig, *probeTimeout)
		if err != nil {
			log.Error("Failed to build HTTP client from http_client_config", "err", err)
			stop()     // release the signal handler explicitly before bypassing defer via os.Exit
			os.Exit(1) //nolint:gocritic // stop() called explicitly above
		}
	}

	if err := probe.ValidateModules(factories, modules); err != nil {
		log.Error("Invalid module definition", "err", err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}

	probeHandler := probe.NewHandler(log, factories, *probeTargetAllowlist, *probeTimeout, *probeTimeoutOffset, modules, defaultClient)
```

Also update `--probe.module`'s help text at `:96-99` to mark it deprecated:

```go
	probeModules := kingpin.Flag(
		"probe.module",
		"Deprecated, prefer the config file's \"modules:\" section. Declare a module: <name>:<collector>[,<collector>...] (repeatable).",
	).Strings()
```

- [ ] **Step 3: Verify the multi scaffold builds and its own gate passes**

```sh
rm -rf /tmp/vA && skills/prometheus-exporter/assets/scaffold.sh --src skills/prometheus-exporter/assets --dst /tmp/vA --flavor http --forge none --target-model multi --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DEFAULT_PORT=9999 --var OWNER=demo --var LICENSE=apache-2.0 --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/vA && make build && make check
```

Expected: both green. `make check` is what runs vet, golangci-lint, the
tests and govulncheck; `go build` alone would not have caught the gosec
finding that bit the background-refresh epic.

- [ ] **Step 4: Verify a real boot, by hand, before trusting the golden**

```sh
cd /tmp/vA
cat > /tmp/vA-modules.yml <<'EOF'
modules:
  default:
    http_client_config:
      basic_auth: { username: monitor, password: hunter2 }
  other:
    http_client_config:
      basic_auth: { username: other, password: sesame }
  onlyexample:
    collectors: [example]
EOF
./bin/demo_exporter --config.file=/tmp/vA-modules.yml --web.listen-address=127.0.0.1:9999 &
sleep 2
curl -s -o /dev/null -w 'default=%{http_code}\n'     'http://127.0.0.1:9999/probe?target=http://127.0.0.1:9999/metrics&module=default'
curl -s -o /dev/null -w 'onlyexample=%{http_code}\n' 'http://127.0.0.1:9999/probe?target=http://127.0.0.1:9999/metrics&module=onlyexample'
curl -s -w '\nambiguous=%{http_code}\n'              'http://127.0.0.1:9999/probe?target=http://127.0.0.1:9999/metrics&module=default,other'
kill %1
```

Expected: `default=200`, `onlyexample=200` (rule 2 step 2 supplies the default
module's credentials), `ambiguous=400` with a body naming both modules.

- [ ] **Step 5: Prove the other two target models are byte-identical**

```sh
cd /home/sckyzo/Dev/work/apps_repo/exporters/prometheus-exporter-plugin
for tm in single multi-instance; do
  rm -rf "/tmp/vA-$tm-head" "/tmp/vA-$tm-base"
  skills/prometheus-exporter/assets/scaffold.sh --src skills/prometheus-exporter/assets --dst "/tmp/vA-$tm-head" --flavor http --forge none --target-model "$tm" --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DEFAULT_PORT=9999 --var OWNER=demo --var LICENSE=apache-2.0 --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
done
git stash push --include-untracked
for tm in single multi-instance; do
  skills/prometheus-exporter/assets/scaffold.sh --src skills/prometheus-exporter/assets --dst "/tmp/vA-$tm-base" --flavor http --forge none --target-model "$tm" --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo --var DEFAULT_PORT=9999 --var OWNER=demo --var LICENSE=apache-2.0 --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
done
git stash pop
for tm in single multi-instance; do
  echo "== $tm =="; diff -r "/tmp/vA-$tm-base" "/tmp/vA-$tm-head" && echo "identical"
done
```

Expected: `identical` for both. The only file both models share with this
change is `internal/config/config.go`, whose addition is a new function no
other model calls, so a difference here means Task 1 was not additive.

- [ ] **Step 6: Commit**

```sh
test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/mains/multi/ skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag
git commit -m "feat(templates): build one client per module at boot in multi main

main resolves the modules: section, builds one *http.Client per
credential-bearing module before serving, and hands the map to the probe
handler. The flavor fragment loses its own client build entirely, so a
scaffold with N collectors stops producing N identical clients,
transports and connection pools for one set of credentials.

Refuses --probe.module together with a modules: section, and marks the
flag deprecated in its own help text. Single and multi-instance scaffolds
come out byte-identical."
```

---

## Task 4: golden-smoke coverage

**Files:**
- Modify: `test/golden-smoke.sh` (the second-collector snippet at `:784-790`,
  and a new block after the `http-multi` live-probe block ends at `:633`)

**Interfaces:**
- Consumes: the built `demo_exporter` binary the cell already produces, and
  the same `curl`/`sleep` polling discipline the two existing live blocks use.
- Produces: nothing other tasks consume.

- [ ] **Step 1: Update the second-collector snippet to the new seam**

In the heredoc at `:784-790`, replace the factory with the four-parameter
shape, using `hc` so the snippet stays faithful to what `/add-collector`
emits:

```sh
  cat > "$second_factory_frag" <<'EOF'
	factories = append(factories, probe.NamedFactory{
		Name: "second",
		New: func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
			if hc != nil {
				return collector.NewSecondCollector(ctx, log, collector.NewClientFor(target, hc)), nil
			}
			return collector.NewSecondCollector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
EOF
```

- [ ] **Step 2: Add the modules sub-check**

Insert immediately after the `http-multi` live-probe block's closing `fi`
(after the line `echo "confirmed: http-multi live-probe check PASSED
($flavor/$forge)"` and its `fi`), before the second-collector block:

```sh
# http-multi modules sub-check (volet A): a scaffolded multi-target exporter
# must boot with a modules: section, serve a probe that names one, and refuse
# the two ambiguous cases with a 400. It probes its OWN /metrics as the
# target, so no authenticated backend exists here: this proves the boot, the
# refusals and the status codes, NOT authentication end to end. That claim is
# carried by internal/probe's Go tests and by nothing else.
#
# Same trap discipline as the live-probe block above: that block killed its
# server and ran `trap - EXIT` before returning, so nothing is installed here.
if [ "$target_model" = multi ]; then
  echo "== http-multi: modules: section sub-check ($flavor/$forge) =="
  bin="$work/bin/demo_exporter"

  mods_config="$work/.golden-smoke-modules-config.yml"
  cat > "$mods_config" <<'EOF'
modules:
  default:
    http_client_config:
      basic_auth: { username: monitor, password: hunter2 }
  other:
    http_client_config:
      basic_auth: { username: other, password: sesame }
  onlyexample:
    collectors: [example]
EOF

  # Rule 9: modules: alongside a top-level http_client_config: must fail the
  # boot rather than silently ignore one of them. Checked with --help, which
  # returns after config loading, so this needs no listener and no port.
  both_config="$work/.golden-smoke-modules-both.yml"
  cat > "$both_config" <<'EOF'
http_client_config:
  basic_auth: { username: monitor, password: hunter2 }
modules:
  prod:
    http_client_config:
      basic_auth: { username: prod, password: hunter2 }
EOF
  if "$bin" --config.file="$both_config" --help >/dev/null 2>&1; then
    die "http-multi modules: a modules: section alongside a top-level http_client_config: was accepted ($flavor/$forge)"
  fi
  echo "confirmed: modules: plus a top-level http_client_config: is refused ($flavor/$forge)"

  # Rule 8: --probe.module and a modules: section cannot both be used. This
  # one is refused AFTER kingpin parses, so --help would exit first; start the
  # process for real and require a non-zero exit.
  if "$bin" --config.file="$mods_config" --probe.module=x:example --web.listen-address=127.0.0.1:9998 >/dev/null 2>&1; then
    die "http-multi modules: --probe.module together with a modules: section was accepted ($flavor/$forge)"
  fi
  echo "confirmed: --probe.module plus a modules: section is refused ($flavor/$forge)"

  mods_port=9999
  mods_log="$work/.golden-smoke-server-modules.log"
  "$bin" --config.file="$mods_config" --web.listen-address="127.0.0.1:$mods_port" --log.level=info >"$mods_log" 2>&1 &
  server_pid=$!
  trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT

  ready=0
  i=0
  while [ "$i" -lt 15 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$mods_port/healthz" 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || die "http-multi modules: server exited before becoming ready, see $mods_log ($flavor/$forge)"
    i=$((i + 1))
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "http-multi modules: server did not become ready on 127.0.0.1:$mods_port within 15s, see $mods_log ($flavor/$forge)"
  echo "confirmed: server ready with a 3-module configuration ($flavor/$forge)"

  mods_target="http://127.0.0.1:$mods_port/metrics"
  probe_code() {
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$mods_port/probe?target=$mods_target&module=$1"
  }

  code=$(probe_code default)
  [ "$code" = 200 ] || die "http-multi modules: ?module=default returned $code, want 200 ($flavor/$forge)"

  # Rule 2 step 2: a module that carries only a collector subset falls back to
  # the default module's credentials rather than probing in the clear.
  code=$(probe_code onlyexample)
  [ "$code" = 200 ] || die "http-multi modules: ?module=onlyexample returned $code, want 200 ($flavor/$forge)"

  # Rule 3: two credential-bearing modules in one request is ambiguous.
  code=$(probe_code default,other)
  [ "$code" = 400 ] || die "http-multi modules: ?module=default,other returned $code, want 400 ($flavor/$forge)"

  echo "confirmed: module selection serves 200 and refuses an ambiguous credential pair with 400 ($flavor/$forge)"

  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" 2>/dev/null || true
  trap - EXIT
  echo "confirmed: http-multi modules sub-check PASSED ($flavor/$forge)"
fi
```

- [ ] **Step 3: Run the multi cell**

```sh
cd /home/sckyzo/Dev/work/apps_repo/exporters/prometheus-exporter-plugin
test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: PASS, with the new `confirmed:` lines for the refusals and the
status codes.

- [ ] **Step 4: Run the whole matrix**

```sh
test/golden-smoke.sh --all
```

Expected: 6/6 cells green. This is the gate; do not proceed on a partial run.

- [ ] **Step 5: Commit**

```sh
test/zero-source-grep.sh
git add test/golden-smoke.sh
git commit -m "test(golden): prove module selection on the http-multi cell

The second-collector snippet moves to the four-parameter seam, which is
also the mechanical proof of what /add-collector appends.

A new sub-check boots the scaffolded binary against a three-module
configuration and asserts the two boot refusals (modules: with a
top-level http_client_config:, modules: with --probe.module) and three
status codes: a named module serves 200, a collector-only module falls
back to the default module's credentials and still serves 200, and two
credential-bearing modules are refused with 400.

The cell probes the exporter's own /metrics, so no authenticated backend
exists in it: this proves the boot, the refusals and the status codes,
never authentication end to end. The comment says so, so a later reader
does not mistake the cell for coverage it does not have."
```

---

## Task 5: `/add-collector` learns the third seam shape

**Files:**
- Modify: `commands/add-collector.md` (the `## Multi-target scaffolds` section,
  `:34-200`)

**Interfaces:**
- Consumes: the seam shape Task 2 and Task 3 produced.
- Produces: nothing other tasks consume. This is an LLM prompt, so its
  verification is the golden's second-collector snippet (Task 4), which
  mirrors the block this task teaches, plus a read-through.

- [ ] **Step 1: Extend the shape detection**

Replace the detection snippet at `:56` and the paragraph introducing it:

````markdown
For a **multi** repository, check the seam's shape before touching
anything. Three shapes exist:

```sh
if grep -q 'hc \*http\.Client' internal/probe/probe.go; then echo modules
elif grep -q 'factories \[\]NamedFactory' internal/probe/probe.go; then echo pre-modules
else echo v0.3.0; fi
```

- **`modules`**: current. Proceed directly to the append below.
- **`pre-modules`**: the seam holds N collectors but its `Factory` takes no
  client, so every collector is probed with the one global
  `http_client_config:`. Migrate with the `pre-modules` steps below.
- **`v0.3.0`**: the seam holds exactly one `factory Factory` field and the
  `NamedFactory` type does not exist at all. Run the `v0.3.0` migration
  first, which lands the repository on `modules` directly, since both
  rewrites replace the same two files.
````

- [ ] **Step 2: Add the `pre-modules` migration**

Insert after the `v0.3.0` migration's consent steps (after `:127`):

````markdown
**If the shape is `pre-modules`**, the repository has the N-collector seam
but not per-module credentials. Exactly three files are in scope, the same
three the `v0.3.0` migration touches and for the same reasons:

- `internal/probe/probe.go` and `internal/probe/probe_test.go`: rewrite
  wholesale from
  `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl`
  and `probe_test.go.tmpl`, substituting the repository's real
  `@@NAMESPACE@@` and `@@MODULE_PATH@@` (`probe_test.go.tmpl` has no
  `@@NAMESPACE@@`). Generic shipped plumbing; a user has no reason to have
  hand-edited either.
- `cmd/*/main.go`'s probe-wiring block only, **not the whole file**, matching
  `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/mains/multi/main.go.tmpl`:
  - `"sort"` joins the import block;
  - every existing `factories = append(...)` closure gains the fourth
    parameter `hc *http.Client` and, in its body, the
    `if hc != nil { ... NewClientFor(target, hc) ... }` branch;
  - every per-collector `var <name>HTTP *http.Client` build block is
    **deleted**: main builds the clients now, so those N identical clients
    collapse into one per module;
  - the module resolution block and the
    `probe.NewHandler(..., modules, defaultClient)` call replace the old
    `ParseModules`/`ValidateModules`/`NewHandler` sequence.

**Show the diff before writing any of it.** Unlike the `v0.3.0` migration,
this one renames no flag and changes no URL: every existing
`/probe?target=...` and every existing `--probe.module` answers identically
afterwards. The only observable change is that N identical HTTP clients
become one, so the exporter opens one connection pool where it opened N. Say
that plainly, then apply it only if the user accepts. If they decline, stop
and hand them the diff; do not append a collector to a seam whose shape you
were not allowed to fix.
````

- [ ] **Step 3: Collapse the two append blocks into one**

Replace the `pre-config-layer` / `has-config` split (`:133-200`) with a single
block. After migration every multi repository is on the `modules` shape, and
that shape's closure references neither `cfg` nor `err`, so the configuration
check that used to distinguish the two cases is no longer needed:

````markdown
Then materialize the collector exactly as for single-target (the five-piece
shape, the test triad, the `docs/metrics.md` entry, the proposed business
alert), and append **one** `probe.NamedFactory` block at the
`// @@PROBE_FACTORIES@@` marker in `cmd/*/main.go`:

```go
	factories = append(factories, probe.NamedFactory{
		Name: "<name>",
		New: func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
			if hc != nil {
				return collector.New<Name>Collector(ctx, log, collector.NewClientFor(target, hc)), nil
			}
			return collector.New<Name>Collector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
```

Nothing else is needed. `hc` is the client the handler resolved from the
module the request named, built once at boot in `main` and shared by every
collector, so this collector honours whatever authentication the operator
configured without building a client of its own. Earlier versions of this
command pasted a per-collector client-build block here; that is what the
current seam exists to remove.

Append, never replace: the marker stays in place for the next collector.

**Never touch modules.** `--probe.module` values and the config file's
`modules:` section both reference collector names. Adding a collector cannot
invalidate an existing module, and composing scrape profiles is an operator
decision, not yours.
````

- [ ] **Step 4: Verify by reading, then by running the golden**

There is no test harness for a prompt. Two checks:

```sh
grep -n 'hc \*http\.Client' commands/add-collector.md
```

Expected: the detection snippet, the migration bullet and the append block,
and no surviving three-parameter `New: func(ctx context.Context, target
string, timeout time.Duration)` in the multi section:

```sh
grep -n 'timeout time.Duration) (prometheus.Collector, error)' commands/add-collector.md
```

Expected: no hits inside the multi-target section (single-target's
`register(...)` shape is unrelated and untouched).

```sh
test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: PASS. The cell's second-collector snippet is the mechanical twin of
the block this task teaches; if they have drifted apart, the cell fails to
compile.

- [ ] **Step 5: Commit**

```sh
test/zero-source-grep.sh
git add commands/add-collector.md
git commit -m "feat(command): teach /add-collector the per-module credential seam

Adds the third seam shape and its migration, which rewrites the two
generic probe files and reshapes only the probe-wiring block of main.go,
diff first and consent required, exactly like the v0.3.0 migration it
mirrors. This one renames no flag and changes no URL: the single
observable effect is N identical HTTP clients collapsing into one.

The pre-config-layer and has-config append branches collapse into one
block, because the appended closure no longer references cfg at all. The
per-collector client build the command used to paste is precisely what
the new seam removes."
```

---

## Task 6: documentation shipped inside every generated exporter

**Files:**
- Modify: `skills/prometheus-exporter/assets/config.example.yml.tmpl`
- Modify: `skills/prometheus-exporter/assets/docs/configuration.md.tmpl`
  (the `## The /probe?target= endpoint (multi-target builds only)` section)
- Modify: `skills/prometheus-exporter/assets/SECURITY.md.tmpl`

**Interfaces:** none. This is operator-facing prose.

- [ ] **Step 1: Add the commented modules block to the example config**

Append to `config.example.yml.tmpl`, after the commented `http_client_config:`
block:

```yaml
# modules: named credential/TLS bundles a multi-target (/probe) exporter can
# select per request with /probe?target=...&module=... Only a multi-target
# build reads this section; single-target and multi-instance builds refuse it.
#
# A module carries an optional collectors: subset and an optional
# http_client_config:. Credentials never combine: at most one of the modules a
# request selects may carry an http_client_config:, and naming two is refused
# with a 400 rather than resolved by a precedence nobody wrote. A module that
# lists no collectors contributes only its credentials, which is what lets a
# credentials module be combined with collector modules.
#
# This section and the top-level http_client_config: above cannot both be set:
# with modules declared, nothing reads the top-level one.
#
# Commented out for the same reason as http_client_config: above, an active
# block pointing at files that do not exist on your machine would fail to load.
#
# Two conventions work, and the choice is yours to make here rather than in
# code, so it is reversible without regenerating anything.
#
# Convention 1, one module per group of targets, each a complete bundle:
#
# modules:
#   prod:
#     collectors: [example]
#     http_client_config:
#       basic_auth:
#         username: monitoring
#         password_file: /etc/@@EXPORTER_NAME@@/prod_password
#   staging:
#     collectors: [example]
#     http_client_config:
#       basic_auth:
#         username: monitoring
#         password_file: /etc/@@EXPORTER_NAME@@/staging_password
#
#   Scraped with: /probe?target=...&module=prod
#
# Convention 2, credentials and collector subsets as independent axes:
#
# modules:
#   default:
#     http_client_config:
#       basic_auth:
#         username: monitoring
#         password_file: /etc/@@EXPORTER_NAME@@/password
#   quick:
#     collectors: [example]
#
#   Scraped with: /probe?target=...&module=quick
#   (the default module supplies the credentials; naming it is optional)
```

- [ ] **Step 2: Document the endpoint's module parameter**

In `docs/configuration.md.tmpl`, under the `/probe?target=` section, add:

````markdown
### Selecting a module

`?module=` names one or more modules declared in `--config.file`'s `modules:`
section. It is repeatable and comma-separated, so `?module=a&module=b,c`
selects a, b and c.

- **Collectors combine.** The probe runs the union of the selected modules'
  `collectors:` lists, always in the exporter's own declared order. A module
  that lists none contributes none.
- **Credentials do not combine.** A request makes one connection, so it needs
  one set of credentials. They resolve in this order, first hit wins: the
  unique selected module carrying an `http_client_config:`, then a module
  named `default`, then the top-level `http_client_config:`. Selecting two
  modules that both carry credentials returns **400**.
- **A probe that resolves no credentials against a file that declares some
  returns 400.** Probing in the clear would return 200 with series nobody
  questions; the 400 makes `up` go to 0 and shows in your monitoring.
- **An unknown module returns 400**, and a request naming no module at all
  runs every collector.

A matching scrape config carries the module as a label and relabels it:

```yaml
  - job_name: '@@EXPORTER_NAME@@-probe'
    metrics_path: /probe
    file_sd_configs: [{ files: ['targets/*.yml'] }]   # each entry carries a `module` label
    relabel_configs:
      - { source_labels: [__address__],    target_label: __param_target }
      - { source_labels: [module],         target_label: __param_module }
      - { source_labels: [__param_target], target_label: instance }
      - { target_label: __address__, replacement: 'exporter-host:@@DEFAULT_PORT@@' }
```
````

- [ ] **Step 3: Note the credential lifecycle in SECURITY.md**

Add to `SECURITY.md.tmpl`:

```markdown
Credentials declared in `--config.file`, whether in the top-level
`http_client_config:` or in a `modules:` entry, are read once at startup.
There is no reload on SIGHUP, so rotating a credential means restarting the
process. A module name is a request parameter, never a metric label: it does
not reach any series this exporter exposes.
```

- [ ] **Step 4: Prove the example still loads on every cell**

```sh
test/golden-smoke.sh --all
```

Expected: 6/6 green, including the `config.example.yml loads` check that runs
in every cell. A block accidentally left uncommented fails there, which is
exactly the regression that survived nine task reviews in v0.4.0.

- [ ] **Step 5: Check no em dash slipped in**

```sh
grep -rn '—\|–' skills/prometheus-exporter/assets/ skills/prometheus-exporter/scripts/ | cat
```

Expected: no output.

- [ ] **Step 6: Commit**

```sh
test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/config.example.yml.tmpl skills/prometheus-exporter/assets/docs/configuration.md.tmpl skills/prometheus-exporter/assets/SECURITY.md.tmpl
git commit -m "docs(templates): document per-module credentials in generated exporters

The example config gains a commented modules: block showing both
conventions side by side, one module per group of targets and
credentials-as-an-independent-axis, so the exporter's author picks in
configuration rather than in code. Commented, because every golden cell
loads this file and an active block pointing at absent credential files
would fail the boot.

The configuration reference documents the resolution order and the two
400s, and SECURITY.md states that credentials are read once at startup
with no SIGHUP reload."
```

---

## Task 7: taught content and the design-time question

**Files:**
- Modify: `skills/prometheus-exporter/references/exporter-architecture.md`
- Modify: `skills/prometheus-exporter/references/project-scaffold.md`
- Modify: `skills/prometheus-exporter/references/security-and-hardening.md`
- Modify: `commands/design-exporter.md`
- Modify: `commands/new-prometheus-exporter.md`

**Interfaces:** none. This is the knowledge the plugin teaches.

- [ ] **Step 1: Add the credential dimension to the architecture decision**

In `references/exporter-architecture.md`, where the three target models are
compared, add to the `multi` entry: a multi-target exporter can authenticate
per target, by declaring `modules:` in its configuration file and having the
scrape config name one with `&module=`. Without that section it authenticates
every target the same way, which is the right answer when every target shares
one credential.

- [ ] **Step 2: Document the four-parameter seam**

In `references/project-scaffold.md`, wherever the probe seam's shape is shown,
update the factory signature to
`func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error)`
and state that `hc` is resolved per request from the selected module and built
once at boot.

- [ ] **Step 3: Add the credentials paragraph to the security reference**

`references/security-and-hardening.md` does not currently mention `/probe` at
all. Read its existing structure first and add, in the section that fits:
per-module credentials live in the configuration file, are read once at boot,
and a probe that cannot resolve credentials against a configuration that
declares some is refused rather than sent in the clear. If no section fits
without distorting the file, say so in the task's report rather than forcing
it: a misplaced paragraph in a reference is worse than a missing one.

- [ ] **Step 4: Add the design-time question**

In `commands/design-exporter.md`, as a sub-question of the target-model
decision, asked **only** when the answer is `multi`:

````markdown
If the target model is `multi`, ask one follow-up, because it decides what
the generated `config.example.yml` should demonstrate, not what code is
produced (the code is identical either way):

> How do your targets authenticate?
>
> **a.** All the same, or not at all. No `modules:` section is needed; one
> `http_client_config:` covers every target.
> **b.** By group: prod and staging, two sites, two tenants. One module per
> group, each carrying its own credentials, and the scrape config names one
> with `&module=`.
> **c.** Credentials and collector subsets vary independently. Credentials-only
> modules combined with collector modules in one request.

Record the answer under `## Architecture decisions` in the brief, as
`Credential convention: a|b|c`, so it survives on disk rather than in this
conversation.
````

- [ ] **Step 5: Repeat it after scaffolding**

In `commands/new-prometheus-exporter.md`'s `## 6. What's next`, add: when the
brief recorded a credential convention, point the user at the matching
commented block in `config.example.yml` and at the `scrape_config` in
`docs/configuration.md`.

- [ ] **Step 6: Verify**

```sh
test/zero-source-grep.sh
grep -rn '—\|–' skills/prometheus-exporter/references/ commands/ | cat
claude plugin validate .
```

Expected: gate `PASS`, no em dashes, manifest valid.

- [ ] **Step 7: Commit**

```sh
git add skills/prometheus-exporter/references/ commands/design-exporter.md commands/new-prometheus-exporter.md
git commit -m "docs(skill): teach per-module credentials and ask for the convention

The architecture reference gains the credential dimension of the multi
decision, the scaffold reference the four-parameter seam, and the security
reference the boot-time credential lifecycle.

/design-exporter asks one follow-up when the target model is multi, and
records the answer in the brief. The three answers produce identical code:
what differs is which commented block of config.example.yml the author is
pointed at, so the choice stays theirs and stays reversible."
```

---

## Task 8: changelog and the full gate

**Files:**
- Modify: `CHANGELOG.md` (the `[Unreleased]` section, which already holds
  volet B)

- [ ] **Step 1: Add the entry**

Under `[Unreleased]`, beside volet B's entry:

```markdown
### Added

- **Per-target credentials for the `multi` target model.** A `/probe` request
  selects credentials by name with `?module=`, so one multi-target exporter
  can probe targets that authenticate differently. Credentials resolve in a
  fixed order (the unique selected module carrying them, then a `default`
  module, then the top-level `http_client_config:`) and never combine:
  selecting two credential-bearing modules returns 400, and so does a probe
  that resolves no credentials against a configuration that declares some.
  The same mechanism expresses both ecosystem conventions, a module as a
  complete bundle or credentials as an independent axis, so the choice lives
  in the configuration file rather than in code.

### Changed

- **`probe.Factory` gains a fourth `hc *http.Client` parameter.** Affects
  repositories scaffolded with `--target-model multi`; `/add-collector`
  detects the older shape and migrates it, diff first. No flag is renamed and
  no URL changes. Per-collector HTTP clients collapse into one client per
  module, built once at boot.

### Deprecated

- **`--probe.module`.** Superseded by the configuration file's `modules:`
  section, which can also carry credentials. Both at once is refused at boot.
  Removal no earlier than v0.6.0.
```

- [ ] **Step 2: Run every gate, in the order CI runs them**

```sh
claude plugin validate .
test/zero-source-grep.sh
test/scaffold_test.sh
test/scaffold_edge_test.sh
test/scaffold_multitarget_test.sh
test/golden-smoke.sh --all
```

Expected: all green, golden 6/6. Show the real output of each. A run that was
not shown did not happen.

- [ ] **Step 3: Commit**

```sh
git add CHANGELOG.md
git commit -m "docs(changelog): record volet A under Unreleased"
```

- [ ] **Step 4: Hand back for review**

Report to the maintainer: the branch, the commit list, the golden result, and
anything a task could not do as written (in particular Task 7 step 3, if
`security-and-hardening.md` had no place for the paragraph). Do not merge and
do not push; both are the maintainer's call.

---

## Self-Review

**Spec coverage.** Rule 1 (Task 2 step 5, tested by
`TestCredentialsOnlyModuleDoesNotWidenSelection`); rule 2 steps 1 to 4
(`TestSelectedModuleSuppliesItsClient`,
`TestCollectorOnlyModuleFallsBackToDefaultCredentials`,
`TestFlagModulesFallBackToTopLevelClient`, `TestNoCredentialsAnywhereStillProbes`);
rule 3 (`TestTwoCredentialBearingModulesRejected`, golden step 2); rule 4 (no
merge code exists, by construction); rule 5 (`TestUnresolvedCredentialsRejected`);
rule 6 (pre-existing `TestUnknownModuleRejected`, kept); rule 7 (`TestFlagModulesFallBackToTopLevelClient`);
rule 8 (Task 3 step 2, golden step 2); rule 9 (Task 1 step 1, golden step 2).
Spec §5 is Task 2 and Task 3, §7 is Task 7, §8 is Task 5, §9 is Task 4, §10 is
Tasks 6 and 7.

**Known gap, deliberate.** Spec §9's first row, "the selected module's client
is the one used", is proven by pointer identity
(`TestSelectedModuleSuppliesItsClient`) rather than by an `Authorization`
header observed on an `httptest.Server`, as §9 describes. Pointer identity
proves the handler resolved and passed the right client; it does not prove the
credentials reach the wire, which is `prometheus/common/config`'s job and is
already its own tested code. If the implementer prefers the header assertion,
it is strictly stronger and welcome, but it needs a real collector rather than
the `stubCollector` the probe tests use, which is why the plan does not
require it. Say which one was implemented in the task report.

**Type consistency.** `Module{Collectors, Client}` in `internal/probe` and
`ResolvedModule{Collectors, ClientConfig}` in `internal/config` are
deliberately different types: the config layer holds a
`*promconfig.HTTPClientConfig` and builds nothing, main turns one into the
other. `NewHandler` takes seven parameters in Tasks 2, 3 and in every test call
site listed in Task 2 step 1.
