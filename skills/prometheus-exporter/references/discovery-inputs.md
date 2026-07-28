# Discovery inputs: the grounding ladder, per-source extraction, and the architecture brief

The architecture decisions `exporter-architecture.md` walks through are
only as sound as whatever grounds them. Today that grounding is a single
input (context7, queried against the target's own library documentation)
which fails exactly where it matters most: an internal or proprietary
target has no library context7 has ever indexed, and the phase quietly
degrades to describing the target from memory, the exact guessing a
grounded design is supposed to prevent. This reference replaces that single
point of failure with a preference-ordered ladder of grounding sources that
always produces a working result, however far down the ladder the walk has
to go, feeding its output straight back into the design phase
`exporter-architecture.md` documents.

## The discovery ladder

Discovery walks the ladder top-down, one rung at a time, from the highest
grounding confidence to the lowest:

| Rung | Source | Confidence | Degrades when |
|---|---|---|---|
| 1 | Local API spec (OpenAPI/Swagger/`.proto`) | High | no spec file offered |
| 2 | Docs folder or URL | Medium | none offered / URL unreachable |
| 3 | context7 (target's lib) | Medium | not installed, or no library match |
| 4 | Live-target probe *(opt-in)* | High | no live instance offered / consent declined / non-interactive run |
| 5 | Dialogue with the user | Low | N/A (always available; terminal rung) |

**Degradation guarantees:**

- The phase never hard-fails. A rung that is unavailable is skipped, not
  blocking, and the walk continues to the next rung down.
- Every rung skipped gets a one-line note recorded in the brief's
  `## Provenance` section: why it was skipped, not just that it was.
- context7 absence is handled at two levels: the MCP server itself absent
  skips rung 3 entirely; installed but `resolve-library-id` returning no
  match skips it with a "context7 has no entry for the target" note
  instead of guessing from a nearby library or from memory.
- The walk favors the highest-confidence source actually available, and
  *supplements*, never replaces, it with lower rungs where they add
  detail the higher rung didn't cover (a local spec that names endpoints
  but stays silent on auth, say, supplemented by a docs page that isn't).
- The brief always records which rung(s) actually grounded the design and
  the resulting confidence (high/medium/low), so whoever reviews it knows
  how much to trust each decision.

Rung 4 is **opt-in**: it runs only when the user offers a running instance of
the target and consents to it being probed. When it is not activated the walk
is exactly `1→2→3→5` and nothing changes for anyone. Its data confidence is
high (it is the real instance) but its position stays low because it is
conditional on that instance existing and on explicit consent, so it
**supplements** the walk rather than leading it: it confirms what a higher
rung already stated and fills gaps a higher rung left silent. Where a live
probe *contradicts* a higher rung, that discrepancy is recorded as an
`## Open questions / assumptions` entry, never silently resolved. A running
instance can be mis-configured or an old build, so the design phase flags the
conflict for the user instead of picking a winner. The probe never runs
silently: `/design-exporter` shows the exact URL or command and gets explicit
consent first, and every capture passes through the redaction backbone
(`scripts/probe-target.sh`) before any of it can reach the brief.

## Per-source extraction

Each rung above has its own concrete extraction method: never "analyze
the docs and see what's there."

### OpenAPI/Swagger

- Each tagged group of paths becomes a candidate collector.
- Each `GET` operation whose response is a list or collection becomes a
  metric candidate.
- `servers[]` becomes `DATA_SOURCE`.
- The first candidate collector's path becomes `DATA_SOURCE_PATH`.
- `securitySchemes` becomes the auth note carried into the brief.
- A response shaped as an array is a cardinality warning: its size is
  rarely bounded by the spec alone, and the collector built from it needs
  the same budget question `exporter-architecture.md` asks of every label.

### gRPC `.proto`

- Each `service` becomes a candidate collector.
- Each unary RPC whose response message has `repeated` fields becomes a
  metric candidate.
- This is the gRPC-adapts-the-HTTP-flavor case `exporter-architecture.md`
  already describes: no dedicated `grpc` flavor ships, so a gRPC-backed
  collector reuses the `http` flavor's injectable-client shape
  (`collector-pattern.md`), a generated stub standing in for `net/http`.

### Docs folder / URL

Read the files directly, or fetch the URL, and extract the documented
endpoints or commands and the resources they expose. This is prose, not a
machine-readable contract, so it carries less confidence than rung 1. Mark
any decision drawn from it as such in the brief's Provenance and Confidence
fields, rather than letting it read as equally certain.

### context7

`resolve-library-id` on the target, then `query-docs` for its API surface,
unchanged from what step 0 has always done, now explicitly named as rung 3:
one input among several, not the only one.

### Live-target probe

Opt-in, and only after the user names a running instance and consents to the
exact command shown. Two modes, matching the two I/O flavors:

- **HTTP target**: `GET` one description surface: `/openapi.json`,
  `/swagger.json`, an existing `/metrics`, or a sample response the exporter
  will parse. Extract candidate collectors/metrics from it exactly as the
  OpenAPI or docs rules above would, marked in Provenance as live-probed
  (highest fidelity: it is what the instance actually serves).
- **CLI target**: run one discovery invocation (`<cmd> --help`,
  `<cmd> --version`, or a named sample sub-command) and read the captured
  output for the sub-commands and fields that become collectors.

Both modes go through `scripts/probe-target.sh`, which fetches or executes
under a timeout, **redacts** common secrets (auth headers,
`key`/`token`/`secret`/`password` pairs, URL credentials, PEM private
keys), then truncates the capture before emitting. Redaction runs
before the size cap, so a truncation boundary can never split a secret,
and the raw response never reaches the model or the brief.
Interpreting the redacted capture into candidates is the model's job; the
backbone does only fetch-redact-truncate. In a non-interactive run no consent
is possible, so the rung is skipped.

The extraction *method* here is `[G]` (fetch-redact-interpret holds for any
target); the instance's actual endpoints, flags, and response shapes are `[S]`
and live only in that target's brief, never folded back into this reference.

### Dialogue

Fall back to the `exporter-architecture.md` question flow: the same
interactive confirmation step 0 has always used, now the ladder's terminal
rung instead of its default starting point. Always available, so the phase
always has somewhere to land.

Across every source above, the extraction *method* (how a spec, a doc, or
a library's own documentation turns into a candidate collector) is `[G]`:
it holds regardless of which target is being discovered. A target's actual
endpoints, message names, and resource shapes are `[S]`: specific to that
one target, and they live only in that target's own brief, never folded
back into this reference or into a shipped template.

## The architecture brief

The ladder's output is a single markdown file, `./exporter-design-brief.md`
by default in the working directory (overridable with an explicit path).
It is consumed by the **model** executing `/new-prometheus-exporter`'s
prose (never parsed by `scaffold.sh`, which stays a plain `sed`
substitutor), so its format optimizes for human review and model
comprehension, not machine parsing. Identity fields (`MODULE_PATH`,
`OWNER`, `LICENSE`) are deliberately absent: they belong to whoever is
scaffolding, not to the target being discovered, and
`/new-prometheus-exporter` always asks for them whether or not a brief is
present. The exact format:

```markdown
# Exporter design brief: <target>

## Provenance
- Grounded by: <rung(s) actually used, e.g. "OpenAPI spec ./openapi.yaml,
  corroborated by live probe of http://localhost:9100/metrics">
- Skipped: <rungs skipped and why, e.g. "context7: no entry for <target>;
  live probe: no running instance offered">
- Confidence: <high | medium | low>

## Architecture decisions
- Data source: <REST API | gRPC | CLI>, <base URL / command>
- I/O flavor: <http | cli>
- Target model: <single | multi | multi-instance>
- Collectors (ordered):
  1. `<name>`, <resource>, endpoint `<path>`, <one line>
  2. ...
- Cardinality budget (per collector): labels, worst-case series, reduction flag
- Business-alert candidates: per collector, one line each

## Scaffold inputs
- EXPORTER_NAME: <name>
- NAMESPACE: <suggested>
- DATA_SOURCE: <url or command>
- DATA_SOURCE_PATH: <first collector endpoint, or "unused" for CLI>
- DEFAULT_PORT: <port>

## Open questions / assumptions
- <anything discovery could not resolve, flagged for the user>
```

Every section maps to something the ladder produced or a gap it left open:
`## Provenance` is the ladder's own audit trail; `## Architecture decisions`
is `exporter-architecture.md`'s output items in brief form;
`## Scaffold inputs` is exactly what `/new-prometheus-exporter` step 1 asks
for, minus identity; and `## Open questions / assumptions` is where a rung
that came back ambiguous (a spec silent on auth, a doc page that didn't say
how big a collection gets) is flagged for the user instead of quietly
assumed.
