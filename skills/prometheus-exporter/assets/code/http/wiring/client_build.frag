	// One ceiling per distinct target address, so two collectors pointed at
	// the same machine share it and two pointed at different machines do not.
	// Declared here, in the frag spliced at // @@CLIENT_BUILD@@ (after
	// kingpin.MustParse, so *maxRequestsPerTarget already holds its real
	// value), rather than directly in main.go.tmpl: that file is shared with
	// the cli flavor's own client_build frag, which has no per-target Client
	// to hang a LimiterSet off of (cli assigns collector.CommandLimiter
	// directly instead, see its own client_build.frag) and does not even
	// define collector.LimiterSet. Consulted at startup only, over the finite
	// set of --collector.<name>.target flags, so no caller-controlled key
	// ever reaches it. The multi-instance model does not use this: there,
	// each Handle owns its own, which is what lets an instance added by a
	// reload get one.
	limiters := collector.NewLimiterSet(*maxRequestsPerTarget)

	// A limiter with no bound on its own wait is exactly the silent-queueing
	// failure mode a concurrency ceiling exists to prevent (see
	// Client.WithLimiter's own doc comment, which names this exact check as
	// the thing that must happen here, at flag-parse time). Reject at boot,
	// naming the collector, the same way instance.Handle.ClientFor already
	// refuses a non-positive NewClientOn timeout.
	if *maxRequestsPerTarget > 0 && *exampleTimeout <= 0 {
		fmt.Fprintln(os.Stderr, fmt.Errorf("collector %q: a positive --collector.example.timeout is required when --exporter.max-requests-per-target is set, got %v (the limiter wait would otherwise be unbounded)", "example", *exampleTimeout))
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
	exampleClient = exampleClient.WithLimiter(limiters.For(*exampleTarget))
