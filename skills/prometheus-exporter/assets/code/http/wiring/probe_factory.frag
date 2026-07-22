	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(ctx context.Context, target string, timeout time.Duration) (prometheus.Collector, error) {
			if cfg.HTTPClientConfig != nil {
				c, err := collector.NewClientWithConfig(target, timeout, *cfg.HTTPClientConfig)
				if err != nil {
					return nil, err
				}
				return collector.NewExampleCollector(ctx, log, c), nil
			}
			return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
