# `/add-collector` on multi-target scaffolds: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen the multi-target probe seam from one collector to N, give every
collector a context that can actually be cancelled, add a `module` query
parameter that selects a subset of collectors per probe, and teach
`/add-collector` to work on a multi-target scaffold.

**Architecture:** The probe `Handler` stops holding a single `Factory` and holds
an ordered slice of `NamedFactory`. Each factory receives the probe's real
deadline as a `context.Context`, injected into the collector's constructor
because `prometheus.Collector.Collect(ch)` takes no context of its own. A
repeatable `--probe.module` flag maps module names to collector-name lists,
validated at startup, selected per request. `/add-collector` gains a shape
check that migrates a v0.3.0 scaffold's probe seam before appending a factory.

**Tech Stack:** Go 1.2x, `prometheus/client_golang`, `alecthomas/kingpin/v2`,
POSIX shell (`scaffold.sh` and the `test/` harness). No new dependency.

**Spec:** `docs/design/2026-07-12-add-collector-multi-target-design.md`

## Global Constraints

These bind every task. They are not optional and not negotiable.

- **No AI or automation attribution in any git artifact.** No
  `Co-authored-by: Claude`, no `Claude-Session:` trailer, no "Generated with",
  no `claude.ai` link, in any commit message or PR body.
- **Commit with `git -c commit.gpgsign=false commit …`.**
- **`test/zero-source-grep.sh` must pass before every commit.** Hard gate. It
  forbids the words `slurm` / `sacct` outside `docs/`, `test/`, root files and
  the root `.github/`, and forbids the maintainer handle under `skills/`,
  `commands/`, `agents/`.
- **Conventional Commits with a scope**: `feat(templates):`, `fix(probe):`,
  `docs(command):`, `test(golden):`.
- **English for every shipped artifact**: `SKILL.md`, `references/`, `assets/`
  templates, `commands/`, `agents/`, root `README.md` / `CLAUDE.md`.
- **The [G]/[S] discipline**: templates carry only the generic shape. Anything
  exporter-specific is a `@@VAR@@`. Never bake a concrete namespace, endpoint,
  or metric name into a shipped template.
