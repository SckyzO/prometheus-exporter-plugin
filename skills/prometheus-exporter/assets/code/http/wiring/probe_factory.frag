	// Built once, before the closure: see NewHTTPClient on why building a
	// client per probe would defeat connection reuse. An unreadable CA or
	// credentials file is a configuration fault, so it stops the exporter
	// here rather than surfacing on the first probe.
	var exampleHTTP *http.Client
	if cfg.HTTPClientConfig != nil {
		exampleHTTP, err = collector.NewHTTPClient(*cfg.HTTPClientConfig, *probeTimeout)
		if err != nil {
			log.Error("Failed to build HTTP client from http_client_config", "err", err)
			stop()     // release the signal handler explicitly before bypassing defer via os.Exit
			os.Exit(1) //nolint:gocritic // stop() called explicitly above
		}
	}

	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(ctx context.Context, target string, timeout time.Duration) (prometheus.Collector, error) {
			if exampleHTTP != nil {
				return collector.NewExampleCollector(ctx, log, collector.NewClientFor(target, exampleHTTP)), nil
			}
			return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
