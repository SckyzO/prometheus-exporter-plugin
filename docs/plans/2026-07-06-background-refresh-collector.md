# Background-Refresh Collector Variant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `/add-collector` scaffold a collector that fetches its data in a background goroutine on a fixed interval and serves the last cached result on every Prometheus scrape, so a slow or expensive backend (the driving case: an IBM TS4500 tape library, seconds per call) is never on the scrape's critical path.

**Architecture:** Two new template files per flavor (`code/<flavor>/variants/background_collector.go.tmpl` + its test) ship the standard five-piece collector plus a `Start(ctx)`/`Done()` goroutine, a `sync.RWMutex`-guarded cache, and an always-emitted freshness gauge. `main.go.tmpl` gains a generic, dormant `backgroundCollector`/`backgroundCollectors` shutdown-wait seam that ships unconditionally (empty and inert for a purely synchronous exporter). `scaffold.sh` never ships the `variants/` staging directory — it exists only for `/add-collector` to read from the plugin tree. `/add-collector` gains a `--variant background` branch (with an interactive fallback question) that reads the variant template instead of the synchronous one and splices an eager-construct-plus-`Start`-plus-`register` snippet, all inside the `register()` closure so it runs after `kingpin.Parse()`, not before. The architecture-design phase proactively asks whether any collector's backend is slow/expensive enough to warrant this.

**Tech Stack:** Go 1.26 (`sync`, `context`, `time.Ticker`), `prometheus/client_golang` (`prometheus.Desc`/`MustNewConstMetric`/`testutil`), POSIX `sh`+`sed` (`scaffold.sh`, `test/golden-smoke.sh`), Markdown command/reference prose (`commands/`, `skills/prometheus-exporter/references/`).

## Global Constraints

- **Commits:** `git -c commit.gpgsign=false`, Conventional Commits with scope, **NO AI/automation attribution** of any kind (no `Co-authored-by`, no `Claude-Session`, no "Generated with", no claude.ai links) in any commit message or body.
- **Zero-source gate:** before every commit run `test/zero-source-grep.sh` (SLURM-GREP + HANDLE-GREP). The source project name (`slurm`, `slurm_exporter`, `sacct`, `sacct_efficiency`) and the maintainer handle must NEVER appear in shipped files (`assets/`, `commands/`, `skills/`). Exempt: `docs/`, `test/`, root `.github/`. The adapted background template must use the plugin's own generic `example`/`@@VAR@@` naming, never the reference's `sacct` names.
- **Additive / non-breaking:** the synchronous `code/<flavor>/collector.go.tmpl` and the default `/new` scaffold output stay BYTE-IDENTICAL. Prove it in the relevant task (scaffold before/after, diff empty except the intended main.go seam).
- **Brief format contract untouched:** the discovery-inputs brief's 4 frozen headers (`## Provenance`, `## Architecture decisions`, `## Scaffold inputs`, `## Open questions / assumptions`) and the golden brief-format check stay verbatim. The background need is recorded as free-form prose under the existing `## Architecture decisions`.
- **Locked design values:** interval default **`5m`**; freshness gauge `<namespace>_<name>_last_refresh_timestamp_seconds`, **always emitted** (value `0` before first refresh); **fail-open** on refresh error (keep previous cache, log, retry next tick); `sync.RWMutex` guarding `cached []prometheus.Metric` + `lastRefresh time.Time`; `New*Collector` pure, separate `Start(ctx)` runs immediate refresh then `time.NewTicker(interval)` loop, `defer close(c.done)`, `Done() <-chan struct{}`.
- `claude plugin validate .` must pass. Shipped artifacts + commit messages in **English**.
- Golden `--all` (`{http,cli}×{none,github}`) must end green.

---

## File Structure

**Created:**
- `skills/prometheus-exporter/assets/code/http/variants/background_collector.go.tmpl` — Task 3
- `skills/prometheus-exporter/assets/code/http/variants/background_collector_test.go.tmpl` — Task 3
- `skills/prometheus-exporter/assets/code/cli/variants/background_collector.go.tmpl` — Task 4
- `skills/prometheus-exporter/assets/code/cli/variants/background_collector_test.go.tmpl` — Task 4

**Modified:**
- `skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl` — the dormant `Done()` seam (Task 1)
- `skills/prometheus-exporter/assets/scaffold.sh` — never ship `variants/` (Task 2)
- `commands/add-collector.md` — the `--variant background` branch (Task 5)
- `commands/design-exporter.md`, `skills/prometheus-exporter/references/exporter-architecture.md`, `skills/prometheus-exporter/SKILL.md` — the design-time probe (Task 6)
- `test/golden-smoke.sh` — the end-to-end background sub-check (Task 7)
- `CHANGELOG.md`, `ROADMAP.md` — bookkeeping (Task 8)

**Explicitly NOT modified:** `skills/prometheus-exporter/assets/code/http/collector.go.tmpl`, `skills/prometheus-exporter/assets/code/cli/collector.go.tmpl` (and their tests), and any `metrics.md.tmpl` — the synchronous flavor and the default `/new` output stay byte-for-byte as they are; a background collector is never the scaffold's default starter collector, so no default-metrics doc ever needs it.

---

### Task 1: `main.go.tmpl` generic dormant `Done()` seam

**Files:**
- Modify: `skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl` (declarations right after `var log *logger.Logger` ~line 95, and the signal-aware-shutdown block ~lines 175-204)

**Interfaces:**
- Produces: `type backgroundCollector interface{ Done() <-chan struct{} }` and `var backgroundCollectors []backgroundCollector`, plus the **moved-up** `ctx, stop := signal.NotifyContext(...)`, all declared inside `func main()` **before** the `// @@CLIENT_INIT@@` / `// @@COLLECTOR_REGISTRY@@` markers. Consumed by Task 5's `register(...)` closures spliced AT those markers (which reference `ctx` for `.Start(ctx)` and `append` to `backgroundCollectors`) and by this same task's own post-`web.ListenAndServe` wait loop. Any `*<Name>Collector` produced by Tasks 3/4 satisfies `backgroundCollector` structurally (it has a `Done() <-chan struct{}` method) — no import, no explicit interface assertion needed anywhere.

This is foundational — every later task's registry snippet (Task 5) and golden proof (Task 7) depends on this seam existing and compiling for both flavors. `time` is already imported by `main.go.tmpl` (used by `5 * time.Second` on the `http.Server`), and `context`/`os`/`os/signal`/`syscall` are already imported (used by the existing `signal.NotifyContext` call this task relocates), so no import changes are needed.

