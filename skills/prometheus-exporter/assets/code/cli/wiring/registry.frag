	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(log, *exampleTimeout)
	}, true)
	register("command_exec", func() prometheus.Collector { return collector.CommandDuration }, true)
