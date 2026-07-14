	factory := func(target string, timeout time.Duration) prometheus.Collector {
		return collector.NewExampleCollector(context.Background(), log, collector.NewClient(target, timeout))
	}
