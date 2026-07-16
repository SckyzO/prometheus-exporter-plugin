	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, *exampleTimeout)
	}, true)
	register("command_exec", func() prometheus.Collector { return collector.CommandDuration }, true)
