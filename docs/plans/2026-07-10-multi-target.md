# Multi-target `/probe` scaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `/new-prometheus-exporter` scaffold a multi-target exporter (Prometheus's `/probe?target=` fan-out pattern) via a new opt-in `--target-model multi` flag, without changing anything a single-target scaffold produces at runtime.

**Architecture:** `scaffold.sh` gains a `--target-model <single|multi>` axis (default `single`) that selects one of two `main.go` templates (`mains/single/`, `mains/multi/`), mirroring the existing `code/<flavor>/` selection. Multi requires `--flavor http`. The `/probe` handler lives in a new `internal/probe/` package (shipped only in multi), building a fresh registry + collector set per request scoped to the `target` query parameter, emitting `probe_success`/`probe_duration_seconds`. The startup security helpers are extracted to a shared, tested `security.go`. The runtime `NewClient(target, timeout)` seam is unchanged — it already takes the target as a parameter.

**Tech Stack:** Go 1.26, `prometheus/client_golang` (`promhttp`, `prometheus.Gatherers`), `prometheus/client_model/go` (dto, read-only), `alecthomas/kingpin/v2`, `exporter-toolkit/web`. POSIX `sh` for `scaffold.sh` and the test harnesses.

**Design doc:** `docs/design/2026-07-10-multi-target-design.md`.

## Global Constraints

