	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(log, collector.NewClient(*exampleTarget, *exampleTimeout))
	}, true)