- **No dead code.** Do not add a parameter, field, or template that nothing
  reads. This is why the background collector variants are deliberately left
  alone (see the note at the end of the spec's §4).
- **Single-target behavior does not change.** Single passes
  `context.Background()`, which is exactly the value `Collect` mints for itself
  today. The constructor grows an argument; the code that runs is identical.
  The golden cells for `{http,cli}x{none,github}` are the proof obligation.
- **`claude plugin validate .` must pass** before any commit that touches
  `commands/`, `agents/`, `skills/`, or the manifest.

## Where the work happens

Everything under `skills/prometheus-exporter/assets/` is a **template shipped
into every generated exporter**. It is never compiled in this repository. Go
code in `assets/` is only ever type-checked by scaffolding a real exporter and
running `make check` inside it, which is what `test/golden-smoke.sh` does. So:

- **`go build` / `go test` in the plugin repo proves nothing.** There is no Go
  module here.
- The only real compiler feedback is `bash test/golden-smoke.sh --flavor http
  --forge none --target-model multi`, which scaffolds into `test/_work/` and
  runs `make build` + `make check` there.
- That command needs a Go toolchain. It is slow (a minute or two). Run it at the
  end of every task that touches a `.tmpl` or a `.frag`.

## File structure

### Multi-target only

| File | Responsibility after this plan |
|---|---|
| `assets/internal/probe/probe.go.tmpl` | `NamedFactory`, `Handler.factories`, the probe deadline, `probe_timeout_seconds`, module parsing/validation/selection, the `ServeHTTP` loop |
| `assets/internal/probe/probe_test.go.tmpl` | N factories, the real-deadline regression test, the timeout calculation, module semantics |
| `assets/mains/multi/main.go.tmpl` | `var factories`, `--probe.timeout`, `--probe.timeout-offset`, `--probe.module`, fail-fast startup validation |
| `assets/code/http/wiring/probe_factory.frag` | an `append` to `factories`, so N of them stack at the marker |

### Shared by both target models

| File | Responsibility after this plan |
|---|---|
| `assets/code/http/collector.go.tmpl` | constructor takes `ctx`; `Collect` uses `c.ctx` |
| `assets/code/cli/collector.go.tmpl` | same |
| `assets/code/http/collector_test.go.tmpl` | the new constructor argument |
| `assets/code/cli/collector_test.go.tmpl` | same |
| `assets/code/http/wiring/registry.frag` | passes `context.Background()` |
| `assets/code/cli/wiring/registry.frag` | same |

### Deliberately NOT touched

`assets/code/{http,cli}/variants/background_collector*.tmpl`. A background
collector's `Collect` reads a cache under a mutex and never calls
`context.Background()`; its I/O runs in `refresh(ctx)` driven by `Start(ctx)`,
which already carries `main`'s real shutdown context. It has a live context
already. Adding a constructor `ctx` there would be a field nothing reads.

### Plugin knowledge and tests (never shipped)

`commands/add-collector.md`, `skills/prometheus-exporter/references/exporter-architecture.md`,
`ROADMAP.md`, `CHANGELOG.md`, `test/scaffold_multitarget_test.sh`,
`test/golden-smoke.sh`.

---

### Task 1: Inject a real context into the standard collector constructors

Behavior-preserving refactor. `NewExampleCollector` grows a leading `ctx`
argument and stores it; `Collect` reads `c.ctx` instead of minting
`context.Background()`. Every call site passes `context.Background()`, so the
code that runs is byte-for-byte what runs today. Nothing gains a deadline yet.
This task exists on its own so that the reviewer can confirm "nothing changed
at runtime" without also reasoning about the probe seam.

**Files:**
- Modify: `skills/prometheus-exporter/assets/code/http/collector.go.tmpl` (struct at 57-62, constructor at 66, `Collect` at 106-107)
- Modify: `skills/prometheus-exporter/assets/code/cli/collector.go.tmpl` (struct at 123, constructor at 132, `Collect` at 177-178)
- Modify: `skills/prometheus-exporter/assets/code/http/collector_test.go.tmpl` (imports at 3-15; call sites at 53, 86, 109, 161, 190)
- Modify: `skills/prometheus-exporter/assets/code/cli/collector_test.go.tmpl` (call sites at 37, 72, 97, 174)
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/registry.frag`
- Modify: `skills/prometheus-exporter/assets/code/cli/wiring/registry.frag`
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag`

**Interfaces:**
- Produces: `func NewExampleCollector(ctx context.Context, log *logger.Logger, client *Client) prometheus.Collector` (http flavor) and `func NewExampleCollector(ctx context.Context, log *logger.Logger, timeout time.Duration) prometheus.Collector` (cli flavor). Task 2 and Task 3 call these from the probe factory.

- [ ] **Step 1: Add the `ctx` field and constructor argument to the http collector**

In `assets/code/http/collector.go.tmpl`, replace the struct (currently lines
57-62) and the constructor signature (line 66):

```go
// ExampleCollector is the starter collector materialized by
// /new-prometheus-exporter. It is meant to be renamed and pointed at a real
// endpoint (see exampleStats' doc comment), but its shape, I/O then pure
// parse then glue then Describe then Collect, is the one every collector you
// add should follow.
type ExampleCollector struct {
	// ctx bounds this collector's I/O. Storing a context in a struct is
	// normally discouraged in Go, and this is the standard exception:
	// prometheus.Collector's Collect(ch) predates context and offers no other
	// channel to pass one. In a single-target exporter this is
	// context.Background() (no deadline, exactly as before). In a multi-target
	// exporter it is the probe's deadline, so a slow target aborts the scrape
	// instead of outrunning Prometheus.
	ctx     context.Context
	client  *Client
	log     *logger.Logger
	items   *prometheus.Desc
	healthy *prometheus.Desc
}

// NewExampleCollector wires a Client into a ready-to-register
// prometheus.Collector, bounded by ctx.
func NewExampleCollector(ctx context.Context, log *logger.Logger, client *Client) prometheus.Collector {
	return &ExampleCollector{
		ctx:    ctx,
		client: client,
		log:    log,
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
	}
}
```

- [ ] **Step 2: Make the http `Collect` use the injected context**

In the same file, at line 107, replace exactly:

```go
	stats, err := c.exampleGetMetrics(context.Background())
```

with:

```go
	stats, err := c.exampleGetMetrics(c.ctx)
```

Leave the whole doc comment above `Collect` (lines 91-105) untouched: it
documents the collector-authoring rule about emitting zero metrics, which this
change does not affect.

- [ ] **Step 3: Do the same for the cli collector**

In `assets/code/cli/collector.go.tmpl`, add the field to the struct (line 123)
with the identical comment from Step 1, add the leading argument to the
constructor (line 132), which for the cli flavor takes a timeout rather than a
client:

```go
func NewExampleCollector(ctx context.Context, log *logger.Logger, timeout time.Duration) prometheus.Collector {
```

and set `ctx: ctx,` in the returned struct literal. Then at line 178 replace
exactly:

```go
	metrics, err := c.exampleGetMetrics(context.Background())
```

with:

```go
	metrics, err := c.exampleGetMetrics(c.ctx)
```

- [ ] **Step 4: Update the http collector test's imports and call sites**

`assets/code/http/collector_test.go.tmpl` does **not** currently import
`context` (the cli one does). Add it, first in the stdlib group:

```go
import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"@@MODULE_PATH@@/internal/logger"
)
```

Then update all five call sites (lines 53, 86, 109, 161, 190) to pass
`context.Background()` as the first argument. For example line 53:

```go
	c := NewExampleCollector(context.Background(), log, NewClient(srv.URL, time.Second))
```

and line 109, inside its loop:

```go
		c := NewExampleCollector(context.Background(), log, NewClient(target, time.Second))
```

- [ ] **Step 5: Update the cli collector test's call sites**

`assets/code/cli/collector_test.go.tmpl` already imports `context`. Update all
four call sites (lines 37, 72, 97, 174):

```go
	c := NewExampleCollector(context.Background(), log, time.Second)
```

- [ ] **Step 6: Update the three wiring fragments**

`assets/code/http/wiring/registry.frag` becomes:

```go
	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, collector.NewClient(*exampleTarget, *exampleTimeout))
	}, true)
	register("http_client_requests", func() prometheus.Collector { return collector.RequestDuration }, true)
```

`assets/code/cli/wiring/registry.frag` becomes:

```go
	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, *exampleTimeout)
	}, true)
	register("command_exec", func() prometheus.Collector { return collector.CommandDuration }, true)
```

`assets/code/http/wiring/probe_factory.frag` keeps its current single-factory
shape for now (Task 2 rewrites it) and passes `context.Background()`, so the
multi scaffold still compiles. It is still inert here; Task 3 makes it real:

```go
	factory := func(target string, timeout time.Duration) prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, collector.NewClient(target, timeout))
	}
```

Both `mains/single/main.go.tmpl` and `mains/multi/main.go.tmpl` already import
`context` (they use `signal.NotifyContext`), so no import changes are needed in
either main.

- [ ] **Step 7: Prove single-target still builds and passes, on both flavors**

Run, from the repo root:

```bash
bash test/golden-smoke.sh --flavor http --forge none
bash test/golden-smoke.sh --flavor cli --forge none
```

Expected: both end with a green `make check` (vet, lint, test all pass) inside
the scaffolded exporter. These two cells are the non-regression proof that the
default target model is unchanged.

- [ ] **Step 8: Prove multi-target still builds (still inert, but compiling)**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: green `make check`, plus the existing live-probe check passing.

- [ ] **Step 9: Run the zero-source gate and commit**

```bash
bash test/zero-source-grep.sh
```

Expected: `PASS`.

```bash
git add skills/prometheus-exporter/assets/code
git -c commit.gpgsign=false commit -m "refactor(templates): inject a context into the standard collector constructors

prometheus.Collector.Collect(ch) takes no context, so the ctx threaded through
the five-piece pattern was inert: Collect minted its own context.Background()
and the plumbed cancellation was thrown away. Move the context to the
constructor, which is the only channel the Collector interface leaves open.

Behavior is unchanged everywhere. Every call site passes context.Background(),
which is exactly the value Collect minted for itself. This only makes the seam
exist; the multi-target probe fills it with a real deadline in a later commit.

The background collector variants are deliberately untouched: their Collect
reads a cache and their I/O already runs under Start(ctx)'s real context."
```

---

### Task 2: Widen the probe seam from one factory to N

The `Handler` stops holding a single `Factory` and holds an ordered
`[]NamedFactory`. `ServeHTTP` loops over them, which also removes the hardcoded
`"example"` collector name. The wiring fragment becomes an `append`, so a
second `/add-collector` invocation can stack another one at the marker instead
of redeclaring a variable and failing to compile.

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl` (`Factory` at 37, `Handler` at 40-45, `NewHandler` at 49-51, `tracker.Add` at 72)
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl` (`recordingFactory.make` at 24, `newTestHandler` at 53, `TestClampTimeoutHonoursHeaderAndCeiling` at 140)
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag`
- Modify: `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl` (marker at 89, `NewHandler` call at 91)
- Modify: `test/scaffold_multitarget_test.sh`

**Interfaces:**
- Consumes: `collector.NewExampleCollector(ctx, log, client)` from Task 1.
- Produces: `type NamedFactory struct { Name string; New Factory }` and
  `func NewHandler(log *logger.Logger, factories []NamedFactory, allowlist []string, maxTimeout time.Duration) *Handler`.
  Task 3 changes `Factory`'s signature; Tasks 4 and 5 add a `modules` argument
  to `NewHandler`.

- [ ] **Step 1: Write the failing test for N factories**

In `assets/internal/probe/probe_test.go.tmpl`, first make `recordingFactory`
nameable, then add the new test. Replace `recordingFactory.make` (line 24) and
`newTestHandler` (lines 53-55):

```go
func (f *recordingFactory) make(target string, timeout time.Duration) prometheus.Collector {
	f.calls++
	f.target = target
	f.timeout = timeout
	if f.panics {
		return panicCollector{}
	}
	return &stubCollector{desc: prometheus.NewDesc(f.metric, "stub", nil, nil)}
}

// named wraps this factory under a collector name, the way main.go's
// // @@PROBE_FACTORIES@@ block does.
func (f *recordingFactory) named(name string) NamedFactory {
	return NamedFactory{Name: name, New: f.make}
}

func newTestHandler(f *recordingFactory, allowlist []string) *Handler {
	return NewHandler(logger.NewTextLogger("error"), []NamedFactory{f.named("example")}, allowlist, 5*time.Second)
}
```

Add the `metric` field to `recordingFactory` (line 17-22) so two factories in
one probe emit distinguishable series, and default it in `named`:

```go
type recordingFactory struct {
	calls   int
	target  string
	timeout time.Duration
	panics  bool   // when true, the returned collector panics on Collect
	metric  string // the stub series this factory's collector emits
}
```

and in `make`, guard the default so the existing tests that never set `metric`
keep working:

```go
	metric := f.metric
	if metric == "" {
		metric = "stub_up"
	}
	return &stubCollector{desc: prometheus.NewDesc(metric, "stub", nil, nil)}
```

Now the new test:

```go
// TestAllFactoriesAreGathered is the whole point of the multi-collector seam:
// a probe must gather every registered factory, under its own tracker name,
// not just the first one.
func TestAllFactoriesAreGathered(t *testing.T) {
	a := &recordingFactory{metric: "stub_a"}
	b := &recordingFactory{metric: "stub_b"}
	h := NewHandler(logger.NewTextLogger("error"),
		[]NamedFactory{a.named("alpha"), b.named("beta")}, nil, 5*time.Second)

	rec := serve(h, "/probe?target=http://node1:9100")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	if a.calls != 1 || b.calls != 1 {
		t.Fatalf("factory calls: alpha=%d beta=%d, want 1 and 1", a.calls, b.calls)
	}
	body := rec.Body.String()
	for _, want := range []string{"stub_a", "stub_b", "probe_success 1"} {
		if !strings.Contains(body, want) {
			t.Errorf("body is missing %q:\n%s", want, body)
		}
	}
}
```

- [ ] **Step 2: Run it, and watch it fail to compile**

The template is not compiled in this repo, so scaffold it and run its tests:

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: FAIL. `make check` reports a compile error in
`internal/probe/probe_test.go`, along the lines of `undefined: NamedFactory`.
A compile failure is the correct red here: the type the test needs does not
exist yet.

- [ ] **Step 3: Widen the seam in `probe.go.tmpl`**

Replace the `Factory` type and its comment (lines 30-37), which currently
documents the one-collector limitation this task removes:

```go
// Factory builds one collector scoped to one probe target. The multi main.go
// appends one NamedFactory per collector at its // @@PROBE_FACTORIES@@ marker,
// and /add-collector appends another every time it adds a collector.
type Factory func(target string, timeout time.Duration) prometheus.Collector

// NamedFactory pairs a Factory with the collector name that the StatusTracker
// keys its health metric on. Handler holds these in an ordered slice, not a
// map: Go randomizes map iteration, which would make collector ordering and
// error messages nondeterministic for no benefit.
type NamedFactory struct {
	Name string
	New  Factory
}
```

Then the `Handler` struct and `NewHandler` (lines 39-51):

```go
// Handler serves /probe?target=… .
type Handler struct {
	log        *logger.Logger
	factories  []NamedFactory
	allowlist  []string      // empty => allow-any (ecosystem default; see SECURITY.md)
	maxTimeout time.Duration // upper bound on each probe's per-request timeout
}

// NewHandler builds a /probe handler. An empty allowlist accepts any target
// that clears the http/https floor (the Blackbox/SNMP default).
func NewHandler(log *logger.Logger, factories []NamedFactory, allowlist []string, maxTimeout time.Duration) *Handler {
	return &Handler{log: log, factories: factories, allowlist: allowlist, maxTimeout: maxTimeout}
}
```

And in `ServeHTTP`, replace the hardcoded single add (line 72):

```go
	tracker.Add("example", h.factory(target, timeout))
```

with the loop, which removes the `"example"` literal from the generic runtime:

```go
	for _, nf := range h.factories {
		tracker.Add(nf.Name, nf.New(target, timeout))
	}
```

Everything downstream is unchanged: one `reg.Gather()`, the `probe_success` /
`probe_duration_seconds` meta registry, and the `gatheredFamilies` replay all
operate on gathered families, not on the collector count.

- [ ] **Step 4: Make the wiring fragment appendable**

`assets/code/http/wiring/probe_factory.frag` becomes an `append`, so N of them
stack at the marker instead of redeclaring `factory`:

```go
	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(target string, timeout time.Duration) prometheus.Collector {
			return collector.NewExampleCollector(context.Background(), log, collector.NewClient(target, timeout))
		},
	})