- **`--target-model single` (and the flag's absence) is the default and reproduces today's single-target runtime behaviour.** The only single-target tree change across this whole plan is the security-helper extraction (Task 1), a pure refactor covered by a new test. `NewClient`, `collector.go.tmpl`, `status_tracker.go.tmpl`, `execute.go.tmpl` are never touched.
- **`multi` requires `--flavor http`.** `--target-model multi --flavor cli` is rejected at scaffold time with a clear error. There is no cli multi-target.
- **SSRF posture:** allow-any by default (ecosystem parity: Blackbox/SNMP/IPMI), `--probe.target-allowlist` shipped as opt-in hardening, a non-fatal startup WARN when the allowlist is empty, and a non-negotiable floor (target must parse as an `http`/`https` URL). The exporter never refuses to start over this.
- **Metric names `probe_success` / `probe_duration_seconds` are un-namespaced** — a deliberate, documented exception to `prometheus-principles.md`'s `namespace_subsystem_name` rule, matching the multi-target ecosystem.
- **`/add-collector` stays single-only** for this epic; it refuses cleanly on a multi-target scaffold. Multi-target `/add-collector` is documented follow-up.
- **Single scrape per probe:** the handler gathers the target's collectors exactly once per request (no double-fetch). `RequestDuration` never gains a `target` label.
- Run `test/zero-source-grep.sh` before every commit; never `slurm`/`sacct`/`sckyzo` in `assets/`, `commands/`, `skills/`, `agents/` (docs/, test/, root .github/ exempt).
- English for all shipped artifacts and commit messages; Conventional Commits with scope; **no AI/automation attribution** in any git artifact (no `Co-authored-by`, no `Claude-Session:` trailer). Commit with `git -c commit.gpgsign=false commit`.
- RED-before-GREEN proven for the SSRF floor/allowlist tests; no cosmetic tests; never bundle distinct logical fixes in one commit.
- Tests for `.tmpl` Go files run inside a scaffolded tree (via `scaffold.sh` → `go test` / `make check`), the same way the golden matrix already validates the scaffold — there is no way to `go test` a `.tmpl` directly.

---

### Task 1: Extract startup security helpers into a shared, tested `security.go`

Pure refactor. `isLoopbackHost` + `warnIfExposedAndUnauthenticated` move out of `main.go` into a sibling `security.go` (same `package main`), so both the single and (Task 2) multi entry points share them and they gain a unit test. No behaviour change.

**Files:**
- Create: `skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/security.go.tmpl`
- Create: `skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/security_test.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl` (remove the two functions and the now-unused `net` import)

**Interfaces:**
- Produces (same package `main`): `isLoopbackHost(host string) bool`; `warnIfExposedAndUnauthenticated(log *logger.Logger, listenAddresses []string, webConfigFile string)`. Task 2's multi `main.go` calls `warnIfExposedAndUnauthenticated`.

- [ ] **Step 1: Write the failing test** — `security_test.go.tmpl`:

```go
package main

import "testing"

func TestIsLoopbackHost(t *testing.T) {
	cases := []struct {
		host string
		want bool
	}{
		{"", false},          // bare ":9999" binds every interface — NOT loopback
		{"localhost", true},
		{"127.0.0.1", true},
		{"127.0.0.5", true},  // whole 127.0.0.0/8
		{"::1", true},
		{"0.0.0.0", false},
		{"192.168.1.10", false},
		{"example.com", false}, // unresolvable/remote name: never assume safe
	}
	for _, c := range cases {
		if got := isLoopbackHost(c.host); got != c.want {
			t.Errorf("isLoopbackHost(%q) = %v, want %v", c.host, got, c.want)
		}
	}
}
```

- [ ] **Step 2: Run it to verify it fails** — scaffold a tree and run the test:

```bash
cd skills/prometheus-exporter/assets
TMP=$(mktemp -d)
sh scaffold.sh --src . --dst "$TMP" --flavor http --forge none \
  --var EXPORTER_NAME=demo --var NAMESPACE=demo --var MODULE_PATH=example.com/demo \
  --var DEFAULT_PORT=9999 --var LICENSE=apache-2.0 --var OWNER=demo
cd "$TMP" && go test ./cmd/... 2>&1 | head
```
Expected before Step 3: compile failure — `security_test.go` references `isLoopbackHost` which is still only in `main.go` (it compiles, so this test actually PASSES here since both are package `main`). To make the RED real, Step 1's value is guarding the *extraction*: after Step 3 the function lives only in `security.go`; if the extraction drops or renames it, this test fails to compile. Proceed — the extraction is the change under test.

- [ ] **Step 3: Create `security.go.tmpl`** with the two functions moved verbatim from `main.go.tmpl`:

```go
package main

import (
	"net"

	"@@MODULE_PATH@@/internal/logger"
)

// isLoopbackHost reports whether host — the address part of a
// --web.listen-address value, port already stripped — only reaches this
// machine. An empty host (from a bare ":9999") binds every interface, so it
// is deliberately NOT loopback despite also covering localhost traffic.
func isLoopbackHost(host string) bool {
	if host == "" {
		return false
	}
	if host == "localhost" {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback() // covers 127.0.0.0/8 and ::1
	}
	return false // unresolvable/unknown host: don't assume it's safe
}

// warnIfExposedAndUnauthenticated implements security-and-hardening.md's
// Rule 3: log one visible, non-fatal warning at startup if any listenAddress
// is reachable from outside this host AND no --web.config.file is set to
// enable TLS/Basic Auth. It never blocks startup or alters a default
// (Rule 2) — it only makes an already-exposed posture visible.
func warnIfExposedAndUnauthenticated(log *logger.Logger, listenAddresses []string, webConfigFile string) {
	if webConfigFile != "" {
		return // TLS/Basic Auth already configured
	}
	for _, addr := range listenAddresses {
		host, _, err := net.SplitHostPort(addr)
		if err != nil {
			host = addr // no "host:port" shape found; treat the whole value as host
		}
		if !isLoopbackHost(host) {
			log.Warn("/metrics is served unauthenticated on a reachable address; "+
				"set --web.config.file to enable TLS/Basic Auth if this exporter is reachable from an untrusted network",
				"listen_address", addr)
			return // one warning is enough even if more than one address is exposed
		}
	}
}
```

- [ ] **Step 4: Remove the two functions from `main.go.tmpl`** — delete lines currently holding `isLoopbackHost` and `warnIfExposedAndUnauthenticated` (main.go.tmpl:244-282), and remove `"net"` from the import block (it is now used only by `security.go`). Leave the *call* to `warnIfExposedAndUnauthenticated` in `main()` intact.

- [ ] **Step 5: Run tests + build to verify GREEN** — re-scaffold as in Step 2, then:

```bash
cd "$TMP" && go build ./... && go test ./cmd/... && go vet ./...
```
Expected: build OK, tests PASS, vet clean (no unused `net` import).

- [ ] **Step 6: Run the plugin's own scaffold gates**

```bash
cd skills/prometheus-exporter/assets/../../..   # repo root
sh test/scaffold_test.sh && sh test/scaffold_edge_test.sh && sh test/zero-source-grep.sh
```
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add skills/prometheus-exporter/assets/cmd
git -c commit.gpgsign=false commit -m "refactor(scaffold): extract startup security helpers into security.go"
```

---

### Task 2: Multi-target runtime — `scaffold.sh` model selection + `internal/probe` + multi `main.go`

The whole vertical: a `--target-model multi` scaffold produces a building, checking exporter serving `/probe` + `/metrics` + `/healthz`, with the SSRF floor/allowlist enforced and unit-tested.

**Files:**
- Create: `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl`
- Create: `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl`
- Create: `skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag`
- Create: `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl`
- Move: `skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl` → `skills/prometheus-exporter/assets/mains/single/main.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/scaffold.sh`
- Modify: `skills/prometheus-exporter/assets/go.mod.tmpl` (client_model: indirect → direct require)
- Modify: `test/scaffold_test.sh` (or add `test/scaffold_multitarget_test.sh`)
- Modify: `test/golden-smoke.sh` (new `http × multi` cell)

**Interfaces:**
- Consumes: `collector.NewStatusTracker(log)` + `tracker.Add(name, c)` (unchanged); `collector.NewExampleCollector(log, *collector.Client)`; `collector.NewClient(target string, timeout time.Duration) *collector.Client`; the StatusTracker success family name `@@NAMESPACE@@_exporter_collector_success`; `security.go`'s `warnIfExposedAndUnauthenticated` (Task 1).
- Produces: `probe.NewHandler(log *logger.Logger, factory probe.Factory, allowlist []string, maxTimeout time.Duration) *probe.Handler` where `type Factory func(target string, timeout time.Duration) prometheus.Collector`. The multi `main.go`'s `// @@PROBE_FACTORIES@@` marker defines a local `factory` variable. `scaffold.sh --target-model <single|multi>`.

- [ ] **Step 1: Write `internal/probe/probe.go.tmpl`**

```go
// Package probe implements the multi-target /probe?target=… endpoint: per
// request it validates the target, builds a fresh registry + collector set
// scoped to that one target, and emits probe_success / probe_duration_seconds
// alongside the scoped collectors' own series. This is Prometheus's
// multi-target exporter pattern (Blackbox/SNMP style): the exporter is a
// fan-out proxy, not a sidecar reporting on one fixed target.
package probe

import (
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	dto "github.com/prometheus/client_model/go"

	"@@MODULE_PATH@@/internal/collector"
	"@@MODULE_PATH@@/internal/logger"
)

// collectorSuccessMetric is the per-collector health gauge StatusTracker emits
// (see internal/collector/status_tracker.go). probe_success is derived from it
// so the probe reports "did every scoped collector scrape cleanly?" without a
// second scrape of the target.
const collectorSuccessMetric = "@@NAMESPACE@@_exporter_collector_success"

// Factory builds the collector set scoped to one probe target. The multi
// main.go fills a factory at its // @@PROBE_FACTORIES@@ marker; adding a
// collector to a multi-target exporter means adding a line there (see the
// scaffold's docs).
type Factory func(target string, timeout time.Duration) prometheus.Collector

// Handler serves /probe?target=… .
type Handler struct {
	log        *logger.Logger
	factory    Factory
	allowlist  []string      // empty => allow-any (ecosystem default; see SECURITY.md)
	maxTimeout time.Duration // upper bound on each probe's per-request timeout
}

// NewHandler builds a /probe handler. An empty allowlist accepts any target
// that clears the http/https floor (the Blackbox/SNMP default).
func NewHandler(log *logger.Logger, factory Factory, allowlist []string, maxTimeout time.Duration) *Handler {
	return &Handler{log: log, factory: factory, allowlist: allowlist, maxTimeout: maxTimeout}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	target := r.URL.Query().Get("target")

	// Non-negotiable floor: must parse as an http/https URL. Always on, even
	// in allow-any mode — bounds the SSRF surface to HTTP.
	if err := validateTargetFloor(target); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if !h.targetAllowed(target) {
		http.Error(w, "target not allowed", http.StatusForbidden)
		return
	}

	timeout := h.clampTimeout(r)

	// Fresh registry + collectors, scoped to THIS target, for THIS request.
	reg := prometheus.NewRegistry()
	tracker := collector.NewStatusTracker(h.log)
	tracker.Add("example", h.factory(target, timeout))
	reg.MustRegister(tracker)

	// probe_success / probe_duration_seconds live in a separate registry so we
	// can set them from the single collector gather below and still serve
	// everything in one response without re-scraping the target.
	meta := prometheus.NewRegistry()
	probeSuccess := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "probe_success",
		Help: "Displays whether the probe of the target succeeded (1) or failed (0).",
	})
	probeDuration := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "probe_duration_seconds",
		Help: "Returns how long the probe took to complete in seconds.",
	})
	meta.MustRegister(probeSuccess, probeDuration)

	start := time.Now()
	mfs, err := reg.Gather() // the ONE scrape of the target's collectors
	probeDuration.Set(time.Since(start).Seconds())
	switch {
	case err != nil:
		h.log.Warn("probe gather reported an error", "target", target, "err", err)
	case collectorsHealthy(mfs):
		probeSuccess.Set(1)
	}

	// Serve the already-gathered collector families plus the meta gauges,
	// without re-gathering reg (gatheredFamilies just replays mfs).
	promhttp.HandlerFor(
		prometheus.Gatherers{gatheredFamilies(mfs), meta},
		promhttp.HandlerOpts{EnableOpenMetrics: true, ErrorHandling: promhttp.ContinueOnError},
	).ServeHTTP(w, r)
}

// gatheredFamilies replays an already-collected metric-family slice as a
// prometheus.Gatherer, so the target's collectors are scraped exactly once per
// probe (during reg.Gather above), never again by promhttp.
type gatheredFamilies []*dto.MetricFamily

func (g gatheredFamilies) Gather() ([]*dto.MetricFamily, error) { return g, nil }

// validateTargetFloor enforces the always-on http/https floor. A bare
// "host:9100" parses with Scheme=="host", and "file:///…" with Scheme=="file";
// both are rejected here.
func validateTargetFloor(target string) error {
	if target == "" {
		return fmt.Errorf("missing 'target' query parameter")
	}
	u, err := url.Parse(target)
	if err != nil {
		return fmt.Errorf("target is not a valid URL: %v", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("target scheme %q not allowed (only http/https)", u.Scheme)
	}
	if u.Hostname() == "" {
		return fmt.Errorf("target has no host")
	}
	return nil
}

// targetAllowed applies the allowlist. Empty allowlist => allow-any (the
// ecosystem default). A non-empty allowlist matches a target's host either
// port-insensitively (entry == host) or exactly (entry == host:port).
func (h *Handler) targetAllowed(target string) bool {
	if len(h.allowlist) == 0 {
		return true
	}
	u, err := url.Parse(target)
	if err != nil {
		return false
	}
	for _, a := range h.allowlist {
		if a == u.Hostname() || a == u.Host {
			return true
		}
	}
	return false
}

// clampTimeout uses min(--collector.example.timeout, Prometheus's own scrape
// timeout header), so a probe never outruns Prometheus's deadline or the
// operator's configured ceiling.
func (h *Handler) clampTimeout(r *http.Request) time.Duration {
	t := h.maxTimeout
	if v := r.Header.Get("X-Prometheus-Scrape-Timeout-Seconds"); v != "" {
		if secs, err := strconv.ParseFloat(v, 64); err == nil && secs > 0 {
			if d := time.Duration(secs * float64(time.Second)); d < t {
				t = d
			}
		}
	}
	return t
}

// collectorsHealthy reports whether every collector scoped to this probe
// reported success (collector_success == 1). Returns false if no success
// metric was emitted at all (a probe that produced nothing is not a success).
func collectorsHealthy(mfs []*dto.MetricFamily) bool {
	found := false
	for _, mf := range mfs {
		if mf.GetName() != collectorSuccessMetric {
			continue
		}
		for _, m := range mf.GetMetric() {
			found = true
			if g := m.GetGauge(); g == nil || g.GetValue() != 1 {
				return false
			}
		}
	}
	return found
}
```

- [ ] **Step 2: Write `internal/probe/probe_test.go.tmpl`** (the SSRF floor/allowlist is the security control — RED first):

```go
package probe

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"@@MODULE_PATH@@/internal/logger"
)

// recordingFactory records how it was called and returns a stub collector.
type recordingFactory struct {
	calls   int
	target  string
	timeout time.Duration
	panics  bool // when true, the returned collector panics on Collect
}

func (f *recordingFactory) make(target string, timeout time.Duration) prometheus.Collector {
	f.calls++
	f.target = target
	f.timeout = timeout
	if f.panics {
		return panicCollector{}
	}
	return &stubCollector{desc: prometheus.NewDesc("stub_up", "stub", nil, nil)}
}

type stubCollector struct{ desc *prometheus.Desc }

func (s *stubCollector) Describe(ch chan<- *prometheus.Desc) { ch <- s.desc }
func (s *stubCollector) Collect(ch chan<- prometheus.Metric) {
	ch <- prometheus.MustNewConstMetric(s.desc, prometheus.GaugeValue, 1)
}

type panicCollector struct{}

func (panicCollector) Describe(chan<- *prometheus.Desc) {}
func (panicCollector) Collect(chan<- prometheus.Metric) { panic("collector boom") }

func serve(h *Handler, rawurl string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, rawurl, nil)
	h.ServeHTTP(rec, req)
	return rec
}

func newTestHandler(f *recordingFactory, allowlist []string) *Handler {
	return NewHandler(logger.NewTextLogger("error"), f.make, allowlist, 5*time.Second)
}

func TestFloorRejectsNonHTTPScheme(t *testing.T) {
	f := &recordingFactory{}
	rec := serve(newTestHandler(f, nil), "/probe?target=file:///etc/passwd")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("file:// target: got %d, want 400", rec.Code)
	}
	if f.calls != 0 {
		t.Fatalf("factory invoked %d times for a rejected target, want 0", f.calls)
	}
}

func TestFloorRejectsBareHost(t *testing.T) {
	f := &recordingFactory{}
	rec := serve(newTestHandler(f, nil), "/probe?target=localhost:9100")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("bare host target: got %d, want 400", rec.Code)
	}
	if f.calls != 0 {
		t.Fatalf("factory invoked for a scheme-less target, want 0")
	}
}

func TestMissingTargetRejected(t *testing.T) {
	f := &recordingFactory{}
	rec := serve(newTestHandler(f, nil), "/probe")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("missing target: got %d, want 400", rec.Code)
	}
	if f.calls != 0 {
		t.Fatalf("factory invoked with no target, want 0")
	}
}

func TestAllowlistDeniesUnlistedTarget(t *testing.T) {
	f := &recordingFactory{}
	rec := serve(newTestHandler(f, []string{"node1"}), "/probe?target=http://node2:9100")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("unlisted target: got %d, want 403", rec.Code)
	}
	if f.calls != 0 {
		t.Fatalf("factory invoked for a denied target, want 0")
	}
}

func TestAllowlistAllowsListedTarget(t *testing.T) {
	f := &recordingFactory{}
	rec := serve(newTestHandler(f, []string{"node1"}), "/probe?target=http://node1:9100")
	if rec.Code != http.StatusOK {
		t.Fatalf("listed target: got %d, want 200", rec.Code)
	}
	if f.calls != 1 || f.target != "http://node1:9100" {
		t.Fatalf("factory calls=%d target=%q, want 1 / http://node1:9100", f.calls, f.target)
	}
}

func TestEmptyAllowlistAllowsAnyHTTPTarget(t *testing.T) {
	f := &recordingFactory{}
	rec := serve(newTestHandler(f, nil), "/probe?target=http://anything.internal:9100")
	if rec.Code != http.StatusOK {
		t.Fatalf("allow-any: got %d, want 200", rec.Code)
	}
	if f.calls != 1 {
		t.Fatalf("factory calls=%d, want 1", f.calls)
	}
}

func TestProbeSuccessTrueWhenCollectorHealthy(t *testing.T) {
	f := &recordingFactory{}
	rec := serve(newTestHandler(f, nil), "/probe?target=http://ok:9100")
	if !strings.Contains(rec.Body.String(), "probe_success 1") {
		t.Fatalf("expected probe_success 1, body:\n%s", rec.Body.String())
	}
}

func TestProbeSuccessFalseWhenCollectorPanics(t *testing.T) {
	f := &recordingFactory{panics: true}
	rec := serve(newTestHandler(f, nil), "/probe?target=http://bad:9100")
	if !strings.Contains(rec.Body.String(), "probe_success 0") {
		t.Fatalf("expected probe_success 0, body:\n%s", rec.Body.String())
	}
}

func TestClampTimeoutHonoursHeaderAndCeiling(t *testing.T) {
	h := NewHandler(logger.NewTextLogger("error"), (&recordingFactory{}).make, nil, 5*time.Second)

	req := httptest.NewRequest(http.MethodGet, "/probe?target=http://x:9100", nil)
	req.Header.Set("X-Prometheus-Scrape-Timeout-Seconds", "30")
	if got := h.clampTimeout(req); got != 5*time.Second {
		t.Errorf("header above ceiling: got %v, want 5s", got)
	}

	req.Header.Set("X-Prometheus-Scrape-Timeout-Seconds", "2")
	if got := h.clampTimeout(req); got != 2*time.Second {
		t.Errorf("header below ceiling: got %v, want 2s", got)
	}

	req.Header.Del("X-Prometheus-Scrape-Timeout-Seconds")
	if got := h.clampTimeout(req); got != 5*time.Second {
		t.Errorf("no header: got %v, want 5s", got)
	}
}
```

- [ ] **Step 3: Write `code/http/wiring/probe_factory.frag`** (multi-only; injected at `// @@PROBE_FACTORIES@@`, references `log` assigned above the marker):

```go
	factory := func(target string, timeout time.Duration) prometheus.Collector {
		return collector.NewExampleCollector(log, collector.NewClient(target, timeout))
	}
```

- [ ] **Step 4: Create the `mains/` split.** Move today's single entry point and write the multi one.

```bash
cd skills/prometheus-exporter/assets
mkdir -p mains/single mains/multi
git mv cmd/@@EXPORTER_NAME@@/main.go.tmpl mains/single/main.go.tmpl
```

Write `mains/multi/main.go.tmpl`:

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
	"github.com/prometheus/common/version"
	"github.com/prometheus/exporter-toolkit/web"
	webflag "github.com/prometheus/exporter-toolkit/web/kingpinflag"

	"@@MODULE_PATH@@/internal/collector"
	"@@MODULE_PATH@@/internal/logger"
	"@@MODULE_PATH@@/internal/probe"
)

