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

// The default-preserving half of the contract -- that an unset flag leaves the
// wait bounded by the collector's own timeout -- is asserted by
// TestWithAcquireTimeoutIgnoresNonPositive in limiter_test.go, which SHIPS in
// every scaffolded http exporter. It lived here first, when nothing else
// covered it; a copy in this fixture would now collide with the shipped one at
// compile time, since this file is dropped into the same package. It belongs
// downstream anyway: every generated exporter depends on that property, so
// every generated exporter should carry its own guard rather than trusting a
// test that only ever runs in this plugin's repository.
