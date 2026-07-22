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
