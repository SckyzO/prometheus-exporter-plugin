package collector

// The configured-wait-budget column of the queue sweep. Compiles only against
// post-phase-2 templates, which is why it is a separate file from
// sweep_common_test.go: the baseline column has to be measurable on an older
// commit, and a compile failure is not a measurement.
//
// See sweep_common_test.go for the sweep's shape and why its parameters are
// what they are.

import (
	"testing"
	"time"
)

// sweepWaitBudget is what --exporter.max-request-wait would be set to. The
// last collector to be served waits (sweepCollectors-1)*sweepWork, which is
// 3.78s here, so 6s clears it with room and is still a number an operator
// would plausibly write. This is the "minutes where a request is in seconds"
// sizing, scaled down so the test runs in about four seconds.
const sweepWaitBudget = 6 * time.Second

// TestQueueBudgetSweepWithWaitBudget measures the same sweep with the wait
// budget sized independently of the request timeout, which is the whole point
// of phase 2.
//
// This is the column that has to move. If it reports the same fourteen
// starving collectors as the default column, the wait budget is not reaching
// Client.acquire and the change has not happened, whatever the diff says.
func TestQueueBudgetSweepWithWaitBudget(t *testing.T) {
	got := runSweep(t, func(tr *Transport, url string, lim *Limiter) *Client {
		return NewClientOn(tr, url, sweepRequestTimeout).
			WithLimiter(lim).
			WithAcquireTimeout(sweepWaitBudget)
	})
	t.Logf("SWEEP with wait budget %s: %s", sweepWaitBudget, got)

	want := sweepCounts{ok: sweepCollectors, starved: 0, failed: 0}
	if got != want {
		t.Errorf("wait-budget sweep: got %s, want %s", got, want)
	}
}

// TestWithAcquireTimeoutIgnoresNonPositive pins the default-preserving half of
// the contract, which is what keeps every already-scaffolded exporter on the
// behaviour it has today. An unset flag is 0, and the wiring passes it through
// unconditionally rather than testing it first, so 0 MUST leave the seeded
// per-request deadline in place.
//
// Without this, a WithAcquireTimeout that assigned unconditionally would set
// acquireTimeout to 0, acquire would skip its WithTimeout entirely, and the
// wait would become unbounded: the exact silent-queueing failure the ceiling
// exists to prevent, reachable by not setting a flag.
func TestWithAcquireTimeoutIgnoresNonPositive(t *testing.T) {
	for _, d := range []time.Duration{0, -1 * time.Second} {
		c := NewClientOn(NewTransport(nil), "http://example.invalid", 5*time.Second).
			WithAcquireTimeout(d)
		if c.acquireTimeout != 5*time.Second {
			t.Errorf("WithAcquireTimeout(%v): acquireTimeout = %v, want the seeded 5s left untouched", d, c.acquireTimeout)
		}
	}
}
