# Configuration reload and concurrency ceiling: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a scaffolded `multi` or `multi-instance` exporter a real
configuration reload (SIGHUP always, `POST /-/reload` behind
`--web.enable-lifecycle`), and give `multi-instance` and `single` an opt-in
ceiling on concurrent requests per target.

**Architecture:** One swappable transport per watched machine is the shared
groundwork for both halves. `internal/collector` gains a `Transport` (an
`*http.Client` behind an atomic pointer) and a `Limiter` (a semaphore);
`internal/reload` owns the mechanism (signal, endpoint, serialization,
prepare/commit, metrics) while each `main.go` supplies the policy;
`internal/instance` gains a `Handle` per machine and a reconciler that boot
and reload both go through, so the reload path is exercised on every start.

**Tech Stack:** Go 1.26.5, `prometheus/client_golang` v1.24.1,
`prometheus/common` v0.70.1, `prometheus/exporter-toolkit` v0.17.1,
`alecthomas/kingpin/v2` v2.4.0, POSIX sh for `scaffold.sh` and the golden
harness.

**Spec:** [`docs/design/2026-07-28-config-reload-and-concurrency-design.md`](../design/2026-07-28-config-reload-and-concurrency-design.md)

## Global Constraints

- **Scope.** Reload ships for `multi` and `multi-instance` only. The
  concurrency ceiling ships for `multi-instance` and `single` only. `single`
  gets no reload and `multi` gets no ceiling, both documented with their
  reason.
- **`single` must stay byte-identical at runtime.** `NewClient(target,
  timeout)` keeps its signature, keeps building its own private
  `http.Client{Timeout: timeout}`, and leaves `Client.timeout` at zero. Every
  shipped collector test calls it, and so does every repository scaffolded
  before this change.
- **Defaults do not move.** `--web.enable-lifecycle` defaults to `false`.
  `--exporter.max-requests-per-target` defaults to `0`, meaning unlimited.
- **`flags:` is never reloadable.** A reload that finds that section changed
  refuses the whole reload and names the differing keys.
- **Atomicity is structural.** Every reload splits into a prepare phase that
  may fail and mutates nothing, and a commit phase that cannot fail.
- **[G]/[S] discipline.** No concrete data source, metric prefix, endpoint
  path or owner handle enters a template. Use `@@VAR@@`.
- **English only** in every shipped artifact: `assets/`, `commands/`,
  `agents/`, `skills/`, `references/`.
- **No em dashes or en dashes** anywhere under `skills/prometheus-exporter/assets/`
  or `skills/prometheus-exporter/scripts/`. Use `.`, `,`, `:` or parentheses.
- **Conventional Commits** with a scope: `feat(collector):`, `fix(reload):`,
  `docs(skill):`, `test(instance):`.
- **Gates before any commit that touches `assets/`:** `sh test/zero-source-grep.sh`
  must PASS. Gates before declaring a task done: the task's own tests, plus
  `go test -race ./...` inside a scaffolded exporter for any task touching Go
  templates.
- **Never claim a gate passed without pasting its output.** Evidence precedes
  assertion.

## File structure

| File | Responsibility |
|---|---|
| `assets/code/http/client.go.tmpl` (modify) | `Transport`, `Client`, the four constructors, `Fetch` with its context deadline and limiter acquisition |
| `assets/code/http/limiter.go.tmpl` (create) | `Limiter`, `LimiterSet`, `RequestWait` histogram |
| `assets/code/http/limiter_test.go.tmpl` (create) | Ceiling respected, context cancellation, zero means pass-through |
| `assets/code/cli/client.go.tmpl` (modify) | The cli flavor's equivalent `Limiter` plumbing only where it has an I/O boundary |
| `assets/internal/config/config.go.tmpl` (modify) | `DiffFlags` |
| `assets/internal/reload/reload.go.tmpl` (create) | `Reloader`: signal, endpoint, serialization, the two gauges |
| `assets/internal/reload/reload_test.go.tmpl` (create) | Serialization, fail-closed, flags refusal, handler status |
| `assets/internal/probe/probe.go.tmpl` (modify) | `handlerConfig` behind `atomic.Pointer`, `SetConfig` |
| `assets/internal/instance/instance.go.tmpl` (modify) | `Handle`, the new `Factory` shape, `Registry` with `Prepare`/`Commit` |
| `assets/internal/instance/instance_test.go.tmpl` (modify) | The five diff cases |
| `assets/mains/multi/main.go.tmpl` (modify) | Reload policy for `multi`, `--web.enable-lifecycle` |
| `assets/mains/multi-instance/main.go.tmpl` (modify) | Reload policy for `multi-instance`, boot through the reconciler |
| `assets/code/http/wiring/instance_factory.frag` (modify) | Factory closure on the new signature |
| `assets/code/http/wiring/client_build.frag` (modify) | `single`'s limiter lookup |
| `assets/scaffold.sh` (modify) | Select `internal/reload/` for `multi` and `multi-instance` |
| `commands/add-collector.md` (modify) | Fourth seam shape, refuse and point at rescaffolding |
| `commands/design-exporter.md` (modify) | The conditional concurrency question |
| `commands/new-prometheus-exporter.md` (modify) | Apply the brief's answer |
| `skills/prometheus-exporter/references/*.md` (modify) | Six documents |
| `assets/SECURITY.md.tmpl`, `assets/monitoring/`, `assets/systemd/` (modify) | Posture, alert rule, `ExecReload` |
| `test/golden-smoke.sh` (modify) | Reload assertions on the two cells |

---

# Tranche 1: groundwork in `internal/collector`

No observable behaviour changes in this tranche. The existing collector
tests are the non-regression proof.

## Task 1: a swappable transport under the client

**Files:**
- Modify: `skills/prometheus-exporter/assets/code/http/client.go.tmpl`
- Test: `skills/prometheus-exporter/assets/code/http/collector_test.go.tmpl`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `type Transport struct{ ... }`
  - `func NewTransport(hc *http.Client) *Transport`
  - `func (t *Transport) Set(hc *http.Client)`
  - `func (t *Transport) Get() *http.Client`
  - `func NewClientOn(tr *Transport, target string, timeout time.Duration) *Client`
  - unchanged: `NewClient(target string, timeout time.Duration) *Client`,
    `NewClientFor(target string, hc *http.Client) *Client`,
    `NewClientWithConfig(target string, timeout time.Duration, httpCfg promconfig.HTTPClientConfig) (*Client, error)`,
    `NewHTTPClient(httpCfg promconfig.HTTPClientConfig, timeout time.Duration) (*http.Client, error)`,
    `func (c *Client) Fetch(ctx context.Context, path string) ([]byte, error)`

- [ ] **Step 1: Write the failing test**

Append to `collector_test.go.tmpl`:

```go
// TestTransportSetIsVisibleToExistingClients proves the reload seam: a Client
// built on a Transport picks up a replacement *http.Client without being
// rebuilt. This is what lets a multi-instance reload rotate credentials
// without stopping the poller and dropping its cache.
func TestTransportSetIsVisibleToExistingClients(t *testing.T) {
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("first"))
	}))
	defer first.Close()

	tr := NewTransport(&http.Client{})
	c := NewClientOn(tr, first.URL, time.Second)

	got, err := c.Fetch(context.Background(), "/")
	if err != nil {
		t.Fatalf("first fetch: %v", err)
	}
	if string(got) != "first" {
		t.Fatalf("first fetch returned %q, want %q", got, "first")
	}

	// Swap the transport for one that refuses every request, and prove the
	// SAME Client now uses it.
	tr.Set(&http.Client{Transport: refusingRoundTripper{}})
	if _, err := c.Fetch(context.Background(), "/"); err == nil {
		t.Fatal("fetch succeeded after Transport.Set installed a refusing client")
	}
}

// refusingRoundTripper fails every request, so a test can prove which
// transport a Client actually used.
type refusingRoundTripper struct{}

func (refusingRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("refused by test transport")
}

// TestNewClientOnAppliesItsOwnTimeout proves two collectors can share one
// transport and still carry different per-collector deadlines, which
// http.Client.Timeout cannot express because it lives on the shared client.
func TestNewClientOnAppliesItsOwnTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write([]byte("slow"))
	}))
	defer srv.Close()

	tr := NewTransport(&http.Client{})
	quick := NewClientOn(tr, srv.URL, 20*time.Millisecond)
	patient := NewClientOn(tr, srv.URL, 5*time.Second)

	if _, err := quick.Fetch(context.Background(), "/"); err == nil {
		t.Fatal("the 20ms client did not time out against a 200ms handler")
	}
	if _, err := patient.Fetch(context.Background(), "/"); err != nil {
		t.Fatalf("the 5s client failed against a 200ms handler: %v", err)
	}
}

// TestNewClientKeepsItsPrivateTimeout pins the non-regression contract: the
// constructor every shipped collector test and every pre-v0.7 scaffold calls
// still enforces its deadline through http.Client.Timeout, not through a
// context, so its connection behaviour is untouched.
func TestNewClientKeepsItsPrivateTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
	}))
	defer srv.Close()

	c := NewClient(srv.URL, 20*time.Millisecond)
	if c.timeout != 0 {
		t.Fatalf("NewClient set Client.timeout to %v; it must stay 0 so the private http.Client.Timeout remains the only deadline", c.timeout)
	}
	if _, err := c.Fetch(context.Background(), "/"); err == nil {
		t.Fatal("NewClient's 20ms timeout did not fire")
	}
}
```

Add `"errors"` to the test file's imports if absent.

- [ ] **Step 2: Run the tests to verify they fail**

Scaffold a throwaway exporter and run them:

```bash
A=skills/prometheus-exporter/assets
rm -rf /tmp/t1 && mkdir -p /tmp/t1
sh "$A/scaffold.sh" --src "$A" --dst /tmp/t1 --flavor http --forge none --target-model single --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var DEFAULT_PORT=9999 \
  --var OWNER=acme --var LICENSE=apache-2.0 --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/t1 && go test ./internal/collector/ -run 'TestTransport|TestNewClientOn|TestNewClientKeeps' -v
```

Expected: FAIL, `undefined: NewTransport`, `undefined: NewClientOn`.

- [ ] **Step 3: Implement**

In `client.go.tmpl`, replace the `Client` struct and `NewClient` with:

```go
// Transport holds the *http.Client every Client bound to one machine shares.
// The pointer is atomic so a configuration reload can replace the transport
// underneath collectors that are already running: their next request uses the
// new credentials, their goroutine is never stopped, and their cache survives.
//
// A nil-safe zero value is deliberately NOT offered: a Transport with no
// client would fail every request with a confusing nil dereference, and every
// construction path here supplies one.
type Transport struct {
	hc atomic.Pointer[http.Client]
}

// NewTransport wraps an already-built *http.Client. Build the client with
// NewHTTPClient so its authentication and TLS come from the configuration.
func NewTransport(hc *http.Client) *Transport {
	t := &Transport{}
	t.hc.Store(hc)
	return t
}

// Set replaces the shared client. Callers should call CloseIdleConnections on
// the one they replaced: it only closes IDLE connections, so a request already
// in flight on the old client finishes undisturbed.
func (t *Transport) Set(hc *http.Client) { t.hc.Store(hc) }

// Get returns the client in force right now. Fetch calls it once per request,
// so a request that starts before a reload completes runs entirely on the
// transport it started with.
func (t *Transport) Get() *http.Client { return t.hc.Load() }

// Client is the HTTP boundary every collector in this flavor talks to.
// Building it around a base URL, instead of reaching for http.DefaultClient
// directly from a collector, is what makes collectors testable: point
// NewClient at an httptest.Server instead of a real target.
//
// There are two deadline mechanisms here and exactly one is active per
// construction path, which is what keeps the pre-v0.7 path unchanged:
//
//   - NewClient owns a PRIVATE *http.Client and puts the deadline on its
//     Timeout field, leaving c.timeout at zero. This is what every shipped
//     collector test and every repository scaffolded before v0.7 uses, and its
//     connection behaviour is identical to what it always was.
//   - NewClientOn SHARES a Transport with the other collectors of one machine,
//     so the deadline cannot live on http.Client.Timeout (it would be the same
//     for all of them). It goes in c.timeout and Fetch applies it as a context
//     deadline instead, which is what lets one collector wait fifteen minutes
//     while its sibling waits five seconds.
type Client struct {
	tr      *Transport
	baseURL string
	timeout time.Duration // 0 means "the deadline is on the shared-nothing http.Client"
	limiter *Limiter      // nil means unlimited, see limiter.go
}

// NewClient builds a Client bound to target (a base URL, for example
// "http://localhost:9100"), applying timeout to every request. Unchanged
// since v0.1: its transport is private to this Client and its deadline is
// http.Client.Timeout.
func NewClient(target string, timeout time.Duration) *Client {
	return &Client{
		tr:      NewTransport(&http.Client{Timeout: timeout}),
		baseURL: target,
	}
}

// NewClientOn binds a Client to a SHARED Transport, with its own per-collector
// deadline and an optional concurrency limiter. This is the multi-instance
// construction path: one Transport and one Limiter per watched machine, one
// Client per collector polling it.
//
// A non-positive timeout is a programming error rather than "no deadline": the
// shared http.Client carries no Timeout of its own, so a collector reaching
// here without one would hang its poller forever. Callers that take the
// timeout from a flag should reject a non-positive value at boot; see
// instance.Handle.ClientFor, which returns an error for exactly this.
func NewClientOn(tr *Transport, target string, timeout time.Duration) *Client {
	return &Client{tr: tr, baseURL: target, timeout: timeout}
}

// WithLimiter returns the same Client bound to lim, which bounds how many
// requests this exporter has in flight against one machine at a time. A nil
// limiter means unlimited, which is the default.
func (c *Client) WithLimiter(lim *Limiter) *Client {
	c.limiter = lim
	return c
}
```

Keep `NewClientFor`, `NewClientWithConfig` and `NewHTTPClient` as they are, but
have `NewClientFor` build its Transport:

```go
// NewClientFor binds an already-built *http.Client to one base URL. Many
// targets share one *http.Client, each paying only this struct.
func NewClientFor(target string, hc *http.Client) *Client {
	return &Client{tr: NewTransport(hc), baseURL: target}
}
```

Then rework `Fetch`'s head:

