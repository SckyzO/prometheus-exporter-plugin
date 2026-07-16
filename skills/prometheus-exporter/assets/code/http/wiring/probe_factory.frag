	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(ctx context.Context, target string, timeout time.Duration) prometheus.Collector {
			return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout))
		},
	})
