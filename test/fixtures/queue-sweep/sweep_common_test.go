package collector

// The queue-budget sweep, the measurement that decides whether a concurrency
// ceiling of 1 is serviceable. Copied into a scaffolded exporter's
// internal/collector/ by test/queue-budget-sweep.sh and run there, so it
// measures the code the templates actually render rather than a
// reimplementation of it.
//
// It reproduces the shape the field reported: N collectors of one watched
// machine, sharing one transport and one ceiling, all firing together because
// same-interval tickers align and that alignment does not break up on its own.
// Each holds the single slot for the duration of its request, so collector i
// wins the slot at roughly i*work and every collector whose wait budget
// expires before that starves.
//
// This file compiles against both the pre-phase-2 and post-phase-2 templates:
// it constructs clients exactly as the wiring does when no wait budget is
// configured. That is what makes it the non-regression column. The companion
// file sweep_budget_test.go exercises a configured wait budget and compiles
// only after phase 2.

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Sweep parameters. work is deliberately NOT an exact fifth of requestTimeout:
// at exactly a fifth, the fifth collector wins its slot at the same instant its
// budget expires, and which one gets there first is a race. 210ms against
// 1000ms puts the boundary 160ms clear of both neighbours, so the counts are
// stable across repetitions rather than stable-in-practice.
const (
	sweepCollectors   = 19
	sweepRequestTimeout = 1000 * time.Millisecond
	sweepWork           = 210 * time.Millisecond
)

// sweepCounts is the three-column result: a request that completed, one that
// gave up waiting for a slot, and one that won a slot but ran out of budget
// mid-request. The third column is the one phase 1 drove to zero.
type sweepCounts struct {
	ok      int
	starved int
	failed  int
}

func (c sweepCounts) String() string {
	return fmt.Sprintf("ok=%d starved=%d failed=%d", c.ok, c.starved, c.failed)
}

// runSweep fires sweepCollectors clients at one server through one ceiling of
// 1, all at the same instant, and classifies each outcome. build is how the
// caller constructs one client, which is the only thing that differs between
// the default column and the configured-wait-budget column.
func runSweep(t *testing.T, build func(tr *Transport, url string, lim *Limiter) *Client) sweepCounts {
	t.Helper()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(sweepWork):
		case <-r.Context().Done():
		}
		_, _ = w.Write([]byte("ok"))
	}))
	defer srv.Close()

	// Timeout 0 on the shared client is required, not incidental: NewClientOn's
	// own doc comment makes it the precondition that lets each collector carry
	// its own deadline. A non-zero value here would fire underneath all of them.
	tr := NewTransport(&http.Client{})
	lim := NewLimiter(1)

	var (
		wg    sync.WaitGroup
		mu    sync.Mutex
		got   sweepCounts
		start = make(chan struct{})
	)
	for i := 0; i < sweepCollectors; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c := build(tr, srv.URL, lim)
			<-start
			_, err := c.Fetch(context.Background(), "/")

			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				got.ok++
			case strings.HasPrefix(err.Error(), "wait for a request slot"):
				// Fetch's own wrapping of the acquire failure. Matching the
				// message rather than the error value is deliberate: the point
				// of phase 1 was that a starved collector reports the wait as
				// itself, so the message IS the property under measurement.
				got.starved++
			default:
				got.failed++
			}
		}()
	}
	close(start)
	wg.Wait()
	return got
}

// TestQueueBudgetSweepDefault measures the shipped default: no wait budget
// configured, so the wait is bounded by the collector's own request timeout,
// which is what every constructor has always set acquireTimeout to.
//
// This is the non-regression column. Its expected counts are identical before
// and after phase 2, and a change in them means phase 2 moved a default it was
// not supposed to move.
func TestQueueBudgetSweepDefault(t *testing.T) {
	got := runSweep(t, func(tr *Transport, url string, lim *Limiter) *Client {
		return NewClientOn(tr, url, sweepRequestTimeout).WithLimiter(lim)
	})
	t.Logf("SWEEP default (no wait budget configured): %s", got)

	// Collector i wins the slot at about i*work and its wait budget is the
	// request timeout, so it survives while i*work < requestTimeout: five of
	// them, and the other fourteen starve. Nothing fails mid-request, because
	// phase 1 already gave the request its own budget once the slot is won.
	want := sweepCounts{ok: 5, starved: 14, failed: 0}
	if got != want {
		t.Errorf("default sweep: got %s, want %s", got, want)
	}
}
