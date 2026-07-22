	if cfg.HTTPClientConfig != nil {
		fmt.Fprintln(os.Stderr, "config file: http_client_config is not supported by this exporter. "+
			"It runs a local command rather than issuing HTTP requests, so there is nothing to authenticate.")
		stop()     // release the signal handler explicitly before bypassing defer via os.Exit
		os.Exit(1) //nolint:gocritic // stop() called explicitly above
	}