```

- [ ] **Step 5: Declare the slice and pass it, in the multi main**

In `assets/mains/multi/main.go.tmpl`, replace the marker line (89) and the
`NewHandler` call (91):

```go
	// factories holds one entry per probed collector, in declaration order.
	// The // @@PROBE_FACTORIES@@ marker below is where scaffold.sh injects the
	// starter collector, and where /add-collector appends every collector you
	// add later. Leave the marker in place.
	var factories []probe.NamedFactory

	// @@PROBE_FACTORIES@@

	probeHandler := probe.NewHandler(log, factories, *probeTargetAllowlist, *exampleTimeout)
```

- [ ] **Step 6: Run the scaffolded tests, and watch them pass**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: green `make check`, including the new `TestAllFactoriesAreGathered`,
and the existing live-probe check still passing.

- [ ] **Step 7: Assert the new seam shape in the scaffold test**

In `test/scaffold_multitarget_test.sh`, after the existing `probe.NewHandler`
assertion (line 51), add the two assertions that pin the shape `/add-collector`
depends on:

```sh
grep -q 'var factories \[\]probe.NamedFactory' "$mainfile" || fail "multi scaffold's main.go does not declare the factories slice"
grep -q '// @@PROBE_FACTORIES@@' "$mainfile" || fail "multi scaffold's main.go lost the // @@PROBE_FACTORIES@@ marker (/add-collector appends there)"

probefile="$work/multi/internal/probe/probe.go"
grep -q 'factories \[\]NamedFactory' "$probefile" || fail "multi scaffold's probe.go does not hold N named factories"
```

- [ ] **Step 8: Run the scaffold tests**

```bash
bash test/scaffold_multitarget_test.sh
```

Expected: every `PASS:` line, no `fail`.

- [ ] **Step 9: Run the zero-source gate and commit**

```bash
bash test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/internal/probe \
        skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag \
        skills/prometheus-exporter/assets/mains/multi/main.go.tmpl \
        test/scaffold_multitarget_test.sh
git -c commit.gpgsign=false commit -m "feat(probe): hold N named factories instead of exactly one

The multi-target Handler held a single Factory and hardcoded the collector name
\"example\", so a second factory at the // @@PROBE_FACTORIES@@ marker was a
redeclaration that did not compile, and the Handler had nowhere to put it. This
is why /add-collector refused on multi-target scaffolds.

Handler now holds an ordered []NamedFactory and ServeHTTP gathers every one of
them. A slice, not a map: Go randomizes map iteration, which would make
collector ordering nondeterministic for no benefit. The wiring fragment becomes
an append, so factories stack at the marker."
```

---

### Task 3: Give the probe a real deadline

The seam now holds N collectors, and `StatusTracker.Collect` runs them
**sequentially** (`internal/collector/status_tracker.go.tmpl:74-107`). Four
collectors with a 5s budget each is a 20s probe, long after Prometheus gave up.
So the probe's timeout has to be a real deadline that the collectors actually
observe, not a per-collector budget. `Factory` gains a `ctx`, the handler builds
it with `context.WithTimeout`, and the misnamed `--collector.example.timeout`
becomes `--probe.timeout`.

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl` (`Factory`, `Handler`, `NewHandler`, `ServeHTTP`, `clampTimeout` at 153-166)
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/probe_factory.frag`
- Modify: `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl` (flag at 71-74, `NewHandler` call)

**Interfaces:**
- Consumes: `NamedFactory` from Task 2.
- Produces: `type Factory func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector`, and `NewHandler(log, factories, allowlist, maxTimeout, timeoutOffset)`. Tasks 4 and 5 add `modules` after `timeoutOffset`.

- [ ] **Step 1: Write the failing regression test for the inert context**

This is the test that would have caught the bug, and the one that proves the fix.
Add to `assets/internal/probe/probe_test.go.tmpl`, after the stub collectors:

```go
// blockingCollector models a target that never answers. Its Collect returns
// only when its context is cancelled, or after a delay far longer than any
// test would wait.
type blockingCollector struct {
	ctx  context.Context
	desc *prometheus.Desc
}

func (b *blockingCollector) Describe(ch chan<- *prometheus.Desc) { ch <- b.desc }
func (b *blockingCollector) Collect(ch chan<- prometheus.Metric) {
	select {
	case <-b.ctx.Done():
		// The probe's deadline fired. Emit nothing: StatusTracker reads zero
		// metrics as a failed scrape, which is exactly what this was.
	case <-time.After(30 * time.Second):
		ch <- prometheus.MustNewConstMetric(b.desc, prometheus.GaugeValue, 1)
	}
}

// TestProbeDeadlineAbortsHangingCollector is the regression test for the inert
// context. Before the deadline was injected into the collector's constructor,
// Collect minted its own context.Background(), so a hanging target ran until
// the HTTP client's own timeout with nothing able to interrupt it. A probe that
// has run out of time must stop, not grind on for a response nobody will read.
func TestProbeDeadlineAbortsHangingCollector(t *testing.T) {
	hang := NamedFactory{
		Name: "hang",
		New: func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector {
			return &blockingCollector{ctx: ctx, desc: prometheus.NewDesc("stub_hang", "stub", nil, nil)}
		},
	}
	h := NewHandler(logger.NewTextLogger("error"), []NamedFactory{hang}, nil, 100*time.Millisecond, 0)

	start := time.Now()
	rec := serve(h, "/probe?target=http://hangs.internal:9100")
	elapsed := time.Since(start)

	if elapsed > 5*time.Second {
		t.Fatalf("probe took %v: the deadline did not reach the collector", elapsed)
	}
	if !strings.Contains(rec.Body.String(), "probe_success 0") {
		t.Errorf("expected probe_success 0 for a timed-out probe, body:\n%s", rec.Body.String())
	}
}
```

- [ ] **Step 2: Run it, and watch it fail to compile**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: FAIL. `make check` reports a compile error: the factory literal takes
a `ctx` that `Factory` does not declare, and `NewHandler` takes five arguments
where it declares four. Red for the right reason: the deadline has nowhere to
travel yet.

- [ ] **Step 3: Make `Factory` carry the context**

In `assets/internal/probe/probe.go.tmpl`, change the `Factory` type:

```go
// Factory builds one collector scoped to one probe target, bounded by the
// probe's deadline. ctx is what makes that deadline real: prometheus.Collector's
// Collect(ch) takes no context, so the collector receives it at construction
// (see the collector template's ctx field).
type Factory func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector
```

Add `"context"` to the import block, first in the stdlib group:

```go
import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"time"
	...
)
```

- [ ] **Step 4: Add the timeout offset to the Handler**

Replace the `Handler` struct and `NewHandler`:

```go
// Handler serves /probe?target=… .
type Handler struct {
	log           *logger.Logger
	factories     []NamedFactory
	allowlist     []string      // empty => allow-any (ecosystem default; see SECURITY.md)
	maxTimeout    time.Duration // --probe.timeout: ceiling on each probe's deadline
	timeoutOffset time.Duration // --probe.timeout-offset: answer before Prometheus gives up
}

// NewHandler builds a /probe handler. An empty allowlist accepts any target
// that clears the http/https floor (the Blackbox/SNMP default).
func NewHandler(log *logger.Logger, factories []NamedFactory, allowlist []string, maxTimeout, timeoutOffset time.Duration) *Handler {
	return &Handler{
		log:           log,
		factories:     factories,
		allowlist:     allowlist,
		maxTimeout:    maxTimeout,
		timeoutOffset: timeoutOffset,
	}
}
```

- [ ] **Step 5: Build the deadline in `ServeHTTP` and hand it to every factory**

Replace the timeout line and the factory loop in `ServeHTTP`:

```go
	timeout := h.clampTimeout(r)

	// The probe's deadline, and the reason the ctx plumbed through every
	// collector is not decorative. StatusTracker collects sequentially, so N
	// collectors cost the SUM of their scrapes; without a shared deadline a
	// probe could run for N x timeout, long after Prometheus abandoned it.
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	// Fresh registry + collectors, scoped to THIS target, for THIS request.
	reg := prometheus.NewRegistry()
	tracker := collector.NewStatusTracker(h.log)
	for _, nf := range h.factories {
		tracker.Add(nf.Name, nf.New(ctx, target, timeout))
	}
	reg.MustRegister(tracker)
```

Then add `probe_timeout_seconds` to the meta registry, alongside the two
existing gauges, so whoever is debugging a slow target can see the deadline the
probe actually ran under:

```go
	probeTimeout := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "probe_timeout_seconds",
		Help: "Returns the deadline this probe ran under, in seconds.",
	})
	meta.MustRegister(probeSuccess, probeDuration, probeTimeout)
	probeTimeout.Set(timeout.Seconds())