// namespace is this exporter's Prometheus metric prefix (used by the landing
// page and startup log). See internal/collector for how @@NAMESPACE@@ is
// substituted into each collector's own metric names.
const namespace = "@@NAMESPACE@@"

var (
	logLevel     = kingpin.Flag("log.level", "Only log messages with the given severity or above. One of: [debug, info, warn, error]").Default("info").Enum("debug", "info", "warn", "error")
	logFormat    = kingpin.Flag("log.format", "Log format. One of: [json, text]").Default("text").Enum("json", "text")
	toolkitFlags = webflag.AddFlags(kingpin.CommandLine, ":@@DEFAULT_PORT@@")

	// disableExporterMetrics removes Go runtime and process metrics from /metrics.
	disableExporterMetrics = kingpin.Flag(
		"web.disable-exporter-metrics",
		"Exclude Go runtime and process metrics from the /metrics endpoint.",
	).Default("false").Bool()

	// probeTargetAllowlist restricts which targets /probe will scrape. Empty
	// (the default) accepts any http/https target — the Blackbox/SNMP
	// ecosystem default. See SECURITY.md and the startup warning.
	probeTargetAllowlist = kingpin.Flag(
		"probe.target-allowlist",
		"Restrict /probe to these target hosts (repeatable; host or host:port). Empty (default) accepts any http/https target.",
	).Strings()
)

