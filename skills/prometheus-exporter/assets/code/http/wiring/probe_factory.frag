	factories = append(factories, probe.NamedFactory{
		Name: "example",
		New: func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
			// hc is the client the handler resolved from the module this
			// request named, or nil when no module carries credentials. It is
			// built once at boot, in main, and shared by every collector: see
			// NewHTTPClient on why a client per probe would defeat connection
			// reuse.
			if hc != nil {
				return collector.NewExampleCollector(ctx, log, collector.NewClientFor(target, hc)), nil
			}
			return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout)), nil
		},
	})
