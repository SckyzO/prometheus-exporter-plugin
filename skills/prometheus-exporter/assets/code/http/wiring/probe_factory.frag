	factory := func(target string, timeout time.Duration) prometheus.Collector {
		return collector.NewExampleCollector(log, collector.NewClient(target, timeout))
	}