// indexHTML is the landing page served at /.
var indexHTML = fmt.Sprintf(`<html>
	<head><title>%s Exporter</title></head>
	<body>
		<h1>%s Exporter (multi-target)</h1>
		<p>Probe a target: <a href='/probe?target=http://localhost:9100'>/probe?target=http://localhost:9100</a></p>
		<p>Exporter self-metrics: <a href='/metrics'>/metrics</a></p>
	</body>
</html>`, namespace, namespace)

func main() {
	var log *logger.Logger

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	// Upper bound for each /probe request's timeout. Named to match the
	// single-target flavor's collector.example.timeout so the knob is
	// consistent across models; the probe handler clamps it further by
	// Prometheus's own X-Prometheus-Scrape-Timeout-Seconds header.
	exampleTimeout := kingpin.Flag(
		"collector.example.timeout",
		"Upper bound for each /probe request's timeout.",
	).Default("5s").Duration()

	kingpin.Version(version.Print("@@EXPORTER_NAME@@"))
	kingpin.HelpFlag.Short('h')
	kingpin.Parse()

	if *logFormat == "json" {
		log = logger.NewJSONLogger(*logLevel)
	} else {
		log = logger.NewTextLogger(*logLevel)
	}

	warnIfExposedAndUnauthenticated(log, *toolkitFlags.WebListenAddresses, *toolkitFlags.WebConfigFile)
	warnIfProbeUnrestricted(log, *probeTargetAllowlist)

	// @@PROBE_FACTORIES@@

	probeHandler := probe.NewHandler(log, factory, *probeTargetAllowlist, *exampleTimeout)

	// /metrics reports on the EXPORTER ITSELF (build info, Go runtime/process,
	// aggregate request timing), scraped independently of any probed target —
	// exactly like the Blackbox exporter. The per-target series come from
	// /probe, on a fresh registry per request.
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewBuildInfoCollector())
	if !*disableExporterMetrics {
		reg.MustRegister(
			collectors.NewGoCollector(),
			collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		)
	}
	reg.MustRegister(collector.RequestDuration)

	log.Info("Starting multi-target exporter server...", "namespace", namespace)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(indexHTML))
	})
	http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{
		EnableOpenMetrics: true,
		ErrorHandling:     promhttp.ContinueOnError,
	}))
	http.Handle("/probe", probeHandler)
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
}

