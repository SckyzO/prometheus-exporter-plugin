	exampleTimeout := kingpin.Flag("collector.example.timeout", "Per-request timeout for the example collector.").Default("5s").Duration()
	exampleInterval := kingpin.Flag("collector.example.interval", "Background refresh interval for the example collector.").Default("5m").Duration()
	exampleEnabled := kingpin.Flag("collector.example", "Enable the example collector.").Default("true").Bool()
	// The closure defers every flag dereference and the log reference to the
	// reconciler, which runs after kingpin.Parse() and after log is built. It no
	// longer builds a transport: the Handle owns one per machine, shared by
	// every collector, so a reload can swap it underneath them.
	factories = append(factories, instance.Factory{
		Name:    "example",
		Enabled: exampleEnabled,
		New: func(h *instance.Handle) (instance.BackgroundCollector, error) {
			c, err := h.ClientFor(*exampleTimeout)
			if err != nil {
				return nil, err
			}
			return collector.NewExampleCollector(log, c, *exampleInterval), nil
		},
	})