```

- [ ] **Step 6: Rewrite `clampTimeout` with the offset**

Replace `clampTimeout` (lines 153-166) entirely:

```go
// clampTimeout computes this probe's deadline, following Blackbox's model:
//
//	min(--probe.timeout, scrape_timeout - --probe.timeout-offset)
//
// The offset is subtracted from Prometheus's own scrape timeout so the exporter
// answers BEFORE Prometheus abandons the scrape. Without it, a probe that uses
// its full budget is always a wasted scrape: the result arrives after nobody is
// listening.
func (h *Handler) clampTimeout(r *http.Request) time.Duration {
	v := r.Header.Get("X-Prometheus-Scrape-Timeout-Seconds")
	if v == "" {
		return h.maxTimeout // scraped by something that is not Prometheus
	}
	secs, err := strconv.ParseFloat(v, 64)
	if err != nil || secs <= 0 {
		return h.maxTimeout
	}

	budget := time.Duration((secs - h.timeoutOffset.Seconds()) * float64(time.Second))
	if budget <= 0 {
		// The offset swallows Prometheus's entire scrape timeout: one of the two
		// is misconfigured. Warn and ignore the offset, rather than handing every
		// probe an already-expired context and failing every scrape silently.
		h.log.Warn("probe timeout offset exceeds Prometheus's scrape timeout; ignoring the offset",
			"scrape_timeout_seconds", v, "timeout_offset", h.timeoutOffset)
		budget = time.Duration(secs * float64(time.Second))
	}
	if budget < h.maxTimeout {
		return budget
	}
	return h.maxTimeout
}
```

- [ ] **Step 7: Pass the ctx through the wiring fragment**

`assets/code/http/wiring/probe_factory.frag` now hands the probe's real context
to the collector instead of `context.Background()`:

```go
	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector {
			return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout))
		},
	})
```

- [ ] **Step 8: Rename the flag and add the offset, in the multi main**

In `assets/mains/multi/main.go.tmpl`, replace the `exampleTimeout` flag block
(lines 66-74). The old name was a lie: it never configured the `example`
collector, it bounded every probe.

```go
	// The ceiling on each /probe request's deadline. The handler clamps it
	// further by Prometheus's own X-Prometheus-Scrape-Timeout-Seconds header,
	// minus the offset below.
	probeTimeout := kingpin.Flag(
		"probe.timeout",
		"Ceiling on each /probe request's deadline.",
	).Default("5s").Duration()

	// Subtracted from Prometheus's scrape timeout so the exporter answers
	// BEFORE Prometheus abandons the scrape. A probe that uses its full budget
	// and replies a moment too late is a wasted scrape.
	probeTimeoutOffset := kingpin.Flag(
		"probe.timeout-offset",
		"Subtracted from Prometheus's scrape timeout when computing a probe's deadline.",
	).Default("0.5s").Duration()
```

and the `NewHandler` call:

```go
	probeHandler := probe.NewHandler(log, factories, *probeTargetAllowlist, *probeTimeout, *probeTimeoutOffset)