// warnIfProbeUnrestricted logs one visible, non-fatal warning when /probe has
// no allowlist: it then accepts any http/https target, so anyone who can reach
// this exporter can make it issue requests to arbitrary hosts. Never blocks
// startup (same posture as warnIfExposedAndUnauthenticated).
func warnIfProbeUnrestricted(log *logger.Logger, allowlist []string) {
	if len(allowlist) == 0 {
		log.Warn("/probe accepts any target: anyone who can reach this exporter can make it " +
			"issue HTTP requests to arbitrary hosts; set --probe.target-allowlist to restrict, and see SECURITY.md")
	}
}
```

- [ ] **Step 5: Teach `scaffold.sh` the `--target-model` axis.** Four edits:

**(5a) Usage + arg parse.** In the usage string add `[--target-model <single|multi>]`. Beside the `--flavor` case add:
```sh
    --target-model)
      [ $# -ge 2 ] || die "--target-model requires a value"
      target_model=$2
      shift 2
      ;;
```
Initialize `target_model="single"` near the other defaults (`flavor=""`). After parsing, validate:
```sh
case "$target_model" in
  single|multi) ;;
  *) die "invalid --target-model '$target_model'; must be single or multi" ;;
esac
if [ "$target_model" = multi ] && [ "$flavor" != http ]; then
  die "--target-model multi requires --flavor http (no cli multi-target)"
