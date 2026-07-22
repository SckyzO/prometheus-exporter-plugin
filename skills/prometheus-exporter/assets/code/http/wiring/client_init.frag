	exampleTarget := kingpin.Flag("collector.example.target", "Base URL the example collector scrapes.").Default("@@DATA_SOURCE@@").String()
	exampleTimeout := kingpin.Flag("collector.example.timeout", "Per-request timeout for the example collector.").Default("5s").Duration()
	// Declared here, assigned at // @@CLIENT_BUILD@@ once flags are parsed.
	// The registry closure below captures it by reference and only
	// dereferences it later, in main's construction loop.
	var exampleClient *collector.Client
