	if cfg.HTTPClientConfig != nil {
		fmt.Fprintln(os.Stderr, "config file: http_client_config is not supported by this exporter. "+
			"It runs a local command rather than issuing HTTP requests, so there is nothing to authenticate.")
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
	// One shared ceiling for every invocation this exporter runs. Unlike the
	// http flavor's LimiterSet, there is no per-target Client to index by,
	// only the single package-level Execute boundary every collector calls
	// through (see execute.go's own CommandLimiter doc comment), so a plain
	// assignment is everything a ceiling here needs. A ceiling of 0 (the
	// default) leaves CommandLimiter nil, which Acquire already treats as
	// unlimited.
	//
	// No boot-time non-positive-timeout guard is needed here the way the http
	// flavor's client_build.frag has one: exampleData unconditionally wraps
	// ctx in context.WithTimeout(ctx, c.timeout) before calling Execute, even
	// for a non-positive c.timeout, so a misconfigured
	// --collector.example.timeout already bounds the wait for a
	// CommandLimiter slot (an immediately-expired context, not an unbounded
	// one), unlike the gap Client.acquireTimeout exists to close on the http
	// flavor. What this flavor does NOT get from that is a wait budget
	// separate from the command's own; see execute.go's comment on the
	// ordering for what that costs and why it is not fixed by reordering.
	collector.CommandLimiter = collector.NewLimiter(*maxRequestsPerTarget)
