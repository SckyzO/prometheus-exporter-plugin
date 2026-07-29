	register("example", func() prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, *exampleTimeout)
	}, true)
	register("command_exec", func() prometheus.Collector { return collector.CommandDuration }, true)
	register("command_exec_wait", func() prometheus.Collector { return collector.RequestWait }, true)
