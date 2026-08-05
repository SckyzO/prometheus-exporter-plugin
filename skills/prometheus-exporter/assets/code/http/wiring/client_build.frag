	// One ceiling per distinct target address, so two collectors pointed at
	// the same machine share it and two pointed at different machines do not.
	// collector.Limiters (see limiter.go) is the single, shared LimiterSet
	// every collector's client_build wiring consults; THIS block only builds
	// it the first time it runs. That nil check is load-bearing, not
	// defensive-for-its-own-sake: this exact frag is spliced once per
	// collector, by scaffold.sh for the first one and by /prometheus-exporter:add-collector for
	// every one after, so with a second collector this block runs a second
	// time in the same main(). A plain `limiters := collector.NewLimiterSet(...)`
	// local declaration would either fail to compile the second time ("no
	// new variables on left side of :="), or, built as an unconditional
	// package-level assignment instead, would silently replace the first
	// collector's LimiterSet with an empty one, breaking the very sharing
	// guarantee this comment opens with for any two collectors that happen
	// to target the same address. Guarding on nil is what makes every
	// collector after the first reuse the SAME set instead. Consulted at
	// startup only, over the finite set of --collector.<name>.target flags,
	// so no caller-controlled key ever reaches it. Not declared directly in
	// main.go.tmpl either: that file is shared with the cli flavor's own
	// client_build frag, which has no per-target Client to hang a LimiterSet
	// off of (cli assigns collector.CommandLimiter directly instead, see its
	// own client_build.frag) and does not even define collector.LimiterSet.
	// The multi-instance model does not use this at all: there, each Handle
	// owns its own Limiter, which is what lets an instance added by a reload
	// get one without touching this set.
	if collector.Limiters == nil {
		collector.Limiters = collector.NewLimiterSet(*maxRequestsPerTarget)
	}

	// A limiter with no bound on its own wait is exactly the silent-queueing
	// failure mode a concurrency ceiling exists to prevent (see
	// Client.WithLimiter's own doc comment, which names this exact check as
	// the thing that must happen here, at flag-parse time). Reject at boot,
	// naming the collector, the same way instance.Handle.ClientFor already
	// refuses a non-positive NewClientOn timeout.
	//
	// --exporter.max-request-wait widens what counts as bounded, so this
	// refusal has to widen with it or it stops being NECESSARY: with a wait
	// budget set, a non-positive collector timeout no longer produces an
	// unbounded wait, and refusing it would reject a configuration that is
	// now correct. It stays SUFFICIENT because acquireTimeout ends up
	// non-positive only when both of these are, which is exactly the
	// condition below. See Client.acquire, which skips its WithTimeout on a
	// non-positive acquireTimeout and hands Acquire an undeadlined context.
	if *maxRequestsPerTarget > 0 && *maxRequestWait <= 0 && *exampleTimeout <= 0 {
		fmt.Fprintln(os.Stderr, fmt.Errorf("collector %q: a positive --collector.example.timeout or --exporter.max-request-wait is required when --exporter.max-requests-per-target is set, got timeout %v (the limiter wait would otherwise be unbounded)", "example", *exampleTimeout))
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}

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
	// WithAcquireTimeout is likewise a no-op at the default 0, which keeps the
	// wait bounded by the collector's own timeout exactly as before.
	exampleClient = exampleClient.WithLimiter(collector.Limiters.For(*exampleTarget)).
		WithAcquireTimeout(*maxRequestWait)
