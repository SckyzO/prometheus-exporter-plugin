# Per-module credentials for the `multi` target model

**Status:** design approved 2026-07-27 · v0.5.0, volet A. Closes the epic
opened by
[`2026-07-23-multi-instance-target-model-design.md`](2026-07-23-multi-instance-target-model-design.md),
whose §1A named this deliverable and whose volet B (the `multi-instance`
target model) has already landed. That drop left `multi` ignoring the
`modules:` section it introduced; this one makes `multi` consume it.

## 1. Goal

A `multi` exporter authenticates every target through one global
`http_client_config:`. It therefore cannot probe two targets that
authenticate differently: one set of credentials, one CA, for every machine
the exporter is ever pointed at. That is the gap volet B's `modules:` schema
was shaped to fill, and the reason `multi` currently parses that section and
does nothing with it.

This design lets a `/probe` request select credentials by name:

```
/probe?target=https://a.example.net&module=prod
```

## 2. Background: what `multi` does today

Three facts decide everything below, all of them already shipped.

**One client, built once, shared by every target.**
`code/http/wiring/probe_factory.frag:1-13` builds a single `*http.Client`
from `cfg.HTTPClientConfig` before the factory closure and captures it. The
comment on `NewHTTPClient` (`code/http/client.go.tmpl:72`) explains why it is
built once rather than per probe: `promconfig.NewClientFromConfig` mints a
fresh `http.Transport` on every call and caches nothing, so a per-request
build would give each request a private connection pool and re-read the CA
and credential files from disk.

**`?module=` already exists, and it is combinable.** `--probe.module` declares
scrape profiles (`<name>:<collector>,...`,
`mains/multi/main.go.tmpl:96-99`), and `selectFactories`
(`internal/probe/probe.go.tmpl:140-166`) resolves a request's `module`
parameter to the **union** of the named modules' collectors, deduplicated and
emitted in declared factory order. The parameter is both repeatable and
comma-separated (`moduleNames`, `:120-130`), which is SNMP's grammar. An
absent `module` runs every registered collector.

**Each added collector currently builds its own client.** On a repository
that has a configuration file, `/add-collector` pastes a
per-collector client-build block (`commands/add-collector.md:164-186`)
before each `factories = append(...)` call. Three collectors therefore
produce three `*http.Client`s, three `http.Transport`s and three connection
pools, all built from the same `cfg.HTTPClientConfig`, all pointed at the
same target.

## 3. The semantics

### 3.1 The problem the design has to answer

Attaching credentials to a module collides with the combinability that
already shipped:

```
/probe?target=X&module=creds_a,creds_b
```

Two credential sets, one request. There is no correct silent answer:
picking the first is undocumented precedence, and merging produces a
combination nobody wrote.

### 3.2 Rules

Evaluated per `/probe` request.

1. **Collectors.** The selection is the deduplicated union of the
   `collectors:` lists of the selected modules, emitted in declared factory
   order. Unchanged from today. **A module that lists no collectors
   contributes none**: it is a credentials-only module, and it does not
   widen the selection. If no selected module contributed any collector,
   every registered collector runs, which is what an absent `module`
   parameter already does.
2. **Credentials resolve in a fixed order**, first hit wins. Selection is
   deduplicated by name first, so `module=a,a` selects one module, not two.
   1. The unique selected module carrying an `http_client_config:`.
   2. Otherwise the `default` module's, if a `default` module is declared.
   3. Otherwise the top-level `http_client_config:`, reachable only when the
      file declares no `modules:` section at all (rule 9). This is the
      v0.4.0 path, and it is what keeps an existing deployment identical.
   4. Otherwise the default transport.
3. **Ambiguity is a 400, never a precedence.** Two selected modules both
   carrying an `http_client_config:` is refused:
   `modules "a" and "b" both carry credentials; a probe can only use one`.
   Step 2.1 is therefore never a choice between two candidates.
