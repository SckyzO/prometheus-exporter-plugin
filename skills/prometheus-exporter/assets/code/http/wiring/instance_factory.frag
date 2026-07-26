	exampleTimeout := kingpin.Flag("collector.example.timeout", "Per-request timeout for the example collector.").Default("5s").Duration()
	exampleInterval := kingpin.Flag("collector.example.interval", "Background refresh interval for the example collector.").Default("5m").Duration()
	exampleEnabled := kingpin.Flag("collector.example", "Enable the example collector.").Default("true").Bool()
	// The closure defers every flag dereference and the log reference to the
	// instance loop, which runs after kingpin.Parse() and after log is built,
	// exactly like the single-target background register() closure.
	factories = append(factories, instance.Factory{
		Name:    "example",
		Enabled: exampleEnabled,
		New: func(addr string, hcfg *promconfig.HTTPClientConfig) (instance.BackgroundCollector, error) {
			var client *collector.Client
			if hcfg != nil {
				var err error
				client, err = collector.NewClientWithConfig(addr, *exampleTimeout, *hcfg)
				if err != nil {
					return nil, err
				}
			} else {
				client = collector.NewClient(addr, *exampleTimeout)
			}
			return collector.NewExampleCollector(log, client, *exampleInterval), nil
		},
	})