Critically, `ctx` and `backgroundCollectors` must be **declared textually before** the `// @@COLLECTOR_REGISTRY@@` marker (~line 99), because Task 5 splices a `register("<name>", func() {... c.Start(ctx); backgroundCollectors = append(...) ...})` closure there and a Go closure can only close over names already in scope at its own textual position. In the pristine `main.go.tmpl` today, `ctx` is declared ~80 lines BELOW that marker (in the shutdown block, ~line 179) — undefined at the marker. So this task moves `ctx` up next to `var log`, mirroring exactly how `log` itself is declared before the markers and only dereferenced later, post-`kingpin.Parse()` (see `register()`'s own doc comment). `signal.NotifyContext` needs no flags, so calling it before `kingpin.Parse()` is safe; an early SIGTERM/SIGINT simply cancels `ctx` and drains cleanly.

- [ ] **Step 1: Confirm the exact current text of the anchors this task edits**

Run: `grep -n "var log \*logger.Logger\|@@CLIENT_INIT@@\|@@COLLECTOR_REGISTRY@@\|NotifyContext\|ListenAndServe\|Server stopped" skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl`
Expected: six matches, confirming `var log *logger.Logger` (~line 95), `// @@CLIENT_INIT@@` (~line 97) and `// @@COLLECTOR_REGISTRY@@` (~line 99) — all BEFORE `kingpin.Parse()` — then `ctx, stop := signal.NotifyContext(...)` currently far below at ~line 179 (inside the shutdown block), `web.ListenAndServe(...)` ~line 197, and `log.Info("Server stopped")` ~line 203. The ordering is the whole point: the two markers where Task 5 splices its `register(...)` closure sit ~80 lines ABOVE the current `ctx` declaration, so `ctx` (and the new slice) must move up to be in scope for that closure — Steps 2 and 3 below do exactly that.

- [ ] **Step 2: Declare `ctx` and the seam up-front, right after `var log`**

Edit `skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl`, replacing:

```go
	// log is declared here (nil) and assigned for real only after
	// kingpin.Parse(), below — see register()'s doc comment for why. Any
	// closure created at the markers below may reference it.
	var log *logger.Logger

	// @@CLIENT_INIT@@
```

with:

```go
	// log is declared here (nil) and assigned for real only after
	// kingpin.Parse(), below — see register()'s doc comment for why. Any
	// closure created at the markers below may reference it.
	var log *logger.Logger

	// ctx is created up-front, before the // @@CLIENT_INIT@@ /
	// // @@COLLECTOR_REGISTRY@@ markers below, so a background-refresh
	// collector variant registered at that marker can capture it in its
	// register() closure (for c.Start(ctx)) — the same early-declaration
	// rationale as log just above: the closure only dereferences ctx later,
	// after kingpin.Parse(), when the registry loop actually invokes it.
	// signal.NotifyContext needs no flags, so calling it before
	// kingpin.Parse() is fine, and an early SIGTERM/SIGINT simply cancels ctx
	// and drains cleanly. It traps SIGTERM/SIGINT to drive graceful shutdown
	// (server.Shutdown below) and to cancel any background collector's
	// goroutine.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	// backgroundCollector is the minimal shutdown-wait seam every
	// background-refresh collector variant satisfies (Start/Done, see
	// internal/collector's background_collector.go once /add-collector has
	// added one). backgroundCollectors stays empty in a purely synchronous
	// exporter — the wait loop after web.ListenAndServe below still runs
	// (over an empty slice, so it is an immediate no-op), which is what
	// lets this seam ship unconditionally without special-casing "no
	// background collectors are registered". /add-collector's background
	// branch appends to this slice inside its register(...) closure at the
	// // @@COLLECTOR_REGISTRY@@ marker below; nothing else in main.go changes
	// when one is added.
	type backgroundCollector interface{ Done() <-chan struct{} }
	var backgroundCollectors []backgroundCollector

	// @@CLIENT_INIT@@
```

- [ ] **Step 3: Remove the now-relocated `ctx` declaration from the shutdown block**

Edit the same file, replacing:

```go
	// Signal-aware shutdown: on SIGTERM/SIGINT, drain in-flight requests for
	// up to 5s via server.Shutdown instead of leaving the process to a bare
	// kill. Any future background-refresh collector variant can derive its
	// own cancellation from this same ctx.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	server := &http.Server{
```

with:

```go
	// Signal-aware shutdown: on SIGTERM/SIGINT, drain in-flight requests for
	// up to 5s via server.Shutdown instead of leaving the process to a bare
	// kill. ctx (and its stop) are declared up-front near var log above, so a
	// background collector registered at the // @@COLLECTOR_REGISTRY@@ marker
	// can capture ctx in its register() closure; the server built here and the
	// shutdown goroutine below still reference that same ctx unchanged.
	server := &http.Server{
```

This leaves `server`, the shutdown `go func(){ <-ctx.Done(); server.Shutdown(...) }`, and the explicit `stop()` on the `web.ListenAndServe` error path all referencing the now-earlier `ctx`/`stop` — none of them moved.

- [ ] **Step 4: Add the post-shutdown wait loop**

Edit the same file, replacing:

```go
	log.Info("Server stopped")
}
```

with:

```go
	log.Info("Server stopped")

	// Wait for every background-refresh collector's goroutine to finish (if
	// any were registered — see backgroundCollectors above), bounded so a
	// collector whose refresh is genuinely stuck never hangs process exit.
	for _, bc := range backgroundCollectors {
		select {
		case <-bc.Done():
		case <-time.After(5 * time.Second):
			log.Warn("a background collector did not stop within 5s; exiting anyway")
		}
	}
}
```

- [ ] **Step 5: Scaffold a throwaway http exporter and confirm it still compiles**

Run:

```sh
rm -rf test/_work/task1-http-none
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst test/_work/task1-http-none \
  --flavor http --forge none --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0
( cd test/_work/task1-http-none && go vet ./... )
( cd test/_work/task1-http-none && make build )
```

Expected: `scaffolded test/_work/task1-http-none`; `go vet ./...` exits 0 with no output (proves the dormant `for _, bc := range backgroundCollectors` compiles — the loop uses the variable, so no "declared and not used", and the unused `backgroundCollector` interface type is legal Go); `make build` exits 0 (containerized via the tools image, or the native-fallback warning banner + host Go toolchain if no Docker/Podman is present — either path is a PASS) and reports `Building bin/demo_exporter`.

- [ ] **Step 6: Scaffold a throwaway cli exporter and confirm the same**

Run:

```sh
rm -rf test/_work/task1-cli-none
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst test/_work/task1-cli-none \
  --flavor cli --forge none --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=demo_cli --var DATA_SOURCE_PATH=unused \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0
( cd test/_work/task1-cli-none && go vet ./... )
( cd test/_work/task1-cli-none && make build )
```

Expected: same as Step 5 — `go vet ./...` clean, `make build` exits 0.

- [ ] **Step 7: Confirm the seam text landed in both scaffolds, then clean up**

Run:

```sh
grep -c 'var backgroundCollectors \[\]backgroundCollector' test/_work/task1-http-none/cmd/demo_exporter/main.go
grep -c 'var backgroundCollectors \[\]backgroundCollector' test/_work/task1-cli-none/cmd/demo_exporter/main.go
rm -rf test/_work/task1-http-none test/_work/task1-cli-none
```

Expected: both `grep -c` calls print `1`.

- [ ] **Step 8: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add skills/prometheus-exporter/assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl
git -c commit.gpgsign=false commit -m "feat(scaffold): add a dormant background-collector shutdown seam to main.go"
```

---

### Task 2: `scaffold.sh` never ships `variants/`

**Files:**
- Modify: `skills/prometheus-exporter/assets/scaffold.sh` (the flavor-selection block)

**Interfaces:**
- Consumes: nothing new — a one-line addition to the existing flavor-selection move.
- Produces: the guarantee that `code/<flavor>/variants/` (created by Tasks 3 and 4 next) never reaches a scaffolded repository's `internal/collector/`. `/add-collector` (Task 5) reads those variant templates directly from the **plugin's own tree**, never through `scaffold.sh`.

This lands BEFORE the variant templates exist (Tasks 3/4), on purpose: with the exclusion already in `scaffold.sh`, Tasks 3/4 can each run an unrestricted `go build ./...` on a fresh scaffold with no orphaned `variants/` package to trip over. `scaffold.sh`'s flavor-selection step `mv`s **every** entry under `code/$flavor/` (files and subdirectories) into `internal/collector/`, so a `code/<flavor>/variants/` subdir would land at `internal/collector/variants/` — a **distinct Go package** (a subdirectory is its own package regardless of its `package` clause) that can never see `internal/collector`'s own `Client`/`logger` declarations, breaking `go build ./...` with `undefined: Client`. Because the real variant templates do not exist yet, this task proves the exclusion with a throwaway stub file it creates and then removes.

- [ ] **Step 1: Create a throwaway stub under `code/http/variants/` and `code/cli/variants/`**

Run:

```sh
mkdir -p skills/prometheus-exporter/assets/code/http/variants \
         skills/prometheus-exporter/assets/code/cli/variants
printf 'package collector\n\n// scaffold-exclusion stub — removed at the end of this task.\n' \
  > skills/prometheus-exporter/assets/code/http/variants/stub.go.tmpl
printf 'package collector\n\n// scaffold-exclusion stub — removed at the end of this task.\n' \
  > skills/prometheus-exporter/assets/code/cli/variants/stub.go.tmpl
```

Expected: the two stub files exist. They are temporary scaffolding for THIS task's test only — Step 6 deletes them; the real templates arrive in Tasks 3/4.

- [ ] **Step 2: Reproduce the leak empirically (RED, against the current scaffold.sh)**

Run:

```sh
rm -rf test/_work/task2-http-none
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst test/_work/task2-http-none \
  --flavor http --forge none --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0

[ -f test/_work/task2-http-none/internal/collector/variants/stub.go ] && echo "LEAKED (expected at RED)" || echo "absent"
```

Expected: **RED** — prints `LEAKED (expected at RED)`: the stub was moved into `internal/collector/variants/` and `.tmpl`-stripped, proving the current `scaffold.sh` ships the whole `variants/` subtree.

- [ ] **Step 3: Add the fix**

Edit `skills/prometheus-exporter/assets/scaffold.sh`, replacing:

```sh
if [ -d "$dst/code/$flavor" ]; then
  mkdir -p "$dst/internal/collector"
  for entry in "$dst/code/$flavor"/* "$dst/code/$flavor"/.[!.]* "$dst/code/$flavor"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      mv "$entry" "$dst/internal/collector/"
    fi
  done
fi
rm -rf "$dst/code"
```

with:

```sh
if [ -d "$dst/code/$flavor" ]; then
  mkdir -p "$dst/internal/collector"
  for entry in "$dst/code/$flavor"/* "$dst/code/$flavor"/.[!.]* "$dst/code/$flavor"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      mv "$entry" "$dst/internal/collector/"
    fi
  done
fi
rm -rf "$dst/code"

# variants/ (the background_collector.go.tmpl + test that /add-collector adds
# — see code/<flavor>/variants/) is /add-collector's own staging ground: it
# reads those templates directly from the PLUGIN tree (exactly as it reads
# code/<flavor>/collector.go.tmpl today), never through scaffold.sh. Landed
# at internal/collector/variants/ by the flavor-selection move above like any
# other flavor file, it must never reach a scaffolded repo: left in place, a
# @@VAR@@-substituted, .tmpl-stripped background_collector.go would sit in its
# own internal/collector/variants PACKAGE (a subdirectory is a distinct
# package regardless of its package clause), which can never see
# internal/collector's own Client/logger declarations — go build ./... fails
# on it with "undefined: Client". Mirrors the existing wiring/ staging removal
# below. rm -rf on a path that doesn't exist is a silent no-op, so this is
# harmless for a flavor that ships no variants/ at all.
rm -rf "$dst/internal/collector/variants"
```

- [ ] **Step 4: Confirm the exclusion, http flavor (GREEN)**

Run:

```sh
rm -rf test/_work/task2-http-none-fixed
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst test/_work/task2-http-none-fixed \
  --flavor http --forge none --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0

[ -d test/_work/task2-http-none-fixed/internal/collector/variants ] && echo "STILL LEAKING" || echo "ABSENT (expected)"
( cd test/_work/task2-http-none-fixed && go build ./... )
( cd test/_work/task2-http-none-fixed && go vet ./... )
```

Expected: `ABSENT (expected)`; `go build ./...` and `go vet ./...` both exit 0 (the stub never reaches the scaffold, so there is no orphaned `variants/` package).

- [ ] **Step 5: Confirm the exclusion, cli flavor (GREEN)**

Run:

```sh
rm -rf test/_work/task2-cli-none-fixed
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst test/_work/task2-cli-none-fixed \
  --flavor cli --forge none --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=demo_cli --var DATA_SOURCE_PATH=unused \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0

[ -d test/_work/task2-cli-none-fixed/internal/collector/variants ] && echo "STILL LEAKING" || echo "ABSENT (expected)"
( cd test/_work/task2-cli-none-fixed && go build ./... )
( cd test/_work/task2-cli-none-fixed && go vet ./... )
```

Expected: same as Step 4.

- [ ] **Step 6: Prove `/new` output is byte-identical to pre-change, then remove the stubs**

Run:

```sh
diff -rq test/_work/task2-http-none/internal/collector/collector.go \
         test/_work/task2-http-none-fixed/internal/collector/collector.go
diff -rq test/_work/task2-http-none/internal/collector/client.go \
         test/_work/task2-http-none-fixed/internal/collector/client.go
diff -rq test/_work/task2-http-none/cmd/demo_exporter/main.go \
         test/_work/task2-http-none-fixed/cmd/demo_exporter/main.go
rm -f skills/prometheus-exporter/assets/code/http/variants/stub.go.tmpl \
      skills/prometheus-exporter/assets/code/cli/variants/stub.go.tmpl
rmdir skills/prometheus-exporter/assets/code/http/variants \
      skills/prometheus-exporter/assets/code/cli/variants
rm -rf test/_work/task2-http-none test/_work/task2-http-none-fixed \
       test/_work/task2-cli-none-fixed
```

Expected: all three `diff` calls print nothing — the only difference the fix makes to a scaffold is dropping the (stub) `variants/` dir; every synchronous file, and `main.go` (already carrying Task 1's seam), is byte-identical before and after. The two `rmdir` calls succeed because this step just removed the only file in each `variants/` dir, leaving them empty — the plugin tree returns to exactly its pre-task state (no `variants/` dirs), ready for Tasks 3/4 to create the real ones. Only `scaffold.sh` remains changed on disk.

- [ ] **Step 7: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add skills/prometheus-exporter/assets/scaffold.sh
git -c commit.gpgsign=false commit -m "fix(scaffold): never ship internal/collector/variants/ in scaffolded output"
```

---

### Task 3: http background collector + test templates

**Files:**
- Create: `skills/prometheus-exporter/assets/code/http/variants/background_collector.go.tmpl`
- Create: `skills/prometheus-exporter/assets/code/http/variants/background_collector_test.go.tmpl`

**Interfaces:**
- Consumes: `*Client`/`func (c *Client) Fetch(ctx context.Context, path string) ([]byte, error)` and `func NewClient(target string, timeout time.Duration) *Client` (`code/http/client.go.tmpl`, already shipped); `*logger.Logger` with `.Error(msg string, args ...any)` (`internal/logger/logger.go.tmpl`, already shipped); `func NewStatusTracker(log *logger.Logger) *StatusTracker` and `func (st *StatusTracker) Add(name string, c prometheus.Collector)` (`internal/collector/status_tracker.go.tmpl`, already shipped); the package-scope `const statusTrackerSuccessMetric` already declared by the flavor's own `collector_test.go.tmpl` (reused here, never redeclared).
- Produces: `func New<Name>Collector(log *logger.Logger, client *Client, interval time.Duration) *<Name>Collector` (returns the **concrete pointer type**, not `prometheus.Collector` — Task 5's registry snippet needs to call `.Start(ctx)` and pass the value to `backgroundCollectors`, neither of which the bare interface exposes); `func (c *<Name>Collector) Start(ctx context.Context)`; `func (c *<Name>Collector) Done() <-chan struct{}`; field names `mu sync.RWMutex`, `cached []prometheus.Metric`, `lastRefresh time.Time`, `lastRefreshDesc *prometheus.Desc`, `done chan struct{}` — Task 5's prose and Task 7's golden sub-check both reference these exact names.

The background collector keeps the same five-piece shape as the synchronous flavor (`<name>Data` → `parse<Name>` → `<name>GetMetrics` → `Describe`/`Collect`), so `/add-collector`'s existing identifier-rename table (`add-collector.md` §3: `example`→`<name>`, `Example`→`<Name>`, ...) applies to this template unchanged — Task 5 only adds new rows for the pieces this template adds (`interval`, `lastRefreshDesc`, `Start`, `Done`, `refresh`). The template is authored with the SAME placeholder identifiers (`example`/`Example`) the synchronous template uses, never `<name>`/`<Name>` template syntax — those are mechanically substituted by `/add-collector`, not by `scaffold.sh`.

- [ ] **Step 1: Write the failing test template**

Create `skills/prometheus-exporter/assets/code/http/variants/background_collector_test.go.tmpl`:

```go
package collector

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"@@MODULE_PATH@@/internal/logger"
)

// TestParseExample exercises parseExample (piece 2, the pure parser) with a
// static byte fixture: no HTTP, no collector, no logger, no goroutine
// involved. Identical in spirit to the synchronous flavor's own test of the
// same name — the parser is pure regardless of how its caller schedules I/O.
func TestParseExample(t *testing.T) {
	data, err := os.ReadFile("testdata/example.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	stats, err := parseExample(data)
	if err != nil {
		t.Fatalf("parseExample: %v", err)
	}
	if stats.Items != 42 {
		t.Errorf("Items = %d, want 42", stats.Items)
	}
	if !stats.Healthy {
		t.Error("Healthy = false, want true")
	}

	t.Run("malformed input yields an error, not a panic", func(t *testing.T) {
		if _, err := parseExample([]byte("not json")); err == nil {
			t.Error("parseExample(malformed) returned a nil error, want non-nil")
		}
	})
}

// TestExampleCollector_Describe locks the descriptor count at exactly 3
// (items, healthy, and the freshness gauge lastRefreshDesc — one more than
// the synchronous flavor, which has no freshness gauge) so a future edit
// that silently adds or drops a metric is caught here rather than
// downstream.
func TestExampleCollector_Describe(t *testing.T) {
	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, NewClient("http://example.invalid", time.Second), time.Hour)

	ch := make(chan *prometheus.Desc, 10)
	c.Describe(ch)
	close(ch)

	count := 0
	for range ch {
		count++
	}
	if count != 3 {
		t.Fatalf("Describe sent %d descriptors, want 3", count)
	}
}

// TestExampleCollector_DoneClosesOnCancel verifies the Done() channel closes
// when the context passed to Start is cancelled. This is the mechanism
// main.go's backgroundCollector shutdown seam relies on (see
// cmd/@@EXPORTER_NAME@@/main.go's wait loop after web.ListenAndServe).
func TestExampleCollector_DoneClosesOnCancel(t *testing.T) {
	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, NewClient("http://example.invalid", time.Second), time.Hour)
	ctx, cancel := context.WithCancel(context.Background())

	c.Start(ctx)
	cancel()

	select {
	case <-c.Done():
		// success
	case <-time.After(2 * time.Second):
		t.Fatal("Done() did not close within 2s after cancel — graceful shutdown broken")
	}
}

// TestExampleCollector_CollectServesCacheWithoutIO proves Collect never
// calls the target: after Start's own immediate refresh completes, a long
// interval (1 hour) guarantees the ticker cannot fire again during this
// test, so any further request the server receives could only come from
// Collect itself calling out — which the design forbids. Scraping (via
// Gather) three times back to back must not move the request counter past
// whatever Start's own first refresh already set it to.
func TestExampleCollector_CollectServesCacheWithoutIO(t *testing.T) {
	var calls atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		http.ServeFile(w, r, "testdata/example.json")
	}))
	defer srv.Close()

	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, NewClient(srv.URL, time.Second), time.Hour)
	ctx, cancel := context.WithCancel(context.Background())
	defer func() {
		cancel()
		<-c.Done()
	}()

	c.Start(ctx)
	time.Sleep(100 * time.Millisecond) // let Start's immediate refresh land

	afterStart := calls.Load()
	if afterStart == 0 {
		t.Fatal("calls = 0 after Start, want >= 1: Start must run an immediate refresh")
	}

	reg := prometheus.NewRegistry()
	if err := reg.Register(c); err != nil {
		t.Fatalf("Register: %v", err)
	}
	for i := 0; i < 3; i++ {
		if _, err := testutil.GatherAndCount(reg); err != nil {
			t.Fatalf("GatherAndCount (scrape %d): %v", i, err)
		}
	}

	if got := calls.Load(); got != afterStart {
		t.Fatalf("calls after 3 scrapes = %d, want %d unchanged: Collect must never call the target", got, afterStart)
	}
}

// TestExampleCollector_ErrorKeepsPreviousCache scripts the backend to
// succeed once, then fail on every later call, and drives at least one more
// refresh via a short interval. The cache from the successful first refresh
// must survive the later failure — fail-open, per this collector's Collect
// doc comment — rather than being cleared or replaced with nothing.
func TestExampleCollector_ErrorKeepsPreviousCache(t *testing.T) {
	var calls atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			http.ServeFile(w, r, "testdata/example.json")
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, NewClient(srv.URL, time.Second), 20*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	defer func() {
		cancel()
		<-c.Done()
	}()

	c.Start(ctx)
	time.Sleep(150 * time.Millisecond) // first (successful) refresh + at least one failed refresh

	reg := prometheus.NewRegistry()
	if err := reg.Register(c); err != nil {
		t.Fatalf("Register: %v", err)
	}
	count, err := testutil.GatherAndCount(reg)
	if err != nil {
		t.Fatalf("GatherAndCount: %v", err)
	}
	if count == 0 {
		t.Fatal("GatherAndCount = 0, want > 0: the previous cache must survive a later refresh error")
	}
}

// TestExampleCollector_FirstScrapeEmitsFreshnessGaugeZero covers the startup
// window before Start's first refresh has completed (Start is deliberately
// never called here). Collect must still emit exactly the freshness gauge,
// valued 0 (not a zero time.Time's large-negative Unix()), and StatusTracker
// must still report this collector as successful — because "Collect ran
// and returned data" and "the data is fresh" are different questions (see
// this collector's Collect doc comment); an empty cache before the first
// refresh is a normal startup state, not a failed scrape.
func TestExampleCollector_FirstScrapeEmitsFreshnessGaugeZero(t *testing.T) {
	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, NewClient("http://example.invalid", time.Second), time.Hour)
	// Do NOT call Start(): cache is empty, no refresh has ever run.

	expected := `
# HELP @@NAMESPACE@@_example_last_refresh_timestamp_seconds Unix time of the last successful example refresh. Alert if time() - this > 2 x the collector's configured interval.
# TYPE @@NAMESPACE@@_example_last_refresh_timestamp_seconds gauge
@@NAMESPACE@@_example_last_refresh_timestamp_seconds 0
`
	if err := testutil.CollectAndCompare(c, strings.NewReader(expected)); err != nil {
		t.Fatalf("unexpected collecting result:\n%s", err)
	}

	tracker := NewStatusTracker(log)
	tracker.Add("example", c)

	expectedSuccess := `
# HELP ` + statusTrackerSuccessMetric + ` Whether the last scrape of the collector succeeded (1=success, 0=failure)
# TYPE ` + statusTrackerSuccessMetric + ` gauge
` + statusTrackerSuccessMetric + `{collector="example"} 1
`
	if err := testutil.CollectAndCompare(tracker, strings.NewReader(expectedSuccess), statusTrackerSuccessMetric); err != nil {
		t.Fatalf("unexpected collecting result:\n%s", err)
	}
}
```

- [ ] **Step 2: Instantiate the test template alone into a throwaway scaffold and confirm it fails to compile (RED)**

Run:

```sh
rm -rf test/_work/task3-http-bg
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst test/_work/task3-http-bg \
  --flavor http --forge none --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0

# Instantiate the new test template as a SECOND collector "bg", alongside
# the scaffold's own pre-existing "example" collector (mirroring
# test/golden-smoke.sh's mechanical /add-collector sub-check). Identifier
# rename MUST run before @@VAR@@ substitution: @@MODULE_PATH@@'s value
# (example.com/demo_exporter) contains the substring "example" too — found
# the hard way while wiring golden-smoke.sh's own queue sub-check.
sed -e 's/example/bg/g' -e 's/Example/Bg/g' \
  skills/prometheus-exporter/assets/code/http/variants/background_collector_test.go.tmpl \
  > test/_work/task3-http-bg/internal/collector/bg_test.go.tmp
sed \
  -e 's/@@MODULE_PATH@@/example.com\/demo_exporter/g' \
  -e 's/@@NAMESPACE@@/demo/g' \
  test/_work/task3-http-bg/internal/collector/bg_test.go.tmp \
  > test/_work/task3-http-bg/internal/collector/bg_test.go
rm -f test/_work/task3-http-bg/internal/collector/bg_test.go.tmp
cp skills/prometheus-exporter/assets/code/http/testdata/example.json \
  test/_work/task3-http-bg/internal/collector/testdata/bg.json

( cd test/_work/task3-http-bg && go test -race ./internal/collector/ -run 'Bg' -v )
```

Expected: **FAIL** — a build error, not a test failure, since `background_collector.go.tmpl` does not exist yet: `undefined: NewBgCollector` (and similarly `BgCollector`, `parseBg`, `bgData`, `bgGetMetrics` wherever `bg_test.go` references them).

- [ ] **Step 3: Write the implementation template**

Create `skills/prometheus-exporter/assets/code/http/variants/background_collector.go.tmpl`:

```go
package collector

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"@@MODULE_PATH@@/internal/logger"
)

// exampleStats is the parsed shape of the example target's response. This is
// a placeholder shape, {"items": <int>, "healthy": <bool>}, documenting the
// pattern rather than a real API. Replace it, and parseExample below, with
// your actual target's real response shape when adapting this collector.
type exampleStats struct {
	Items   int  `json:"items"`
	Healthy bool `json:"healthy"`
}

// exampleData is this collector's only I/O: it fetches the raw response body
// from the configured target. Kept separate from parsing (parseExample,
// below) so parsing stays pure and unit-testable without a live server.
func (c *ExampleCollector) exampleData(ctx context.Context) ([]byte, error) {
	return c.client.Fetch(ctx, "@@DATA_SOURCE_PATH@@")
}

// parseExample decodes exampleData's response body into exampleStats. Pure:
// no I/O, no logging, no side effects, so every input maps deterministically
// to an output. That is what makes it unit-testable with plain byte
// fixtures (see the test file's TestParseExample).
func parseExample(b []byte) (exampleStats, error) {
	var stats exampleStats
	if err := json.Unmarshal(b, &stats); err != nil {
		return exampleStats{}, fmt.Errorf("parse example response: %w", err)
	}
	return stats, nil
}

// exampleGetMetrics is the glue between the I/O step (exampleData) and the
// pure parsing step (parseExample): the shape every collector in this
// exporter follows, regardless of flavor. refresh, below, calls this on its
// own background schedule; nothing else in this file calls the target
// directly.
func (c *ExampleCollector) exampleGetMetrics(ctx context.Context) (exampleStats, error) {
	data, err := c.exampleData(ctx)
	if err != nil {
		return exampleStats{}, err
	}
	return parseExample(data)
}

// ExampleCollector is the background-refresh variant materialized by
// /add-collector --variant background. Unlike the synchronous collector
// (collector.go.tmpl), Collect never calls the target: a background
// goroutine (started by Start, below) refreshes a cached metric slice on a
// fixed interval, and Collect only ever reads that cache under mu. This
// decouples scrape cadence from fetch cadence entirely, so a scrape never
// blocks on a slow or expensive target, no matter how slow it is.
type ExampleCollector struct {
	client   *Client
	interval time.Duration
	log      *logger.Logger

	items           *prometheus.Desc
	healthy         *prometheus.Desc
	lastRefreshDesc *prometheus.Desc

	// mu guards cached and lastRefresh: refresh (below) writes them from the
	// background goroutine started by Start, Collect reads them from
	// whichever goroutine calls it (a Prometheus scrape). RWMutex, not a
	// plain Mutex, because Collect only ever reads.
	mu          sync.RWMutex
	cached      []prometheus.Metric
	lastRefresh time.Time

	// done is closed when the background goroutine launched by Start exits.
	// main.go waits on Done() (via the backgroundCollector seam) after the
	// HTTP server has shut down, so the process doesn't exit mid-refresh.
	done chan struct{}
}

// NewExampleCollector builds the collector and its Descs. It is pure: it
// starts no goroutine and performs no I/O, which is what makes it
// constructible in tests with no background refresh running. Call Start
// once, after construction, to begin refreshing.
func NewExampleCollector(log *logger.Logger, client *Client, interval time.Duration) *ExampleCollector {
	return &ExampleCollector{
		client:   client,
		interval: interval,
		log:      log,
		items: prometheus.NewDesc(
			"@@NAMESPACE@@_items",
			"Number of items reported by the example target.",
			nil, nil,
		),
		healthy: prometheus.NewDesc(
			"@@NAMESPACE@@_healthy",
			"Whether the example target reports itself healthy (1) or not (0).",
			nil, nil,
		),
		lastRefreshDesc: prometheus.NewDesc(
			"@@NAMESPACE@@_example_last_refresh_timestamp_seconds",
			"Unix time of the last successful example refresh. Alert if time() - this > 2 x the collector's configured interval.",
			nil, nil,
		),
		done: make(chan struct{}),
	}
}

// Start launches the background refresh goroutine. Call once, after
// construction. The first refresh runs immediately (so the cache starts
// filling as soon as the process starts) without Start itself waiting for
// it — a slow first fetch never blocks process startup. The goroutine exits
// when ctx is cancelled; Done() can then be used to wait for it to finish.
func (c *ExampleCollector) Start(ctx context.Context) {
	go func() {
		defer close(c.done)
		c.refresh(ctx)
		ticker := time.NewTicker(c.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				c.refresh(ctx)
			case <-ctx.Done():
				return
			}
		}
	}()
}

// Done returns a channel that is closed when the background goroutine
// started by Start has fully exited. main.go's shutdown seam waits on this
// (bounded, so a stuck refresh can't hang process exit forever) after the
// HTTP server itself has stopped.
func (c *ExampleCollector) Done() <-chan struct{} {
	return c.done
}

// refresh performs the one flavor-specific I/O call (exampleGetMetrics, via
// the injected *Client) and, on success, atomically replaces the cache.
// On error it logs and returns, leaving the previous cache and lastRefresh
// untouched — fail-open: a transient failure serves the last-known-good
// data instead of dropping the series, and the freshness gauge (below) is
// the signal that a refresh is stale, not a dropped scrape.
func (c *ExampleCollector) refresh(ctx context.Context) {
	stats, err := c.exampleGetMetrics(ctx)
	if err != nil {
		c.log.Error("Failed to refresh example metrics — keeping previous cache", "err", err)
		return
	}

	healthy := 0.0
	if stats.Healthy {
		healthy = 1.0
	}
	metrics := []prometheus.Metric{
		prometheus.MustNewConstMetric(c.items, prometheus.GaugeValue, float64(stats.Items)),
		prometheus.MustNewConstMetric(c.healthy, prometheus.GaugeValue, healthy),
	}

	c.mu.Lock()
	c.cached = metrics
	c.lastRefresh = time.Now()
	c.mu.Unlock()
}

// Describe sends every one of this collector's descriptors, including the
// freshness gauge. Constant regardless of scrape or refresh outcome, which
// is what makes prometheus.DescribeByCollect unnecessary here.
func (c *ExampleCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.items
	ch <- c.healthy
	ch <- c.lastRefreshDesc
}

// Collect replays the cached metrics from the last successful refresh —
// O(cached size), never touches the target, never blocks on it. It then
// ALWAYS sends the freshness gauge, even before any refresh has ever
// completed (value 0 in that case, since a zero time.Time's Unix() is a
// large negative, not a meaningful "ancient" epoch marker) — see the
// collector-authoring rule in collector.go.tmpl's Collect for why a
// collector must never emit zero metrics on what it considers a healthy
// outcome: StatusTracker counts emitted metrics per scrape, and an empty
// cache before the first refresh completes is a normal startup window, not
// a failure. The freshness gauge alone guarantees at least one metric every
// scrape, so StatusTracker reports this collector as alive; the gauge's own
// value (0 until the first refresh lands) is the separate, correct signal
// for staleness — see NewExampleCollector's lastRefreshDesc help text.
func (c *ExampleCollector) Collect(ch chan<- prometheus.Metric) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	for _, m := range c.cached {
		ch <- m
	}

	refreshUnix := 0.0
	if !c.lastRefresh.IsZero() {
		refreshUnix = float64(c.lastRefresh.Unix())
	}
	ch <- prometheus.MustNewConstMetric(c.lastRefreshDesc, prometheus.GaugeValue, refreshUnix)
}
```

- [ ] **Step 4: Re-instantiate both templates and confirm the test suite passes (GREEN)**

Run:

```sh
sed -e 's/example/bg/g' -e 's/Example/Bg/g' \
  skills/prometheus-exporter/assets/code/http/variants/background_collector.go.tmpl \
  > test/_work/task3-http-bg/internal/collector/bg.go.tmp
sed \
  -e 's/@@MODULE_PATH@@/example.com\/demo_exporter/g' \
  -e 's/@@DATA_SOURCE_PATH@@/\/api\/bg/g' \
  -e 's/@@NAMESPACE@@/demo/g' \
  test/_work/task3-http-bg/internal/collector/bg.go.tmp \
  > test/_work/task3-http-bg/internal/collector/bg.go
rm -f test/_work/task3-http-bg/internal/collector/bg.go.tmp

( cd test/_work/task3-http-bg && go test -race ./internal/collector/ -run 'Bg' -v )
( cd test/_work/task3-http-bg && go build ./... )
( cd test/_work/task3-http-bg && go vet ./... )
```

Expected: **PASS** — `TestParseBg`, `TestBgCollector_Describe`, `TestBgCollector_DoneClosesOnCancel`, `TestBgCollector_CollectServesCacheWithoutIO`, `TestBgCollector_ErrorKeepsPreviousCache`, `TestBgCollector_FirstScrapeEmitsFreshnessGaugeZero` all report `--- PASS`, overall `PASS`, `ok`. Then `go build ./...` and `go vet ./...` both exit 0 — proving the whole scaffolded module (with `bg.go` added as an ordinary `internal/collector/` file) still compiles cleanly. This unrestricted `./...` sweep is safe because Task 2 already made `scaffold.sh` exclude any `variants/` package from the scaffold, so there is no orphaned package to trip it.

- [ ] **Step 5: Confirm the pre-existing default collector still passes too, then clean up**

Run:

```sh
( cd test/_work/task3-http-bg && go test -race ./internal/collector/ -run 'Example' -v )
rm -rf test/_work/task3-http-bg
```

Expected: **PASS** — the scaffold's own default `ExampleCollector` tests (`TestParseExample`, `TestExampleCollector_Collect`, `_Describe`, `_ErrorHandling`, `_StatusTrackerSuccess`, `_StatusTrackerFailure`) are unaffected by the new `bg.go`/`bg_test.go` sitting alongside them in the same package — proving the new template's identifiers never collide with the synchronous flavor's own.

- [ ] **Step 6: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add skills/prometheus-exporter/assets/code/http/variants/background_collector.go.tmpl \
        skills/prometheus-exporter/assets/code/http/variants/background_collector_test.go.tmpl
git -c commit.gpgsign=false commit -m "feat(templates): add the http background-refresh collector variant"
```

---

### Task 4: cli background collector + test templates

**Files:**
- Create: `skills/prometheus-exporter/assets/code/cli/variants/background_collector.go.tmpl`
- Create: `skills/prometheus-exporter/assets/code/cli/variants/background_collector_test.go.tmpl`

**Interfaces:**
- Consumes: the package-level `var Execute = func(ctx context.Context, name string, args ...string) ([]byte, error)` and `CommandDuration` (`code/cli/execute.go.tmpl`, already shipped, reassignable in tests); `*logger.Logger`; `NewStatusTracker`/`statusTrackerSuccessMetric` (same as Task 3, already shipped).
- Produces: `func New<Name>Collector(log *logger.Logger, timeout, interval time.Duration) *<Name>Collector` (concrete pointer, same reasoning as Task 3); `Start(ctx context.Context)`; `Done() <-chan struct{}`; the same field names as Task 3 (`mu sync.RWMutex`, `cached []prometheus.Metric`, `lastRefresh time.Time`, `lastRefreshDesc *prometheus.Desc`, `done chan struct{}`) — Task 5's prose and Task 7's golden sub-check depend on this being identical across flavors.

The cli flavor splits its synchronous parser test into a separate `parser_test.go.tmpl`, merged into one `<name>_test.go` by `/add-collector` §4 for any second-or-later collector. The background variant ships only ONE test template (per the design's Template Surface list), so it must already contain the merged parser-plus-lifecycle tests — no separate `background_parser_test.go.tmpl` exists.

- [ ] **Step 1: Write the failing test template (parser tests + lifecycle tests merged)**

Create `skills/prometheus-exporter/assets/code/cli/variants/background_collector_test.go.tmpl`:

```go
package collector

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"@@MODULE_PATH@@/internal/logger"
)

// TestParseExample exercises parseExample (piece 2, the pure parser) with a
// static byte fixture: no subprocess, no collector, no logger, no goroutine
// involved. Identical in spirit to the synchronous flavor's own test of the
// same name — the parser is pure regardless of how its caller schedules I/O.
func TestParseExample(t *testing.T) {
	data, err := os.ReadFile("testdata/example.txt")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	metrics, err := parseExample(data)
	if err != nil {
		t.Fatalf("parseExample: %v", err)
	}

	want := map[string]float64{"foo": 1, "bar": 2, "baz": 3}
	if len(metrics) != len(want) {
		t.Fatalf("parseExample returned %d entries, want %d", len(metrics), len(want))
	}
	for _, m := range metrics {
		wantValue, ok := want[m.Key]
		if !ok {
			t.Errorf("unexpected key %q in parseExample result", m.Key)
			continue
		}
		if m.Value != wantValue {
			t.Errorf("parseExample[%q] = %v, want %v", m.Key, m.Value, wantValue)
		}
	}

	t.Run("malformed input yields an error, not a panic", func(t *testing.T) {
		if _, err := parseExample([]byte("not-a-valid-line")); err == nil {
			t.Error("parseExample(malformed) returned a nil error, want non-nil")
		}
	})

	t.Run("duplicate key yields an error, not a panic", func(t *testing.T) {
		if _, err := parseExample([]byte("foo 1\nfoo 2\n")); err == nil {
			t.Error("parseExample(duplicate key) returned a nil error, want non-nil")
		}
	})

	t.Run("empty input yields zero entries, not an error", func(t *testing.T) {
		metrics, err := parseExample([]byte(""))
		if err != nil {
			t.Fatalf("parseExample(empty): %v", err)
		}
		if len(metrics) != 0 {
			t.Fatalf("parseExample(empty) returned %d entries, want 0", len(metrics))
		}
	})
}

// TestExampleCollector_Describe locks the descriptor count at exactly 3
// (entries, value, and the freshness gauge lastRefreshDesc — one more than
// the synchronous flavor, which has no freshness gauge) so a future edit
// that silently adds or drops a metric is caught here rather than
// downstream.
func TestExampleCollector_Describe(t *testing.T) {
	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, time.Second, time.Hour)

	ch := make(chan *prometheus.Desc, 10)
	c.Describe(ch)
	close(ch)

	count := 0
	for range ch {
		count++
	}
	if count != 3 {
		t.Fatalf("Describe sent %d descriptors, want 3", count)
	}
}

// TestExampleCollector_DoneClosesOnCancel verifies the Done() channel closes
// when the context passed to Start is cancelled. This is the mechanism
// main.go's backgroundCollector shutdown seam relies on (see
// cmd/@@EXPORTER_NAME@@/main.go's wait loop after web.ListenAndServe).
func TestExampleCollector_DoneClosesOnCancel(t *testing.T) {
	oldExecute := Execute
	defer func() { Execute = oldExecute }()
	Execute = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return []byte(""), nil
	}

	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, time.Second, time.Hour)
	ctx, cancel := context.WithCancel(context.Background())

	c.Start(ctx)
	cancel()

	select {
	case <-c.Done():
		// success
	case <-time.After(2 * time.Second):
		t.Fatal("Done() did not close within 2s after cancel — graceful shutdown broken")
	}
}

// TestExampleCollector_CollectServesCacheWithoutIO proves Collect never
// runs the command: after Start's own immediate refresh completes, a long
// interval (1 hour) guarantees the ticker cannot fire again during this
// test, so any further Execute call could only come from Collect itself —
// which the design forbids. Scraping (via Gather) three times back to back
// must not move the call counter past whatever Start's own first refresh
// already set it to.
//
// Execute is restored via defer immediately after saving it, and the test
// waits on c.Done() after cancelling before that restore runs, so the
// background goroutine's own read of Execute can never race the restore —
// the same ordering the reference collector's own tests use.
func TestExampleCollector_CollectServesCacheWithoutIO(t *testing.T) {
	var calls atomic.Int64

	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, time.Second, time.Hour)
	ctx, cancel := context.WithCancel(context.Background())

	oldExecute := Execute
	defer func() {
		cancel()
		<-c.Done()
		Execute = oldExecute
	}()
	Execute = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls.Add(1)
		return []byte("foo 1\nbar 2\nbaz 3\n"), nil
	}

	c.Start(ctx)
	time.Sleep(100 * time.Millisecond) // let Start's immediate refresh land

	afterStart := calls.Load()
	if afterStart == 0 {
		t.Fatal("calls = 0 after Start, want >= 1: Start must run an immediate refresh")
	}

	reg := prometheus.NewRegistry()
	if err := reg.Register(c); err != nil {
		t.Fatalf("Register: %v", err)
	}
	for i := 0; i < 3; i++ {
		if _, err := testutil.GatherAndCount(reg); err != nil {
			t.Fatalf("GatherAndCount (scrape %d): %v", i, err)
		}
	}

	if got := calls.Load(); got != afterStart {
		t.Fatalf("calls after 3 scrapes = %d, want %d unchanged: Collect must never run the command", got, afterStart)
	}
}

// TestExampleCollector_ErrorKeepsPreviousCache scripts Execute to succeed
// once, then fail on every later call, and drives at least one more
// refresh via a short interval. The cache from the successful first refresh
// must survive the later failure — fail-open, per this collector's Collect
// doc comment — rather than being cleared or replaced with nothing.
func TestExampleCollector_ErrorKeepsPreviousCache(t *testing.T) {
	var calls atomic.Int64

	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, time.Second, 20*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())

	oldExecute := Execute
	defer func() {
		cancel()
		<-c.Done()
		Execute = oldExecute
	}()
	Execute = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if calls.Add(1) == 1 {
			return []byte("foo 1\nbar 2\n"), nil
		}
		return nil, errors.New("simulated command failure")
	}

	c.Start(ctx)
	time.Sleep(150 * time.Millisecond) // first (successful) refresh + at least one failed refresh

	reg := prometheus.NewRegistry()
	if err := reg.Register(c); err != nil {
		t.Fatalf("Register: %v", err)
	}
	count, err := testutil.GatherAndCount(reg)
	if err != nil {
		t.Fatalf("GatherAndCount: %v", err)
	}
	if count == 0 {
		t.Fatal("GatherAndCount = 0, want > 0: the previous cache must survive a later refresh error")
	}
}

// TestExampleCollector_FirstScrapeEmitsFreshnessGaugeZero covers the startup
// window before Start's first refresh has completed (Start is deliberately
// never called here). Collect must still emit exactly the freshness gauge,
// valued 0 (not a zero time.Time's large-negative Unix()), and StatusTracker
// must still report this collector as successful — because "Collect ran
// and returned data" and "the data is fresh" are different questions (see
// this collector's Collect doc comment); an empty cache before the first
// refresh is a normal startup state, not a failed scrape.
func TestExampleCollector_FirstScrapeEmitsFreshnessGaugeZero(t *testing.T) {
	log := logger.NewTextLogger("error")
	c := NewExampleCollector(log, time.Second, time.Hour)
	// Do NOT call Start(): cache is empty, no refresh has ever run.

	expected := `
# HELP @@NAMESPACE@@_example_last_refresh_timestamp_seconds Unix time of the last successful example refresh. Alert if time() - this > 2 x the collector's configured interval.
# TYPE @@NAMESPACE@@_example_last_refresh_timestamp_seconds gauge
@@NAMESPACE@@_example_last_refresh_timestamp_seconds 0
`
	if err := testutil.CollectAndCompare(c, strings.NewReader(expected)); err != nil {
		t.Fatalf("unexpected collecting result:\n%s", err)
	}

	tracker := NewStatusTracker(log)
	tracker.Add("example", c)

	expectedSuccess := `
# HELP ` + statusTrackerSuccessMetric + ` Whether the last scrape of the collector succeeded (1=success, 0=failure)
# TYPE ` + statusTrackerSuccessMetric + ` gauge
` + statusTrackerSuccessMetric + `{collector="example"} 1
`
	if err := testutil.CollectAndCompare(tracker, strings.NewReader(expectedSuccess), statusTrackerSuccessMetric); err != nil {
		t.Fatalf("unexpected collecting result:\n%s", err)
	}
}
```

Note what this file deliberately does NOT declare, mirroring `add-collector.md` §4's exclusion table: no `const statusTrackerSuccessMetric` (reused from the package's pre-existing `collector_test.go`), no `TestExecute_Success`/`TestExecute_CommandNotFound`/`TestCommandDuration_CustomRegistryReachable` (those test the shared `Execute`/`CommandDuration` in `execute.go`, already covered once by the scaffold's default collector's own test file).

- [ ] **Step 2: Instantiate the test template alone into a throwaway scaffold and confirm it fails to compile (RED)**

Run:

```sh
rm -rf test/_work/task4-cli-bg
sh skills/prometheus-exporter/assets/scaffold.sh \
  --src skills/prometheus-exporter/assets --dst test/_work/task4-cli-bg \
  --flavor cli --forge none --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo \
  --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=demo_cli --var DATA_SOURCE_PATH=unused \
  --var DEFAULT_PORT=9999 --var OWNER=acme --var LICENSE=apache-2.0

# Same rename-before-substitute order as Task 3 (@@MODULE_PATH@@ contains
# the substring "example" too).
sed -e 's/example/bg/g' -e 's/Example/Bg/g' \
  skills/prometheus-exporter/assets/code/cli/variants/background_collector_test.go.tmpl \
  > test/_work/task4-cli-bg/internal/collector/bg_test.go.tmp
sed \
  -e 's/@@MODULE_PATH@@/example.com\/demo_exporter/g' \
  -e 's/@@NAMESPACE@@/demo/g' \
  test/_work/task4-cli-bg/internal/collector/bg_test.go.tmp \
  > test/_work/task4-cli-bg/internal/collector/bg_test.go
rm -f test/_work/task4-cli-bg/internal/collector/bg_test.go.tmp
cp skills/prometheus-exporter/assets/code/cli/testdata/example.txt \
  test/_work/task4-cli-bg/internal/collector/testdata/bg.txt

( cd test/_work/task4-cli-bg && go test -race ./internal/collector/ -run 'Bg' -v )
```

Expected: **FAIL** — a build error, since `background_collector.go.tmpl` does not exist yet: `undefined: NewBgCollector` (and similarly `BgCollector`, `parseBg`).

- [ ] **Step 3: Write the implementation template**

Create `skills/prometheus-exporter/assets/code/cli/variants/background_collector.go.tmpl`:

```go
package collector

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"@@MODULE_PATH@@/internal/logger"
)

// exampleMetric is one parsed key/value line from the example data source —
// for example the line "foo 1" parses to {Key: "foo", Value: 1}. This is a
// placeholder shape documenting the pattern, not any real target's real
// output. Replace it, and parseExample below, with your actual data
// source's real parsing logic when adapting this collector.
type exampleMetric struct {
	Key   string
	Value float64
}

// exampleData is this collector's only I/O: it runs the configured command
// and returns its raw output. Kept separate from parsing (parseExample,
// below) so parsing stays pure and unit-testable without running a real
// command. The per-command timeout is applied here, around the single
// Execute call, rather than inside Execute itself — see execute.go's own
// doc comment for why that split is deliberate.
func (c *ExampleCollector) exampleData(ctx context.Context) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	return Execute(ctx, "@@DATA_SOURCE@@")
}

// parseExample decodes exampleData's raw output into one exampleMetric per
// non-blank line. Pure: no I/O, no logging, no side effects, so every input
// maps deterministically to an output — this is what makes it
// unit-testable with plain byte fixtures (see the test file's
// TestParseExample).
//
// The expected shape is one "key value" pair per line, arbitrary
// whitespace-separated, for example:
//
//	foo 1
//	bar 2
//
// Blank lines are skipped. Anything else — a line that isn't exactly two
// whitespace-separated fields, whose second field isn't a number, or whose
// key repeats a key already seen earlier in the same input — is a parse
// error, for the same duplicate-label-set reason documented in the
// synchronous flavor's own parseExample (collector.go.tmpl): refresh, below,
// emits one MustNewConstMetric per entry sharing the same descriptor and
// labeled only by key, so two entries with the same key would produce two
// metrics with an identical label set — something Registry.Gather rejects
// at scrape time. Rejecting the duplicate here, at parse time, keeps that
// failure inside this collector's own refresh, which fails open (logs and
// keeps the previous cache — see refresh's own doc comment) instead of
// surfacing downstream as a Gather error that would blank out every OTHER
// collector's metrics for that scrape too.
func parseExample(b []byte) ([]exampleMetric, error) {
	var metrics []exampleMetric
	seen := make(map[string]struct{})

	scanner := bufio.NewScanner(bytes.NewReader(b))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("parse example line %q: want exactly 2 whitespace-separated fields, got %d", line, len(fields))
		}

		value, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			return nil, fmt.Errorf("parse example line %q: value %q is not a number: %w", line, fields[1], err)
		}

		key := fields[0]
		if _, dup := seen[key]; dup {
			return nil, fmt.Errorf("parse example line %q: duplicate key %q (each key must appear at most once per scrape)", line, key)
		}
		seen[key] = struct{}{}

		metrics = append(metrics, exampleMetric{Key: key, Value: value})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan example output: %w", err)
	}

	return metrics, nil
}

// exampleGetMetrics is the glue between the I/O step (exampleData) and the
// pure parsing step (parseExample): the shape every collector in this
// exporter follows, regardless of flavor. refresh, below, calls this on its
// own background schedule; nothing else in this file runs the command
// directly.
func (c *ExampleCollector) exampleGetMetrics(ctx context.Context) ([]exampleMetric, error) {
	data, err := c.exampleData(ctx)
	if err != nil {
		return nil, err
	}
	return parseExample(data)
}

// ExampleCollector is the background-refresh variant materialized by
// /add-collector --variant background. Unlike the synchronous collector
// (collector.go.tmpl), Collect never runs the command: a background
// goroutine (started by Start, below) refreshes a cached metric slice on a
// fixed interval, and Collect only ever reads that cache under mu. This
// decouples scrape cadence from fetch cadence entirely, so a scrape never
// blocks on a slow or expensive command, no matter how long it takes.
type ExampleCollector struct {
	timeout  time.Duration
	interval time.Duration
	log      *logger.Logger

	entries         *prometheus.Desc
	value           *prometheus.Desc
	lastRefreshDesc *prometheus.Desc

	// mu guards cached and lastRefresh: refresh (below) writes them from the
	// background goroutine started by Start, Collect reads them from
	// whichever goroutine calls it (a Prometheus scrape). RWMutex, not a
	// plain Mutex, because Collect only ever reads.
	mu          sync.RWMutex
	cached      []prometheus.Metric
	lastRefresh time.Time

	// done is closed when the background goroutine launched by Start exits.
	// main.go waits on Done() (via the backgroundCollector seam) after the
	// HTTP server has shut down, so the process doesn't exit mid-refresh.
	done chan struct{}
}

// NewExampleCollector builds the collector and its Descs. It is pure: it
// starts no goroutine and performs no I/O, which is what makes it
// constructible in tests with no background refresh running. Call Start
// once, after construction, to begin refreshing.
func NewExampleCollector(log *logger.Logger, timeout, interval time.Duration) *ExampleCollector {
	return &ExampleCollector{
		timeout:  timeout,
		interval: interval,
		log:      log,
		entries: prometheus.NewDesc(
			"@@NAMESPACE@@_example_entries",
			"Number of key/value entries parsed from the example data source in the last scrape.",
			nil, nil,
		),
		value: prometheus.NewDesc(
			"@@NAMESPACE@@_example",
			"Value reported by the example data source, by key.",
			[]string{"key"}, nil,
		),
		lastRefreshDesc: prometheus.NewDesc(
			"@@NAMESPACE@@_example_last_refresh_timestamp_seconds",
			"Unix time of the last successful example refresh. Alert if time() - this > 2 x the collector's configured interval.",
			nil, nil,
		),
		done: make(chan struct{}),
	}
}

// Start launches the background refresh goroutine. Call once, after
// construction. The first refresh runs immediately (so the cache starts
// filling as soon as the process starts) without Start itself waiting for
// it — a slow first fetch never blocks process startup. The goroutine exits
// when ctx is cancelled; Done() can then be used to wait for it to finish.
func (c *ExampleCollector) Start(ctx context.Context) {
	go func() {
		defer close(c.done)
		c.refresh(ctx)
		ticker := time.NewTicker(c.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				c.refresh(ctx)
			case <-ctx.Done():
				return
			}
		}
	}()
}

// Done returns a channel that is closed when the background goroutine
// started by Start has fully exited. main.go's shutdown seam waits on this
// (bounded, so a stuck refresh can't hang process exit forever) after the
// HTTP server itself has stopped.
func (c *ExampleCollector) Done() <-chan struct{} {
	return c.done
}

// refresh performs the one flavor-specific I/O call (exampleGetMetrics, via
// the package-level Execute) and, on success, atomically replaces the
// cache. On error it logs and returns, leaving the previous cache and
// lastRefresh untouched — fail-open: a transient failure serves the
// last-known-good data instead of dropping the series, and the freshness
// gauge (below) is the signal that a refresh is stale, not a dropped
// scrape.
func (c *ExampleCollector) refresh(ctx context.Context) {
	metrics, err := c.exampleGetMetrics(ctx)
	if err != nil {
		c.log.Error("Failed to refresh example metrics — keeping previous cache", "err", err)
		return
	}

	cached := make([]prometheus.Metric, 0, len(metrics)+1)
	cached = append(cached, prometheus.MustNewConstMetric(c.entries, prometheus.GaugeValue, float64(len(metrics))))
	for _, m := range metrics {
		cached = append(cached, prometheus.MustNewConstMetric(c.value, prometheus.GaugeValue, m.Value, m.Key))
	}

	c.mu.Lock()
	c.cached = cached
	c.lastRefresh = time.Now()
	c.mu.Unlock()
}

// Describe sends every one of this collector's descriptors, including the
// freshness gauge. Constant regardless of scrape or refresh outcome, which
// is what makes prometheus.DescribeByCollect unnecessary here.
func (c *ExampleCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.entries
	ch <- c.value
	ch <- c.lastRefreshDesc
}

// Collect replays the cached metrics from the last successful refresh —
// O(cached size), never runs the command, never blocks on it. It then
// ALWAYS sends the freshness gauge, even before any refresh has ever
// completed (value 0 in that case, since a zero time.Time's Unix() is a
// large negative, not a meaningful "ancient" epoch marker) — see the
// collector-authoring rule in collector.go.tmpl's Collect for why a
// collector must never emit zero metrics on what it considers a healthy
// outcome: StatusTracker counts emitted metrics per scrape, and an empty
// cache before the first refresh completes is a normal startup window, not
// a failure. The freshness gauge alone guarantees at least one metric every
// scrape, so StatusTracker reports this collector as alive; the gauge's own
// value (0 until the first refresh lands) is the separate, correct signal
// for staleness — see NewExampleCollector's lastRefreshDesc help text.
func (c *ExampleCollector) Collect(ch chan<- prometheus.Metric) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	for _, m := range c.cached {
		ch <- m
	}

	refreshUnix := 0.0
	if !c.lastRefresh.IsZero() {
		refreshUnix = float64(c.lastRefresh.Unix())
	}
	ch <- prometheus.MustNewConstMetric(c.lastRefreshDesc, prometheus.GaugeValue, refreshUnix)
}
```

- [ ] **Step 4: Re-instantiate both templates and confirm the test suite passes (GREEN)**

Run:

```sh
sed -e 's/example/bg/g' -e 's/Example/Bg/g' \
  skills/prometheus-exporter/assets/code/cli/variants/background_collector.go.tmpl \
  > test/_work/task4-cli-bg/internal/collector/bg.go.tmp
sed \
  -e 's/@@MODULE_PATH@@/example.com\/demo_exporter/g' \
  -e 's/@@DATA_SOURCE@@/demo_cli/g' \
  -e 's/@@NAMESPACE@@/demo/g' \
  test/_work/task4-cli-bg/internal/collector/bg.go.tmp \
  > test/_work/task4-cli-bg/internal/collector/bg.go
rm -f test/_work/task4-cli-bg/internal/collector/bg.go.tmp

( cd test/_work/task4-cli-bg && go test -race ./internal/collector/ -run 'Bg' -v )
( cd test/_work/task4-cli-bg && go build ./... )
( cd test/_work/task4-cli-bg && go vet ./... )
```

Expected: **PASS** — `TestParseBg`, `TestBgCollector_Describe`, `TestBgCollector_DoneClosesOnCancel`, `TestBgCollector_CollectServesCacheWithoutIO`, `TestBgCollector_ErrorKeepsPreviousCache`, `TestBgCollector_FirstScrapeEmitsFreshnessGaugeZero` all report `--- PASS`, overall `PASS`, `ok`. Then `go build ./...` and `go vet ./...` both exit 0 — proving the whole scaffolded module still compiles cleanly with `bg.go` added as an ordinary `internal/collector/` file (safe to run unrestricted because Task 2 already excludes any `variants/` package from the scaffold).

- [ ] **Step 5: Confirm the pre-existing default collector still passes too, then clean up**

Run:

```sh
( cd test/_work/task4-cli-bg && go test -race ./internal/collector/ -run 'Example' -v )
rm -rf test/_work/task4-cli-bg
```

Expected: **PASS** — the scaffold's own default `ExampleCollector`/parser tests are unaffected.

- [ ] **Step 6: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add skills/prometheus-exporter/assets/code/cli/variants/background_collector.go.tmpl \
        skills/prometheus-exporter/assets/code/cli/variants/background_collector_test.go.tmpl
git -c commit.gpgsign=false commit -m "feat(templates): add the cli background-refresh collector variant"
```

---

### Task 5: `add-collector.md` background branch

**Files:**
- Modify: `commands/add-collector.md` (§0 flavor detection unaffected; new variant-selection block in §2; §3/§4 read-the-right-template branch; §5 flags + registry snippet; §6 docs row)

**Interfaces:**
- Consumes: `New<Name>Collector`/`Start`/`Done`/field names from Tasks 3 and 4 (identical shape, both flavors); the `backgroundCollector`/`backgroundCollectors` seam plus the moved-up `ctx` from Task 1 (`register(...)`'s closure references `ctx` and appends to `backgroundCollectors`, both now in scope at the marker).
- Produces: nothing further downstream in this plan — Task 7's golden sub-check exercises this prose mechanically, by hand-following the same steps this task documents.

The synchronous branch (today's only branch) stays untouched, verbatim — every edit below is an added "**If variant = background:**" branch alongside the existing text, never a replacement of it.

- [ ] **Step 1: Add variant selection to §2 (identity collection)**

Edit `commands/add-collector.md`, inserting this new block into "## 2. Collect the new collector's identity", immediately after the "**Name.**" bullet's validation rules and before "**Idempotent refusal.**":

```markdown
**Variant: synchronous or background.** Two collector shapes exist:
**synchronous** (default — fetches on every scrape) and **background**
(fetches on a fixed interval in a goroutine, serving the last cached result
on every scrape; use when the backend is slow or expensive enough that a
scrape should never wait on it directly — see
`references/exporter-architecture.md`'s background-refresh note). Decide
which applies to this collector before going further:

- If $ARGUMENTS included a trailing `--variant background` token, strip it
  and use the background variant.
- Otherwise ask: "Is this backend slow or expensive enough (seconds per
  call, rate-limited, or otherwise not built for high-frequency polling)
  that it should refresh on a fixed background interval instead of
  synchronously on every scrape?" A "yes" selects the background variant; a
  "no", or no clear signal, selects the synchronous variant (the default).
- If the design brief's `## Architecture decisions` already flagged this
  collector as background-refresh candidate (see `/design-exporter`'s own
  probe), read that back to the user for confirmation rather than asking
  from scratch.
```

- [ ] **Step 2: Branch §3 (materialize the collector file) on the variant**

Edit `commands/add-collector.md`'s "## 3. Materialize the collector file" section, replacing:

```markdown
Read the flavor's template directly — do **not** run `scaffold.sh` against
this repository: it copies a whole tree and expects an empty (or
`--force`-wiped) destination, which would clobber this already-customized
repo's `go.mod`/`Makefile`/`README.md`/etc. wholesale. A single new file is a
plain adaptation, not a re-scaffold.

- http: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/http/collector.go.tmpl`
- cli: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/cli/collector.go.tmpl`
```

with:

```markdown
Read the flavor's template directly — do **not** run `scaffold.sh` against
this repository: it copies a whole tree and expects an empty (or
`--force`-wiped) destination, which would clobber this already-customized
repo's `go.mod`/`Makefile`/`README.md`/etc. wholesale. A single new file is a
plain adaptation, not a re-scaffold.

**Synchronous variant (default):**

- http: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/http/collector.go.tmpl`
- cli: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/cli/collector.go.tmpl`

**Background variant (step 2 selected it):**

- http: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/http/variants/background_collector.go.tmpl`
- cli: `${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/code/cli/variants/background_collector.go.tmpl`

The background variant keeps the same five-piece shape and the same
`example`/`Example` placeholder identifiers as the synchronous template, so
every rename in the table below applies to it unchanged. It additionally
introduces `interval time.Duration` (a new constructor parameter — see step
5's new interval flag), `lastRefreshDesc *prometheus.Desc` (the always-emitted
freshness gauge, metric name literal
`"@@NAMESPACE@@_example_last_refresh_timestamp_seconds"` — rename this
EXACTLY like any other `"@@NAMESPACE@@_..."` literal in the table below;
its `_last_refresh_timestamp_seconds` suffix is a locked, non-negotiable part
of the name, only `example`→`<name>` and `@@NAMESPACE@@` ever change in it),
`Start(ctx context.Context)`, and `Done() <-chan struct{}` — none of which
need a new rename rule beyond the existing `example`→`<name>`/`Example`→`<Name>`
pair, since none of those identifiers contain "example"/"Example" themselves.
`New<Name>Collector` for this variant returns the **concrete** `*<Name>Collector`
(never `prometheus.Collector`) — step 5's registry snippet calls `.Start(ctx)`
on it, which the bare interface does not expose.
```

- [ ] **Step 3: Branch §4 (test triad) on the variant**

Edit `commands/add-collector.md`'s "## 4. Materialize the full test triad + fixture" section, replacing its opening:

```markdown
Read the flavor's test template(s):

- http: `.../code/http/collector_test.go.tmpl` → write `internal/collector/<name>_test.go`
- cli: `.../code/http/collector_test.go.tmpl` **and** `.../code/cli/parser_test.go.tmpl` → merge both into one `internal/collector/<name>_test.go`.
```

with (note: correcting a pre-existing typo in the same edit — the second bullet's first path wrongly says `.../code/http/collector_test.go.tmpl`, it must read `.../code/cli/collector_test.go.tmpl`):

```markdown
Read the flavor's test template(s), choosing the SAME variant step 2 selected
(synchronous or background) — never mix a synchronous collector file with a
background test file or vice versa:

**Synchronous variant (default):**

- http: `.../code/http/collector_test.go.tmpl` → write `internal/collector/<name>_test.go`
- cli: `.../code/cli/collector_test.go.tmpl` **and** `.../code/cli/parser_test.go.tmpl` → merge both into one `internal/collector/<name>_test.go`.

**Background variant (step 2 selected it):**

- http: `.../code/http/variants/background_collector_test.go.tmpl` → write `internal/collector/<name>_test.go`. Already the complete triad in one file (parser test + lifecycle tests) — no separate parser template exists for this variant.
- cli: `.../code/cli/variants/background_collector_test.go.tmpl` → write `internal/collector/<name>_test.go`. Already merged (parser test + lifecycle tests) — do not also read `.../code/cli/parser_test.go.tmpl`, which is the SYNCHRONOUS flavor's separate parser file and would duplicate `TestParse<Name>`.

Either variant:
```

(The word "Either variant:" reconnects to the existing rename-application and shared-declaration-exclusion guidance immediately below it in the file, which needs no further change — the background test templates already follow the same exclusion rule, since Tasks 3/4 wrote them that way.)

- [ ] **Step 4: Add the interval flag and the corrected registry snippet to §5**

Edit `commands/add-collector.md`'s "## 5. Register the collector" section, replacing:

```markdown
Both markers already exist verbatim in `cmd/*/main.go` (they survive
scaffolding for exactly this purpose). Insert **after the last existing line**
of each block — never replace the marker comment itself, and never re-declare
`log`, which the closures below capture by reference:

**http** — after the last existing flag line under `// @@CLIENT_INIT@@`:

```go
<name>Target := kingpin.Flag("collector.<name>.target", "Base URL the <name> collector scrapes.").Default("<base URL from step 1>").String()
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-request timeout for the <name> collector.").Default("5s").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	return collector.New<Name>Collector(log, collector.NewClient(*<name>Target, *<name>Timeout))
}, true)
```

**cli** — after the last existing flag line under `// @@CLIENT_INIT@@`:

```go
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-command timeout for the <name> collector.").Default("5s").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	return collector.New<Name>Collector(log, *<name>Timeout)
}, true)
```

`register()` auto-declares the negatable `--[no-]collector.<name>` flag
(defaulting to enabled) — nothing else to wire for that.

This insertion point is anchor-based (last line of each marker's existing
block), so it works the same way regardless of how many collectors already
exist — it is never specific to "the second collector".
```

with:

```markdown
Both markers already exist verbatim in `cmd/*/main.go` (they survive
scaffolding for exactly this purpose). Insert **after the last existing line**
of each block — never replace the marker comment itself, and never re-declare
`log`, which the closures below capture by reference:

**Synchronous variant (default) — http** — after the last existing flag line
under `// @@CLIENT_INIT@@`:

```go
<name>Target := kingpin.Flag("collector.<name>.target", "Base URL the <name> collector scrapes.").Default("<base URL from step 1>").String()
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-request timeout for the <name> collector.").Default("5s").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	return collector.New<Name>Collector(log, collector.NewClient(*<name>Target, *<name>Timeout))
}, true)
```

**Synchronous variant (default) — cli** — after the last existing flag line
under `// @@CLIENT_INIT@@`:

```go
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-command timeout for the <name> collector.").Default("5s").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	return collector.New<Name>Collector(log, *<name>Timeout)
}, true)
```

**Background variant (step 2 selected it) — http** — after the last existing
flag line under `// @@CLIENT_INIT@@` (the SAME target/timeout flags as the
synchronous branch above, plus one new interval flag):

```go
<name>Target := kingpin.Flag("collector.<name>.target", "Base URL the <name> collector scrapes.").Default("<base URL from step 1>").String()
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-request timeout for the <name> collector.").Default("5s").Duration()
<name>Interval := kingpin.Flag("collector.<name>.interval", "Refresh interval for the <name> collector.").Default("5m").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	<name>Coll := collector.New<Name>Collector(log, collector.NewClient(*<name>Target, *<name>Timeout), *<name>Interval)
	<name>Coll.Start(ctx)
	backgroundCollectors = append(backgroundCollectors, <name>Coll)
	return <name>Coll
}, true)
```

**Background variant (step 2 selected it) — cli** — after the last existing
flag line under `// @@CLIENT_INIT@@`:

```go
<name>Timeout := kingpin.Flag("collector.<name>.timeout", "Per-command timeout for the <name> collector.").Default("5s").Duration()
<name>Interval := kingpin.Flag("collector.<name>.interval", "Refresh interval for the <name> collector.").Default("5m").Duration()
```

then after the last existing `register(...)` call under
`// @@COLLECTOR_REGISTRY@@`:

```go
register("<name>", func() prometheus.Collector {
	<name>Coll := collector.New<Name>Collector(log, *<name>Timeout, *<name>Interval)
	<name>Coll.Start(ctx)
	backgroundCollectors = append(backgroundCollectors, <name>Coll)
	return <name>Coll
}, true)
```

**Why the eager construction, `Start`, and `append` all live INSIDE the
`register(...)` closure, never as bare statements before it:** both markers
sit textually BEFORE `kingpin.Parse()` in `main.go` — `register(...)`'s call
itself must run there (it just stores the closure), but `log` is still `nil`
and every flag pointer (`*<name>Target`, `*<name>Interval`, ...) still holds
its zero value until `kingpin.Parse()` runs, further down. Putting
`<name>Coll := collector.New<Name>Collector(log, ...)` directly at the
marker (outside the closure) would construct the collector with a nil
logger and a zero-value interval — silently broken. Wrapping construction,
`Start(ctx)`, and the `backgroundCollectors` append inside the closure
(which Go closures capture by reference) defers all of it to the registry
loop later in `main()`, which runs AFTER `kingpin.Parse()` and after `log`
is assigned — exactly how the existing synchronous closures above already
behave, and how `main.go`'s own `backgroundCollectors` seam (Task 1) expects
to be populated. `ctx` and `backgroundCollectors` are both declared up-front,
right after `var log` and BEFORE these two markers (Task 1's seam), precisely
so this closure can capture them; the closure only *dereferences* `ctx` (in
`Start(ctx)`) at invocation time, long after `kingpin.Parse()`, exactly as it
does `log`. (In the pristine `main.go.tmpl`, `ctx` used to be declared far
below these markers in the shutdown block — Task 1 moved it up for exactly
this reason: a Go closure cannot close over a name declared textually after
it.)

`register()` auto-declares the negatable `--[no-]collector.<name>` flag
(defaulting to enabled) — nothing else to wire for that, in either variant.

This insertion point is anchor-based (last line of each marker's existing
block), so it works the same way regardless of how many collectors already
exist — it is never specific to "the second collector".
```

- [ ] **Step 5: Note the freshness-gauge row in §6 (docs/metrics.md)**

Edit `commands/add-collector.md`'s "## 6. Update `docs/metrics.md`" section, appending this paragraph immediately after its existing table-format example:

```markdown
**Background variant only:** add one further row for the always-emitted
freshness gauge, using its exact, locked name and help text (see step 3's
note on why this metric name is not user-chosen):

```markdown
| `<namespace>_<name>_last_refresh_timestamp_seconds` | Gauge | - | Unix time of the last successful <name> refresh. Alert if time() - this > 2 x the collector's configured interval. |
```
```

- [ ] **Step 6: `claude plugin validate .`**

Run: `claude plugin validate .`
Expected: validation success (no manifest/command-loading errors).

- [ ] **Step 7: Zero-source gate**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

This task's own prose has no automated behavioral test of its own — `add-collector.md` is a Markdown instruction file the model executes, not a program with a test harness. Its correctness is proven end-to-end by Task 7's golden sub-check, which mechanically follows exactly these steps (materialize, rename, splice, document, build, docs-check) against a real scaffold.

- [ ] **Step 8: Commit**

```bash
git add commands/add-collector.md
git -c commit.gpgsign=false commit -m "feat(command): add a --variant background branch to /add-collector"
```

---

### Task 6: design-time discoverability probe

**Files:**
- Modify: `commands/design-exporter.md` (§3, decision 4 of the six)
- Modify: `skills/prometheus-exporter/references/exporter-architecture.md` (§4 "Collector decomposition"; "Output of this phase" checklist)
- Modify: `skills/prometheus-exporter/SKILL.md` (§0 "Architecture design first")

**Interfaces:**
- Consumes: nothing from earlier tasks — this is discovery-phase prose, independent of the templates.
- Produces: nothing downstream in this plan; the design brief's free-form `## Architecture decisions` prose is read by a human/maintainer running `/add-collector --variant background` afterward, not parsed by any script.

All edits are additive prose. The brief's frozen 4-header contract (`## Provenance`, `## Architecture decisions`, `## Scaffold inputs`, `## Open questions / assumptions`) is untouched — the background-refresh probe is recorded as more free-form prose under the EXISTING `## Architecture decisions` header, never a new header or a new `## Scaffold inputs` key.

- [ ] **Step 1: `design-exporter.md` — extend decision 4 (collector list)**

Edit `commands/design-exporter.md`'s "## 3. Confirm the six architecture decisions with the user" section, replacing:

```markdown
4. **Collector list**, one resource per collector, in the order they will
   be built.
```

with:

```markdown
4. **Collector list**, one resource per collector, in the order they will
   be built. For each collector on this list, also ask: is this data source
   slow or expensive enough (seconds per call, rate-limited, or otherwise
   not built for high-frequency polling) that it should refresh on a fixed
   background interval instead of synchronously on every scrape? Do not
   wait for the user to raise this — ask proactively if nothing so far has
   signalled it. A "yes" is recorded here, under this same decision, and
   becomes the signal for `/add-collector --variant background <name>` once
   scaffolding begins.
```

- [ ] **Step 2: `exporter-architecture.md` — extend §4 "Collector decomposition"**

Edit `skills/prometheus-exporter/references/exporter-architecture.md`'s "## 4. Collector decomposition" section, appending this paragraph after its existing bullets and before the "A resource that genuinely needs several independent fetches..." paragraph:

```markdown
For each collector, also decide whether its backend is slow or expensive
enough (seconds per call, a rate limit, or a device not built for
high-frequency polling — the kind of backend a scrape should never wait on)
to warrant refreshing on a fixed background interval instead of
synchronously on every scrape. This is `/add-collector`'s
`--variant background` — see `collector-pattern.md` for the shape once the
collector list reaches this one. Most collectors do not need it; a fast,
cheap REST endpoint or CLI call should stay synchronous, the simpler
default.
```

- [ ] **Step 3: `exporter-architecture.md` — extend the "Output of this phase" checklist**

Edit the same file's "## Output of this phase" section, replacing:

```markdown
- [ ] **Collector list**, one resource per collector, in the order
      `/add-collector` will work through them.
```

with:

```markdown
- [ ] **Collector list**, one resource per collector, in the order
      `/add-collector` will work through them.
- [ ] **Background-refresh candidates** flagged, per collector, if any
      backend is slow/expensive enough that a scrape should never wait on
      it directly.
```

- [ ] **Step 4: `SKILL.md` — one-line pointer in step 0**

Edit `skills/prometheus-exporter/SKILL.md`'s "### 0. Architecture design first (API-first)" section, replacing:

```markdown
Decompose the target into one collector per resource, and set a cardinality
budget — which
labels, how many series, what flags will cap them — before writing a line
of code. Output: the I/O flavor (`http`, the default, or `cli`) and the
ordered collector list step 3 works through.
```

with:

```markdown
Decompose the target into one collector per resource, and set a cardinality
budget — which
labels, how many series, what flags will cap them — before writing a line
of code. For any collector whose backend is slow or expensive enough that a
scrape should never wait on it, flag it now for `/add-collector --variant
background` later — see `references/exporter-architecture.md`. Output: the
I/O flavor (`http`, the default, or `cli`) and the ordered collector list
step 3 works through.
```

- [ ] **Step 5: `claude plugin validate .`, zero-source gate, and the brief-format regression guard**

Run:

```sh
claude plugin validate .
bash test/zero-source-grep.sh
for header in '## Provenance' '## Architecture decisions' '## Scaffold inputs' '## Open questions'; do
  command grep -qF "$header" test/fixtures/exporter-design-brief.md && echo "OK: $header" || echo "FAIL: $header"
done
```

Expected: `claude plugin validate .` succeeds; `zero-source-grep.sh: PASS`; four `OK:` lines and zero `FAIL:` lines — proving this task's prose-only edits left the frozen brief-format fixture, and the golden check that guards it, untouched.

- [ ] **Step 6: Commit**

```bash
git add commands/design-exporter.md \
        skills/prometheus-exporter/references/exporter-architecture.md \
        skills/prometheus-exporter/SKILL.md
git -c commit.gpgsign=false commit -m "docs(skill): ask about background-refresh candidates during architecture design"
```

---

### Task 7: `golden-smoke.sh` extension

**Files:**
- Modify: `test/golden-smoke.sh` (the existing http/none mechanical `/add-collector` sub-check, ~lines 681-797)

**Interfaces:**
- Consumes: `code/http/variants/background_collector.go.tmpl` (Task 3); the `backgroundCollector`/`backgroundCollectors` seam, the moved-up `ctx`, and the `// @@CLIENT_INIT@@`/`// @@COLLECTOR_REGISTRY@@` markers (Task 1); the corrected closure-based registry snippet documented in Task 5, Step 4.
- Produces: nothing downstream — this is the plan's own end-to-end proof, run once as its own task.

This extends the SAME `if [ "$flavor" = http ] && [ "$forge" = none ]; then ... fi` block the existing "queue" sub-check already occupies, adding a SECOND mechanically-added collector, named **"tape"** after this epic's own driving case (the design doc's IBM TS4500 tape library) — deliberately distinct from "queue" so the two sub-checks never collide on an identifier or a metric name in the same package. Same rename-before-`@@VAR@@`-substitution ordering discipline the existing queue sub-check already established (see its own header comment).

- [ ] **Step 1: Add the background sub-check, immediately after the existing queue sub-check**

Edit `test/golden-smoke.sh`, replacing:

```sh
  echo "== add-collector sub-check: make build ($flavor/$forge) =="
  if ! ( cd "$work" && make build ); then
    die "add-collector sub-check: make build FAILED after mechanically adding queue — a template/marker change likely broke /add-collector ($flavor/$forge)"
  fi

  echo "== add-collector sub-check: make docs-check ($flavor/$forge) =="
  if ! ( cd "$work" && make docs-check ); then
    die "add-collector sub-check: make docs-check FAILED after mechanically adding queue — docs/metrics.md and internal/collector/queue.go disagree ($flavor/$forge)"
  fi
  echo "confirmed: add-collector sub-check PASSED ($flavor/$forge)"
fi
```

with:

```sh
  echo "== add-collector sub-check: make build ($flavor/$forge) =="
  if ! ( cd "$work" && make build ); then
    die "add-collector sub-check: make build FAILED after mechanically adding queue — a template/marker change likely broke /add-collector ($flavor/$forge)"
  fi

  echo "== add-collector sub-check: make docs-check ($flavor/$forge) =="
  if ! ( cd "$work" && make docs-check ); then
    die "add-collector sub-check: make docs-check FAILED after mechanically adding queue — docs/metrics.md and internal/collector/queue.go disagree ($flavor/$forge)"
  fi
  echo "confirmed: add-collector sub-check PASSED ($flavor/$forge)"

  # Background-refresh collector epic (docs/plans/2026-07-06-background-
  # refresh-collector.md, Task 7): extend this SAME http/none /add-collector
  # sub-check to ALSO mechanically exercise the NEW --variant background
  # branch, right after the synchronous "queue" sub-check above. Named
  # "tape" after this epic's own driving case
  # (docs/design/2026-07-06-background-refresh-collector-design.md's IBM
  # TS4500 tape library) — deliberately distinct from "queue" above, so the
  # two mechanical sub-checks never collide on an identifier or a metric
  # name in the same package. Same rename-before-substitute ordering
  # discipline as the queue sub-check above (see its own comment for why:
  # @@MODULE_PATH@@'s value contains the substring "example" too).
  echo "== mechanical /add-collector --variant background sub-check ($flavor/$forge): background template compiles and wires into the Done() seam =="
  addc_bg_tmpl="$assets/code/http/variants/background_collector.go.tmpl"
  addc_bg_main="$work/cmd/demo_exporter/main.go"
  addc_bg_metrics_doc="$work/docs/metrics.md"
  addc_bg_client="$work/internal/collector/.addc_bg_client_init.frag.tmp"
  addc_bg_registry="$work/internal/collector/.addc_bg_registry.frag.tmp"

  [ -f "$addc_bg_tmpl" ] || die "background collector template missing: $addc_bg_tmpl"

  # 1. Materialize tape.go: identical rename-then-substitute order as queue
  # above.
  sed \
    -e 's/@@NAMESPACE@@_items/@@NAMESPACE@@_tape_items/' \
    -e 's/@@NAMESPACE@@_healthy/@@NAMESPACE@@_tape_healthy/' \
    -e 's/example/tape/g' \
    -e 's/Example/Tape/g' \
    "$addc_bg_tmpl" > "$work/internal/collector/tape.go.tmp"
  sed \
    -e 's/@@MODULE_PATH@@/example.com\/demo_exporter/g' \
    -e 's/@@DATA_SOURCE_PATH@@/\/api\/tape/g' \
    -e 's/@@NAMESPACE@@/demo/g' \
    "$work/internal/collector/tape.go.tmp" > "$work/internal/collector/tape.go"
  rm -f "$work/internal/collector/tape.go.tmp"

  # 2. Flags under // @@CLIENT_INIT@@ (target, timeout, interval) — the
  # SAME marker the queue sub-check already injected into above; the marker
  # comment itself survives every previous injection (see scaffold.sh's own
  # comment on why), so it is still there to reuse.
  cat > "$addc_bg_client" <<'EOF'
	tapeTarget := kingpin.Flag("collector.tape.target", "Base URL the tape collector scrapes.").Default("http://localhost:9999").String()
	tapeTimeout := kingpin.Flag("collector.tape.timeout", "Per-request timeout for the tape collector.").Default("5s").Duration()
	tapeInterval := kingpin.Flag("collector.tape.interval", "Refresh interval for the tape collector.").Default("5m").Duration()
EOF
  grep -q '^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$' "$addc_bg_main" || die "add-collector background sub-check: no standalone // @@CLIENT_INIT@@ marker in $addc_bg_main"
  sed -e '\|^[[:blank:]]*// @@CLIENT_INIT@@[[:blank:]]*$|r '"$addc_bg_client" "$addc_bg_main" > "$addc_bg_main.tmp" && mv "$addc_bg_main.tmp" "$addc_bg_main"
  rm -f "$addc_bg_client"

  # 3. Registry snippet under // @@COLLECTOR_REGISTRY@@: eager-construct +
  # Start(ctx) + append(backgroundCollectors, ...) ALL INSIDE the
  # register(...) closure (see commands/add-collector.md §5's own note on
  # why: this splice point sits BEFORE kingpin.Parse() in main.go, so log
  # is still nil and every flag pointer still holds its zero value there —
  # the closure defers all of this to the registry loop later in main(),
  # which runs after Parse() and after log is assigned).
  cat > "$addc_bg_registry" <<'EOF'
	register("tape", func() prometheus.Collector {
		tapeColl := collector.NewTapeCollector(log, collector.NewClient(*tapeTarget, *tapeTimeout), *tapeInterval)
		tapeColl.Start(ctx)
		backgroundCollectors = append(backgroundCollectors, tapeColl)
		return tapeColl
	}, true)
EOF
  grep -q '^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$' "$addc_bg_main" || die "add-collector background sub-check: no standalone // @@COLLECTOR_REGISTRY@@ marker in $addc_bg_main"
  sed -e '\|^[[:blank:]]*// @@COLLECTOR_REGISTRY@@[[:blank:]]*$|r '"$addc_bg_registry" "$addc_bg_main" > "$addc_bg_main.tmp" && mv "$addc_bg_main.tmp" "$addc_bg_main"
  rm -f "$addc_bg_registry"

  # Regression-lock, mirroring the queue sub-check's own exact-count guard
  # above: an unanchored marker match would ALSO splice into register()'s
  # own doc-comment prose mention of // @@COLLECTOR_REGISTRY@@.
  addc_bg_regcount=$(grep -c 'register("tape"' "$addc_bg_main")
  [ "$addc_bg_regcount" -eq 1 ] || die "add-collector background sub-check: expected exactly 1 injected register(\"tape\" call, found $addc_bg_regcount ($flavor/$forge)"
  addc_bg_clientcount=$(grep -c 'tapeTarget := kingpin.Flag' "$addc_bg_main")
  [ "$addc_bg_clientcount" -eq 1 ] || die "add-collector background sub-check: expected exactly 1 injected client_init copy, found $addc_bg_clientcount ($flavor/$forge)"

  # 4. docs/metrics.md row, including the freshness gauge — the metric
  # Decision 4/6 of the background-refresh design exist for.
  cat >> "$addc_bg_metrics_doc" <<'EOF'

## TapeCollector

Defined in `internal/collector/tape.go`.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `demo_tape_items` | Gauge | - | Number of items reported by the tape target. |
| `demo_tape_healthy` | Gauge | - | Whether the tape target reports itself healthy (1) or not (0). |
| `demo_tape_last_refresh_timestamp_seconds` | Gauge | - | Unix time of the last successful tape refresh. Alert if time() - this > 2 x the collector's configured interval. |
EOF

  echo "== add-collector background sub-check: make build ($flavor/$forge) =="
  if ! ( cd "$work" && make build ); then
    die "add-collector background sub-check: make build FAILED after mechanically adding tape — the background template or the Done() seam likely broke ($flavor/$forge)"
  fi

  echo "== add-collector background sub-check: make docs-check ($flavor/$forge) =="
  if ! ( cd "$work" && make docs-check ); then
    die "add-collector background sub-check: make docs-check FAILED after mechanically adding tape — docs/metrics.md and internal/collector/tape.go disagree ($flavor/$forge)"
  fi
  echo "confirmed: add-collector background sub-check PASSED ($flavor/$forge)"
fi
```

- [ ] **Step 2: Run the extended golden cell**

Run: `bash test/golden-smoke.sh --flavor http --forge none`
Expected: every existing sub-check still prints `confirmed:`/`PASS` as before, the new sub-check prints `== mechanical /add-collector --variant background sub-check ...`, `confirmed: add-collector background sub-check PASSED (http/none)`, and the whole script ends `golden-smoke.sh: PASS — http/none scaffold + build + check green`.

- [ ] **Step 3: Run the full matrix to confirm no other cell regressed**

Run: `bash test/golden-smoke.sh --all`
Expected: `golden-smoke.sh --all: PASS - all 4 matrix cells green` (the new sub-check only runs for the `http/none` cell, per its own existing `if [ "$flavor" = http ] && [ "$forge" = none ]` guard — the other three cells are unaffected by this task and must stay green exactly as before).

- [ ] **Step 4: Zero-source gate, then commit**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

```bash
git add test/golden-smoke.sh
git -c commit.gpgsign=false commit -m "test(golden): exercise /add-collector --variant background end to end"
```

---

### Task 8: docs + CHANGELOG + ROADMAP

**Files:**
- Modify: `CHANGELOG.md` (the `## [Unreleased]` section)
- Modify: `ROADMAP.md` (the v0.2 list)

**Interfaces:** none — pure bookkeeping prose, consumed by nothing else in this plan.

No flavor's `metrics.md.tmpl` needs a change: the design's own Template Surface list does not include either `metrics.md.tmpl`, because a background collector is never the scaffold's default starter collector — it is always an ADDITIONAL collector added later via `/add-collector --variant background`, whose own `docs/metrics.md` row (including the freshness gauge) is already covered by Task 5's §6 edit and proven end-to-end by Task 7. This task is CHANGELOG/ROADMAP bookkeeping only.

- [ ] **Step 1: Add the `CHANGELOG.md` entry**

Edit `CHANGELOG.md`, replacing:

```markdown
## [Unreleased]

### Added

- **`/design-exporter <target>`** — runs the step-0 architecture-design phase
  with broadened discovery (a preference-ordered ladder: local API spec >
  docs folder/URL > context7 > dialogue, with graceful degradation) and writes
  a reviewable architecture brief.
- **`references/discovery-inputs.md`** — the discovery input taxonomy, the
  degradation ladder, per-source extraction methods, and the architecture-brief
  format.
- **`/new-prometheus-exporter` consumes an architecture brief** when one is
  present (`./exporter-design-brief.md` or a named path), pre-filling step-0
  decisions and step-1 variables; with no brief it stays fully interactive.
```

with:

```markdown
## [Unreleased]

### Added

- **`/design-exporter <target>`** — runs the step-0 architecture-design phase
  with broadened discovery (a preference-ordered ladder: local API spec >
  docs folder/URL > context7 > dialogue, with graceful degradation) and writes
  a reviewable architecture brief.
- **`references/discovery-inputs.md`** — the discovery input taxonomy, the
  degradation ladder, per-source extraction methods, and the architecture-brief
  format.
- **`/new-prometheus-exporter` consumes an architecture brief** when one is
  present (`./exporter-design-brief.md` or a named path), pre-filling step-0
  decisions and step-1 variables; with no brief it stays fully interactive.
- **`/add-collector --variant background`** — scaffolds a collector that
  refreshes its cache on a fixed interval (default `5m`) in a background
  goroutine instead of on the scrape's critical path, for a backend too slow
  or expensive to hit on every scrape (both HTTP and CLI flavors). Ships an
  always-emitted `<namespace>_<name>_last_refresh_timestamp_seconds`
  freshness gauge (`0` before the first successful refresh) and fails open
  on a refresh error (serves the previous cache, logs, retries next tick).
  `main.go` gains a generic, dormant `Done()`-wait shutdown seam
  (`backgroundCollectors`) that every scaffolded exporter ships from `/new`
  on, populated only once a background collector is actually added. The
  architecture-design phase (`/design-exporter`, and the `prometheus-exporter`
  skill's step 0) now proactively asks whether any collector's backend is
  slow/expensive enough to warrant this.
```

- [ ] **Step 2: Update `ROADMAP.md`**

Edit `ROADMAP.md`, replacing:

```markdown
- Cache and background-refresh collector variants.
```

with:

```markdown
- **Background-refresh collector variant** *(delivered, unreleased)*:
  `/add-collector --variant background` scaffolds a collector that refreshes
  its cache on a fixed interval in a background goroutine instead of on the
  scrape's critical path, so a slow or expensive backend (the driving case:
  a legacy device with a seconds-per-call interface) never blocks a scrape.
  The architecture-design phase now proactively asks whether any collector
  needs this. The lazy TTL-cache variant (refetch inline when stale, no
  goroutine — a legitimate, simpler pattern that does not give the same
  "scrape never blocks" guarantee) remains a fast-follow, not built here.
```

- [ ] **Step 3: Zero-source gate**

Run: `bash test/zero-source-grep.sh`
Expected: `zero-source-grep.sh: PASS`

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md ROADMAP.md
git -c commit.gpgsign=false commit -m "docs(changelog): record the background-refresh collector epic"
```

---

## Self-Review

**1. Spec coverage** — every design decision maps to a task:

- Decision 1 (per-collector, `/add-collector`-time selection, synchronous stays default) → Task 5, Step 1 (variant question) + Step 2/3 (byte-identical synchronous branch preserved, background as an added branch).
- Decision 2 (both flavors, one flavor-specific I/O line) → Tasks 3 and 4 (identical shape, `c.client.Fetch` vs `Execute` is the only `refresh`-internal difference).
- Decision 3 (dormant `Done()` seam + closure-wrapped registry snippet) → Task 1 (the seam, with `ctx` moved up-front) + Task 5 Step 4 (the registry snippet, corrected to wrap eager-construct/`Start`/`append` inside the closure — see the judgment call below) + Task 7 (exercised end-to-end).
- Decision 4 (always-emit freshness gauge, decoupled from `StatusTracker` success) → Tasks 3/4's `Collect` implementation + the `_FirstScrapeEmitsFreshnessGaugeZero` test (asserts both the gauge value AND `StatusTracker` success=1).
- Decision 5 (fail-open on refresh error) → Tasks 3/4's `refresh` implementation + the `_ErrorKeepsPreviousCache` test.
- Decision 6 (freshness gauge name + help text) → Tasks 3/4's `lastRefreshDesc` construction; Task 5 Step 2's note that the name is locked, not user-chosen; Task 7's docs row.
- Decision 7 (`--collector.<name>.interval`, default `5m`, no lookback flag) → Task 5 Step 4's flag declarations (both flavors); Task 7's `tapeInterval` flag.
- Decision 8 (design-time proactive probe) → Task 6 (all three files).
- Template Surface (4 new files, `scaffold.sh`/`main.go.tmpl`/`add-collector.md`/`design-exporter.md`/`exporter-architecture.md`/`SKILL.md` modified, `metrics.md.tmpl`/synchronous `collector.go.tmpl` NOT modified) → Tasks 1-6 exactly, Task 8's own note on why `metrics.md.tmpl` needs nothing.
- Testing section (lifecycle tests, golden smoke extension, `make race` coverage via `-race` in every `go test` command, no live-binary SIGTERM test) → Tasks 3/4 (tests + `-race` flag throughout), Task 7 (golden), no task adds a live-binary signal test (explicitly out of scope per the spec's own Non-goals).
- Non-goals (lazy TTL cache, fully automatic brief→scaffold, live-binary signal test) → none of the 8 tasks build any of these; Task 8's ROADMAP wording explicitly names the lazy cache as a fast-follow, not delivered here.

**2. Placeholder scan** — searched this plan for "TBD", "add error handling", "similar to Task", "handle edge cases", and bare prose describing code without showing it. None found: every code step above shows complete file contents or complete diffs (old/new pairs), every shell step shows the literal command and a concrete expected output, and Tasks 3/4's two background-collector templates appear in full in both tasks (not cross-referenced as "same as Task 3").

**3. Type/name consistency across Tasks 1, 3, 4, 5** (the seam this whole plan hinges on):

| Symbol | Task 1 (`main.go.tmpl`) | Task 3 (http template) | Task 4 (cli template) | Task 5 (prose) | Task 7 (golden) |
|---|---|---|---|---|---|
| Shutdown interface | `type backgroundCollector interface{ Done() <-chan struct{} }` | satisfied structurally by `func (c *ExampleCollector) Done() <-chan struct{}` | same | referenced, not redeclared | n/a |
| Signal context | `ctx, stop := signal.NotifyContext(...)` declared **before** the markers (moved up from the shutdown block) | n/a | n/a | closure calls `<name>Coll.Start(ctx)`, capturing that up-front `ctx` | closure calls `tapeColl.Start(ctx)` |
| Registry slice | `var backgroundCollectors []backgroundCollector` (before the markers) | n/a | n/a | `backgroundCollectors = append(backgroundCollectors, <name>Coll)` inside the closure | `backgroundCollectors = append(backgroundCollectors, tapeColl)` |
| Constructor | n/a | `func NewExampleCollector(log *logger.Logger, client *Client, interval time.Duration) *ExampleCollector` | `func NewExampleCollector(log *logger.Logger, timeout, interval time.Duration) *ExampleCollector` | `collector.New<Name>Collector(log, collector.NewClient(*<name>Target, *<name>Timeout), *<name>Interval)` (http) / `collector.New<Name>Collector(log, *<name>Timeout, *<name>Interval)` (cli) | `collector.NewTapeCollector(log, collector.NewClient(*tapeTarget, *tapeTimeout), *tapeInterval)` |
| Lifecycle | `Start(ctx context.Context)` / `Done() <-chan struct{}` | same signatures | same signatures | `<name>Coll.Start(ctx)` | `tapeColl.Start(ctx)` |
| Cache fields | n/a | `mu sync.RWMutex`, `cached []prometheus.Metric`, `lastRefresh time.Time`, `lastRefreshDesc *prometheus.Desc`, `done chan struct{}` | identical field names | field names referenced in prose match | n/a (opaque via `.Start`/registration) |
| Freshness metric | n/a | `"@@NAMESPACE@@_example_last_refresh_timestamp_seconds"` | same literal | "locked... only `example`→`<name>` and `@@NAMESPACE@@` ever change" | `demo_tape_last_refresh_timestamp_seconds` (after `example`→`tape`, `@@NAMESPACE@@`→`demo`) |

All consistent. One inconsistency in the SOURCE BRIEF was caught and resolved rather than propagated: the brief's "EXACT BACKGROUND COLLECTOR SHAPE" section names the timestamp field `lastRefreshAt` and the Desc field `lastRefresh`, while its own Global Constraints line and its own `Collect(ch)` bullet instead say `lastRefresh time.Time` and `c.lastRefreshDesc` respectively — three different spellings for two fields. This plan follows the Global Constraints wording plus the reference implementation (`sacct_efficiency.go`'s own `lastRefresh time.Time` / `lastRefreshDesc *prometheus.Desc`) as the tie-break, and uses `lastRefresh`/`lastRefreshDesc` uniformly in Tasks 3, 4, and every cross-reference in Tasks 5 and 7.

A second, more consequential correction: the brief's Decision-3 registry snippet shows `<name>Coll := collector.New<Name>Collector(...)`, `.Start(ctx)`, and `backgroundCollectors = append(...)` as bare statements BEFORE the `register("<name>", func() {...}, true)` call. Read literally, that places construction before `kingpin.Parse()` (both markers in `main.go.tmpl` sit before `Parse()`), which would build the collector with a `nil` logger and zero-value flags. The reference's own `main.go` (`collectorConstructors["sacct_efficiency"] = func(l *logger.Logger) prometheus.Collector { c := ...; c.Start(ctx); ...; return c }`) does NOT do this — it wraps construction and `Start` inside the deferred closure. This plan follows the reference's actual (working) shape in Tasks 5 and 7, not the brief's literal snippet.

A third correction, from controller review: the pristine `main.go.tmpl` declares `ctx` far BELOW the `// @@COLLECTOR_REGISTRY@@` marker (in the shutdown block, ~line 179), but Task 5 splices a `register(...)` closure AT that marker (~line 99) that captures `ctx`. A Go closure cannot close over a name declared textually after it, so a naive port compiles with `undefined: ctx` / `undefined: backgroundCollectors` the moment a background collector is added. **Task 1 resolves this by moving `ctx, stop := signal.NotifyContext(...)` and the `backgroundCollectors` slice up to immediately after `var log`, before both markers** — mirroring how `log` itself is already declared before the markers and only dereferenced post-`Parse()`. The shutdown block keeps `server`, its shutdown goroutine, and the error-path `stop()`, all referencing the now-earlier `ctx` unchanged.

A fourth, ordering correction, also from controller review: the `scaffold.sh` "never ship `variants/`" exclusion (**Task 2**) is sequenced BEFORE the template-creation tasks (Tasks 3/4), not after. This eliminates a broken intermediate state — had the templates landed first, a plain `/new` scaffold would ship an orphaned `internal/collector/variants/` package that fails `go build ./...`. With the exclusion already in place, Tasks 3/4 each run an unrestricted `go build ./...` / `go vet ./...` on a fresh scaffold as extra proof, with no orphaned package to trip over. Task 2 proves its exclusion with a throwaway stub file (the real templates do not exist yet), created and removed within the task.

## Execution Handoff

Plan complete and saved to `docs/plans/2026-07-06-background-refresh-collector.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
