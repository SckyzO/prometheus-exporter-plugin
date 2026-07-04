	exampleTarget := kingpin.Flag("collector.example.target", "Base URL the example collector scrapes.").Default("@@DATA_SOURCE@@").String()
	exampleTimeout := kingpin.Flag("collector.example.timeout", "Per-request timeout for the example collector.").Default("5s").Duration()