4. **Replacement, not merge.** A selected module's client config is taken
   whole. There is no field-level merge with the top-level section
   (volet B's §3 rule 3, unchanged).
5. **Resolving no credentials against a configuration that declares some is a
   400.** When every step of rule 2 misses and at least one module in the
   file carries an `http_client_config:`, the request is refused:

   ```
   no credentials selected: modules "prod", "staging" declare credentials but this
   request selected none; name one with &module=, or declare a "default" module
   ```

   This is the anti-silent-unauthenticated guard, and it covers two distinct
   mistakes with one rule: a scrape config that forgot `&module=` entirely,
   and one that named only a collector-subset module. Probing in the clear
   against a target the operator went to the trouble of giving credentials
   for is the one outcome worse than a failed scrape, because a 400 makes
   `up` go to 0 and shows up in the monitoring, while a silent unauthenticated
   probe returns 200 and empty or wrong series that nobody notices.

   A configuration that declares no credentials anywhere is untouched by this
   rule: the probe runs on the default transport, exactly as it does today.
6. **Unknown module is a 400.** Unchanged (`selectFactories`,
   `probe.go.tmpl:149-151`).
7. **Flag-declared modules carry no credentials.** When the modules come from
   `--probe.module` (rule 8 makes that the only other source), no module can
   carry an `http_client_config:`, so rules 2 and 3 can never fire and the
   top-level `http_client_config:` applies to every request exactly as it
   does today. This is the guarantee that a v0.4.0 deployment, rescaffolded
   or migrated, behaves identically.
8. **The `--probe.module` flag and a `modules:` section are mutually
   exclusive**, refused at boot with a clear message; the flag is documented
   as deprecated, for removal in a later version. Volet B's §3 rule, applied
   here for the first time.
9. **A `modules:` section and a top-level `http_client_config:` are mutually
   exclusive**, refused at boot. With modules declared, the top-level section
   has no reader, so accepting both would silently ignore one of two places
   an operator wrote credentials. This is what makes rule 2's step 3
   unambiguous: the top-level section is reachable only when no module is.
   No deployment can depend on the combination, because `multi` ignores
   `modules:` entirely until this change lands.

### 3.3 One mechanism, two conventions

Rules 1 and 2 are not a compromise between the ecosystem's two shapes; they
are the superset that expresses both, in configuration, with one code path.

**Blackbox convention**, a module is a complete bundle:

```yaml
modules:
  prod: { collectors: [disks, network], http_client_config: { basic_auth: {...} } }
```
```
/probe?target=X&module=prod
```

**SNMP convention**, credentials and metric subsets are independent axes.
`snmp_exporter` splits them into two parameters, `auth` and `module`
(verified against its current endpoint documentation). The same split is
expressible here with one parameter, because a credentials-only module
contributes no collectors (rule 1):

```yaml
modules:
  prod_creds: { http_client_config: { basic_auth: {...} } }   # no collectors:
  disks:      { collectors: [disks] }
  network:    { collectors: [network] }
```
```
/probe?target=X&module=prod_creds,disks,network
```

Rule 1's second sentence is what makes the second convention expressible.
Without it, `prod_creds` would mean "every collector" and would swallow the
`disks,network` narrowing.

The developer chooses a convention **in the configuration file**, never in
code, so the choice is reversible without rescaffolding. §7 covers how the
plugin walks them to that choice.

### 3.4 Alternatives rejected

- **One module per request (strict Blackbox).** Simplest to teach, but it
  withdraws the combinability the plugin already teaches, and it makes the
  SNMP convention inexpressible.
- **A second `auth=` parameter (strict SNMP).** Two orthogonal axes, one
  clean rule each, and it is the closest ecosystem precedent to the exact
  problem. Rejected because volet B already shipped
  `instances[].module` referencing a module *for its credentials*: adopting
  `auth=` here would mean either two YAML sections for one concept or
  renaming volet B's key. The chosen rules give the same expressiveness
  without a second parameter or a second section.

## 4. Configuration schema

No schema change. Volet B already ships the `Module` type
(`internal/config/config.go.tmpl:59-72`) with exactly the two keys this
design needs, and already validates each module's client config, with paths
resolved relative to the configuration file, at load time (`:127-142`).

What changes is which target model acts on it: `collectors:` is honoured
under `multi` (volet B's §3 rule 2 already says so and already refuses it
under `multi-instance`), and `http_client_config:` becomes selectable per
request instead of ignored.

One new exported function on `Config`, the mirror of `ResolveInstances`
(`:383-455`):

```go
// ResolveModules validates the modules section for the multi target model.
func (c *Config) ResolveModules() (map[string]ResolvedModule, error)

type ResolvedModule struct {
	Collectors   []string
	ClientConfig *promconfig.HTTPClientConfig
}
```

It applies the v0.4.0 compatibility rule the same way `resolveModule`
(`:462-477`) already does for instances: with no `modules:` section, a
top-level `http_client_config:` is the `default` module. **A declared
`modules:` section with no `default` key is not a boot failure**: it is
legitimate for an operator to require every scrape config to name its module
explicitly, and rule 5 turns an unresolved request into a per-request 400
instead. What `ResolveModules` does refuse at boot is rule 9's combination, a
`modules:` section alongside a top-level `http_client_config:`.
`internal/config` builds no `*http.Client`: it stays a parsing and validation
layer with no I/O, exactly as volet B left it, and the caller builds the
clients (§5.3).

## 5. The probe seam

### 5.1 Signature

```go
type Factory func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error)
```

A fourth parameter; `nil` means the default transport. The taught closure
body is unchanged from what `probe_factory.frag` already ships:

```go
New: func(ctx context.Context, target string, timeout time.Duration, hc *http.Client) (prometheus.Collector, error) {
	if hc != nil {
		return collector.NewExampleCollector(ctx, log, collector.NewClientFor(target, hc)), nil
	}
	return collector.NewExampleCollector(ctx, log, collector.NewClient(target, timeout)), nil
},
```

A narrower seam was considered and rejected: `New(ctx, *collector.Client)`
would drop `target` and `timeout` entirely, but it would move client
construction and the timeout policy into `internal/probe`, which would then
have to know the flavor's `Client` type, and it would diverge from
`instance.Factory`'s shape (`internal/instance`, volet B). Three seams that
mirror each other are what makes `/add-collector` teachable; three seams that
each solve the problem differently are not.

### 5.2 The handler's module map

`Handler.modules map[string][]string` becomes:

```go
type Module struct {
	Collectors []string     // empty: contributes credentials only (rule 1)
	Client     *http.Client // nil: default transport
}
```

`ParseModules` (the flag source) fills `Collectors` and leaves `Client` nil.
The configuration source fills both. The two sources are mutually exclusive
at boot (rule 8), so the map never has two origins. `ValidateModules`
(`probe.go.tmpl:171-193`) takes the new type and keeps doing its job: every
module's collector names must match a registered factory, checked at boot,
failing sorted so the same module fails every time.

`selectFactories` gains rules 1, 2, 3, 5 and 6, and returns the selected
factories plus the resolved client. `NewHandler` gains one parameter, the
top-level client of rule 2 step 3: it is non-nil only when the file declared
a `http_client_config:` and no `modules:` section, which rule 9 guarantees is
the only way both can be spelled.

### 5.3 What leaves the fragment

The boot-time client build leaves `probe_factory.frag` and leaves
`/add-collector`'s appended block. `mains/multi/main.go.tmpl` builds the
map once, after `config.Load` and before `probe.NewHandler`: one
`*http.Client` per module carrying an `http_client_config:`, built with
`collector.NewHTTPClient(cfg, *probeTimeout)` exactly as the fragment builds
its single client today. An unreadable CA or an absent `password_file` fails
the boot, not the first probe.

The per-request client timeout is unchanged: the client's own `Timeout` is
the `--probe.timeout` ceiling, and the request's real, clamped deadline is
carried by `ctx`, as it already is.

This removes the duplication described in §2: N collectors on a configured
repository stop producing N identical clients, transports and connection
pools. `/add-collector`'s instructions get shorter, not longer.

## 6. Boot sequence (`mains/multi/main.go.tmpl`)

Inserted into the existing sequence (`:108-159`), which is otherwise
untouched:

1. `config.Load` (unchanged), `cfg.Validate` (unchanged), the `instances:`
   refusal (unchanged, `:119-123`).
2. `kingpin.MustParse`, logger, warnings (unchanged).
3. The `// @@PROBE_FACTORIES@@` marker and the factories it fills
   (unchanged in position; the closures gain the fourth parameter).
4. **New:** refuse `--probe.module` together with a `modules:` section
   (rule 8).
5. **New:** `cfg.ResolveModules()`, then one `*http.Client` per
   credential-bearing module, then merge with the flag-declared modules
   (only one source can be non-empty).
6. `probe.ValidateModules` (unchanged in role, new map type).
7. `probe.NewHandler(...)` with the module map.

Rule 8's refusal cannot sit before `kingpin.MustParse`: it reads
`*probeModules`, and a kingpin flag pointer holds its zero value until the
parse runs. An earlier revision of this section placed it at step 2, ahead of
the parse, where it would have compared `cfg.Modules` against an always-empty
flag slice and never fired. It is written after the parse instead, which is
also where the logger exists, so the refusal can be reported with `log.Error`
like every other boot failure in this block rather than with a bare
`fmt.Fprintln`.

Every failure in steps 4 and 5 exits non-zero before the server binds,
matching the `os.Exit(1)` posture the file already uses throughout.

## 7. Accompanying the developer

The choice of convention (§3.3) belongs to whoever builds the exporter, not
to this plugin. Three pieces carry that choice, and **none of them is a code
variant**: the generated code is identical in all cases.

1. **`/design-exporter` asks, at architecture time**, as a sub-question of
   the target-model decision and only when the answer is `multi`:

   > How do your targets authenticate?
   > **a.** All the same, or not at all: no `modules:` section is needed; the
   > global `http_client_config:` covers every target (v0.4.0 behaviour).
   > **b.** By group (prod/staging, two sites, two tenants): one module per
   > group, the Blackbox convention. Prometheus relabels `module` from the
   > service-discovery entry.
   > **c.** Credentials and collector subsets vary independently: the SNMP
   > convention, credentials-only modules combined with collector modules.

2. **The answer lands in the architecture brief** under
   `## Architecture decisions`, so it survives on disk rather than in the
   conversation.

3. **`/new-prometheus-exporter` repeats it** in its closing section: which
   block to uncomment in `config.example.yml`, which `scrape_config` to copy
   from `docs/configuration.md`.

## 8. Migration of already-scaffolded repositories

`/add-collector` detects two seam shapes today (`commands/add-collector.md:56`).
It will detect three:

```sh
grep -q 'hc \*http\.Client' internal/probe/probe.go && echo modules \
  || (grep -q 'factories \[\]NamedFactory' internal/probe/probe.go && echo current || echo v0.3.0)
```

The migration protocol is the one already proven by the `v0.3.0` migration
(`add-collector.md:56-127`): `internal/probe/probe.go` and
`internal/probe/probe_test.go` rewritten wholesale from the templates
(generic shipped plumbing, never hand-edited), the probe-wiring block of
`cmd/*/main.go` alone reshaped, **the diff shown before anything is
written**, and a decline leaving the repository untouched with the diff in
the user's hands.

Two things make it cheaper than its predecessor:

- **No flag is renamed.** The `v0.3.0` migration renamed
  `--collector.example.timeout` to `--probe.timeout`, breaking anyone already
  running the exporter. This one is additive: every existing URL and flag
  answers identically.
- **The only observable change** is the collapse of N identical clients into
  one: same credentials, same requests, one connection pool instead of N.

The existing per-collector `<name>HTTP` build blocks are removed by the
migration, and their credentials are carried by the `default` module.

## 9. Test matrix

| Claim | Proven by |
|---|---|
| The selected module's client is the one used | `internal/probe/probe_test.go.tmpl`: two modules, two `httptest.Server`s, assertion on the `Authorization` header the server actually received |
| Two credential-bearing modules produce a 400 | `probe_test.go.tmpl` and the golden `http-multi` cell |
| A module with no `collectors:` does not widen the selection | `probe_test.go.tmpl` |
| A request resolving no credentials against a file that declares some produces a 400, both when `module` is absent and when it names only a collector-subset module | `probe_test.go.tmpl` |
| A file declaring no credentials at all still probes on the default transport | `probe_test.go.tmpl` |
| A `modules:` section alongside a top-level `http_client_config:` fails the boot | `config_test.go.tmpl` |
| `ResolveModules`: v0.4.0 compatibility, unknown module, sorted deterministic errors | `internal/config/config_test.go.tmpl`, mirroring the `ResolveInstances` tests |
| The binary boots with a `modules:` section | golden `http-multi` cell |
| The binary refuses to boot with both `--probe.module` and `modules:` | golden `http-multi` cell (this lives in `main`, so no unit test can reach it) |
| `single` and `multi-instance` are unaffected | `golden-smoke --all`, six cells, **none added** |

**What the golden cannot prove, stated plainly.** The cell probes the
exporter itself, so no real authenticated backend exists in it. It proves the
boot, the refusals and the HTTP status codes; it does not prove
authentication end to end. That claim is carried by the Go test above and by
nothing else. `config.example.yml` is loaded by every cell since v0.4.0,
which is why the new `modules:` block ships **commented out** (§10): an
active block would have to be valid for a boot that has no such credentials
to read.

## 10. Documentation surface

Shipped inside every generated exporter:

- `assets/config.example.yml.tmpl`: a commented `modules:` section showing
  both conventions side by side, alongside the already-commented
  `http_client_config:`.
- `assets/docs/configuration.md.tmpl`: the `/probe?target=` section gains the
  seven rules, the two conventions, and the `scrape_config` with
  `__param_module` (volet B's §11).
- `assets/SECURITY.md.tmpl`: credentials are read at boot; there is no hot
  reload (deferred to v0.6.0); a module name never reaches a series.

Taught by the plugin:

- `references/exporter-architecture.md`: the `multi` decision gains its
  credential dimension.
- `references/project-scaffold.md`: the four-parameter seam.
- `references/security-and-hardening.md`: this file does not currently
  mention `/probe` at all; a per-module credentials paragraph is added, to be
  confirmed against its existing structure during implementation.
- `commands/add-collector.md`: the third seam shape, and the shortened append
  block.
- `commands/new-prometheus-exporter.md` and `commands/design-exporter.md`:
  §7 above.

## 11. Non-goals

- **A per-module target allowlist.** `--probe.target-allowlist` stays global.
  No consumer needs the cross product, and a per-module allowlist would make
  a 403 depend on two independent settings.
- **Per-module timeouts or intervals.** Volet B's per-instance override
  refusal, for the same reason: kingpin parses the flag surface once.
- **Labels carried by a module.** They come from Prometheus relabeling
  (volet B §11), not from the exporter.
- **Hot reload.** SIGHUP is already deferred to v0.6.0 by volet B; per-module
  credentials inherit that deferral, which is why §10 has `SECURITY.md` say so
  out loud.

## 12. Deferred / open

- **Removing `--probe.module`.** Deprecated by rule 8, removed no earlier
  than v0.6.0, per the plugin's two-phase rule.
- **`ResolveInstances` does not enforce rule 9.** Under `multi-instance`, a
  `modules:` section alongside a top-level `http_client_config:` silently
  ignores the latter (`resolveModule` consults it only when `len(c.Modules)`
  is zero, `config.go.tmpl:466-471`). That is shipped v0.5.0 behaviour, so
  aligning it is a two-phase change of its own rather than a drive-by edit
  here. Recorded for v0.6.0.
- **The default transport is still built per request.** The `hc == nil` path
  calls `collector.NewClient(target, timeout)` inside the closure, once per
  probe, as it already does today. Hoisting it to boot would mean pinning a
  client timeout that the per-request clamp can shorten. Pre-existing, out of
  scope here, recorded so it is not mistaken for something this design
  introduced.
