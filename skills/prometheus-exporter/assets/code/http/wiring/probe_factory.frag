	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(target string, timeout time.Duration) prometheus.Collector {
			return collector.NewExampleCollector(context.Background(), log, collector.NewClient(target, timeout))
		},
	})