fi
```

**(5b) Main-model selection** — immediately after the flavor-selection block (after `rm -rf "$dst/code"`, before the substitution passes), insert:
```sh
# Main entry-point model selection (single|multi), mirroring flavor selection
# above: place the chosen main.go into the one cmd/<name>/ dir (which already
# ships security.go), then drop the whole mains/ staging tree.
if [ -d "$dst/mains" ]; then
  [ -f "$dst/mains/$target_model/main.go.tmpl" ] || die "no main.go template for --target-model '$target_model'"
  cmddir=""
  for d in "$dst"/cmd/*/; do
    [ -d "$d" ] || continue
    [ -z "$cmddir" ] || die "expected exactly one cmd/*/ dir, found more than one"
    cmddir=$d
  done
  [ -n "$cmddir" ] || die "no cmd/*/ directory to place the selected main.go into"
  mv "$dst/mains/$target_model/main.go.tmpl" "${cmddir}main.go.tmpl"
fi
rm -rf "$dst/mains"

# internal/probe/ is multi-only: a single-target scaffold never ships it.
if [ "$target_model" != multi ]; then
  rm -rf "$dst/internal/probe"
fi
```

**(5c) Conditional wiring injection.** Replace the two `if [ -f …client_init.frag ]` / `…registry.frag` blocks (main.go.tmpl:363-372 region) with a marker-conditional loop that also handles `probe_factory.frag`. A frag whose marker is absent from the selected main is skipped (each main model carries only its own markers), instead of the old die-if-absent:
```sh
  for pair in \
    "client_init.frag:@@CLIENT_INIT@@" \
    "registry.frag:@@COLLECTOR_REGISTRY@@" \
    "probe_factory.frag:@@PROBE_FACTORIES@@"; do
    fragfile="$dst/internal/collector/wiring/${pair%%:*}"
    marker="${pair##*:}"
    [ -f "$fragfile" ] || continue
    grep -q "^[[:blank:]]*// $marker[[:blank:]]*\$" "$mainfile" || continue
    sed -e "\\|^[[:blank:]]*// $marker[[:blank:]]*\$|r $fragfile" "$mainfile" > "$mainfile.scaffoldtmp"
    mv "$mainfile.scaffoldtmp" "$mainfile"
  done
```
(Keep the surrounding `if [ -d wiring ]` guard, the single-`mainfile` discovery, and the final `rm -rf wiring` unchanged.)

**(5d) Residual-sentinel exemption.** Add `PROBE_FACTORIES` to the marker exemption (main.go.tmpl:434):
```sh
grep -v -E '@@(CLIENT_INIT|COLLECTOR_REGISTRY|PROBE_FACTORIES)@@' "$sentinels" > "$pathlist" || filtered_rc=$?
```

- [ ] **Step 6: Promote `client_model` to a direct dependency** in `go.mod.tmpl` — `internal/probe` imports `github.com/prometheus/client_model/go` directly. Move its line out of the `// indirect` block into the top `require (…)` block (drop the `// indirect` comment). `go.sum` already carries `v0.6.2`'s hashes — no `go.sum` change:
```
require (
	github.com/alecthomas/kingpin/v2 v2.4.0
	github.com/prometheus/client_golang v1.23.2
	github.com/prometheus/client_model v0.6.2
	github.com/prometheus/common v0.68.1
	github.com/prometheus/exporter-toolkit v0.16.0
)
```