```go
func (c *Client) Fetch(ctx context.Context, path string) (data []byte, err error) {
	start := time.Now()
	defer func() {
		outcome := "success"
		if err != nil {
			outcome = "error"
		}
		RequestDuration.WithLabelValues(outcome).Observe(time.Since(start).Seconds())
	}()

	// The per-collector deadline, for clients sharing a Transport. Applied
	// before the limiter on purpose: time spent waiting for a slot is charged
	// against this collector's own budget, never added on top of it, so a
	// starved poller fails its refresh and says so instead of silently
	// stretching its effective interval while time.Ticker drops its ticks.
	if c.timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, c.timeout)
		defer cancel()
	}

	release, err := c.limiter.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("wait for a request slot for %s: %w", path, err)
	}
	defer release()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	// ... unchanged from here down, except:
	resp, err := c.tr.Get().Do(req)
	// ... unchanged
}
```

Add `"sync/atomic"` to the imports.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /tmp/t1 && go test ./internal/collector/ -race -v 2>&1 | tail -20
```

Expected: PASS, including every pre-existing test in the file. If
`TestNewClientForSharesOneTransport` fails, `NewClientFor` is no longer
sharing: two Clients built from one `*http.Client` must still reach the same
transport.

- [ ] **Step 5: Mirror the cli flavor**

`assets/code/cli/client.go.tmpl` has no `*http.Client`, so it gets no
`Transport`. It needs only the limiter field and the `Acquire` call, which
Task 2 adds. Confirm nothing in the cli flavor referenced the fields renamed
above:

```bash
grep -n "httpClient" skills/prometheus-exporter/assets/code/cli/*.tmpl || echo "cli flavor untouched"
```

- [ ] **Step 6: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/code/http/client.go.tmpl \
        skills/prometheus-exporter/assets/code/http/collector_test.go.tmpl
git commit -m "feat(collector): put the shared http.Client behind a swappable Transport

A Client built with NewClientOn shares one Transport with the other collectors
of the same machine, so a reload can replace the credentials underneath a
running poller without stopping it and dropping its cache. Sharing the
transport means the deadline can no longer live on http.Client.Timeout, which
would be identical for every collector on it, so NewClientOn carries a
per-collector timeout that Fetch applies as a context deadline.

NewClient is untouched: private transport, deadline on http.Client.Timeout,
Client.timeout left at zero. That is the constructor every shipped collector
test and every repository scaffolded before this change calls, and a test now
pins that contract rather than trusting it."
```

---

## Task 2: the concurrency limiter

**Files:**
- Create: `skills/prometheus-exporter/assets/code/http/limiter.go.tmpl`
- Create: `skills/prometheus-exporter/assets/code/http/limiter_test.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/code/http/client.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/code/cli/client.go.tmpl`

> **Amended after Task 1.** This task, not Task 1, owns the `Client.limiter`
> field, the `WithLimiter` method and the `c.limiter.Acquire(ctx)` call in
> `Fetch`. Task 1 deferred them, correctly: `Limiter` does not exist until this
> task, so wiring them earlier left `internal/collector` uncompilable in every
> flavor. Add them here, in the same commit that creates `limiter.go.tmpl`.

**Interfaces:**
- Consumes: `Client` and `Fetch` as Task 1 left them.
- Produces:
  - `func NewLimiter(limit int) *Limiter` (returns nil when `limit <= 0`)
  - `func (l *Limiter) Acquire(ctx context.Context) (release func(), err error)`
  - `func NewLimiterSet(limit int) *LimiterSet`
  - `func (s *LimiterSet) For(target string) *Limiter`
  - `var RequestWait *prometheus.HistogramVec`

- [ ] **Step 1: Write the failing test**

Create `limiter_test.go.tmpl`:

```go
package collector

import (
	"context"
	"sync"
	"testing"
	"time"
)

// TestNilLimiterIsPassThrough pins the default: --exporter.max-requests-per-target
// is 0, NewLimiter returns nil for that, and a nil *Limiter must cost nothing
// and never block.
func TestNilLimiterIsPassThrough(t *testing.T) {
	var l *Limiter
	if NewLimiter(0) != nil {
		t.Fatal("NewLimiter(0) returned a limiter; 0 must mean unlimited")
	}
	if NewLimiter(-1) != nil {
		t.Fatal("NewLimiter(-1) returned a limiter; a non-positive ceiling must mean unlimited")
	}
	release, err := l.Acquire(context.Background())
	if err != nil {
		t.Fatalf("nil limiter refused an acquisition: %v", err)
	}
	release()
}

// TestLimiterEnforcesItsCeiling proves the third caller waits while two hold
// slots, and proceeds as soon as one is released.
func TestLimiterEnforcesItsCeiling(t *testing.T) {
	l := NewLimiter(2)

	r1, err := l.Acquire(context.Background())
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	r2, err := l.Acquire(context.Background())
	if err != nil {
		t.Fatalf("second acquire: %v", err)
	}

	third := make(chan struct{})
	go func() {
		r3, err := l.Acquire(context.Background())
		if err == nil {
			r3()
		}
		close(third)
	}()

	select {
	case <-third:
		t.Fatal("the third acquire proceeded while both slots were held")
	case <-time.After(50 * time.Millisecond):
	}

	r1()
	select {
	case <-third:
	case <-time.After(2 * time.Second):
		t.Fatal("the third acquire did not proceed after a slot was released")
	}
	r2()
}

// TestLimiterAcquireHonoursContext is the property that keeps a ceiling from
// degrading silently: a starved caller fails on its own deadline instead of
// queueing forever while its ticker drops ticks.
func TestLimiterAcquireHonoursContext(t *testing.T) {
	l := NewLimiter(1)
	release, err := l.Acquire(context.Background())
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	defer release()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := l.Acquire(ctx); err == nil {
		t.Fatal("Acquire returned success on an expired context while the only slot was held")
	}
}

// TestLimiterReleaseIsSafeUnderConcurrency runs the ceiling under -race with
// more callers than slots, and asserts the ceiling was never exceeded.
func TestLimiterReleaseIsSafeUnderConcurrency(t *testing.T) {
	const ceiling = 3
	l := NewLimiter(ceiling)

	var mu sync.Mutex
	inFlight, peak := 0, 0

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			release, err := l.Acquire(context.Background())
			if err != nil {
				t.Errorf("acquire: %v", err)
				return
			}
			mu.Lock()
			inFlight++
			if inFlight > peak {
				peak = inFlight
			}
			mu.Unlock()

			time.Sleep(time.Millisecond)

			mu.Lock()
			inFlight--
			mu.Unlock()
			release()
		}()
	}
	wg.Wait()

	if peak > ceiling {
		t.Fatalf("peak concurrency was %d, ceiling is %d", peak, ceiling)
	}
	if peak == 0 {
		t.Fatal("no goroutine was ever observed in flight; the test proved nothing")
	}
}

// TestLimiterSetGroupsByTarget proves two collectors on the same address share
// one ceiling and two collectors on different addresses do not.
func TestLimiterSetGroupsByTarget(t *testing.T) {
	s := NewLimiterSet(4)
	if s.For("http://a.example") != s.For("http://a.example") {
		t.Fatal("LimiterSet handed out two limiters for one target")
	}
	if s.For("http://a.example") == s.For("http://b.example") {
		t.Fatal("LimiterSet shared one limiter across two targets")
	}
	if NewLimiterSet(0).For("http://a.example") != nil {
		t.Fatal("a LimiterSet built with ceiling 0 handed out a non-nil limiter")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /tmp/t1 && go test ./internal/collector/ -run TestLimiter -run TestNilLimiter -v
```

Expected: FAIL, `undefined: NewLimiter`.

- [ ] **Step 3: Implement**

Create `limiter.go.tmpl`:

```go
package collector

import (
	"context"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// RequestWait records how long a request waited for a concurrency slot before
// it was issued. Unlabelled, like RequestDuration next to it: the exporter's
// own registry carries no per-instance label, and the per-collector freshness
// gauge the background variant already emits is what identifies WHICH
// collector is starving. This one answers whether anything is queueing at all.
//
// Observed even when no ceiling is configured (the wait is then zero), so the
// series exists from the first scrape and an operator can tell "no ceiling" from
// "the metric is missing".
var RequestWait = prometheus.NewHistogram(prometheus.HistogramOpts{
	Name: "@@NAMESPACE@@_exporter_request_wait_seconds",
	Help: "Duration in seconds a request waited for a per-target concurrency slot before being issued.",
})

// Limiter bounds how many requests this exporter has in flight against one
// target at a time. It exists because every collector under the multi-instance
// target model is a background poller with its own goroutine and its own
// ticker, entirely outside the sequential collection StatusTracker performs, so
// nothing else caps how many of them hit one machine at once.
//
// A nil *Limiter is a valid, unlimited limiter. That is the default
// (--exporter.max-requests-per-target is 0), so the common path costs one nil
// check and no allocation.
type Limiter struct {
	slots chan struct{}
}

// NewLimiter returns a limiter admitting at most limit concurrent requests, or
// nil when limit is not positive, meaning unlimited.
func NewLimiter(limit int) *Limiter {
	if limit <= 0 {
		return nil
	}
	return &Limiter{slots: make(chan struct{}, limit)}
}

// Acquire blocks until a slot is free or ctx is done, and returns the function
// that gives the slot back. The returned release is always safe to call, and
// is a no-op when err is non-nil, so callers can defer it unconditionally
// after checking the error.
//
// Honouring ctx is what makes a ceiling safe to turn on: the caller's own
// deadline (a collector's --collector.<name>.timeout) bounds the wait, so a
// starved poller fails its refresh, logs, and keeps its previous cache. Without
// it the poller would sit in the queue while time.Ticker silently dropped its
// ticks and the effective refresh interval drifted with nothing reporting it.
func (l *Limiter) Acquire(ctx context.Context) (func(), error) {
	if l == nil {
		return func() {}, nil
	}
	start := time.Now()
	select {
	case l.slots <- struct{}{}:
		RequestWait.Observe(time.Since(start).Seconds())
		var once sync.Once
		return func() { once.Do(func() { <-l.slots }) }, nil
	case <-ctx.Done():
		RequestWait.Observe(time.Since(start).Seconds())
		return func() {}, ctx.Err()
	}
}

// LimiterSet indexes one Limiter per target address. It exists for the
// single-target model, where each collector carries its own
// --collector.<name>.target and there is no shared per-machine object to hang a
// ceiling on: collectors naming the same address must share one ceiling, and
// collectors naming different addresses must not.
//
// The multi-instance model does NOT use this: there, instance.Handle owns one
// Limiter per watched machine by construction, so an instance added by a reload
// gets its own without anything having to be pre-populated. Keeping that model
// off this index is deliberate, because a pre-populated map would silently fail
// to cover an instance added later.
//
// For is called at startup only, over the finite and immutable set of target
// flags, so the key space is never caller-controlled.
type LimiterSet struct {
	limit int

	mu       sync.Mutex
	byTarget map[string]*Limiter
}

// NewLimiterSet returns a set handing out limiters with the given ceiling. A
// non-positive ceiling makes every For return nil, meaning unlimited.
func NewLimiterSet(limit int) *LimiterSet {
	return &LimiterSet{limit: limit, byTarget: make(map[string]*Limiter)}
}

// For returns the limiter shared by every collector pointed at target.
func (s *LimiterSet) For(target string) *Limiter {
	if s == nil || s.limit <= 0 {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if l, ok := s.byTarget[target]; ok {
		return l
	}
	l := NewLimiter(s.limit)
	s.byTarget[target] = l
	return l
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /tmp/t1 && go test ./internal/collector/ -race -v 2>&1 | tail -25
```

Expected: PASS on all five new tests plus every pre-existing one.

- [ ] **Step 5: Give the cli flavor the same boundary**

`assets/code/cli/client.go.tmpl` executes a command rather than issuing HTTP,
but its `Run` is the same I/O boundary and the same ceiling applies. Add the
field and the acquisition, mirroring Task 1's shape:

```go
// limiter bounds how many invocations of the target command run at once. nil
// means unlimited, the default. See internal/collector/limiter.go.
limiter *Limiter
```

and at the top of the exec function, after any per-command deadline is applied:

```go
release, err := c.limiter.Acquire(ctx)
if err != nil {
	return nil, fmt.Errorf("wait for a run slot: %w", err)
}
defer release()
```

Then copy `limiter.go.tmpl` and `limiter_test.go.tmpl` to
`assets/code/cli/`, since `code/<flavor>/` is staging and only the selected
flavor's files reach `internal/collector/`.

- [ ] **Step 6: Prove both flavors**

```bash
cd /tmp/t1 && go test ./... -race 2>&1 | tail -5
# then scaffold the cli flavor into /tmp/t1cli the same way and:
cd /tmp/t1cli && go test ./... -race 2>&1 | tail -5
```

Expected: PASS in both.

- [ ] **Step 7: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/code/http/limiter.go.tmpl \
        skills/prometheus-exporter/assets/code/http/limiter_test.go.tmpl \
        skills/prometheus-exporter/assets/code/cli/limiter.go.tmpl \
        skills/prometheus-exporter/assets/code/cli/limiter_test.go.tmpl \
        skills/prometheus-exporter/assets/code/cli/client.go.tmpl
git commit -m "feat(collector): add an opt-in per-target concurrency ceiling

Every collector under multi-instance is a background poller owning its own
goroutine and ticker, outside the sequential collection StatusTracker performs,
so nothing caps how many of them hit one machine at once. Limiter is that cap:
nil means unlimited, which is the default, so the common path costs one nil
check.

Acquire honours the caller's context, which is what makes the ceiling safe to
turn on. The wait is charged against the collector's own timeout rather than
added on top of it, so a starved poller fails its refresh and says so instead
of queueing while time.Ticker drops its ticks and the effective interval
drifts unreported.

LimiterSet indexes by target for the single-target model, which has no shared
per-machine object. multi-instance deliberately does not use it: a
pre-populated index would silently fail to cover an instance added by a reload."
```

---

# Tranche 2: the reload mechanism, and `multi`

## Task 3: naming the flags a reload cannot apply

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/config/config.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl`

**Interfaces:**
- Consumes: `Config.Flags map[string]interface{}` (already exists).
- Produces: `func DiffFlags(a, b *Config) []string`, returning sorted keys
  whose value differs, including keys present in only one of the two.

- [ ] **Step 1: Write the failing test**

```go
func TestDiffFlagsNamesEveryChangedKey(t *testing.T) {
	boot := &Config{Flags: map[string]interface{}{
		"log.level":         "info",
		"web.listen-address": []interface{}{":9999"},
	}}
	next := &Config{Flags: map[string]interface{}{
		"log.level":         "debug", // changed
		"collector.example": false,   // added
		// web.listen-address removed
	}}

	got := DiffFlags(boot, next)
	want := []string{"collector.example", "log.level", "web.listen-address"}
	if len(got) != len(want) {
		t.Fatalf("DiffFlags returned %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("DiffFlags returned %v, want %v (sorted)", got, want)
		}
	}
}

func TestDiffFlagsIsEmptyForIdenticalSections(t *testing.T) {
	a := &Config{Flags: map[string]interface{}{"log.level": "info", "x": []interface{}{1, 2}}}
	b := &Config{Flags: map[string]interface{}{"x": []interface{}{1, 2}, "log.level": "info"}}
	if got := DiffFlags(a, b); len(got) != 0 {
		t.Fatalf("DiffFlags reported %v for two identical sections", got)
	}
}

func TestDiffFlagsHandlesAbsentSections(t *testing.T) {
	if got := DiffFlags(&Config{}, &Config{}); len(got) != 0 {
		t.Fatalf("DiffFlags reported %v for two configs with no flags section", got)
	}
	got := DiffFlags(&Config{}, &Config{Flags: map[string]interface{}{"log.level": "debug"}})
	if len(got) != 1 || got[0] != "log.level" {
		t.Fatalf("DiffFlags returned %v; adding a flags section must be reported", got)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /tmp/t1 && go test ./internal/config/ -run TestDiffFlags -v
```

Expected: FAIL, `undefined: DiffFlags`.

- [ ] **Step 3: Implement**

Append to `config.go.tmpl`:

```go
// DiffFlags returns the sorted names of every "flags:" key whose value differs
// between a and b, including keys present in only one of them.
//
// It exists because "flags:" cannot be reloaded. This package renders that
// section back into command-line arguments and lets kingpin parse them exactly
// once (see the package comment for why writing into flags after Parse is
// wrong), so a running process cannot adopt a new value for one. A reload that
// finds this section changed therefore refuses the whole reload and names these
// keys, rather than applying the other sections and leaving the process
// describing neither the old file nor the new one.
//
// reflect.DeepEqual is the right comparison here: the values are whatever YAML
// produced (scalars, bools, and []interface{} for repeatable flags), never
// functions or channels.
func DiffFlags(a, b *Config) []string {
	seen := make(map[string]bool, len(a.Flags)+len(b.Flags))
	for k := range a.Flags {
		seen[k] = true
	}
	for k := range b.Flags {
		seen[k] = true
	}

	var changed []string
	for k := range seen {
		av, aok := a.Flags[k]
		bv, bok := b.Flags[k]
		if aok != bok || !reflect.DeepEqual(av, bv) {
			changed = append(changed, k)
		}
	}
	sort.Strings(changed)
	return changed
}
```

Add `"reflect"` to the imports.

- [ ] **Step 4: Run to verify it passes**

```bash
cd /tmp/t1 && go test ./internal/config/ -race -v 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/internal/config/config.go.tmpl \
        skills/prometheus-exporter/assets/internal/config/config_test.go.tmpl
git commit -m "feat(config): name the flags: keys a reload cannot apply

flags: is rendered back into arguments and parsed once, so a running process
cannot adopt a new value for one. DiffFlags is what lets a reload refuse the
whole file and say which keys forced the refusal, instead of applying the other
sections and leaving the process describing neither the old file nor the new."
```

---

## Task 4: `internal/reload`

**Files:**
- Create: `skills/prometheus-exporter/assets/internal/reload/reload.go.tmpl`
- Create: `skills/prometheus-exporter/assets/internal/reload/reload_test.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/scaffold.sh`

**Interfaces:**
- Consumes: `config.Load`, `config.DiffFlags` (Task 3).
- Produces:
  - `func New(log *logger.Logger, path string, boot *config.Config, apply func(*config.Config) error) *Reloader`
  - `func (r *Reloader) Run(ctx context.Context)`
  - `func (r *Reloader) Handler() http.Handler`
  - `func (r *Reloader) Collectors() []prometheus.Collector`
  - `func (r *Reloader) Reload() error` (the entry point `Run` and `Handler` both funnel into; exported so a test can drive it without signals)

- [ ] **Step 1: Write the failing test**

Create `reload_test.go.tmpl`:

```go
package reload

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"@@MODULE_PATH@@/internal/config"
	"@@MODULE_PATH@@/internal/logger"
)

func writeConfig(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, "config.yml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return p
}

// TestReloadAppliesAValidFile is the happy path, and the one assertion that
// proves a reload CHANGED something rather than merely answering.
func TestReloadAppliesAValidFile(t *testing.T) {
	dir := t.TempDir()
	p := writeConfig(t, dir, "modules:\n  prod: {}\n")
	boot, err := config.Load(p)
	if err != nil {
		t.Fatalf("load: %v", err)
	}

	var applied *config.Config
	r := New(logger.NewTextLogger("error"), p, boot, func(c *config.Config) error {
		applied = c
		return nil
	})

	writeConfig(t, dir, "modules:\n  prod: {}\n  staging: {}\n")
	if err := r.Reload(); err != nil {
		t.Fatalf("reload: %v", err)
	}
	if applied == nil {
		t.Fatal("apply was never called")
	}
	if _, ok := applied.Modules["staging"]; !ok {
		t.Fatal("apply received a config without the module the new file added")
	}
	if v := testGaugeValue(t, r.successful); v != 1 {
		t.Fatalf("config_last_reload_successful is %v after a successful reload, want 1", v)
	}
	if testGaugeValue(t, r.successTime) == 0 {
		t.Fatal("the success timestamp was never advanced")
	}
}

// TestReloadKeepsTheOldConfigWhenTheNewOneIsInvalid is the assertion that
// proves atomicity: a broken file must not be applied, and must not disturb
// what is running.
func TestReloadKeepsTheOldConfigWhenTheNewOneIsInvalid(t *testing.T) {
	dir := t.TempDir()
	p := writeConfig(t, dir, "modules:\n  prod: {}\n")
	boot, _ := config.Load(p)

	calls := 0
	r := New(logger.NewTextLogger("error"), p, boot, func(*config.Config) error {
		calls++
		return nil
	})

	writeConfig(t, dir, "modules:\n  prod: {\n") // not YAML
	if err := r.Reload(); err == nil {
		t.Fatal("reload accepted a file that does not parse")
	}
	if calls != 0 {
		t.Fatalf("apply ran %d times on an unparseable file; it must never be reached", calls)
	}
	if v := testGaugeValue(t, r.successful); v != 0 {
		t.Fatalf("config_last_reload_successful is %v after a failed reload, want 0", v)
	}
}

// TestReloadRefusesAChangedFlagsSection pins the whole-file refusal and the
// message naming the offending keys.
func TestReloadRefusesAChangedFlagsSection(t *testing.T) {
	dir := t.TempDir()
	p := writeConfig(t, dir, "flags:\n  log.level: info\nmodules:\n  prod: {}\n")
	boot, _ := config.Load(p)

	calls := 0
	r := New(logger.NewTextLogger("error"), p, boot, func(*config.Config) error {
		calls++
		return nil
	})

	writeConfig(t, dir, "flags:\n  log.level: debug\nmodules:\n  prod: {}\n")
	err := r.Reload()
	if err == nil {
		t.Fatal("reload accepted a changed flags: section")
	}
	if !strings.Contains(err.Error(), "log.level") {
		t.Fatalf("the refusal does not name the offending key: %v", err)
	}
	if calls != 0 {
		t.Fatalf("apply ran %d times despite the refusal", calls)
	}
}

// TestReloadIsSerialized proves two concurrent reloads never overlap, which is
// what lets the HTTP handler report the status of ITS OWN reload.
func TestReloadIsSerialized(t *testing.T) {
	dir := t.TempDir()
	p := writeConfig(t, dir, "modules:\n  prod: {}\n")
	boot, _ := config.Load(p)

	var mu sync.Mutex
	inFlight, peak := 0, 0
	r := New(logger.NewTextLogger("error"), p, boot, func(*config.Config) error {
		mu.Lock()
		inFlight++
		if inFlight > peak {
			peak = inFlight
		}
		mu.Unlock()
		time.Sleep(5 * time.Millisecond)
		mu.Lock()
		inFlight--
		mu.Unlock()
		return nil
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.Run(ctx)

	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _ = r.Reload() }()
	}
	wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	if peak > 1 {
		t.Fatalf("%d reloads ran at once; they must be serialized", peak)
	}
}

// TestHandlerRejectsGET and TestHandlerReportsItsOwnFailure pin the HTTP
// surface.
func TestHandlerRejectsGET(t *testing.T) {
	dir := t.TempDir()
	p := writeConfig(t, dir, "modules:\n  prod: {}\n")
	boot, _ := config.Load(p)
	r := New(logger.NewTextLogger("error"), p, boot, func(*config.Config) error { return nil })

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/-/reload", nil)
	r.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /-/reload returned %d, want 405", rec.Code)
	}
}

func TestHandlerReportsItsOwnFailure(t *testing.T) {
	dir := t.TempDir()
	p := writeConfig(t, dir, "modules:\n  prod: {}\n")
	boot, _ := config.Load(p)
	r := New(logger.NewTextLogger("error"), p, boot, func(*config.Config) error { return nil })

	writeConfig(t, dir, "modules:\n  prod: {\n")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/-/reload", nil)
	r.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("POST /-/reload on a broken file returned %d, want 500", rec.Code)
	}
}
```

Add a small helper at the bottom of the test file:

```go
// testGaugeValue reads a gauge without going through a registry.
func testGaugeValue(t *testing.T, g prometheus.Gauge) float64 {
	t.Helper()
	var m dto.Metric
	if err := g.Write(&m); err != nil {
		t.Fatalf("read gauge: %v", err)
	}
	return m.GetGauge().GetValue()
}
```

with imports `dto "github.com/prometheus/client_model/go"`, `"github.com/prometheus/client_golang/prometheus"`, `"strings"`, `"time"`.

- [ ] **Step 2: Run to verify it fails**

The package does not exist yet, so scaffold a `multi` exporter (Task 4's
scaffold change lands in Step 4 below; until then copy the directory by hand):

```bash
cd /tmp/t1multi && go test ./internal/reload/ -v
```

Expected: FAIL, package does not compile, `undefined: New`.

- [ ] **Step 3: Implement**

Create `reload.go.tmpl`:

```go
// Package reload implements configuration reload for the target models driven
// by a configuration file: SIGHUP always, and POST /-/reload behind
// --web.enable-lifecycle.
//
// It owns the MECHANISM and nothing else. What a new configuration means, and
// what has to change in the running process to adopt it, is the caller's
// business: main.go passes an apply function, which is where the per-target-model
// policy lives. That split is what keeps this package identical between the
// multi and multi-instance scaffolds.
//
// Three properties, each testable on its own:
//
//   - Serialization. One goroutine consumes every request, so a SIGHUP arriving
//     during a POST waits its turn and the HTTP handler receives the error of
//     its OWN reload rather than someone else's.
//   - Prepare then commit. Everything that can fail (re-read, parse, compare
//     flags:, validate, build transports) runs before anything is mutated. A
//     caller's apply must respect the same split, or a bad CA on the third
//     instance leaves the process half reconfigured.
//   - Fail closed. Any error leaves the running configuration untouched, drives
//     the successful gauge to 0, and logs at Error. The success timestamp only
//     ever advances on a completed commit.
package reload

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"@@MODULE_PATH@@/internal/config"
	"@@MODULE_PATH@@/internal/logger"
)

// Reloader re-reads one configuration file on demand and hands the result to
// apply. Build it with New and start its consumer with Run.
type Reloader struct {
	log   *logger.Logger
	path  string
	boot  *config.Config
	apply func(*config.Config) error

	// requests carries one channel per caller, which is how a caller gets the
	// error of the reload IT asked for. Prometheus itself uses this shape for
	// the same problem.
	requests chan chan error

	// inline serializes callers of Reload when Run is not consuming, which is
	// the case in unit tests. With Run consuming, its single goroutine is the
	// serialization and this is never taken.
	inline sync.Mutex

	successful  prometheus.Gauge
	successTime prometheus.Gauge
}

// New builds a Reloader for path. boot is the configuration the process
// started with, kept so a later reload can tell whether the "flags:" section
// moved. apply adopts a new configuration and must itself be split into a
// phase that can fail and mutates nothing, and a phase that mutates and cannot.
func New(log *logger.Logger, path string, boot *config.Config, apply func(*config.Config) error) *Reloader {
	return &Reloader{
		log:      log,
		path:     path,
		boot:     boot,
		apply:    apply,
		requests: make(chan chan error),
		successful: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "@@NAMESPACE@@_exporter_config_last_reload_successful",
			Help: "Whether the last configuration reload attempt succeeded (1) or failed (0).",
		}),
		successTime: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "@@NAMESPACE@@_exporter_config_last_reload_success_timestamp_seconds",
			Help: "Unix time of the last SUCCESSFUL configuration reload.",
		}),
	}
}

// Collectors returns the metrics this package owns, for main.go to register on
// the exporter's own registry. Returned rather than self-registered: main.go
// builds a custom registry precisely to avoid package-level global state.
func (r *Reloader) Collectors() []prometheus.Collector {
	return []prometheus.Collector{r.successful, r.successTime}
}

// Run consumes reload requests, one at a time, until ctx is done. It also
// installs the SIGHUP handler.
//
// SIGHUP gets its OWN signal.Notify channel and never touches the
// signal.NotifyContext main.go uses for SIGTERM and SIGINT: routing it there
// would cancel the process context and turn a reload into a shutdown.
func (r *Reloader) Run(ctx context.Context) {
	// Mark the process as "configuration currently good" before serving, so
	// the gauge is meaningful from the first scrape rather than absent until
	// somebody reloads.
	r.successful.Set(1)

	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	defer signal.Stop(hup)

	for {
		select {
		case <-ctx.Done():
			return
		case <-hup:
			r.log.Info("SIGHUP received, reloading configuration", "path", r.path)
			if err := r.reloadOnce(); err != nil {
				r.log.Error("Configuration reload failed, keeping the running configuration", "err", err)
			} else {
				r.log.Info("Configuration reloaded")
			}
		case reply := <-r.requests:
			err := r.reloadOnce()
			if err != nil {
				r.log.Error("Configuration reload failed, keeping the running configuration", "err", err)
			} else {
				r.log.Info("Configuration reloaded")
			}
			reply <- err
		}
	}
}

// Reload performs one reload and returns its outcome. It is what Handler calls
// and what a test drives directly.
//
// When Run is consuming, the work happens on Run's goroutine, which is what
// keeps it serialized with SIGHUP and lets each caller receive the error of the
// reload IT asked for. When Run is not consuming (a unit test that never
// started it), the send finds no receiver and falls through to an inline
// reload, serialized by the same mutex Run's single goroutine would otherwise
// have provided.
func (r *Reloader) Reload() error {
	reply := make(chan error, 1)
	select {
	case r.requests <- reply:
		return <-reply
	default:
		r.inline.Lock()
		defer r.inline.Unlock()
		return r.reloadOnce()
	}
}

// reloadOnce is the prepare-then-commit body. Everything above the apply call
// can fail and mutates nothing.
func (r *Reloader) reloadOnce() error {
	if r.path == "" {
		return r.fail(fmt.Errorf("no configuration file to reload: this exporter was started without --config.file"))
	}

	next, err := config.Load(r.path) // re-read, UnmarshalStrict, resolve relative paths
	if err != nil {
		return r.fail(err)
	}

	// "flags:" is applied once, at startup, by rendering it into arguments for
	// kingpin. A running process cannot adopt a new value for one, so a changed
	// section refuses the WHOLE reload rather than applying the rest and leaving
	// the process describing neither file.
	if changed := config.DiffFlags(r.boot, next); len(changed) > 0 {
		return r.fail(fmt.Errorf(
			"flags section changed (%s); these are applied once at startup, restart to apply them",
			strings.Join(changed, ", ")))
	}

	if err := r.apply(next); err != nil {
		return r.fail(err)
	}

	r.successful.Set(1)
	r.successTime.Set(float64(time.Now().Unix()))
	return nil
}

// fail drives the gauge and returns the error, so every failure path is one
// line and none can forget the metric.
func (r *Reloader) fail(err error) error {
	r.successful.Set(0)
	return fmt.Errorf("reload refused: %w", err)
}

// Handler serves POST /-/reload. main.go registers it only when
// --web.enable-lifecycle is set, so an exporter that did not opt in answers 404
// like any unknown path, which is Prometheus's own posture.
//
// A mutating endpoint on an exporter that is unauthenticated by default is the
// reason for that flag: --web.config.file covers this route once it is set, but
// it is not set by default, and SIGHUP already requires being on the machine.
func (r *Reloader) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "use POST to reload the configuration", http.StatusMethodNotAllowed)
			return
		}
		if err := r.Reload(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("reload succeeded\n"))
	})
}
```

Add `"strings"` and `"sync"` to the imports.

- [ ] **Step 4: Teach `scaffold.sh` to select the package**

In `scaffold.sh`, beside the existing `internal/probe` and `internal/instance`
blocks:

```sh
# internal/reload/ is for the configuration-file-driven models only. A
# single-target scaffold's file holds "flags:" (which cannot be reloaded, see
# internal/config) and "http_client_config:" (whose file-backed secrets and TLS
# material prometheus/common already re-reads per request), so there would be
# nothing left for a reload to do there.
if [ "$target_model" != multi ] && [ "$target_model" != multi-instance ]; then
  rm -rf "$dst/internal/reload"
fi
```

Update the header comment at `scaffold.sh:56-58` to mention it alongside
`internal/probe` and `internal/instance`.

- [ ] **Step 5: Run to verify it passes**

```bash
A=skills/prometheus-exporter/assets
rm -rf /tmp/t4 && mkdir -p /tmp/t4
sh "$A/scaffold.sh" --src "$A" --dst /tmp/t4 --flavor http --forge none --target-model multi --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var DEFAULT_PORT=9999 \
  --var OWNER=acme --var LICENSE=apache-2.0 --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/t4 && go test ./internal/reload/ -race -v 2>&1 | tail -20
```

Expected: PASS on all six tests.

Then prove the package is absent from a single-target scaffold:

```bash
test -d /tmp/t1/internal/reload && echo "LEAKED into single" || echo "correctly absent from single"
```

- [ ] **Step 6: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/internal/reload/ \
        skills/prometheus-exporter/assets/scaffold.sh
git commit -m "feat(reload): add the configuration reload mechanism

SIGHUP always, POST /-/reload behind a flag, one goroutine consuming both so a
signal arriving during a request waits its turn and the handler reports the
outcome of its own reload. Every failure leaves the running configuration in
force and drives the gauge to 0; the success timestamp only advances on a
completed commit.

SIGHUP gets its own signal.Notify channel and never the NotifyContext main.go
uses for SIGTERM: routing it there would turn a reload into a shutdown.

The package owns the mechanism only. What a new configuration means is the
caller's apply function, which is what keeps this identical between the multi
and multi-instance scaffolds. scaffold.sh selects it for those two models and
drops it for single, whose file has nothing reloadable left in it."
```

---

## Task 5: swap `multi`'s module table atomically

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/probe/probe.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/probe/probe_test.go.tmpl`

**Interfaces:**
- Consumes: `probe.Module`, `probe.NamedFactory`, `probe.ValidateModules` (all unchanged).
- Produces:
  - `func (h *Handler) SetConfig(modules map[string]Module, defaultClient *http.Client)`
  - `NewHandler` keeps its seven-parameter signature exactly as it is today.

- [ ] **Step 1: Write the failing test**

```go
// TestSetConfigIsVisibleToTheNextProbe proves a reload reaches /probe without
// rebuilding the handler.
func TestSetConfigIsVisibleToTheNextProbe(t *testing.T) {
	h := NewHandler(testLogger(), nil, nil, time.Second, 0,
		map[string]Module{"prod": {}}, nil)

	if _, _, err := h.selectFactories([]string{"staging"}); err == nil {
		t.Fatal("an unknown module was accepted before the swap")
	}

	h.SetConfig(map[string]Module{"prod": {}, "staging": {}}, nil)

	if _, _, err := h.selectFactories([]string{"staging"}); err != nil {
		t.Fatalf("the module added by SetConfig is not visible: %v", err)
	}
}

// TestSelectFactoriesUsesOneSnapshot proves an in-flight probe keeps a coherent
// table even if a reload lands mid-request: it must not see half of one
// configuration and half of another.
func TestSelectFactoriesUsesOneSnapshot(t *testing.T) {
	h := NewHandler(testLogger(), nil, nil, time.Second, 0,
		map[string]Module{"a": {}, "b": {}}, nil)

	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			if i%2 == 0 {
				h.SetConfig(map[string]Module{"a": {}, "b": {}}, nil)
			} else {
				h.SetConfig(map[string]Module{"a": {}, "b": {}, "c": {}}, nil)
			}
		}
	}()

	for i := 0; i < 2000; i++ {
		if _, _, err := h.selectFactories([]string{"a", "b"}); err != nil {
			close(stop)
			wg.Wait()
			t.Fatalf("a probe naming two always-present modules failed during a swap: %v", err)
		}
	}
	close(stop)
	wg.Wait()
}

// TestSetConfigRecomputesTheCredentialedList proves the derived state travels
// with the table, so the anti-silent-unauthenticated guard cannot go stale.
func TestSetConfigRecomputesTheCredentialedList(t *testing.T) {
	h := NewHandler(testLogger(), nil, nil, time.Second, 0, map[string]Module{"plain": {}}, nil)
	if _, _, err := h.selectFactories(nil); err != nil {
		t.Fatalf("a probe with no modules declaring credentials must succeed: %v", err)
	}

	h.SetConfig(map[string]Module{"plain": {}, "creds": {Client: &http.Client{}}}, nil)
	if _, _, err := h.selectFactories(nil); err == nil {
		t.Fatal("after a module carrying credentials was added, a credential-less probe must be refused")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /tmp/t4 && go test ./internal/probe/ -run 'TestSetConfig|TestSelectFactoriesUsesOneSnapshot' -race -v
```

Expected: FAIL, `h.SetConfig undefined`.

- [ ] **Step 3: Implement**

In `probe.go.tmpl`, replace the three configuration fields with one atomic
pointer:

```go
// handlerConfig is everything about a Handler that a configuration reload can
// replace. Kept together and IMMUTABLE behind an atomic pointer rather than
// under a mutex: /probe is the hot path, it reads this on every request and
// never writes it, so a pointer load costs no lock. It also makes "a reader
// observed a half-replaced table" impossible by construction rather than by
// discipline, since the value is never mutated in place, only swapped.
type handlerConfig struct {
	modules       map[string]Module
	defaultClient *http.Client // top-level http_client_config; nil unless it was set
	credentialed  []string     // sorted names of modules carrying credentials; logged, never served
}

// Handler serves /probe?target=… .
type Handler struct {
	log           *logger.Logger
	factories     []NamedFactory
	allowlist     []string      // empty => allow-any (ecosystem default; see SECURITY.md)
	maxTimeout    time.Duration // --probe.timeout: ceiling on each probe's deadline
	timeoutOffset time.Duration // --probe.timeout-offset: answer before Prometheus gives up

	// cfg is replaced wholesale by SetConfig on every configuration reload.
	// allowlist, maxTimeout and timeoutOffset are NOT in here: they come from
	// flags, which are parsed once at startup and which a reload refuses to
	// change (see internal/config's DiffFlags).
	cfg atomic.Pointer[handlerConfig]
}
```

`NewHandler` keeps its signature and delegates:

```go
func NewHandler(log *logger.Logger, factories []NamedFactory, allowlist []string, maxTimeout, timeoutOffset time.Duration, modules map[string]Module, defaultClient *http.Client) *Handler {
	h := &Handler{
		log:           log,
		factories:     factories,
		allowlist:     allowlist,
		maxTimeout:    maxTimeout,
		timeoutOffset: timeoutOffset,
	}
	h.SetConfig(modules, defaultClient)
	return h
}

// SetConfig installs a new module table, atomically. A probe already in flight
// finishes against the table it started with; the next one sees this.
//
// The caller is responsible for calling CloseIdleConnections on any
// *http.Client this replaces. Doing it here would be wrong: this Handler cannot
// know whether the caller still references the old clients elsewhere.
func (h *Handler) SetConfig(modules map[string]Module, defaultClient *http.Client) {
	// Precomputed for the guard rule 5 applies, and sorted so a credential-less
	// probe names the candidates in the same order every time.
	var credentialed []string
	for name, m := range modules {
		if m.Client != nil {
			credentialed = append(credentialed, name)
		}
	}
	sort.Strings(credentialed)

	h.cfg.Store(&handlerConfig{
		modules:       modules,
		defaultClient: defaultClient,
		credentialed:  credentialed,
	})
}
```

In `selectFactories`, take the snapshot once at the top and read every field
from it:

```go
func (h *Handler) selectFactories(vals []string) ([]NamedFactory, *http.Client, error) {
	// ONE snapshot for this whole request: a reload landing mid-probe must not
	// let this function see half of one configuration and half of another.
	cfg := h.cfg.Load()
	names := moduleNames(vals)
	// ... replace every h.modules with cfg.modules,
	//     every h.defaultClient with cfg.defaultClient,
	//     every h.credentialed with cfg.credentialed
}
```

Add `"sync/atomic"` to the imports.

- [ ] **Step 4: Run to verify it passes**

```bash
cd /tmp/t4 && go test ./internal/probe/ -race -v 2>&1 | tail -20
```

Expected: PASS, including every pre-existing probe test.

- [ ] **Step 5: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/internal/probe/
git commit -m "feat(probe): make the module table swappable behind an atomic pointer

The three fields a reload replaces move into one immutable handlerConfig behind
an atomic.Pointer, and selectFactories takes one snapshot per request. A probe
in flight finishes against a coherent table; the next one sees the new one.

An atomic pointer rather than the RWMutex the roadmap named: /probe reads this
on every request and never writes it, so the read costs no lock, and a reader
observing a half-replaced table becomes impossible by construction rather than
by discipline. allowlist, timeout and timeout-offset stay outside it: they come
from flags, which a reload refuses to change.

NewHandler keeps its seven-parameter signature, so nothing that consumes the
seam has to move."
```

---

## Task 6: wire the reload into `mains/multi`

**Files:**
- Modify: `skills/prometheus-exporter/assets/mains/multi/main.go.tmpl`

**Interfaces:**
- Consumes: `reload.New`, `reload.Reloader.Run/Handler/Collectors` (Task 4);
  `probe.Handler.SetConfig` (Task 5); `config.ResolveModules`,
  `collector.NewHTTPClient` (both unchanged).
- Produces: a `buildModules(cfg) (map[string]probe.Module, *http.Client, error)`
  local function, shared by boot and reload, so the two cannot drift.

- [ ] **Step 1: Extract the module-building block into a function**

The boot path at `mains/multi/main.go.tmpl:143-194` already does exactly what
a reload's prepare phase must do. Lift it verbatim into a function declared
after `main`:

```go
// buildModules turns a parsed configuration into the probe handler's module
// table. This is the PREPARE phase, shared by boot and by every reload so the
// two cannot drift: it can fail, and it mutates nothing. Building a transport
// is the step that fails on an unreadable CA or secret file, and it happens
// here, before anything is swapped.
//
// Sorted iteration so a file with two broken modules always fails on the same
// one, at boot and at reload alike.
func buildModules(cfg *config.Config, factories []probe.NamedFactory, timeout time.Duration) (map[string]probe.Module, *http.Client, error) {
	resolved, err := cfg.ResolveModules()
	if err != nil {
		return nil, nil, fmt.Errorf("invalid \"modules:\" section: %w", err)
	}

	names := make([]string, 0, len(resolved))
	for name := range resolved {
		names = append(names, name)
	}
	sort.Strings(names)

	modules := make(map[string]probe.Module, len(resolved))
	for _, name := range names {
		rm := resolved[name]
		m := probe.Module{Collectors: rm.Collectors}
		if rm.ClientConfig != nil {
			hc, cerr := collector.NewHTTPClient(*rm.ClientConfig, timeout)
			if cerr != nil {
				return nil, nil, fmt.Errorf("build HTTP client for module %q: %w", name, cerr)
			}
			m.Client = hc
		}
		modules[name] = m
	}

	var defaultClient *http.Client
	if cfg.HTTPClientConfig != nil {
		defaultClient, err = collector.NewHTTPClient(*cfg.HTTPClientConfig, timeout)
		if err != nil {
			return nil, nil, fmt.Errorf("build HTTP client from http_client_config: %w", err)
		}
	}

	if err := probe.ValidateModules(factories, modules); err != nil {
		return nil, nil, fmt.Errorf("invalid module definition: %w", err)
	}
	return modules, defaultClient, nil
}

// closeIdle releases the connections held by clients a reload replaced.
// Only IDLE connections are closed, so a probe still in flight on an old client
// finishes undisturbed; without this the old transports would hold their
// sockets until IdleConnTimeout.
func closeIdle(modules map[string]probe.Module, defaultClient *http.Client) {
	for _, m := range modules {
		if m.Client != nil {
			m.Client.CloseIdleConnections()
		}
	}
	if defaultClient != nil {
		defaultClient.CloseIdleConnections()
	}
}
```

Replace lines 143 to 194 of `main` with:

```go
	modules, defaultClient, err := buildModules(cfg, factories, *probeTimeout)
	if err != nil {
		log.Error("Invalid configuration", "err", err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
```

- [ ] **Step 2: Add the lifecycle flag**

Beside `probeTargetAllowlist` in the `var` block:

```go
	// enableLifecycle exposes POST /-/reload. Default false, which is
	// Prometheus's own posture and not Blackbox's: a scaffolded multi-target
	// exporter is allow-any and unauthenticated by default, so shipping every
	// generated exporter an unauthenticated MUTATING endpoint would be the one
	// change here that degrades the default posture of an operator who
	// configured nothing. --web.config.file covers the route once it is set,
	// but it is not set by default. SIGHUP is always on: it already requires
	// being on the machine.
	enableLifecycle = kingpin.Flag(
		"web.enable-lifecycle",
		"Expose POST /-/reload, which reloads --config.file. SIGHUP always works and needs no flag.",
	).Default("false").Bool()
```

- [ ] **Step 3: Build the reloader and register its routes**

After `probeHandler := probe.NewHandler(...)`:

```go
	// The reload policy for this target model: rebuild the module table, swap
	// it atomically, then release the connections the replaced clients held.
	// buildModules is the prepare phase and cannot mutate; SetConfig and
	// closeIdle are the commit phase and cannot fail.
	//
	// Captured by reference so a reload sees the CURRENT table, not the one
	// that existed when this closure was created.
	current := struct {
		modules       map[string]probe.Module
		defaultClient *http.Client
	}{modules, defaultClient}

	reloader := reload.New(log, config.ExtractFlagValue(os.Args[1:], "config.file"), cfg,
		func(next *config.Config) error {
			newModules, newDefault, err := buildModules(next, factories, *probeTimeout)
			if err != nil {
				return err
			}
			probeHandler.SetConfig(newModules, newDefault)
			closeIdle(current.modules, current.defaultClient)
			current.modules, current.defaultClient = newModules, newDefault
			return nil
		})
	go reloader.Run(ctx)
```

Register the gauges on the exporter's registry, beside
`reg.MustRegister(collector.RequestDuration)`:

```go
	reg.MustRegister(collector.RequestDuration, collector.RequestWait)
	reg.MustRegister(reloader.Collectors()...)
```

And the route, beside `/probe`:

```go
	// Registered only when the operator opted in, so an exporter that did not
	// answers 404 on this path like any other unknown one.
	if *enableLifecycle {
		http.Handle("/-/reload", reloader.Handler())
	} else {
		log.Info("POST /-/reload is disabled; SIGHUP still reloads the configuration",
			"enable_with", "--web.enable-lifecycle")
	}
```

Add `"@@MODULE_PATH@@/internal/reload"` to the imports.

- [ ] **Step 4: Prove it end to end by hand**

```bash
A=skills/prometheus-exporter/assets
rm -rf /tmp/t6 && mkdir -p /tmp/t6
sh "$A/scaffold.sh" --src "$A" --dst /tmp/t6 --flavor http --forge none --target-model multi --force \
  --var EXPORTER_NAME=demo_exporter --var NAMESPACE=demo --var MODULE_PATH=example.com/demo_exporter \
  --var DATA_SOURCE=http://localhost:9999 --var DATA_SOURCE_PATH=/api/example --var DEFAULT_PORT=9999 \
  --var OWNER=acme --var LICENSE=apache-2.0 --var COLLECTOR_HEALTH_BY=job --var COLLECTOR_LOCATION=instance
cd /tmp/t6 && go build ./... && printf 'modules:\n  prod: {}\n' > /tmp/t6/c.yml
./bin/demo_exporter --config.file=/tmp/t6/c.yml --web.listen-address=127.0.0.1:19991 &
sleep 1
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:19991/-/reload   # expect 404
kill %1
./bin/demo_exporter --config.file=/tmp/t6/c.yml --web.enable-lifecycle --web.listen-address=127.0.0.1:19991 &
sleep 1
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19991/-/reload           # expect 405
printf 'modules:\n  prod: {}\n  staging: {}\n' > /tmp/t6/c.yml
curl -s -X POST http://127.0.0.1:19991/-/reload                                    # expect "reload succeeded"
curl -s http://127.0.0.1:19991/metrics | grep config_last_reload                   # expect successful 1
printf 'modules:\n  prod: {\n' > /tmp/t6/c.yml
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:19991/-/reload   # expect 500
curl -s http://127.0.0.1:19991/metrics | grep config_last_reload_successful        # expect 0
kill %1
```

Paste every observed value. All six expectations must hold.

- [ ] **Step 5: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/mains/multi/main.go.tmpl
git commit -m "feat(probe): reload the module table on SIGHUP and POST /-/reload

The boot path's module building becomes buildModules, shared verbatim by boot
and by every reload so the two cannot drift. It is the prepare phase: it can
fail, on an unreadable CA or secret file, and it mutates nothing. SetConfig
plus closeIdle are the commit phase: they cannot fail.

closeIdle releases what the replaced clients held. Only idle connections are
closed, so a probe in flight on an old client finishes undisturbed.

POST /-/reload sits behind --web.enable-lifecycle, defaulting to false, which
is Prometheus's posture rather than Blackbox's: a scaffolded multi-target
exporter is allow-any and unauthenticated by default, so an unauthenticated
mutating endpoint would be the one change here that degrades the default
posture of an operator who configured nothing. SIGHUP needs no flag."
```

---

# Tranche 3: `multi-instance`

## Task 7: `instance.Handle` and the new factory shape

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/instance/instance.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/instance/instance_test.go.tmpl`

**Interfaces:**
- Consumes: `collector.Transport`, `collector.NewClientOn`, `collector.NewLimiter` (Tasks 1 and 2).
- Produces:
  - `type Handle struct{ Name, Address string; ... }`
  - `func NewHandle(name, address string, hc *http.Client, limit int, labels prometheus.Labels) *Handle`
  - `func (h *Handle) ClientFor(timeout time.Duration) (*collector.Client, error)`
  - `func (h *Handle) SetTransport(hc *http.Client) *http.Client` (returns the replaced client, for the caller to close)
  - `func (h *Handle) Labels() prometheus.Labels`
  - `type Factory struct{ Name string; Enabled *bool; New func(h *Handle) (BackgroundCollector, error) }`
  - `BackgroundCollector` unchanged.

- [ ] **Step 1: Write the failing test**

```go
// TestClientForRejectsANonPositiveTimeout pins the reason ClientFor returns an
// error at all: a Handle's transport carries no http.Client.Timeout, so a
// collector reaching it with no deadline would hang its poller forever. That is
// a configuration fault and it must fail the boot, not surface at 3am.
func TestClientForRejectsANonPositiveTimeout(t *testing.T) {
	h := NewHandle("lib1", "https://a.example", &http.Client{}, 0, nil)
	if _, err := h.ClientFor(0); err == nil {
		t.Fatal("ClientFor accepted a zero timeout")
	}
	if _, err := h.ClientFor(-time.Second); err == nil {
		t.Fatal("ClientFor accepted a negative timeout")
	}
	if _, err := h.ClientFor(5 * time.Second); err != nil {
		t.Fatalf("ClientFor rejected a valid timeout: %v", err)
	}
}

// TestSetTransportReachesEveryClient proves one swap reaches all of an
// instance's collectors, which is what lets a credential rotation leave every
// poller running and every cache intact.
func TestSetTransportReachesEveryClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer srv.Close()

	h := NewHandle("lib1", srv.URL, &http.Client{}, 0, nil)
	a, err := h.ClientFor(time.Second)
	if err != nil {
		t.Fatalf("ClientFor: %v", err)
	}
	b, err := h.ClientFor(2 * time.Second)
	if err != nil {
		t.Fatalf("ClientFor: %v", err)
	}

	if _, err := a.Fetch(context.Background(), "/"); err != nil {
		t.Fatalf("first client before the swap: %v", err)
	}

	old := h.SetTransport(&http.Client{Transport: refusingRoundTripper{}})
	if old == nil {
		t.Fatal("SetTransport did not return the client it replaced; the caller cannot close its idle connections")
	}
	if _, err := a.Fetch(context.Background(), "/"); err == nil {
		t.Fatal("the first client did not follow the swap")
	}
	if _, err := b.Fetch(context.Background(), "/"); err == nil {
		t.Fatal("the second client did not follow the swap")
	}
}

// TestHandleSharesOneLimiter proves an instance's collectors contend for one
// ceiling, which is the whole point of hanging it on the Handle.
func TestHandleSharesOneLimiter(t *testing.T) {
	h := NewHandle("lib1", "https://a.example", &http.Client{}, 1, nil)
	a, _ := h.ClientFor(time.Second)
	b, _ := h.ClientFor(time.Second)
	if a.Limiter() == nil {
		t.Fatal("a Handle built with a ceiling handed out a client with no limiter")
	}
	if a.Limiter() != b.Limiter() {
		t.Fatal("two collectors of one instance got different limiters")
	}

	unlimited := NewHandle("lib2", "https://b.example", &http.Client{}, 0, nil)
	c, _ := unlimited.ClientFor(time.Second)
	if c.Limiter() != nil {
		t.Fatal("a Handle built with ceiling 0 handed out a limiter")
	}
}
```

This needs a `Limiter()` accessor on `collector.Client`; add it in this task:

```go
// Limiter returns the ceiling this Client contends for, or nil when
// unlimited. Exported for tests that assert two collectors of one instance
// share one ceiling.
func (c *Client) Limiter() *Limiter { return c.limiter }
```

and export the test's refusing round tripper from Task 1 by moving it into a
shared test helper, or redeclare it in this package's test file.

- [ ] **Step 2: Run to verify it fails**

```bash
cd /tmp/t8 && go test ./internal/instance/ -race -v
```

Expected: FAIL, `undefined: NewHandle`.

- [ ] **Step 3: Implement**

Replace `instance.go.tmpl`'s `Factory` and add `Handle`:

```go
// Handle is everything the process keeps about ONE watched machine: the
// transport its collectors share, the concurrency ceiling they contend for, the
// labels its series carry, and the cancellation that stops its pollers.
//
// It exists because a configuration reload has to be able to change a machine's
// credentials WITHOUT stopping its pollers: restarting them would drop their
// caches, and under this target model a cache is worth up to a full refresh
// interval of data. Sharing one transport per machine also collapses what used
// to be one http.Transport per instance per collector.
//
// Address is immutable on purpose. A changed address is a different machine, so
// the cached data is no longer about the thing it claims to describe: that case
// rebuilds the Handle rather than mutating it.
type Handle struct {
	Name    string
	Address string

	tr      *collector.Transport
	limiter *collector.Limiter
	labels  prometheus.Labels

	// clientConfig is the RESOLVED module content this machine's transport was
	// built from, remembered so a reload can tell a real credential change from
	// a module merely renamed. Compared with reflect.DeepEqual, never by module
	// name: renaming a module without changing what it holds must restart
	// nothing, and editing one under the same name must swap the transport.
	clientConfig *promconfig.HTTPClientConfig

	// tracker is what is registered on the labelled wrapper of the exporter's
	// registry. Kept so a label change can unregister through a wrapper built
	// with the PREVIOUS labels and re-register the same tracker with the new
	// ones, without the collectors ever noticing.
	tracker *collector.StatusTracker

	cancel context.CancelFunc
	bgs    []BackgroundCollector
}

// NewHandle builds a handle for one machine. hc is the client its collectors
// share, built once from the instance's resolved module. limit is
// --exporter.max-requests-per-target; 0 means unlimited.
func NewHandle(name, address string, hc *http.Client, limit int, labels prometheus.Labels) *Handle {
	return &Handle{
		Name:    name,
		Address: address,
		tr:      collector.NewTransport(hc),
		limiter: collector.NewLimiter(limit),
		labels:  labels,
	}
}

// ClientFor returns a Client bound to this machine, carrying one collector's
// own timeout and sharing this machine's transport and ceiling.
//
// A non-positive timeout is refused rather than treated as "no deadline": the
// shared transport carries no http.Client.Timeout of its own, so a collector
// reaching it without one would block its poller forever on a hung connection.
// The error travels out through Factory.New and fails the boot, or fails a
// reload's prepare phase before anything is swapped.
func (h *Handle) ClientFor(timeout time.Duration) (*collector.Client, error) {
	if timeout <= 0 {
		return nil, fmt.Errorf("instance %q: a collector timeout must be positive, got %v (the shared transport carries no timeout of its own)", h.Name, timeout)
	}
	return collector.NewClientOn(h.tr, h.Address, timeout).WithLimiter(h.limiter), nil
}

// SetTransport installs a new shared client and returns the one it replaced, so
// the caller can release its idle connections. Every collector of this machine
// sees the change on its next request, without being stopped and without losing
// its cache.
func (h *Handle) SetTransport(hc *http.Client) *http.Client {
	old := h.tr.Get()
	h.tr.Set(hc)
	return old
}

// Labels returns the identifying and extra labels this machine's series carry.
// They are applied by prometheus.WrapRegistererWith at REGISTRATION, and the
// wrapper adds them at Collect time, so the collectors and their caches know
// nothing about them. That is what makes a label change cost a re-registration
// and not a poller restart.
func (h *Handle) Labels() prometheus.Labels { return h.labels }

// Factory builds one instance-bound background collector.
//
// It takes the Handle rather than an address and a client config because the
// transport is now built once per machine, in the reconciler, and shared: a
// factory that built its own would give every collector of one machine its own
// connection pool and would put the transport out of a reload's reach.
//
// New may fail: ClientFor refuses a non-positive timeout, and a collector may
// have its own reasons. That failure fails the boot, or fails a reload's
// prepare phase before anything is swapped.
type Factory struct {
	Name    string
	Enabled *bool
	New     func(h *Handle) (BackgroundCollector, error)
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /tmp/t8 && go test ./internal/instance/ ./internal/collector/ -race -v 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/internal/instance/ \
        skills/prometheus-exporter/assets/code/http/client.go.tmpl
git commit -m "feat(instance): give each watched machine a Handle

One Handle per machine owns the transport its collectors share, the concurrency
ceiling they contend for, its labels and its cancellation. That is what lets a
reload rotate a machine's credentials without stopping its pollers, which under
this target model would cost up to a full refresh interval of data per instance.
It also collapses one http.Transport per instance per collector into one per
instance.

Factory.New now takes the Handle instead of an address and a client config: a
factory that built its own transport would defeat both the sharing and the swap.
ClientFor refuses a non-positive timeout rather than treating it as no deadline,
because the shared transport carries no timeout of its own and a collector
reaching it without one would hang its poller forever."
```

---

## Task 8: boot `multi-instance` through a reconciler

**Files:**
- Modify: `skills/prometheus-exporter/assets/internal/instance/instance.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/instance_factory.frag`
- Modify: `skills/prometheus-exporter/assets/mains/multi-instance/main.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/instance/instance_test.go.tmpl`

**Interfaces:**
- Consumes: `Handle`, `Factory` (Task 7); `config.ResolvedInstance` (unchanged).
- Produces:
  - `func NewRegistry(log *logger.Logger, root prometheus.Registerer, instanceLabel string, factories []Factory, limit int) *Registry`
  - `func (r *Registry) Prepare(instances []config.ResolvedInstance) (*Plan, error)`
  - `func (r *Registry) Commit(ctx context.Context, p *Plan)`
  - `func (r *Registry) Wait(budget time.Duration)`

- [ ] **Step 1: Implement the reconciler, boot path only**

The point of this task is that **boot and reload go through the same code**, so
the reload path is exercised on every single start and by every golden cell.
`Prepare` against an empty current set is a boot.

```go
// Registry owns the live set of watched machines. Boot and reload both go
// through Prepare then Commit, so the reload path is exercised by every start
// and by every golden cell, not only when somebody sends a SIGHUP.
//
// Not safe for concurrent use: every call comes from the reload goroutine,
// which internal/reload serializes, or from main before that goroutine starts.
type Registry struct {
	log           *logger.Logger
	root          prometheus.Registerer
	instanceLabel string
	factories     []Factory // already filtered to the globally-enabled ones
	limit         int       // --exporter.max-requests-per-target

	handles map[string]*Handle // live, by instance name
}

// NewRegistry builds an empty registry. root is the exporter's own registry;
// each instance's collectors are registered on a wrapper of it carrying that
// instance's labels.
func NewRegistry(log *logger.Logger, root prometheus.Registerer, instanceLabel string, factories []Factory, limit int) *Registry {
	return &Registry{
		log:           log,
		root:          root,
		instanceLabel: instanceLabel,
		factories:     factories,
		limit:         limit,
		handles:       make(map[string]*Handle),
	}
}

// Plan is what Prepare produced and Commit will apply.
//
// Everything in it is already BUILT: the transports exist, so the step that
// fails on an unreadable CA or secret file has already run. That is what makes
// Commit unable to fail, and it is what makes a reload atomic: a bad CA on the
// third instance is refused before the first one has been touched.
type Plan struct {
	add         []*addOp
	remove      []*Handle
	relabel     []*relabelOp
	retransport []*retransportOp
}

// addOp is a machine to start: a handle whose collectors are built but not yet
// started or registered.
type addOp struct {
	handle      *Handle
	tracker     *collector.StatusTracker
	collectors  []BackgroundCollector
}

// relabelOp is the same machine under new labels. The poller is not touched:
// WrapRegistererWith applies its ConstLabels inside the wrapper at Collect
// time, so the collector's cached []prometheus.Metric carries bare Descs and
// knows nothing about them. Only the registration moves.
type relabelOp struct {
	handle    *Handle
	newLabels prometheus.Labels
}

// retransportOp is the same machine with new credentials. The poller is not
// touched either: its Clients share the Handle's Transport, so replacing the
// *http.Client underneath them is enough, and their caches survive.
//
// clientConfig travels with the new client so Commit can record what the
// transport was built from. Without it the next reload compares against the
// stale config and swaps the transport on every reload forever.
type retransportOp struct {
	handle       *Handle
	client       *http.Client
	clientConfig *promconfig.HTTPClientConfig
}
```

- [ ] **Step 2: Write the failing tests for the five diff cases**

One test per row of the spec's table. Every one of them asserts on BOTH the
registration and the poller, because "the cache survived" is the entire claim
of this design and a test that only checks registration would pass on an
implementation that restarts everything.

The shared fixture makes "the poller was not restarted" a number rather than a
narrative:

```go
// fakeBG stands in for a background collector. It counts Start calls, which is
// how every test below distinguishes "kept running" from "rebuilt": a handle
// that was rebuilt has a NEW fakeBG at 1 start, a handle that survived has the
// SAME fakeBG still at 1.
type fakeBG struct {
	starts int32
	desc   *prometheus.Desc
	done   chan struct{}
}

func newFakeBG(name string) *fakeBG {
	return &fakeBG{
		desc: prometheus.NewDesc("demo_"+name, "fixture", nil, nil),
		done: make(chan struct{}),
	}
}

func (f *fakeBG) Describe(ch chan<- *prometheus.Desc) { ch <- f.desc }

// Always emits exactly one metric, so StatusTracker reports it healthy: a
// collector emitting none is counted as a failed scrape.
func (f *fakeBG) Collect(ch chan<- prometheus.Metric) {
	ch <- prometheus.MustNewConstMetric(f.desc, prometheus.GaugeValue, 1)
}

func (f *fakeBG) Start(ctx context.Context) {
	atomic.AddInt32(&f.starts, 1)
	go func() { <-ctx.Done(); close(f.done) }()
}

func (f *fakeBG) Done() <-chan struct{} { return f.done }

// testRegistry builds a Registry whose single factory hands out a fakeBG and
// records every one it made, keyed by the address the Handle carried.
func testRegistry(t *testing.T, root *prometheus.Registry) (*Registry, *[]*fakeBG) {
	t.Helper()
	made := &[]*fakeBG{}
	enabled := true
	factories := []Factory{{
		Name:    "example",
		Enabled: &enabled,
		New: func(h *Handle) (BackgroundCollector, error) {
			bg := newFakeBG("example")
			*made = append(*made, bg)
			return bg, nil
		},
	}}
	return NewRegistry(logger.NewTextLogger("error"), root, "target", factories, 0), made
}

// instancesFrom builds the resolved instance list a test reconciles against.
func inst(name, addr string, labels map[string]string, cfg *promconfig.HTTPClientConfig) config.ResolvedInstance {
	return config.ResolvedInstance{Name: name, Address: addr, Labels: labels, ClientConfig: cfg}
}

// seriesFor counts how many series the root registry gathers carrying the given
// value for the identifying label.
func seriesFor(t *testing.T, root *prometheus.Registry, target string) int {
	t.Helper()
	mfs, err := root.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	n := 0
	for _, mf := range mfs {
		for _, m := range mf.GetMetric() {
			for _, l := range m.GetLabel() {
				if l.GetName() == "target" && l.GetValue() == target {
					n++
				}
			}
		}
	}
	return n
}

// applyOrFail runs one full reconcile cycle, which is what boot and reload both
// do.
func applyOrFail(t *testing.T, r *Registry, ctx context.Context, instances []config.ResolvedInstance) {
	t.Helper()
	p, err := r.Prepare(instances)
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	r.Commit(ctx, p)
}
```

The five cases:

```go
// TestReconcileKeepsAnUnchangedInstanceUntouched: reconciling the same file
// twice must be a no-op, not a rebuild.
func TestReconcileKeepsAnUnchangedInstanceUntouched(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := prometheus.NewRegistry()
	r, made := testRegistry(t, root)

	list := []config.ResolvedInstance{inst("lib1", "https://a.example", nil, nil)}
	applyOrFail(t, r, ctx, list)
	applyOrFail(t, r, ctx, list)

	if len(*made) != 1 {
		t.Fatalf("%d collectors were built; reconciling an unchanged file must build none", len(*made))
	}
	if got := atomic.LoadInt32(&(*made)[0].starts); got != 1 {
		t.Fatalf("the poller was started %d times; an unchanged instance must not be restarted", got)
	}
	if seriesFor(t, root, "lib1") == 0 {
		t.Fatal("the instance's series disappeared after a no-op reconcile")
	}
}

// TestReconcileSwapsTransportWhenOnlyCredentialsChanged: the case that pays for
// this whole design. Rotating a secret written inline must not cost a restart,
// because a restart costs up to one refresh interval of data per instance.
func TestReconcileSwapsTransportWhenOnlyCredentialsChanged(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := prometheus.NewRegistry()
	r, made := testRegistry(t, root)

	before := &promconfig.HTTPClientConfig{BasicAuth: &promconfig.BasicAuth{Username: "u", Password: "old"}}
	after := &promconfig.HTTPClientConfig{BasicAuth: &promconfig.BasicAuth{Username: "u", Password: "new"}}

	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://a.example", nil, before)})
	first := (*made)[0]

	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://a.example", nil, after)})

	if len(*made) != 1 {
		t.Fatalf("%d collectors were built; a credentials-only change must build none", len(*made))
	}
	if got := atomic.LoadInt32(&first.starts); got != 1 {
		t.Fatalf("the poller was started %d times; a credentials-only change must not restart it", got)
	}
	if seriesFor(t, root, "lib1") == 0 {
		t.Fatal("the instance's series disappeared during a credential rotation")
	}
}

// TestReconcileDoesNotSwapWhenOnlyTheModuleNameChanged: credentials are
// compared by resolved CONTENT, so renaming a module without changing what it
// holds must be a no-op. Without this, every rename would swap a transport for
// nothing.
func TestReconcileDoesNotSwapWhenOnlyTheModuleNameChanged(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := prometheus.NewRegistry()
	r, made := testRegistry(t, root)

	cfgA := &promconfig.HTTPClientConfig{BasicAuth: &promconfig.BasicAuth{Username: "u", Password: "p"}}
	cfgB := &promconfig.HTTPClientConfig{BasicAuth: &promconfig.BasicAuth{Username: "u", Password: "p"}}

	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://a.example", nil, cfgA)})
	p, err := r.Prepare([]config.ResolvedInstance{inst("lib1", "https://a.example", nil, cfgB)})
	if err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if len(p.retransport) != 0 {
		t.Fatal("two identical resolved configs produced a transport swap; comparison must be by content, not by pointer or module name")
	}
	if len(p.add) != 0 || len(p.remove) != 0 || len(p.relabel) != 0 {
		t.Fatalf("an identical configuration produced work: %+v", p)
	}
	_ = made
}

// TestReconcileReregistersWhenOnlyLabelsChanged: labels live in the registerer
// wrapper, applied at Collect time, so the collector's cache knows nothing
// about them and a label change costs a re-registration, not a restart.
func TestReconcileReregistersWhenOnlyLabelsChanged(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := prometheus.NewRegistry()
	r, made := testRegistry(t, root)

	applyOrFail(t, r, ctx, []config.ResolvedInstance{
		inst("lib1", "https://a.example", map[string]string{"site": "paris"}, nil)})
	first := (*made)[0]

	applyOrFail(t, r, ctx, []config.ResolvedInstance{
		inst("lib1", "https://a.example", map[string]string{"site": "lyon"}, nil)})

	if len(*made) != 1 {
		t.Fatalf("%d collectors were built; a label-only change must build none", len(*made))
	}
	if got := atomic.LoadInt32(&first.starts); got != 1 {
		t.Fatalf("the poller was started %d times; a label-only change must not restart it", got)
	}

	mfs, err := root.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	sites := map[string]bool{}
	for _, mf := range mfs {
		for _, m := range mf.GetMetric() {
			for _, l := range m.GetLabel() {
				if l.GetName() == "site" {
					sites[l.GetValue()] = true
				}
			}
		}
	}
	if sites["paris"] {
		t.Fatal("the old label value is still being served; the previous registration was not removed")
	}
	if !sites["lyon"] {
		t.Fatal("the new label value is not being served")
	}
}

// TestReconcileRebuildsWhenTheAddressChanged: a different address is a
// different machine, so the cache describes something else now and must go.
func TestReconcileRebuildsWhenTheAddressChanged(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := prometheus.NewRegistry()
	r, made := testRegistry(t, root)

	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://a.example", nil, nil)})
	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://b.example", nil, nil)})

	if len(*made) != 2 {
		t.Fatalf("%d collectors were built; a changed address must rebuild the instance", len(*made))
	}
	if got := atomic.LoadInt32(&(*made)[1].starts); got != 1 {
		t.Fatalf("the replacement poller was started %d times, want 1", got)
	}
	if seriesFor(t, root, "lib1") == 0 {
		t.Fatal("the rebuilt instance is not registered")
	}
}

// TestReconcileStartsAndDrainsOnAddAndRemove: the added machine appears, the
// removed one is unregistered immediately (not after its drain) and its poller
// is cancelled.
func TestReconcileStartsAndDrainsOnAddAndRemove(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := prometheus.NewRegistry()
	r, made := testRegistry(t, root)

	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://a.example", nil, nil)})
	applyOrFail(t, r, ctx, []config.ResolvedInstance{
		inst("lib1", "https://a.example", nil, nil),
		inst("lib2", "https://b.example", nil, nil),
	})
	if seriesFor(t, root, "lib2") == 0 {
		t.Fatal("the added instance is not registered")
	}

	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://a.example", nil, nil)})
	if n := seriesFor(t, root, "lib2"); n != 0 {
		t.Fatalf("the removed instance still has %d series; unregistration must be synchronous, not deferred to the drain", n)
	}
	if seriesFor(t, root, "lib1") == 0 {
		t.Fatal("removing one instance unregistered another")
	}

	// The removed machine's poller must have been cancelled.
	removed := (*made)[1]
	select {
	case <-removed.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("the removed instance's poller was never cancelled")
	}
}

// TestPrepareMutatesNothingOnFailure is the atomicity assertion at unit level:
// a factory failing on the third instance must leave the first two untouched.
func TestPrepareMutatesNothingOnFailure(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := prometheus.NewRegistry()

	enabled := true
	fail := false
	made := 0
	r := NewRegistry(logger.NewTextLogger("error"), root, "target", []Factory{{
		Name:    "example",
		Enabled: &enabled,
		New: func(h *Handle) (BackgroundCollector, error) {
			if fail && h.Name == "lib3" {
				return nil, errors.New("unreadable CA")
			}
			made++
			return newFakeBG("example"), nil
		},
	}}, 0)

	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://a.example", nil, nil)})
	before := seriesFor(t, root, "lib1")

	fail = true
	if _, err := r.Prepare([]config.ResolvedInstance{
		inst("lib1", "https://a.example", nil, nil),
		inst("lib2", "https://b.example", nil, nil),
		inst("lib3", "https://c.example", nil, nil),
	}); err == nil {
		t.Fatal("Prepare succeeded despite a factory that failed")
	}

	if seriesFor(t, root, "lib1") != before {
		t.Fatal("a failed Prepare disturbed the instance that was already running")
	}
	if seriesFor(t, root, "lib2") != 0 {
		t.Fatal("a failed Prepare registered an instance; it must mutate nothing")
	}
}
```

- [ ] **Step 3: Implement `Prepare`, `Commit` and `Wait`**

```go
// labelsFor builds the label set an instance's series carry: the identifying
// label fixed at scaffold time, plus the instance's own extra labels. Built
// here rather than in main so boot and reload cannot disagree about it.
func (r *Registry) labelsFor(inst config.ResolvedInstance) prometheus.Labels {
	labels := prometheus.Labels{r.instanceLabel: inst.Name}
	for k, v := range inst.Labels {
		labels[k] = v
	}
	return labels
}

// Prepare classifies every instance in the new configuration against the live
// set and builds everything the resulting Plan will need. This is the phase
// that can fail, and it mutates nothing: on error the caller keeps running
// exactly what it was running.
//
// Boot is Prepare against an empty live set, which is why this code path is
// exercised by every start rather than only by a reload.
//
// Instances are processed in the order the file declares them, so a file with
// two broken instances always fails on the same one.
func (r *Registry) Prepare(instances []config.ResolvedInstance) (*Plan, error) {
	p := &Plan{}
	seen := make(map[string]bool, len(instances))

	for _, inst := range instances {
		seen[inst.Name] = true
		labels := r.labelsFor(inst)
		cur, live := r.handles[inst.Name]

		// Not watched yet: build it whole. Every collector is constructed here,
		// so a factory that fails (a non-positive timeout, or a reason of its
		// own) fails the whole reload before anything has been started.
		if !live || cur.Address != inst.Address {
			hc, err := clientFor(inst.ClientConfig)
			if err != nil {
				return nil, fmt.Errorf("instance %q: %w", inst.Name, err)
			}
			h := NewHandle(inst.Name, inst.Address, hc, r.limit, labels)
			h.clientConfig = inst.ClientConfig

			tracker := collector.NewStatusTracker(r.log)
			var bgs []BackgroundCollector
			for _, f := range r.factories {
				bg, err := f.New(h)
				if err != nil {
					return nil, fmt.Errorf("instance %q, collector %q: %w", inst.Name, f.Name, err)
				}
				tracker.Add(f.Name, bg)
				bgs = append(bgs, bg)
			}
			p.add = append(p.add, &addOp{handle: h, tracker: tracker, collectors: bgs})

			// A changed ADDRESS is a different machine: the cache describes
			// something else now, so the old handle is removed alongside.
			if live {
				p.remove = append(p.remove, cur)
			}
			continue
		}

		// Same machine, still at the same address. Two things may have moved,
		// and each is cheap on its own: neither stops a poller or drops a cache.
		if !reflect.DeepEqual(cur.labels, labels) {
			p.relabel = append(p.relabel, &relabelOp{handle: cur, newLabels: labels})
		}
		if !reflect.DeepEqual(cur.clientConfig, inst.ClientConfig) {
			hc, err := clientFor(inst.ClientConfig)
			if err != nil {
				return nil, fmt.Errorf("instance %q: %w", inst.Name, err)
			}
			p.retransport = append(p.retransport, &retransportOp{
				handle:       cur,
				client:       hc,
				clientConfig: inst.ClientConfig,
			})
		}
	}

	// Anything the file no longer declares. Sorted so a reload removing several
	// instances logs them in the same order every time.
	var gone []string
	for name := range r.handles {
		if !seen[name] {
			gone = append(gone, name)
		}
	}
	sort.Strings(gone)
	for _, name := range gone {
		p.remove = append(p.remove, r.handles[name])
	}

	return p, nil
}

// clientFor builds the shared *http.Client for one instance. A nil resolved
// config means the default transport, exactly as it did before this package
// owned the construction.
func clientFor(hcfg *promconfig.HTTPClientConfig) (*http.Client, error) {
	if hcfg == nil {
		return &http.Client{}, nil
	}
	// The per-request deadline lives on each collector's Client, not here: this
	// transport is shared by collectors whose timeouts differ.
	return collector.NewHTTPClient(*hcfg, 0)
}

// Commit applies a prepared plan. It cannot fail: every construction that could
// has already happened in Prepare, the names it registers were proved unique by
// ResolveInstances, and starting a goroutine does not fail.
//
// Order matters. Removals unregister FIRST, so a removed instance's series are
// gone from the very next scrape rather than lingering for the length of a
// drain. Draining is then handed to a background goroutine, so a reload never
// blocks behind a poller stuck in a long request.
func (r *Registry) Commit(ctx context.Context, p *Plan) {
	for _, h := range p.remove {
		prometheus.WrapRegistererWith(h.labels, r.root).Unregister(h.tracker)
		delete(r.handles, h.Name)
		h.cancel()
		r.log.Info("Stopped watching instance", "instance", h.Name, "address", h.Address)
		go h.drain(5 * time.Second)
	}

	for _, op := range p.relabel {
		// Unregister through a wrapper built with the PREVIOUS labels: that is
		// how the registry identifies what to remove, and it is why the handle
		// remembers them. The tracker and every collector behind it are
		// untouched, so no cache is lost.
		prometheus.WrapRegistererWith(op.handle.labels, r.root).Unregister(op.handle.tracker)
		op.handle.labels = op.newLabels
		prometheus.WrapRegistererWith(op.handle.labels, r.root).MustRegister(op.handle.tracker)
		r.log.Info("Relabelled instance", "instance", op.handle.Name)
	}

	for _, op := range p.retransport {
		old := op.handle.SetTransport(op.client)
		// Store what the new transport was built FROM, or the next reload will
		// compare against the stale config and swap the transport again on
		// every single reload.
		op.handle.clientConfig = op.clientConfig
		if old != nil {
			// Only IDLE connections close, so a request in flight on the old
			// client finishes undisturbed. Without this the old transport holds
			// its sockets until IdleConnTimeout.
			old.CloseIdleConnections()
		}
		r.log.Info("Rotated credentials for instance", "instance", op.handle.Name)
	}

	for _, op := range p.add {
		instCtx, cancel := context.WithCancel(ctx)
		op.handle.cancel = cancel
		op.handle.bgs = op.collectors
		op.handle.tracker = op.tracker
		for _, bg := range op.collectors {
			bg.Start(instCtx)
		}
		prometheus.WrapRegistererWith(op.handle.labels, r.root).MustRegister(op.tracker)
		r.handles[op.handle.Name] = op.handle
		r.log.Info("Watching instance", "instance", op.handle.Name, "address", op.handle.Address)
	}
}

// drain waits for one removed instance's pollers to exit, under a bounded
// budget, and warns if they do not. Called on its own goroutine so a reload
// returns immediately: the instance is already unregistered, so a lingering
// poller is unreferenced and harmless.
func (h *Handle) drain(budget time.Duration) {
	deadline := time.After(budget)
	for _, bg := range h.bgs {
		select {
		case <-bg.Done():
		case <-deadline:
			return
		}
	}
}

// Wait blocks until every live instance's pollers have exited, under ONE shared
// budget rather than one per collector: with N instances by M collectors, a
// per-collector wait would worst-case at N*M*budget. Called by main at
// shutdown, after the HTTP server has stopped.
func (r *Registry) Wait(budget time.Duration) {
	deadline := time.After(budget)
	for _, h := range r.handles {
		for _, bg := range h.bgs {
			select {
			case <-bg.Done():
			case <-deadline:
				r.log.Warn("background collectors did not all stop within the shutdown budget; exiting anyway")
				return
			}
		}
	}
}
```

One prerequisite in `internal/collector`: `clientFor` passes timeout `0` to
`NewHTTPClient`, which currently does `hc.Timeout = timeout` unconditionally.
Zero is correct and load-bearing here, because the shared transport must carry
no deadline of its own: each collector's `Client` applies its own through the
context, and a shared `http.Client.Timeout` would be the same for all of them.
Amend that constructor's doc comment to say so, and add the test that pins it:

```go
// TestNewHTTPClientAcceptsAZeroTimeout pins the contract the multi-instance
// reconciler depends on: a shared transport carries no deadline, because its
// collectors' deadlines differ and are applied per request through the context.
func TestNewHTTPClientAcceptsAZeroTimeout(t *testing.T) {
	hc, err := NewHTTPClient(promconfig.HTTPClientConfig{}, 0)
	if err != nil {
		t.Fatalf("NewHTTPClient with a zero timeout: %v", err)
	}
	if hc.Timeout != 0 {
		t.Fatalf("NewHTTPClient forced Timeout to %v on a zero request; the shared transport must carry none", hc.Timeout)
	}
}
```

- [ ] **Step 4: Update the factory fragment**

`assets/code/http/wiring/instance_factory.frag` becomes:

```go
	exampleTimeout := kingpin.Flag("collector.example.timeout", "Per-request timeout for the example collector.").Default("5s").Duration()
	exampleInterval := kingpin.Flag("collector.example.interval", "Background refresh interval for the example collector.").Default("5m").Duration()
	exampleEnabled := kingpin.Flag("collector.example", "Enable the example collector.").Default("true").Bool()
	// The closure defers every flag dereference and the log reference to the
	// reconciler, which runs after kingpin.Parse() and after log is built. It no
	// longer builds a transport: the Handle owns one per machine, shared by
	// every collector, so a reload can swap it underneath them.
	factories = append(factories, instance.Factory{
		Name:    "example",
		Enabled: exampleEnabled,
		New: func(h *instance.Handle) (instance.BackgroundCollector, error) {
			c, err := h.ClientFor(*exampleTimeout)
			if err != nil {
				return nil, err
			}
			return collector.NewExampleCollector(log, c, *exampleInterval), nil
		},
	})
```

Drop the now-unused `promconfig` import from the fragment's requirements and
check `mains/multi-instance/main.go.tmpl` still imports what it needs.

- [ ] **Step 5: Rewrite the main's instance loop**

Replace `mains/multi-instance/main.go.tmpl:162-186` with a `Prepare` plus
`Commit`, and keep the fail-fast:

```go
	registry := instance.NewRegistry(log, reg, instanceLabel, enabled, *maxRequestsPerTarget)
	plan, err := registry.Prepare(instances)
	if err != nil {
		log.Error("Invalid instance configuration", "err", err)
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
	registry.Commit(ctx, plan)
```

and replace the shutdown block at `:229-237` with `registry.Wait(5 * time.Second)`,
preserving the single shared budget and its comment.

- [ ] **Step 6: Prove it**

```bash
cd /tmp/t8 && go test ./... -race 2>&1 | tail -5
sh test/golden-smoke.sh --flavor http --forge none --target-model multi-instance 2>&1 | tail -5
```

Expected: PASS, and the golden cell green. This is the task where a seam change
either compiles across the whole scaffold or does not.

- [ ] **Step 7: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/internal/instance/ \
        skills/prometheus-exporter/assets/code/http/wiring/instance_factory.frag \
        skills/prometheus-exporter/assets/mains/multi-instance/main.go.tmpl
git commit -m "feat(instance): boot through the reconciler that reload will use

Prepare then Commit, with boot being Prepare against an empty current set. Boot
and reload therefore share one code path, so the reload logic is exercised by
every start and by every golden cell rather than only when somebody sends a
SIGHUP.

Prepare classifies each instance into exactly one of five cases and builds
everything that can fail, transports included. Commit only stores, registers and
starts goroutines, so it cannot fail. Credentials are compared by resolved
content rather than by module name: renaming a module without changing it must
restart nothing, and editing one under the same name must swap the transport."
```

---

## Task 9: reload `multi-instance`

**Files:**
- Modify: `skills/prometheus-exporter/assets/mains/multi-instance/main.go.tmpl`
- Test: `skills/prometheus-exporter/assets/internal/instance/instance_test.go.tmpl`

**Interfaces:**
- Consumes: `Registry.Prepare/Commit` (Task 8), `reload.New` (Task 4).
- Produces: nothing new; wires the two together.

- [ ] **Step 1: Add the lifecycle flag**

Identical to Task 6 Step 2, same comment, same default.

- [ ] **Step 2: Wire the reloader**

```go
	// The reload policy for this target model. ResolveInstances plus Prepare
	// are the prepare phase: they validate the file and build every transport,
	// so an unreadable CA on the third instance fails here, before anything has
	// been started or stopped. Commit is the commit phase and cannot fail.
	reloader := reload.New(log, configPath, cfg, func(next *config.Config) error {
		nextInstances, err := next.ResolveInstances(instanceLabel, "collector")
		if err != nil {
			return err
		}
		plan, err := registry.Prepare(nextInstances)
		if err != nil {
			return err
		}
		registry.Commit(ctx, plan)
		return nil
	})
	go reloader.Run(ctx)
```

Register the gauges and the route exactly as in Task 6 Step 3.

- [ ] **Step 3: Write the failing test for what this task alone adds**

Task 8's suite already covers the five diff cases and the atomicity of a failed
`Prepare`. Do not repeat them here. What this task introduces, and what nothing
yet pins, is the ORDER of the reload closure: `ResolveInstances` must run and be
allowed to fail BEFORE `Prepare`, so an instance list that no longer validates
(a duplicate name, an unresolvable module, a label colliding with the
identifying one) never reaches the reconciler.

Add to `instance_test.go.tmpl`:

```go
// TestReloadOrderRejectsAnInvalidInstanceListBeforeReconciling pins the shape
// of main's reload closure. ResolveInstances is validation and it must run
// first: a list with a duplicate name or an unresolvable module has to be
// refused while the running set is still untouched, not discovered halfway
// through a reconcile.
//
// The closure itself lives in package main and cannot be imported, so this test
// asserts the contract the closure depends on: that a Registry which never saw
// an invalid list is exactly the Registry it was before.
func TestReloadOrderRejectsAnInvalidInstanceListBeforeReconciling(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	root := prometheus.NewRegistry()
	r, made := testRegistry(t, root)

	applyOrFail(t, r, ctx, []config.ResolvedInstance{inst("lib1", "https://a.example", nil, nil)})
	before := seriesFor(t, root, "lib1")

	// What main's closure does on a reload, in order. The validation step is
	// the one that must reject this file.
	cfg := &config.Config{Instances: []config.Instance{
		{Name: "lib1", Address: "https://a.example"},
		{Name: "lib1", Address: "https://b.example"}, // duplicate name
	}}
	if _, err := cfg.ResolveInstances("target", "collector"); err == nil {
		t.Fatal("ResolveInstances accepted a duplicate instance name")
	}

	// Because validation failed, Prepare was never reached and the live set is
	// untouched.
	if seriesFor(t, root, "lib1") != before {
		t.Fatal("the running instance was disturbed by a configuration that never validated")
	}
	if len(*made) != 1 {
		t.Fatalf("%d collectors exist; a rejected configuration must build none", len(*made))
	}
}
```

- [ ] **Step 4: Prove it**

Same manual sequence as Task 6 Step 4, against a `multi-instance` scaffold with
a two-instance file, adding a third and confirming it appears in `/metrics`.

- [ ] **Step 5: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/mains/multi-instance/main.go.tmpl \
        skills/prometheus-exporter/assets/internal/instance/instance_test.go.tmpl
git commit -m "feat(instance): reload the instance list on SIGHUP and POST /-/reload

ResolveInstances plus Prepare are the prepare phase, so an unreadable CA on the
third instance fails before anything has been started or stopped. Commit cannot
fail.

Unregistering a removed instance is synchronous, so its series are gone from the
very next scrape; waiting for its goroutines happens separately under the same
shared budget the shutdown path uses, so a reload never blocks behind a poller
stuck in a long request."
```

---

## Task 10: wire the ceiling flag

**Files:**
- Modify: `skills/prometheus-exporter/assets/mains/multi-instance/main.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/mains/single/main.go.tmpl`
- Modify: `skills/prometheus-exporter/assets/code/http/wiring/client_build.frag`
- Modify: `skills/prometheus-exporter/assets/code/cli/wiring/client_build.frag`

**Interfaces:**
- Consumes: `collector.NewLimiterSet` (Task 2), `instance.NewRegistry`'s `limit` parameter (Task 8).
- Produces: the flag `--exporter.max-requests-per-target`.

- [ ] **Step 1: Declare the flag in both mains**

```go
	// maxRequestsPerTarget bounds how many requests this exporter has in flight
	// against ONE target at a time. 0, the default, means unlimited, which is
	// the same posture --probe.target-allowlist takes with its empty value:
	// this is opt-in hardening, not a default that moves under an operator who
	// configured nothing.
	//
	// A ceiling turns a slow collector into a source of starvation for its
	// siblings, so it is a deliberate choice with a visible cost. The wait is
	// charged against each collector's own timeout, and
	// @@NAMESPACE@@_exporter_request_wait_seconds is what makes queueing
	// visible rather than silent.
	maxRequestsPerTarget = kingpin.Flag(
		"exporter.max-requests-per-target",
		"Maximum concurrent requests this exporter issues to one target. 0 (default) means unlimited.",
	).Default("0").Int()
```

- [ ] **Step 2: multi-instance passes it to the reconciler**

Already threaded in Task 8 Step 5 as `*maxRequestsPerTarget`. Confirm the
`Handle` built by `Prepare` receives it.

- [ ] **Step 3: single builds a `LimiterSet`**

In `mains/single/main.go.tmpl`, before the `// @@CLIENT_BUILD@@` marker:

```go
	// One ceiling per distinct target address, so two collectors pointed at the
	// same machine share it and two pointed at different machines do not. Built
	// here and consulted at startup only, over the finite set of
	// --collector.<name>.target flags, so no caller-controlled key ever reaches
	// it. The multi-instance model does not use this: there, each Handle owns
	// its own, which is what lets an instance added by a reload get one.
	limiters := collector.NewLimiterSet(*maxRequestsPerTarget)
```

and `client_build.frag` gains `.WithLimiter(limiters.For(*exampleTarget))` on
both branches:

```go
	if cfg.HTTPClientConfig != nil {
		exampleClient, err = collector.NewClientWithConfig(*exampleTarget, *exampleTimeout, *cfg.HTTPClientConfig)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			stop()     // release the signal handler explicitly before bypassing defer via os.Exit
			os.Exit(1) //nolint:gocritic // stop() called explicitly above
		}
	} else {
		// No http_client_config section: keep the transport every existing
		// deployment already runs.
		exampleClient = collector.NewClient(*exampleTarget, *exampleTimeout)
	}
	// A nil limiter (the default ceiling of 0) leaves this a no-op.
	exampleClient = exampleClient.WithLimiter(limiters.For(*exampleTarget))
```

- [ ] **Step 4: Register the wait histogram in single**

`registry.frag` registers `collector.RequestDuration`; add `RequestWait` beside
it so `docs/metrics.md` can document a metric that is actually exposed.

- [ ] **Step 5: Prove it**

```bash
cd /tmp/t1 && go build ./... && ./bin/demo_exporter --help | grep max-requests
cd /tmp/t8 && go build ./... && ./bin/demo_exporter --help | grep max-requests
```

Expected: the flag appears in both, defaulting to 0.

Then a live check that the ceiling is real, on a multi-instance scaffold with a
handler that counts concurrent requests and a ceiling of 1.

- [ ] **Step 6: Commit**

```bash
sh test/zero-source-grep.sh
git add skills/prometheus-exporter/assets/mains/single/main.go.tmpl \
        skills/prometheus-exporter/assets/mains/multi-instance/main.go.tmpl \
        skills/prometheus-exporter/assets/code/http/wiring/ \
        skills/prometheus-exporter/assets/code/cli/wiring/
git commit -m "feat(collector): wire --exporter.max-requests-per-target

0 by default, meaning unlimited: the same posture --probe.target-allowlist takes
with its empty value. A non-zero default would make the starvation scenario the
out-of-the-box behaviour rather than a deliberate choice, and the model has
never been measured under concurrent load.

multi-instance hangs the ceiling on each Handle, so an instance added by a
reload gets one. single indexes by target address instead, because each of its
collectors carries its own --collector.<name>.target and there is no shared
per-machine object; that index is consulted at startup only, over a finite set
of flags, so no caller-controlled key reaches it. multi gets no ceiling: it has
no background pollers, and its target comes from the query string."
```

---

# Tranche 4: the taught layer and the gates

## Task 11: `/add-collector` learns the fourth seam shape

**Files:**
- Modify: `commands/add-collector.md`

- [ ] **Step 1: Add the detection**

The command already recognises three seam shapes. Add the v0.7 shape,
identified by `New: func(h *instance.Handle)`, and make an older
multi-instance seam (`New: func(addr string, hcfg *promconfig.HTTPClientConfig)`)
a refusal that names the version and points at rescaffolding, exactly as the
v0.6 policy does for the probe seam.

- [ ] **Step 2: Update the appended fragment**

The multi-instance append must emit the Task 8 fragment shape verbatim,
including the `ClientFor` error branch.

- [ ] **Step 3: Prove it**

```bash
sh test/golden-smoke.sh --flavor http --forge none --target-model multi-instance 2>&1 | grep -E "add-collector|second-collector"
```

Expected: the mechanical `/add-collector` sub-check still passes on the new
seam.

- [ ] **Step 4: Commit**

---

## Task 12: `/design-exporter` asks about concurrency

**Files:**
- Modify: `commands/design-exporter.md`
- Modify: `commands/new-prometheus-exporter.md`

- [ ] **Step 1: Add the conditional sub-question**

Asked only when the target model is `multi-instance`, or `single` with at
least one background collector. Same three-piece shape as v0.5's credential
convention question: asked here, written into the brief, applied by
`/new-prometheus-exporter`.

Wording, to be used verbatim:

> Does this target tolerate several requests at once? Some devices and
> appliances serialize internally, or degrade sharply, and this exporter can
> hold at most N requests open against one machine at a time. Leave it
> unlimited unless you know otherwise; a ceiling makes a slow collector delay
> its siblings, which the freshness gauge and
> `<namespace>_exporter_request_wait_seconds` will show.

- [ ] **Step 2: Record it in the brief and apply it**

The answer becomes `--exporter.max-requests-per-target` in the generated
`config.example.yml`'s `flags:` section, commented out when the answer is
"unlimited".

- [ ] **Step 3: Prove it**

The golden's brief-format contract check must still pass, and the new section
must not break it.

- [ ] **Step 4: Commit**

---

## Task 13: the reference layer, docs and monitoring

**Files:**
- Modify: `skills/prometheus-exporter/references/exporter-architecture.md`
- Modify: `skills/prometheus-exporter/references/packaging-and-ops.md`
- Modify: `skills/prometheus-exporter/references/security-and-hardening.md`
- Modify: `skills/prometheus-exporter/references/dashboards-and-alerts.md`
- Modify: `skills/prometheus-exporter/references/collector-pattern.md`
- Modify: `skills/prometheus-exporter/references/docs-and-governance.md`
- Modify: `skills/prometheus-exporter/assets/SECURITY.md.tmpl`
- Modify: `skills/prometheus-exporter/assets/systemd/*.service.tmpl`
- Modify: `skills/prometheus-exporter/assets/monitoring/` health rules
- Modify: `skills/prometheus-exporter/assets/docs/metrics.md.tmpl`
- Modify: `skills/prometheus-exporter/assets/config.example.yml.tmpl`

- [ ] **Step 1: The three new metrics reach `docs/metrics.md`**

```
@@NAMESPACE@@_exporter_config_last_reload_successful
@@NAMESPACE@@_exporter_config_last_reload_success_timestamp_seconds
@@NAMESPACE@@_exporter_request_wait_seconds
```

`make docs-check` compares this file against the code, so a missing entry is a
red gate, not an omission.

- [ ] **Step 2: The alert rule**

```yaml
- alert: ConfigReloadFailed
  expr: @@NAMESPACE@@_exporter_config_last_reload_successful == 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "{{ $labels.job }} rejected its last configuration reload"
    description: >
      The exporter is still running its previous configuration. The file on
      disk and the running process disagree, so the next restart will pick up
      whatever is wrong. Check the exporter's log for the refusal.
```

- [ ] **Step 3: systemd**

```ini
ExecReload=/bin/kill -HUP $MAINPID
```

- [ ] **Step 4: `single` documents why it has no reload**

In `exporter-architecture.md`'s three-model comparison, state plainly that
`single` has no reload and why: its file holds `flags:`, which cannot be
reloaded, and `http_client_config:`, whose file-backed secrets and TLS material
`prometheus/common` already re-reads on every request. Point at `password_file`.

- [ ] **Step 5: Prove it**

```bash
sh test/zero-source-grep.sh
grep -c '[—–]' skills/prometheus-exporter/references/*.md skills/prometheus-exporter/assets/SECURITY.md.tmpl
sh test/golden-smoke.sh --flavor http --forge none --target-model multi-instance 2>&1 | grep -E "docs-check|promtool"
```

Expected: zero-source PASS, zero em dashes under `assets/`, `docs-check` and
`promtool check rules` green.

- [ ] **Step 6: Commit**

---

## Task 14: the golden gate

**Files:**
- Modify: `test/golden-smoke.sh`

- [ ] **Step 1: Add the four reload assertions to both reloadable cells**

For `http-multi` and `http-multi-instance`:

1. Start without the flag, `POST /-/reload` returns **404**. Proves the closed
   default.
2. Restart with `--web.enable-lifecycle`, rewrite the file to add an instance
   or a module, reload: **200**, `config_last_reload_successful 1`, **and the
   new instance appears in `/metrics`**.
3. Write a broken file, reload: **500**, gauge **0**, **and the previous
   instances are still served**.
4. Change `flags:`, reload: **500**, and the message names the key.

Assertion 3 is the one that proves atomicity. Assertions 2 and 3 exist because
of the v0.4 lesson: the golden checked that `config.example.yml` **existed**,
never that it **loaded**, and the defect survived nine task reviews. The
equivalent trap here is checking that `/-/reload` answers without ever checking
that it changed anything.

- [ ] **Step 2: Exercise a non-zero ceiling**

The `http-multi-instance` cell runs one configuration with
`--exporter.max-requests-per-target=1`, so the non-trivial limiter path is
proven end to end and not only in unit tests. With the ceiling at its default
of 0, nothing else in the matrix would ever execute it.

- [ ] **Step 3: Prove the whole matrix**

```bash
setsid nohup sh test/golden-smoke.sh --all > /tmp/golden-v07.log 2>&1 < /dev/null &
```

Wait for it (a Bash call is capped at ten minutes in foreground and background
alike, which is why this runs detached), then confirm 6/6 and check the log's
mtime is newer than the launch before quoting it.

- [ ] **Step 4: Commit**

- [ ] **Step 5: Update `ROADMAP.md` and `CHANGELOG.md`**

Move the delivered v0.7 items out of the roadmap's open list, and correct the
roadmap's own justification: it says the gap is credential rotation, which is
false for every secret held in a file.

---

## Self-review

**Spec coverage.** Every section of the design maps to a task: operator surface
to Tasks 4, 6, 9 and 13; the common layer to Task 4; `multi`'s swap to Tasks 5
and 6; the shared transport to Tasks 1 and 7; the five-case diff to Tasks 8 and
9; the ceiling to Tasks 2 and 10; consumers to Tasks 11, 12 and 13; the proofs
to every task's own steps plus Task 14.

**Known gaps, deliberate.** Tasks 11 through 13 carry less literal code than
Tasks 1 through 10 because they edit prose and YAML rather than Go, and the
exact wording is a judgement the implementer makes against the surrounding
document's voice. Every one of them still names its files, its assertion and
its gate.

**Type consistency.** `NewClientOn(tr, target, timeout)` then `.WithLimiter(l)`
is used identically in Tasks 1, 7 and 10. `Handle.ClientFor` returns
`(*collector.Client, error)` in Tasks 7, 8 and 11. `Factory.New` takes
`*Handle` and returns `(BackgroundCollector, error)` in Tasks 7, 8 and 11.
`Reloader.Reload() error` is what both `Handler` and the tests call, in Tasks 4,
6 and 9.

**Risk carried from the spec, and since REFUTED.** The spec warned that
`net/http` defaults `MaxIdleConnsPerHost` to 2, so collapsing one transport per
instance per collector into one per instance would put fifteen collectors on two
idle connections and churn them.

That does not happen. `prometheus/common@v0.70.1`'s `newRT`
(`config/http_config.go:652-664`) builds its transport with
`MaxIdleConns: 20000` and `MaxIdleConnsPerHost: 1000`, citing golang/go#13801,
and `NewClientFromConfig` reaches it unconditionally. Every path in this
scaffold that SHARES a client goes through `NewHTTPClient` and therefore through
that constructor. The one bypass is `NewClient`'s bare
`&http.Client{Timeout: ...}`, which inherits the default of 2, but that client is
private to a single `Client`, so no contention exists on it.

Established during Task 1 by the implementer and verified independently by the
reviewer against the module source. No override is needed, and adding one would
be redundant and fragile. Kept here rather than deleted because the spec still
states the risk, and a reader comparing the two documents deserves the
resolution.
