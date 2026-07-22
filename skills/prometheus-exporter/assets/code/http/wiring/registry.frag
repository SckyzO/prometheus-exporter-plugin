	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, exampleClient)
	}, true)
	register("http_client_requests", func() prometheus.Collector { return collector.RequestDuration }, true)
