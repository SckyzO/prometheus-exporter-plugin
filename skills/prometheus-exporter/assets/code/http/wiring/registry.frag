	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(log, collector.NewClient(*exampleTarget, *exampleTimeout))
	}, true)
	register("http_client_requests", func() prometheus.Collector { return collector.RequestDuration }, true)