```

- [ ] **Step 9: Update the existing timeout test for the offset**

In `assets/internal/probe/probe_test.go.tmpl`, `newTestHandler` (Task 2's
version) gains the offset argument, at zero so the existing assertions keep
their meaning:

```go
func newTestHandler(f *recordingFactory, allowlist []string) *Handler {
	return NewHandler(logger.NewTextLogger("error"), []NamedFactory{f.named("example")}, allowlist, 5*time.Second, 0)
}
```

`recordingFactory.make` gains the ctx argument to satisfy `Factory`:

```go
func (f *recordingFactory) make(ctx context.Context, target string, timeout time.Duration) prometheus.Collector {
```

Then replace `TestClampTimeoutHonoursHeaderAndCeiling` (line 139) with a version
that covers the offset, including the misconfiguration case:

```go
func TestClampTimeoutHonoursHeaderCeilingAndOffset(t *testing.T) {
	h := NewHandler(logger.NewTextLogger("error"),
		[]NamedFactory{(&recordingFactory{}).named("example")}, nil, 5*time.Second, 500*time.Millisecond)

	req := httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/probe?target=http://x:9100", nil)

	// Header far above the ceiling: the ceiling wins.
	req.Header.Set("X-Prometheus-Scrape-Timeout-Seconds", "30")
	if got := h.clampTimeout(req); got != 5*time.Second {
		t.Errorf("header above ceiling: got %v, want 5s", got)
	}

	// Header below the ceiling: the header wins, minus the offset.
	req.Header.Set("X-Prometheus-Scrape-Timeout-Seconds", "2")
	if got := h.clampTimeout(req); got != 1500*time.Millisecond {
		t.Errorf("header below ceiling: got %v, want 1.5s (2s - 0.5s offset)", got)
	}

	// No header at all (not scraped by Prometheus): the ceiling stands.
	req.Header.Del("X-Prometheus-Scrape-Timeout-Seconds")
	if got := h.clampTimeout(req); got != 5*time.Second {
		t.Errorf("no header: got %v, want 5s", got)
	}

	// Offset larger than the scrape timeout: ignore the offset rather than
	// handing the probe an already-expired context.
	req.Header.Set("X-Prometheus-Scrape-Timeout-Seconds", "0.2")
	if got := h.clampTimeout(req); got != 200*time.Millisecond {
		t.Errorf("offset exceeds scrape timeout: got %v, want 200ms", got)
	}
}
```

- [ ] **Step 10: Run the scaffolded tests, and watch them pass**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: green `make check`, including `TestProbeDeadlineAbortsHangingCollector`
(which now completes in ~100ms instead of hanging) and the rewritten timeout
test.

- [ ] **Step 11: Confirm single-target is still untouched**

```bash
bash test/golden-smoke.sh --flavor http --forge none
bash test/golden-smoke.sh --flavor cli --forge none
```

Expected: both green. Neither flavor has a probe, a deadline, or either new flag.

- [ ] **Step 12: Run the zero-source gate and commit**

```bash
bash test/zero-source-grep.sh
git add skills/prometheus-exporter/assets
git -c commit.gpgsign=false commit -m "feat(probe): give the probe a real deadline, and name its flag honestly

StatusTracker collects sequentially, so N collectors cost the SUM of their
scrapes. With the deadline inert, a 4-collector probe under a 5s budget could
run for 20s, long after Prometheus gave up on it.

The handler now builds context.WithTimeout(r.Context(), effective) and hands it
to every factory, so a probe that runs out of time stops instead of grinding on
for a response nobody will read. effective = min(--probe.timeout, scrape_timeout
- --probe.timeout-offset), which is Blackbox's calculation; the offset makes the
exporter answer before Prometheus abandons the scrape.

--collector.example.timeout is renamed --probe.timeout. The old name never
configured the example collector: it bounded every probe. With one collector the
two were the same thing, so the lie was invisible.

probe_timeout_seconds is exported alongside probe_success and
probe_duration_seconds, mirroring Blackbox."
```

---

### Task 4: Parse and validate `--probe.module` at startup

Modules are runtime configuration, not scaffold-time structure: a repeatable
kingpin flag, no new dependency and no config file to ship or mount. A typo must
kill the process at boot, not surface as a 400 on a probe at 3am.

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl`

**Interfaces:**
- Consumes: `NamedFactory` from Task 2, `NewHandler(log, factories, allowlist, maxTimeout, timeoutOffset)` from Task 3.
- Produces: `func ParseModules(vals []string) (map[string][]string, error)`, `func ValidateModules(factories []NamedFactory, modules map[string][]string) error`, and `NewHandler(log, factories, allowlist, maxTimeout, timeoutOffset, modules)`. Task 5 consumes `Handler.modules`.

- [ ] **Step 1: Write the failing tests for parsing and validation**

Add to `assets/internal/probe/probe_test.go.tmpl`:

```go
func TestParseModules(t *testing.T) {
	mods, err := ParseModules([]string{"basic:disks,pools", "full:disks,pools,perf"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := mods["basic"]; len(got) != 2 || got[0] != "disks" || got[1] != "pools" {
		t.Errorf("basic = %v, want [disks pools]", got)
	}
	if got := mods["full"]; len(got) != 3 {
		t.Errorf("full = %v, want 3 collectors", got)
	}
}

func TestParseModulesRejectsMalformed(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   []string
	}{
		{"no colon", []string{"basic"}},
		{"empty module name", []string{":disks"}},
		{"empty collector list", []string{"basic:"}},
		{"duplicate module", []string{"basic:disks", "basic:pools"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := ParseModules(tc.in); err == nil {
				t.Fatalf("ParseModules(%v) accepted a malformed module, want an error", tc.in)
			}
		})
	}
}

func TestValidateModulesRejectsUnknownCollector(t *testing.T) {
	factories := []NamedFactory{(&recordingFactory{}).named("disks")}

	if err := ValidateModules(factories, map[string][]string{"basic": {"disks"}}); err != nil {
		t.Fatalf("a module naming a registered collector was rejected: %v", err)
	}

	err := ValidateModules(factories, map[string][]string{"basic": {"disks", "typo"}})
	if err == nil {
		t.Fatal("a module naming an unregistered collector was accepted, want an error")
	}
	if !strings.Contains(err.Error(), "typo") {
		t.Errorf("error does not name the offending collector: %v", err)
	}
}
```

- [ ] **Step 2: Run them, and watch them fail to compile**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: FAIL, `undefined: ParseModules` and `undefined: ValidateModules`.

- [ ] **Step 3: Implement parsing and validation**

Add to `assets/internal/probe/probe.go.tmpl`, and add `"sort"` and `"strings"`
to the stdlib import group:

```go
// ParseModules turns repeatable --probe.module=<name>:<collector>[,<collector>…]
// flag values into a module map. Collector names are Go identifiers, so they can
// never contain the ':' or ',' separators and the split is unambiguous.
//
// A module is a scrape profile: it selects among collectors that are already
// compiled in. It does not define probe behavior the way a Blackbox YAML module
// does, because here the collectors are Go code, not configuration.
func ParseModules(vals []string) (map[string][]string, error) {
	modules := make(map[string][]string, len(vals))
	for _, v := range vals {
		name, list, ok := strings.Cut(v, ":")
		if !ok {
			return nil, fmt.Errorf("malformed --probe.module %q: want <module>:<collector>[,<collector>...]", v)
		}
		name = strings.TrimSpace(name)
		if name == "" {
			return nil, fmt.Errorf("malformed --probe.module %q: empty module name", v)
		}
		if _, dup := modules[name]; dup {
			// Silently keeping one of two conflicting definitions would hide an
			// operator mistake.
			return nil, fmt.Errorf("module %q declared twice", name)
		}
		var cols []string
		for _, c := range strings.Split(list, ",") {
			if c = strings.TrimSpace(c); c != "" {
				cols = append(cols, c)
			}
		}
		if len(cols) == 0 {
			// A module that runs nothing is always a typo, never an intent.
			return nil, fmt.Errorf("module %q declares no collectors", name)
		}
		modules[name] = cols
	}
	return modules, nil
}

// ValidateModules checks every module against the registered collectors. Call it
// at startup and fail the boot on error: discovering a typo when the process
// starts is strictly better than discovering it on a probe at 3am.
func ValidateModules(factories []NamedFactory, modules map[string][]string) error {
	known := make(map[string]bool, len(factories))
	for _, nf := range factories {
		known[nf.Name] = true
	}

	// Sorted, so the boot fails on the same module every time regardless of map
	// iteration order.
	names := make([]string, 0, len(modules))
	for name := range modules {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		for _, c := range modules[name] {
			if !known[c] {
				return fmt.Errorf("module %q names unknown collector %q", name, c)
			}
		}
	}
	return nil
}
```

Then store the map on the `Handler` and take it in `NewHandler`:

```go
type Handler struct {
	log           *logger.Logger
	factories     []NamedFactory
	allowlist     []string      // empty => allow-any (ecosystem default; see SECURITY.md)
	maxTimeout    time.Duration // --probe.timeout: ceiling on each probe's deadline
	timeoutOffset time.Duration // --probe.timeout-offset: answer before Prometheus gives up
	modules       map[string][]string
}

func NewHandler(log *logger.Logger, factories []NamedFactory, allowlist []string, maxTimeout, timeoutOffset time.Duration, modules map[string][]string) *Handler {
	return &Handler{
		log:           log,
		factories:     factories,
		allowlist:     allowlist,
		maxTimeout:    maxTimeout,
		timeoutOffset: timeoutOffset,
		modules:       modules,
	}
}
```

- [ ] **Step 4: Update the test helper for the new argument**

In `assets/internal/probe/probe_test.go.tmpl`, `newTestHandler` passes no
modules, and the two direct `NewHandler` calls in
`TestProbeDeadlineAbortsHangingCollector` and
`TestClampTimeoutHonoursHeaderCeilingAndOffset` gain a trailing `nil`:

```go
func newTestHandler(f *recordingFactory, allowlist []string) *Handler {
	return NewHandler(logger.NewTextLogger("error"), []NamedFactory{f.named("example")}, allowlist, 5*time.Second, 0, nil)
}
```

- [ ] **Step 5: Wire the flag and fail fast at startup**

In `assets/mains/multi/main.go.tmpl`, add the flag next to the other probe
flags:

```go
	// Modules are scrape profiles: named subsets of this exporter's collectors,
	// selected per request with /probe?target=…&module=…. Repeatable.
	probeModules := kingpin.Flag(
		"probe.module",
		"Declare a module: <name>:<collector>[,<collector>...] (repeatable).",
	).Strings()
```

Then, after the `// @@PROBE_FACTORIES@@` block has filled `factories` and before
building the handler, parse and validate. Both are fatal:

```go
	modules, err := probe.ParseModules(*probeModules)
	if err != nil {
		log.Error("Invalid --probe.module", "err", err)
		os.Exit(1)
	}
	if err := probe.ValidateModules(factories, modules); err != nil {
		log.Error("Invalid --probe.module", "err", err)
		os.Exit(1)
	}

	probeHandler := probe.NewHandler(log, factories, *probeTargetAllowlist, *probeTimeout, *probeTimeoutOffset, modules)
```

`os` is already imported in the multi main (it uses `os.Interrupt` and
`os.Exit`), so no import change is needed.

- [ ] **Step 6: Run the scaffolded tests, and watch them pass**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: green `make check`, including the three new module tests.

- [ ] **Step 7: Run the zero-source gate and commit**

```bash
bash test/zero-source-grep.sh
git add skills/prometheus-exporter/assets
git -c commit.gpgsign=false commit -m "feat(probe): declare and validate scrape modules at startup

--probe.module=<name>:<collector>[,<collector>...] is repeatable, needs no new
dependency, and ships no config file. Parsing rejects a malformed value, a
duplicate module name (silently keeping one of two conflicting definitions would
hide an operator mistake), and an empty collector list (a module that runs
nothing is always a typo). Validation rejects a module naming a collector that is
not registered.

All of it is fatal at boot. Discovering a typo when the process starts is
strictly better than discovering it on a probe at 3am.

The modules are parsed and stored here; /probe learns to select on them next."
```

---

### Task 5: Select collectors per probe with `module`

`module` is repeatable **and** comma-separated, and named modules **combine**,
exactly as SNMP's `/snmp?target=X&module=a,b` does. An absent `module` runs every
collector, which is what preserves the v0.3.0 scrape-config contract.

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl` (`ServeHTTP`)
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl`

**Interfaces:**
- Consumes: `Handler.modules` and `Handler.factories` from Task 4.
- Produces: no new exported symbol. `/probe` gains the `module` query parameter.

- [ ] **Step 1: Write the failing tests for module semantics**

Add to `assets/internal/probe/probe_test.go.tmpl`. `threeFactoryHandler` gives
each test the same three named collectors:

```go
// threeFactoryHandler registers alpha, beta and gamma, with two modules over
// them, and hands back the factories so a test can assert which ones ran.
func threeFactoryHandler(t *testing.T) (*Handler, map[string]*recordingFactory) {
	t.Helper()
	fs := map[string]*recordingFactory{
		"alpha": {metric: "stub_alpha"},
		"beta":  {metric: "stub_beta"},
		"gamma": {metric: "stub_gamma"},
	}
	factories := []NamedFactory{
		fs["alpha"].named("alpha"),
		fs["beta"].named("beta"),
		fs["gamma"].named("gamma"),
	}
	modules := map[string][]string{
		"ab": {"alpha", "beta"},
		"bc": {"beta", "gamma"},
	}
	h := NewHandler(logger.NewTextLogger("error"), factories, nil, 5*time.Second, 0, modules)
	return h, fs
}

func TestModuleAbsentRunsEveryCollector(t *testing.T) {
	h, fs := threeFactoryHandler(t)
	rec := serve(h, "/probe?target=http://n:9100")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	for name, f := range fs {
		if f.calls != 1 {
			t.Errorf("collector %q ran %d times, want 1: an absent module must run everything", name, f.calls)
		}
	}
}

func TestModuleSelectsOnlyItsMembers(t *testing.T) {
	h, fs := threeFactoryHandler(t)
	rec := serve(h, "/probe?target=http://n:9100&module=ab")

	if rec.Code != http.StatusOK {
		t.Fatalf("got %d, want 200", rec.Code)
	}
	if fs["alpha"].calls != 1 || fs["beta"].calls != 1 {
		t.Errorf("module ab did not run its members: alpha=%d beta=%d", fs["alpha"].calls, fs["beta"].calls)
	}
	if fs["gamma"].calls != 0 {
		t.Errorf("module ab ran gamma %d times, want 0", fs["gamma"].calls)
	}
	if strings.Contains(rec.Body.String(), "stub_gamma") {
		t.Errorf("body carries a series from a collector the module did not select:\n%s", rec.Body.String())
	}
}

func TestModulesCombineAsDeduplicatedUnion(t *testing.T) {
	// ab and bc overlap on beta: it must run ONCE, not twice.
	for _, rawurl := range []string{
		"/probe?target=http://n:9100&module=ab&module=bc", // repeated
		"/probe?target=http://n:9100&module=ab,bc",        // comma-separated
	} {
		t.Run(rawurl, func(t *testing.T) {
			h, fs := threeFactoryHandler(t)
			rec := serve(h, rawurl)

			if rec.Code != http.StatusOK {
				t.Fatalf("got %d, want 200", rec.Code)
			}
			for _, name := range []string{"alpha", "beta", "gamma"} {
				if fs[name].calls != 1 {
					t.Errorf("collector %q ran %d times, want exactly 1", name, fs[name].calls)
				}
			}
		})
	}
}

func TestUnknownModuleRejected(t *testing.T) {
	h, fs := threeFactoryHandler(t)
	rec := serve(h, "/probe?target=http://n:9100&module=nope")

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("unknown module: got %d, want 400", rec.Code)
	}
	for name, f := range fs {
		if f.calls != 0 {
			t.Errorf("collector %q ran for a rejected module, want 0 calls", name)
		}
	}
}
```

- [ ] **Step 2: Run them, and watch them fail**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: FAIL. `TestModuleSelectsOnlyItsMembers` and `TestUnknownModuleRejected`
fail because `module` is ignored today: every collector runs and an unknown
module returns 200 instead of 400.

- [ ] **Step 3: Implement selection**

Add to `assets/internal/probe/probe.go.tmpl`:

```go
// moduleNames flattens the module parameter, which is both repeatable and
// comma-separated: ?module=a&module=b,c selects a, b and c. This is SNMP's
// grammar, and a scrape config should not have to care which spelling it used.
func moduleNames(vals []string) []string {
	var out []string
	for _, v := range vals {
		for _, part := range strings.Split(v, ",") {
			if part = strings.TrimSpace(part); part != "" {
				out = append(out, part)
			}
		}
	}
	return out
}

// selectFactories resolves a request's module parameter to the collectors that
// will run. Named modules COMBINE: the result is the union of their collectors,
// deduplicated, emitted in the handler's declared factory order rather than the
// order the modules were listed, so a probe's output is stable regardless of how
// the scrape config spells its module list.
//
// An absent module runs every registered collector. That is what makes this
// additive: a scrape config that only sets target keeps working untouched.
func (h *Handler) selectFactories(vals []string) ([]NamedFactory, error) {
	names := moduleNames(vals)
	if len(names) == 0 {
		return h.factories, nil
	}

	wanted := make(map[string]bool)
	for _, name := range names {
		cols, ok := h.modules[name]
		if !ok {
			return nil, fmt.Errorf("unknown module %q", name)
		}
		for _, c := range cols {
			wanted[c] = true
		}
	}

	// Declared order, and deduplicated by construction: each factory is
	// considered exactly once, however many selected modules named it.
	var out []NamedFactory
	for _, nf := range h.factories {
		if wanted[nf.Name] {
			out = append(out, nf)
		}
	}
	return out, nil
}
```

Then, in `ServeHTTP`, resolve the selection alongside the other request-level
rejections, before any work is done, and loop over the selection instead of over
every factory:

```go
	if !h.targetAllowed(target) {
		http.Error(w, "target not allowed", http.StatusForbidden)
		return
	}

	factories, err := h.selectFactories(r.URL.Query()["module"])
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	timeout := h.clampTimeout(r)
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	reg := prometheus.NewRegistry()
	tracker := collector.NewStatusTracker(h.log)
	for _, nf := range factories {
		tracker.Add(nf.Name, nf.New(ctx, target, timeout))
	}
	reg.MustRegister(tracker)
```

Note the existing `mfs, err := reg.Gather()` further down already declares `err`;
since `err` is now declared above by `selectFactories`, change that line to
`mfs, gatherErr := reg.Gather()` and update the `switch` that reads it, so the
compiler does not report a shadowed or unused variable.

- [ ] **Step 4: Run the scaffolded tests, and watch them pass**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: green `make check`, all module tests passing.

- [ ] **Step 5: Run the zero-source gate and commit**

```bash
bash test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/internal/probe
git -c commit.gpgsign=false commit -m "feat(probe): select collectors per probe with the module parameter

/probe?target=X&module=a,b selects a subset of the exporter's collectors. module
is repeatable AND comma-separated, and named modules combine, which is SNMP's
grammar: a scrape config should not have to care which spelling it used.

The union is deduplicated (a collector named by two selected modules runs once)
and emitted in the handler's declared factory order rather than the order the
modules were listed, so a probe's output is stable.

An absent module runs every collector. That is what makes this additive: a
v0.3.0 scrape config that only sets target keeps working untouched. An unknown
module is a 400, alongside the existing target-floor and allowlist rejections."
```

---

### Task 6: Prove the seam holds a second collector, end to end

Everything above is unfalsifiable without this. A unit test on a template cannot
show that a second collector compiles into a real repository. This task extends
the golden `http-multi` cell to add a second collector to the scaffolded
exporter, exactly where `/add-collector` would append it, and proves the result
builds, passes `make check`, and serves both collectors' series from one probe.

**Honest scope:** `/add-collector` is a command, an LLM prompt, so no shell test
can run it. What this cell proves is the **seam**: that the marker accepts a
second `NamedFactory`, that two collectors compile side by side, and that a probe
gathers both. That is precisely the property the command depends on and the
property that did not hold before this plan. It does not prove the command's
judgement, and nothing mechanical could.

**Files:**
- Modify: `test/golden-smoke.sh` (after the existing `make check` and live-probe sections, gated on `target_model = multi`)

**Interfaces:**
- Consumes: the `// @@PROBE_FACTORIES@@` marker (which `golden-smoke.sh:380-388` already documents as deliberately surviving into the generated repo), and `probe.NamedFactory` from Task 2.

- [ ] **Step 1: Add the second-collector section to the golden cell**

In `test/golden-smoke.sh`, after the existing `target_model = multi` live-probe
block, add:

```sh
# Second-collector check (multi-target epic): the whole point of widening the
# probe seam is that a SECOND collector can be appended at the
# // @@PROBE_FACTORIES@@ marker and still compile. This is the mechanical core
# of what /add-collector does on a multi-target scaffold. The command itself is
# an LLM prompt and cannot be run from a shell, so this proves the seam, not the
# command's judgement — but the seam is what did not hold before.
if [ "$target_model" = multi ]; then
  echo "== appending a second collector at // @@PROBE_FACTORIES@@ =="

  # A second collector, derived from the scaffolded one: same five-piece shape,
  # different type name and different metric names, so a clash would surface as
  # a duplicate-registration panic rather than passing silently.
  sed -e 's/ExampleCollector/SecondCollector/g' \
      -e 's/exampleStats/secondStats/g' \
      -e 's/exampleData/secondData/g' \
      -e 's/parseExample/parseSecond/g' \
      -e 's/exampleGetMetrics/secondGetMetrics/g' \
      -e 's/NewExampleCollector/NewSecondCollector/g' \
      -e "s/${namespace}_items/${namespace}_second_items/g" \
      -e "s/${namespace}_healthy/${namespace}_second_healthy/g" \
      "$work/internal/collector/collector.go" > "$work/internal/collector/collector_second.go"

  # Append its factory at the marker, exactly as /add-collector does.
  marker='	// @@PROBE_FACTORIES@@'
  mainfile=$(ls "$work"/cmd/*/main.go)
  awk -v marker="$marker" '
    index($0, "@@PROBE_FACTORIES@@") {
      print "\tfactories = append(factories, probe.NamedFactory{"
      print "\t\tName: \"second\","
      print "\t\tNew: func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector {"
      print "\t\t\treturn collector.NewSecondCollector(ctx, log, collector.NewClient(target, timeout))"
      print "\t\t},"
      print "\t})"
    }
    { print }
  ' "$mainfile" > "$mainfile.new" && mv "$mainfile.new" "$mainfile"

  gofmt -w "$mainfile" "$work/internal/collector/collector_second.go"

  echo "== make check (two collectors on the multi-target seam) =="
  if ! ( cd "$work" && make check ); then
    die "make check FAILED after appending a second collector — the probe seam does not hold N collectors"
  fi
fi
```

Note: `$namespace` is the `--var NAMESPACE=` value this cell scaffolds with. If
the script does not already hold it in a shell variable at that point, read it
back from the generated main, which is the same trick
`commands/generate-dashboard.md` uses:

```sh
namespace=$(command grep -hoE 'const[[:space:]]+namespace[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' "$work"/cmd/*/main.go | head -n1 | sed -E 's/.*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/')
```

- [ ] **Step 2: Probe the two-collector exporter and assert both collectors are gathered**

Placement matters. The existing live-probe block (search `test/golden-smoke.sh`
for `http-multi live-probe check`) starts a server on `$probe_port`, installs a
`trap … EXIT`, probes, then **tears the server down and clears the trap**
(`kill "$server_pid"; wait …; trap - EXIT`). Put this whole Step 1 + Step 2
section **after** that teardown, so no server is running and no trap is
installed when you start yours. Do not start a second server while the first is
still bound to the port.

**Assert on the collector health series, not the business metrics.** This is the
one thing the brief gets right only if you read why. The live probe targets the
exporter's own `/metrics` (a self-contained target, no external dependency), so
the example collector's data fetch (`@@DATA_SOURCE_PATH@@` against that target)
does not return the JSON shape it expects and **fails** — which is exactly why
the existing block asserts only that `probe_success` is *present*, never that it
is `1`. A failed collector emits **zero** business metrics, so
`@@NAMESPACE@@_items` and `@@NAMESPACE@@_second_items` will NOT appear, and
`probe_success 1` is not reachable this way.

What IS always emitted, once per registered-and-gathered collector regardless of
whether its own fetch succeeded, is the `StatusTracker` health series
`@@NAMESPACE@@_exporter_collector_success{collector="<name>"}` (verify in
`assets/internal/collector/status_tracker.go.tmpl`: label key is `collector`,
value `0` on a failed scrape, `1` on success). That series appearing for
`collector="second"` is the reliable proof that the second collector was wired
into the seam and gathered. Assert on it:

```sh
  echo "== live /probe with two collectors =="
  # (start the rebuilt binary and curl /probe?target=http://127.0.0.1:$probe_port/metrics
  #  into $probe_body, EXACTLY as the existing live-probe block does — same port
  #  var, same healthz poll, same trap discipline)
  command grep -q "probe_timeout_seconds" "$probe_body" || die "two-collector probe is missing probe_timeout_seconds"
  for name in example second; do
    command grep -q "collector_success{collector=\"$name\"}" "$probe_body" \
      || die "two-collector probe did not gather collector \"$name\" (no collector_success series)"
  done

  echo "== module selection on the live exporter =="
  # Restart with a module that names only the second collector, then probe with
  # &module=only-second. The example collector must NOT be gathered: its health
  # series must be absent. This is the module parameter doing real work end to
  # end, not just passing a unit test.
  # (restart with --probe.module=only-second:second, curl /probe?target=…&module=only-second
  #  into $module_body, same start/poll/teardown discipline)
  command grep -q 'collector_success{collector="second"}' "$module_body" \
    || die "module probe did not gather the collector it selected"
  command grep -q 'collector_success{collector="example"}' "$module_body" \
    && die "module probe gathered a collector the module did not select"
```

Follow the existing live-probe block's exact conventions for starting the binary,
waiting for readiness on `/healthz`, capturing the body with `curl -fsS`, and
killing the process (`kill`/`wait`/`trap - EXIT`). Do not invent a second
mechanism. If you start more than one server across these two probes, make sure
each is torn down before the next starts, and that the final one leaves no trap
or listener behind for the docs-check block that follows.

**Do not assert `probe_success`'s value.** Match the existing block: it may be
`0` here because the self-probe's collectors cannot fetch their expected data.
Asserting `probe_success 1` would be asserting a lie. The proof this task owes is
"two collectors compiled in and were both gathered", and the `collector_success`
series is what proves it.

- [ ] **Step 3: Run the full multi cell**

```bash
bash test/golden-smoke.sh --flavor http --forge none --target-model multi
```

Expected: green. The scaffolded exporter builds with two collectors, `make check`
passes, one probe gathers both (`collector_success{collector="example"}` and
`collector_success{collector="second"}` both present), and a module-scoped probe
gathers only the second (`collector="example"` absent).

- [ ] **Step 4: Run the whole matrix, to prove nothing else moved**

```bash
bash test/golden-smoke.sh --all
```

Expected: all five cells green (`http-none`, `http-github`, `cli-none`,
`cli-github`, `http-multi`).

- [ ] **Step 5: Run the zero-source gate and commit**

```bash
bash test/zero-source-grep.sh
git add test/golden-smoke.sh
git -c commit.gpgsign=false commit -m "test(golden): prove the probe seam holds a second collector

Everything in the multi-collector epic is unfalsifiable without this: a unit test
on a template cannot show that a second collector compiles into a real
repository. The http-multi cell now appends a second collector at the
// @@PROBE_FACTORIES@@ marker, exactly where /add-collector appends one, then
proves the result builds, passes make check, and serves both collectors' series
from a single probe. A module-scoped probe carries only the collector it selected.

This proves the seam, not /add-collector's judgement: the command is an LLM
prompt and cannot be run from a shell. The seam is what did not hold before."
```

---

### Task 7: Teach `/add-collector` the multi-target procedure

The command currently refuses on a multi-target scaffold and points the user at a
manual procedure (`commands/add-collector.md:51-59`). The refusal was honest: the
runtime could not hold a second collector. It can now. Replace the refusal with
detection, migration, and the factory append.

**Files:**
- Modify: `commands/add-collector.md` (flavor detection at 20-66, refusal section at 51-59)

**Interfaces:**
- Consumes: `probe.NamedFactory`, `var factories []probe.NamedFactory`, and the
  `// @@PROBE_FACTORIES@@` marker from Task 2; the `Factory` ctx signature from
  Task 3.

- [ ] **Step 1: Replace the refusal with a shape check and a migration**

In `commands/add-collector.md`, replace the multi-target refusal section
(currently lines 51-59, the block whose detection is
`[ -d internal/probe ] || grep -q '/probe' cmd/*/main.go`) with the real
procedure. Detect the repository's **seam shape**, not just its target model:

````markdown
## Multi-target scaffolds

Detect the target model from what is on disk. Never ask what you can check:

```sh
[ -d internal/probe ] && echo multi || echo single
```

For a **multi-target** repository, check the seam's shape before touching
anything:

```sh
grep -q 'factories \[\]NamedFactory' internal/probe/probe.go && echo current || echo v0.3.0
```

**If the shape is `v0.3.0`** (the seam holds exactly one `factory Factory`), the
repository predates the N-collector seam and cannot hold a second collector.
Migrate it first. `internal/probe/probe.go` and the multi `main.go`'s probe
wiring are generic shipped files: the scaffold writes them and a user has no
reason to have edited them. Rewrite both from the current templates
(`skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl` and
`assets/mains/multi/main.go.tmpl`), substituting the repository's real
`@@NAMESPACE@@` and `@@MODULE_PATH@@`, then:

1. **Show the diff before writing it.** The migration renames
   `--collector.example.timeout` to `--probe.timeout`, which is a breaking flag
   change for anyone running that exporter. Say so plainly.
2. If the user declines, stop and hand them the diff. Do not add the collector to
   a seam that cannot hold it.
3. If the user accepts, apply it, then proceed.

**If the shape is `current`**, proceed directly.

Then materialize the collector exactly as for single-target (the five-piece
shape, the test triad, the `docs/metrics.md` entry, the proposed business alert),
and append **one** `probe.NamedFactory` block at the `// @@PROBE_FACTORIES@@`
marker in `cmd/*/main.go`:

```go
	factories = append(factories, probe.NamedFactory{
		Name: "<collector_name>",
		New: func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector {
			return collector.New<CollectorName>Collector(ctx, log, collector.NewClient(target, timeout))
		},
	})
```

Append, never replace: the marker stays in place for the next collector.

**Never touch modules.** `--probe.module` values are runtime flags that reference
collector names. Adding a collector cannot invalidate an existing module, and
composing scrape profiles is an operator decision, not yours.

**Refuse `--variant background` on a multi-target scaffold.** A background
collector refreshes a cache from a goroutine on a fixed interval. In multi,
collectors are built fresh per request and discarded when the probe returns: a
goroutine per probe is an unbounded leak, and the cache it fills would never be
read twice. Say exactly that, and offer the standard variant instead.
````

- [ ] **Step 2: Confirm the flavor-detection table still reads correctly**

The table at `commands/add-collector.md:20-66` maps
`internal/collector/client.go` to the http flavor and `execute.go` to cli. That
logic is unchanged: multi is always http (`scaffold.sh:190` refuses
`--target-model multi` outside `--flavor http`), so a multi repository always has
`client.go`. Leave the table alone; do not add a multi row to it. Target model and
I/O flavor are different questions and the command now asks both.

- [ ] **Step 3: Validate the plugin manifest**

```bash
claude plugin validate .
```

Expected: no errors. The command's frontmatter is unchanged, but this is the gate
for anything under `commands/`.

- [ ] **Step 4: Run the zero-source gate and commit**

`commands/` is scanned for the maintainer handle by the gate, and this file now
carries a lot of new prose.

```bash
bash test/zero-source-grep.sh
git add commands/add-collector.md
git -c commit.gpgsign=false commit -m "feat(command): teach /add-collector the multi-target procedure

The command refused on a multi-target scaffold and pointed at a manual procedure.
The refusal was honest rather than lazy: the runtime held exactly one collector,
so there was nothing to wire a second one into. The seam now holds N.

/add-collector detects the seam's shape, not just the target model. A v0.3.0
scaffold whose Handler still holds a single Factory is migrated from the current
templates, with the diff shown first because the migration renames
--collector.example.timeout to --probe.timeout, a breaking flag change. Then the
collector is materialized as usual and one probe.NamedFactory is APPENDED at the
marker, which stays in place for the next one.

Modules are never touched: they are runtime flags naming collectors, so adding a
collector cannot invalidate one. --variant background stays refused on multi: a
goroutine per probe on a per-request collector is an unbounded leak."
```

---

### Task 8: Update the taught knowledge and the ledgers

The plugin's own documentation still describes a one-collector multi runtime. A
scaffolding plugin whose taught references contradict its templates is worse than
one with no references.

**Files:**
- Modify: `skills/prometheus-exporter/references/exporter-architecture.md`
- Modify: `skills/prometheus-exporter/references/collector-pattern.md:97-99` (documents the pre-`ctx` constructor signature)
- Modify: `skills/prometheus-exporter/references/project-scaffold.md:137` (shows a `register(…)` call without `context.Background()`)
- Modify: `skills/prometheus-exporter/assets/docs/configuration.md.tmpl` (shipped doc; the multi-target timeout section still names the renamed flag)
- Modify: `ROADMAP.md` (the v0.3 section's two follow-ups)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

- [ ] **Step 0b: Fix the shipped configuration doc, which the Task 3 flag rename made wrong for multi-target**

Task 3 renamed `--collector.example.timeout` to `--probe.timeout` in the multi
main and added `--probe.timeout-offset`. `assets/docs/configuration.md.tmpl`
still documents the old formula, and this doc **ships into every generated
exporter**, so the lie reaches real users. The `X-Prometheus-Scrape-Timeout-Seconds`
bullet currently reads:

```
- **`X-Prometheus-Scrape-Timeout-Seconds`**: Prometheus sends this header on
  every scrape; the handler uses `min(header, --collector.example.timeout)`
  as the request's own timeout, so a probe never outruns Prometheus's
  deadline or the operator's configured ceiling.
```

First read the file and confirm how it is scaffolded: the surrounding bullets
(`--probe.target-allowlist`, the `/probe` floor, the SSRF posture) are
multi-target content, so establish whether this section ships only into multi
scaffolds or into both, before editing. Then correct the formula to Task 3's
actual calculation and document both new flags. The corrected bullet must state
`min(--probe.timeout, X-Prometheus-Scrape-Timeout-Seconds - --probe.timeout-offset)`
and explain the offset (the exporter answers before Prometheus abandons the
scrape). Do not invent defaults: read them from
`assets/mains/multi/main.go.tmpl` (`--probe.timeout` default `5s`,
`--probe.timeout-offset` default `0.5s`). If the single-target flavor still uses
`--collector.example.timeout`, do not remove that name where it is genuinely
still correct for single; fix only the multi-target claim. Verify every value
against the real template before writing it.

- [ ] **Step 0: Correct the constructor signature in the two references that still teach the old one**

Task 1 added a leading `ctx context.Context` to `NewExampleCollector`. Two taught
references still show the old signature, and they are what the skill reads when
it generates or extends an exporter. A reference that contradicts the template it
describes is worse than no reference: it teaches a shape that will not compile.

In `skills/prometheus-exporter/references/collector-pattern.md`, lines 97-99
currently read:

```
   `NewExampleCollector(log *logger.Logger, client *Client)`. CLI:
   `NewExampleCollector(log *logger.Logger, timeout time.Duration)`. Builds
```

Update both signatures to lead with `ctx context.Context`, and add one sentence
saying why the context arrives at construction rather than at `Collect`:
`prometheus.Collector.Collect(ch)` takes no context, so the constructor is the
only channel. In a single-target exporter that context is
`context.Background()`; in a multi-target probe it is the probe's deadline.

In `skills/prometheus-exporter/references/project-scaffold.md`, line 137 currently
reads:

```go
	return collector.NewExampleCollector(log, collector.NewClient(*exampleTarget, *exampleTimeout))
```

Update it to match the shipped `code/http/wiring/registry.frag` exactly:

```go
	return collector.NewExampleCollector(context.Background(), log, collector.NewClient(*exampleTarget, *exampleTimeout))
```

Read both files before editing: verify every claim you write against the real
template, not against this plan.

- [ ] **Step 1: Correct the architecture reference**

Read `skills/prometheus-exporter/references/exporter-architecture.md` and find
every passage describing the multi-target runtime. Rewrite the ones that are now
false. At minimum, the reference must say:

- The probe handler holds an ordered slice of named factories, one per collector,
  and gathers every one it selects on a fresh registry per request.
- Each probe runs under a real deadline,
  `min(--probe.timeout, scrape_timeout - --probe.timeout-offset)`, which reaches
  the collectors through their constructor because `prometheus.Collector.Collect`
  takes no context.
- `StatusTracker` collects sequentially, so a probe costs the sum of its
  collectors, not the slowest. The deadline is what bounds that.
- `module` selects a subset of collectors per probe; absent means all of them.

Do not describe anything you have not read in the templates. Verify each claim
against `assets/internal/probe/probe.go.tmpl` before writing it.

- [ ] **Step 2: Close both follow-ups in the ROADMAP**

In `ROADMAP.md`, the v0.3 section names two remaining follow-ups: `/add-collector`
multi-target awareness, and the `module` query parameter. Both are now done. Move
them out of "remaining" and record them as delivered. They turned out to decouple
cleanly, which is worth one sentence: modules are runtime flags over collector
names, so adding a collector never invalidates a module.

- [ ] **Step 3: Write the changelog entry**

Add to `CHANGELOG.md` under `[Unreleased]`. Lead with the breaking change, because
that is what a reader upgrading needs first:

```markdown
### Changed

- **Breaking (multi-target only):** `--collector.example.timeout` is renamed
  `--probe.timeout`. The old name never configured the `example` collector: it
  bounded every probe. With one collector the two were the same thing, so the lie
  was invisible. `/add-collector` migrates a v0.3.0 scaffold and shows the diff
  first.

### Added

- Multi-target exporters hold more than one collector. `/add-collector` now works
  on a `--target-model multi` scaffold instead of refusing and handing over a
  manual procedure.
- `/probe?target=…&module=…` selects a subset of an exporter's collectors. The
  parameter is repeatable and comma-separated, and named modules combine, as in
  the SNMP exporter. An absent `module` runs every collector, so an existing
  scrape config keeps working.
- `--probe.timeout-offset` (default `0.5s`) is subtracted from Prometheus's
  scrape timeout so a probe answers before Prometheus abandons the scrape.
- `probe_timeout_seconds` is exported alongside `probe_success` and
  `probe_duration_seconds`.

### Fixed

- Collectors now run under a context that can actually be cancelled. `Collect`
  minted its own `context.Background()`, so the context threaded through the
  collector's I/O carried no deadline and cancellation was plumbed and then
  thrown away. In a multi-target probe this meant a hanging target ran until its
  HTTP client timeout with nothing able to interrupt it. Single-target behavior
  is unchanged: it passes `context.Background()` explicitly, which is exactly the
  value `Collect` minted for itself.
```

- [ ] **Step 4: Run every gate**

```bash
bash test/zero-source-grep.sh
claude plugin validate .
bash test/scaffold_test.sh
bash test/scaffold_edge_test.sh
bash test/scaffold_multitarget_test.sh
bash test/golden-smoke.sh --all
```

Expected: all green. `--all` is the slow one and the one that matters.

- [ ] **Step 5: Commit**

```bash
git add skills/prometheus-exporter/references/exporter-architecture.md ROADMAP.md CHANGELOG.md
git -c commit.gpgsign=false commit -m "docs(plugin): the multi runtime holds N collectors and selects them per probe

The architecture reference still described a one-collector probe. A scaffolding
plugin whose taught references contradict its own templates is worse than one
with no references at all.

Closes both v0.3 follow-ups: /add-collector multi-target awareness and the module
query parameter. They decoupled cleanly in the end, because modules are runtime
flags naming collectors, so adding a collector can never invalidate one."
```

---

## Self-review

**Spec coverage.** Every section of
`docs/design/2026-07-12-add-collector-multi-target-design.md` maps to a task:
§3.1 (N factories) → Task 2. §3.2 (appendable frag) → Tasks 1 and 2. §3.3 (real
deadline, `--probe.timeout`, `--probe.timeout-offset`, `probe_timeout_seconds`)
→ Tasks 1 and 3. §3.4 (`--probe.module`, startup validation) → Task 4. §3.5
(module semantics, union, 400) → Task 5. §3.6 (`/add-collector` detection,
migration, wiring) → Task 7. §3.7 (the two refusals) → Task 7. §4 (files touched)
→ the File structure section above. §5 (testing) → the tests inside Tasks 2-5 plus
Task 6, which carries the golden proof. §6 (non-regression) → Task 1 Step 7 and
Task 3 Step 11, both of which run the single-target golden cells. §8 (out of
scope) → nothing in this plan touches concurrency, YAML modules, per-collector
timeouts, or the TTL-cache variant.

**One deliberate deviation from the spec, already agreed.** The spec's §4
originally listed the background collector variants among the files to touch,
"for consistency of the taught shape". That was wrong on the facts: a background
collector's `Collect` reads a cache under a mutex and never calls
`context.Background()`, and its I/O already runs under `Start(ctx)`'s real
context. Giving it a constructor `ctx` would add a field nothing reads, to a
collector that already has a live context, in a repository whose `CLAUDE.md`
forbids dead code. §4 has been corrected in the spec; this plan does not touch
those four files.

**Type consistency.** `NewExampleCollector(ctx, log, client)` (http) and
`NewExampleCollector(ctx, log, timeout)` (cli) are introduced in Task 1 and used
unchanged in Tasks 2, 3, 6 and 7. `NamedFactory{Name, New}` is introduced in Task
2 and used unchanged thereafter. `NewHandler` grows arguments in a declared
order, once per task, and every task that changes it updates the test helper in
the same commit: Task 2 `(log, factories, allowlist, maxTimeout)`, Task 3
`(…, timeoutOffset)`, Task 4 `(…, modules)`. `Factory` gains its `ctx` in Task 3
only, which is why Task 2's frag still passes `context.Background()`: it keeps
each commit compiling on its own.

**Sequencing constraint.** Tasks 1 through 5 must land in order. Each one leaves
the templates compiling, and each depends on the previous task's signature. Task
6 depends on Task 2 (the marker seam) and Task 5 (modules, for its live check).
Tasks 7 and 8 depend on everything before them but not on each other.