- [ ] **Step 7: Verify RED then GREEN — scaffold multi and run the probe tests.**

```bash
cd skills/prometheus-exporter/assets
TMP=$(mktemp -d)
sh scaffold.sh --src . --dst "$TMP" --flavor http --forge none --target-model multi \
  --var EXPORTER_NAME=demo --var NAMESPACE=demo --var MODULE_PATH=example.com/demo \
  --var DEFAULT_PORT=9999 --var LICENSE=apache-2.0 --var OWNER=demo
cd "$TMP" && go build ./... && go test ./internal/probe/... -v && go vet ./...
```
Expected GREEN: build OK; all `Test*` PASS; vet clean. RED proof (run once, then revert): comment out the `validateTargetFloor` call in `probe.go.tmpl` → `TestFloorRejectsNonHTTPScheme`/`TestFloorRejectsBareHost` fail with `factory invoked … want 0`.

- [ ] **Step 8: Verify single is still correct + `go mod tidy` is a no-op.**

```bash
cd skills/prometheus-exporter/assets
TMP2=$(mktemp -d)
sh scaffold.sh --src . --dst "$TMP2" --flavor http --forge none \
  --var EXPORTER_NAME=demo --var NAMESPACE=demo --var MODULE_PATH=example.com/demo \
  --var DEFAULT_PORT=9999 --var LICENSE=apache-2.0 --var OWNER=demo
test ! -d "$TMP2/internal/probe" || { echo "FAIL: single shipped internal/probe"; exit 1; }
grep -q '/probe' "$TMP2"/cmd/*/main.go && { echo "FAIL: single main has /probe"; exit 1; }
cd "$TMP2" && go build ./... && go test ./... && go mod tidy && git diff --quiet go.mod go.sum 2>/dev/null; echo "tidy clean: $?"
```
Expected: single has no `internal/probe`, no `/probe`; builds; tests pass. (The `git diff` line is illustrative — `$TMP2` isn't a repo; the real guard is that `go mod tidy` prints nothing and leaves go.mod unchanged.)

- [ ] **Step 9: Add scaffold-level assertions** to `test/scaffold_test.sh` (or a new `test/scaffold_multitarget_test.sh` wired into CI the same way): scaffold `--target-model multi` and assert the tree ships `internal/probe/probe.go`, `cmd/*/main.go` contains `/probe` and `probe.NewHandler`; scaffold default/`single` and assert no `internal/probe` and no `/probe`; assert `--target-model multi --flavor cli` exits non-zero with the cli-rejection message. Follow the existing harness's assert helpers.

- [ ] **Step 10: Add a `http × multi` cell to `test/golden-smoke.sh`.** Mirror the existing `http` cell but pass `--target-model multi`; after `make build`/`make check`, start the binary, `curl -fsS 'http://127.0.0.1:<port>/probe?target=http://127.0.0.1:<port>/metrics'` (probe the exporter's own /metrics as a live HTTP target), and pipe the output through `promtool check metrics`, asserting `probe_success` and `probe_duration_seconds` are present. Read the existing cell first and match its structure, port handling, and teardown.

- [ ] **Step 11: Run the full plugin gate + commit.**

```bash
cd <repo root>
sh test/zero-source-grep.sh && sh test/scaffold_test.sh && sh test/scaffold_edge_test.sh
# optional locally (slow, Docker): sh test/golden-smoke.sh --all
git add skills/prometheus-exporter/assets test/scaffold_test.sh test/golden-smoke.sh
git -c commit.gpgsign=false commit -m "feat(scaffold): multi-target /probe runtime via --target-model multi"
```

---

### Task 3: Docs, knowledge references, command wiring, ROADMAP, CHANGELOG

Flip every "multi-target = documented follow-up / not implemented" claim to "opt-in via `--target-model multi` (http only)", document the `/probe` endpoint + SSRF posture + the naming exception in the shipped docs, wire the flag into `/new-prometheus-exporter`, make `/add-collector` refuse cleanly on multi scaffolds, and record the change.

**Files (shipped docs — assets):**
- Modify: `assets/docs/configuration.md.tmpl`, `assets/SECURITY.md.tmpl`, `assets/README.md.tmpl`, `assets/code/http/metrics.md.tmpl`

**Files (plugin knowledge — never shipped):**
- Modify: `skills/prometheus-exporter/references/exporter-architecture.md`, `references/project-scaffold.md`, `references/prometheus-principles.md`, `references/discovery-inputs.md`, `SKILL.md`
- Modify: `commands/new-prometheus-exporter.md`, `commands/add-collector.md`
- Modify: `ROADMAP.md`, `CHANGELOG.md`

- [ ] **Step 1: Shipped docs — the `/probe` endpoint, SSRF posture, metric names.**
  - `SECURITY.md.tmpl`: a "Multi-target `/probe` (if applicable)" section — `/probe` is an SSRF primitive; default is allow-any (ecosystem parity); harden with `--probe.target-allowlist`; always isolate the exporter's network; the http/https floor is always on.
  - `configuration.md.tmpl`: document `--probe.target-allowlist` and the `/probe?target=` endpoint (note it exists only in multi-target builds).
  - `README.md.tmpl`: a `/probe` usage example + a Prometheus `scrape_configs` snippet with `metrics_path: /probe`, `params`, and the `__param_target`→`instance` relabeling (from the design doc's context7-verified example).
  - `code/http/metrics.md.tmpl`: document `probe_success` and `probe_duration_seconds` so `make docs-check` stays truthful for multi builds.
  - These are conditional-content docs shipped to every http scaffold; phrase the `/probe` parts so they read correctly whether or not multi was chosen (e.g. "Multi-target builds also expose …"). Confirm no `slurm`/`sacct`/`sckyzo` leaks.

- [ ] **Step 2: Knowledge references.**
  - `exporter-architecture.md` §2: change "**This scaffold produces single-target exporters only.**" and the "documented follow-up work" paragraph to: multi-target is now scaffolded opt-in via `--target-model multi` (http flavor only); keep the structural-fork explanation. Add the `probe_success` naming exception cross-reference.
  - `project-scaffold.md` "What this scaffold does not do": replace the "There is no `/probe?target=` handler here" paragraph with the two-model description (single default; multi via the flag ships `internal/probe` + a `/probe` handler).
  - `prometheus-principles.md`: add the deliberate `probe_success`/`probe_duration_seconds` un-namespaced exception, with the ecosystem rationale.
  - `discovery-inputs.md:170`: the brief's Target-model line — drop "(documented follow-up)" from the `multi-target` option.
  - `SKILL.md:44-47`: "only single-target is implemented today, so a multi-target design becomes documented follow-up work" → multi-target is now scaffolded opt-in (http only) via `--target-model multi`.

- [ ] **Step 3: Command wiring.**
  - `new-prometheus-exporter.md`: in the variable-collection / scaffold-invocation procedure, offer `--target-model` (default single); when the architecture brief's Target-model is multi, require http and pass `--target-model multi` to `scaffold.sh`; reject multi+cli with a clear message.
  - `add-collector.md`: detect a multi-target scaffold (e.g. presence of `internal/probe/` or a `/probe` handler in `cmd/*/main.go`) and refuse cleanly, pointing at the manual procedure (add one factory line at `// @@PROBE_FACTORIES@@`); state that multi-target `/add-collector` is a documented follow-up.

- [ ] **Step 4: ROADMAP + CHANGELOG.**
  - `ROADMAP.md:52`: change "Advanced multi-target support." to note basic multi-target (`/probe`, opt-in) shipped in v0.2.x, with the remaining follow-ups being `/add-collector` multi-awareness and a `module` parameter.
  - `CHANGELOG.md` `## [Unreleased]` → `### Added`:
    ```
    - **Multi-target scaffolding** (`--target-model multi`, http flavor only):
      `/new-prometheus-exporter` can now scaffold a Prometheus multi-target
      (`/probe?target=…`) exporter — a fresh registry and collector set per
      request scoped to the target, `probe_success`/`probe_duration_seconds`,
      a `--probe.target-allowlist` hardening flag with a startup warning when
      empty, and an always-on http/https target floor. Single-target remains
      the default and is unchanged.
    ```

- [ ] **Step 5: Verify docs-check + gates, then commit.**

```bash
cd skills/prometheus-exporter/assets
TMP=$(mktemp -d)
sh scaffold.sh --src . --dst "$TMP" --flavor http --forge none --target-model multi \
  --var EXPORTER_NAME=demo --var NAMESPACE=demo --var MODULE_PATH=example.com/demo \
  --var DEFAULT_PORT=9999 --var LICENSE=apache-2.0 --var OWNER=demo
cd "$TMP" && make docs-check   # probe_success/probe_duration_seconds documented ⇔ emitted
cd <repo root>
sh test/zero-source-grep.sh
git add -A
git -c commit.gpgsign=false commit -m "docs(scaffold): document multi-target /probe, SSRF posture, and naming exception"
```
Expected: `make docs-check` PASS; zero-source-grep clean.

---

## Self-Review

- **Spec coverage:** §3.1 two models → Task 2 Step 4; §3.2 handler → Task 2 Steps 1-2; §3.3 metric split → multi main.go (Step 4) + probe.go; §3.4 SSRF → probe.go + `warnIfProbeUnrestricted` + Step 5a validation; §3.5 timeout → `clampTimeout`; §3.6 factory frag + `/add-collector` refusal → Steps 3, 5c + Task 3 Step 3; §3.7 naming → probe.go gauges + Task 3 Steps 1-2; §4 all files mapped across Tasks 1-3; §5 tests → Task 1 Step 1, Task 2 Steps 2/9/10; §6 non-regression → Task 2 Step 8.
- **Placeholder scan:** none. All code shown in full; docs steps carry exact CHANGELOG text and precise per-file instructions.
- **Type consistency:** `Factory func(target string, timeout time.Duration) prometheus.Collector` used identically in probe.go, probe_factory.frag, and probe_test.go; `NewHandler(log, factory, allowlist, maxTimeout)` matches the multi main.go call; `collectorSuccessMetric` == the StatusTracker name `@@NAMESPACE@@_exporter_collector_success` verified against `status_tracker.go.tmpl`.
