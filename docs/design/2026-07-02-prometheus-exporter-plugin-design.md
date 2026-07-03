# Design — Plugin `prometheus-exporter`

> Spec de conception (livrable de brainstorming). Statut : **à relire par le mainteneur**.
> Date : 2026-07-02. Auteur : Tom.
> Cible : plugin Claude Code réutilisable pour scaffolder et durcir des exporters Prometheus,
> calqué sur la maturité de `slurm_exporter`.
> Dépôt : `~/Dev/work/apps_repo/exporters/prometheus-exporter-plugin/`.

---

## 1. Objectif

Fournir un **plugin Claude Code** qui capture le savoir-faire d'un exporter Prometheus Go
« mature » (celui de `slurm_exporter`) et le rend **réutilisable, paramétrable, partageable et
auditable** pour créer de nouveaux exporters de qualité production, en respectant **d'abord**
les conventions officielles Prometheus.

À partir de ~6 variables (`name`, `namespace`, `external command`, `module path`, `port`,
`owner`), on obtient un dépôt d'exporter **buildable, testé, documenté, releasable**, sans
réinventer le pattern collector, la toolchain, la CI/CD, ni la discipline docs.

Non-objectifs (YAGNI v1) :
- Pas de support multi-langage (Go uniquement ; couche principes séparable pour extension
  future — §2).
- Pas de génération de dashboards Grafana (référencée en doc, pas scaffoldée).
- Pas de MCP/LSP/hooks dans le plugin v1.

---

## 2. Périmètre technique (confirmé)

**Cœur Go opinionné calqué sur `slurm_exporter` + couche « principes Prometheus » séparable.**

- Couche **principes Prometheus** (naming, types, labels, cardinalité, OpenMetrics) isolée
  dans son fichier de référence, sourcée de la **doc officielle via context7 / `prometheus.io`**
  (*Writing Exporters* + *Metric and label naming*). Langage-agnostique, réutilisable si un
  backend non-Go était visé en phase 2.
- Couche **blueprint Go** appliquant le pattern exact du repo : `var Execute` mockable,
  collector en 5 pièces, triade de tests, registry map-driven, StatusTracker,
  self-instrumentation, exporter-toolkit, shutdown signal-aware, toolchain containerisée,
  GoReleaser + cosign + SBOM, Docker dual-variant, discipline docs.

Séparation systématique **[G] générique réutilisable** vs **[S] spécifique** : les templates ne
conservent que le [G] ; le [S] (commande externe, préfixe métrique, parsing) devient des
variables ou des trous à remplir.

**Principe d'auto-portance (important).** Le plugin ne doit **rien présupposer d'un
`CLAUDE.md`/profil personnel du mainteneur**. Une fois distribué, il tourne chez des tiers sans
ce contexte ; en dépendre = couplage caché. Les principes d'ingénierie OSS sur lesquels le
plugin s'appuie sont donc **extraits et de-personnalisés** dans le plugin lui-même (voir §7bis),
en distinguant *principe universel* (encodé) de *préférence personnelle* (exclue).

**Contrainte dure — aucune mention de la source dans les artefacts livrés.** `slurm_exporter`
(et toute identité de mainteneur / chemin perso) ne doit apparaître **nulle part** dans les
composants chargés/livrés du plugin : `SKILL.md`, `references/`, `assets/` (templates),
`commands/`, `agents/`, `README.md`, `CLAUDE.md` racine. Le plugin est générique et autonome.
`slurm_exporter` ne peut être nommé **que** dans ce design doc (`docs/design/`), qui est
l'historique de *création*, pas un composant du plugin.
**Vérification automatisable :** `grep -ri -e slurm -e <maintainer-handle>` sur l'arbre du
plugin **hors `docs/design/`** doit retourner **0 résultat**.

**Principe container-first (important).** Tout l'outillage de dev — build, test, race, lint,
vuln, sécurité, report — s'exécute **dans un conteneur** (image `*-tools` à versions d'outils
**pinnées**), jamais sur des outils hôte par défaut. Bénéfice : reproductibilité + dernières
versions des binaires sans casser l'hôte. Deux exigences complémentaires :
1. **Multi-moteur** : détection auto `docker` **ou** `podman` (`CONTAINER_ENGINE ?=`).
2. **Fallback natif** : si aucun moteur n'est détecté, exécution sur outils hôte avec
   **avertissement** « versions non pinnées » + escape hatch `NATIVE=1`. Indispensable car
   chaque exporter généré hérite de ce Makefile → ses contributeurs tiers doivent pouvoir
   travailler sans conteneur.

---

## 3. Nature & emballage (décidé)

**Plugin Claude Code** `prometheus-exporter`, versionné et partageable, contenant **3
composants** :

1. **Skill** `prometheus-exporter` — le savoir + le workflow (SKILL.md routeur + `references/`
   + `assets/`).
2. **Slash command** `/new-prometheus-exporter <name>` — scaffolde un dépôt d'exporter complet
   depuis les templates en remplissant les variables.
3. **Subagent** `exporter-reviewer` — audite un exporter sur les critères **spécifiques
   exporter** (Definition of Done, conventions Prometheus, séparation [G]/[S], cardinalité,
   triade de tests présente). Conçu pour être **lancé en parallèle** de `/code-review` et
   `pr-review-toolkit` par le workflow (voir §8 — nuance d'imbrication).

**Emplacement :** dépôt dédié `~/Dev/work/apps_repo/exporters/prometheus-exporter-plugin/`
(`git init` fait), transformable en marketplace pour distribution. **Rien n'est committé dans
le repo `slurm_exporter`.**

### Rappel structure officielle (docs code.claude.com)

- Manifeste : `.claude-plugin/plugin.json` (`name` + `description` requis ; `version`,
  `author`, `license`, `keywords`, `homepage`, `repository` optionnels).
- Composants **à la racine du plugin** (auto-découverts) : `commands/` (1 `.md`/commande),
  `agents/` (1 `.md`/agent), `skills/<nom>/SKILL.md` (+ `references/`, `assets/` imbriqués).
- Assets bundlés référencés via **`${CLAUDE_PLUGIN_ROOT}`**.
- Dev local : `claude --plugin-dir ./prometheus-exporter-plugin`, `claude plugin validate .`,
  `/reload-plugins` pour recharger sans redémarrer.
- Distribution : `marketplace.json` (source `github`/`git`/relative path).

---

## 4. Structure du plugin

```
prometheus-exporter-plugin/               # racine du dépôt (git)
  .claude-plugin/
    plugin.json                           # manifeste : name, version, description, author, license, keywords
  CLAUDE.md                               # règles de contribution AU PLUGIN (voir §7)
  README.md                               # présentation, install, dev loop (SANS mention de source — §2)
  ROADMAP.md                              # jalons (v0.1 MVP → v1.0)
  TODO.md                                 # backlog opérationnel
  CHANGELOG.md                            # Keep-a-Changelog
  LICENSE
  docs/
    design/2026-07-02-prometheus-exporter-plugin-design.md   # ce spec
  commands/
    new-prometheus-exporter.md            # slash command de scaffolding
  agents/
    exporter-reviewer.md                  # subagent d'audit exporter-spécifique
  skills/
    prometheus-exporter/
      SKILL.md                            # routeur : quand/comment, checklist, context7-first
      references/
        prometheus-principles.md          # conventions officielles (source context7)
        collector-pattern.md              # les 5 pièces + triade de tests + var Execute
        project-scaffold.md               # layout, main.go registry, flags auto, endpoints, shutdown
        makefile-and-tooling.md           # toolchain containerisée, targets, golangci, scripts
        cicd-and-release.md               # workflows, GoReleaser, cosign/SBOM, dependabot, CODEOWNERS
        packaging-and-ops.md              # Dockerfile dual, compose durci, systemd
        security-and-hardening.md         # sécu OSS de-personnalisée : jamais de secret en métrique, warnings, config opt.
        docs-and-governance.md            # jeu de docs, Definition of Done, SECURITY/CHANGELOG/CONTRIBUTING
      assets/                             # templates matérialisés par /new-prometheus-exporter
        code/       collector.go.tmpl, collector_test.go.tmpl, parser_test.go.tmpl,
                    execute.go.tmpl, status_tracker.go.tmpl, cache.go.tmpl,
                    background_collector.go.tmpl, main.go.tmpl, go.mod.tmpl
        build/      Makefile.tmpl, .golangci.yml,
                    scripts/docker/tools/{Dockerfile.tmpl, goreport.sh, deps-report.sh}
        release/    .goreleaser.yaml.tmpl, .goreleaser.dev.yaml.tmpl,
                    workflows/{ci,release,dev-release,govulncheck,trivy-scan,scorecard}.yml(.tmpl),
                    dependabot.yml.tmpl, CODEOWNERS.tmpl
        packaging/  Dockerfile.tmpl, Dockerfile.minimal.tmpl,
                    docker-compose.yml.tmpl, docker-compose.minimal.yml.tmpl,
                    .dockerignore, systemd.service.tmpl
        docs/       README.md.tmpl, CONTRIBUTING.md.tmpl (Definition of Done),
                    SECURITY.md.tmpl, CHANGELOG.md.tmpl,
                    docs/{metrics,configuration,validation-checklist}.md.tmpl
        github/     ISSUE_TEMPLATE/{bug_report,feature_request,question}.yml,
                    pull_request_template.md
```

> Distinction importante : **deux niveaux de gouvernance**.
> - Le `CLAUDE.md`/`ROADMAP.md`/`TODO.md` **à la racine** régissent le développement **du
>   plugin lui-même**.
> - Les templates `docs/` sous `assets/` produisent la gouvernance **de l'exporter généré**.

---

## 5. Variables de templating

| Variable | Rôle | Exemple |
|---|---|---|
| `{{EXPORTER_NAME}}` | nom binaire / dépôt | `redis_exporter` |
| `{{NAMESPACE}}` | préfixe métrique Prometheus | `redis` |
| `{{MODULE_PATH}}` | chemin de module Go | `github.com/user/redis_exporter` |
| `{{EXTERNAL_CMD}}` | commande/binaire interrogé (1er collector) | `redis-cli` |
| `{{DEFAULT_PORT}}` | port d'écoute par défaut | `9121` |
| `{{OWNER}}` / `{{AUTHOR}}` | attribution, CODEOWNERS, OCI labels | `SckyzO` |

`/new-prometheus-exporter <name>` collecte/déduit ces variables puis matérialise
l'arborescence.

---

## 6. Contenu détaillé des références (le savoir enseigné)

### 6.1 `prometheus-principles.md` [G]
Source **context7 d'abord** (`prometheus.io` *Writing Exporters* + *Metric and label naming*).
Naming (`namespace_subsystem_unit`, `_total`/`_seconds`/`_bytes`, pas d'unité en label) ;
types (Gauge/Counter/Histogram + **note explicite** sur le pattern « const-Gauge pour tout »
observé et ses limites vs sémantique Counter stricte) ; labels basse cardinalité ; cardinalité
maîtrisée par flags ; OpenMetrics ; self-instrumentation `_exporter_*`.

### 6.2 `collector-pattern.md` [G]
Les **5 pièces** (`{{Name}}Data` I/O → `Parse{{Name}}` pure → `{{Name}}GetMetrics` glue →
`{{Name}}Collector` struct de descs → `New{{Name}}Collector`) + `Describe`/`Collect` (sur
erreur : log + `return`, **0 métrique** → StatusTracker marque l'échec). **`var Execute`
mockable** = clé de testabilité. **Triade de tests** par collector : parser (fixture),
`_Collect` (registry+Gather), `_Describe` (compte exact de descs), `_ErrorHandling`
(Execute→err ⇒ `err==nil` + 0 métrique). Fixtures = stdout brut **anonymisé** dans
`test_data/`. Variantes : collector **caché** (`timedCache` RWMutex+TTL partagé) et
**background-refresh** (goroutine+ticker+ctx, rejoue un cache, garde l'ancien en cas d'erreur,
timestamp de fraîcheur).

### 6.3 `project-scaffold.md` [G]
Layout `cmd/` + `internal/collector/` + `internal/logger/`. `main.go` : **registry
map-driven**, **flags auto** `--[no-]collector.<name>` (négation kingpin, `disabledByDefault`
pour opt-in), **StatusTracker** wrapping (anti-descs-dupliqués + `recover()` par collector),
`RegisterExecMetrics`/`RegisterCacheMetrics`, registry custom, BuildInfo/Go/Process gated,
**exporter-toolkit** (`--web.listen-address`/`--web.config.file` TLS+BasicAuth), endpoints
`/metrics` (OpenMetrics) `/healthz` `/`, **shutdown signal-aware** (`signal.NotifyContext`,
`Start(ctx)`/`Done()`, drain 5s).

### 6.4 `makefile-and-tooling.md` [G]
**Toolchain container-first** (§2). Image `*-tools` à versions pinnées, `IN_TOOLS =
$(CONTAINER_ENGINE) run --rm -v $(CURDIR):/repo -w /repo $(TOOLS_IMG)`.
- **Détection moteur** : `CONTAINER_ENGINE ?=` auto (docker → podman → aucun).
- **Fallback natif** : moteur absent ⇒ `IN_TOOLS` vide (exécution hôte) + bandeau
  d'avertissement « versions non pinnées » ; escape hatch `NATIVE=1 make <target>`.
Targets : `build`, `test`, `race`, `vet`, `lint`, `vuln`, `actionlint`, `zizmor`, `secrets`,
`osv`, `deadcode`, **`check`** (gate = miroir CI), **`report`** (goreportcard offline, échec
< B), **`report-deps`**, `docker-build*`, `docker-run*`, `clean`. `.golangci.yml` v2 (default
none + enable explicite). Le fallback natif est documenté dans `development.md`/README de
l'exporter généré.

**Corrections vs le Makefile source de `slurm_exporter`** (le template est la version
*corrigée*, cf. §11.2) :
1. **`build` containerisé** aussi (l'original le laisse sur le Go hôte, ce qui rend faux le
   claim « docker only ») → la promesse container-first devient vraie.
2. **Suppression du target `setup`** (install de Go hôte via `wget|tar`) : contredit
   container-first, passif de maintenance/sécu, doublon avec l'image tools.
3. **Une seule source de version Go** = le Dockerfile de l'image tools (pas de `GO_VERSION`
   hôte périmé en parallèle).
4. **Overlap `lint`/`report` documenté** (gofmt/vet/ineffassign/misspell couverts par
   golangci-lint *et* goreport — buts distincts : gate vs note/grade).

### 6.5 `cicd-and-release.md` [G]
Workflows (actions **pinnées SHA**, least-privilege) : `ci`, `release` (GoReleaser+cosign+syft),
`dev-release`, `govulncheck`, `trivy-scan`, `scorecard`. **GoReleaser** : multi-OS/arch CGO off,
checksums, **SBOM CycloneDX**, **cosign keyless**, `dockers_v2` multi-arch dual-variant, tags
flottants gated `Prerelease==""`. `dependabot.yml`, `CODEOWNERS`.

### 6.6 `packaging-and-ops.md` [G]
`Dockerfile` (base applicative + user non-root dédié) vs `Dockerfile.minimal` (**distroless
nonroot**). `docker-compose` durci (`no-new-privileges`, `cap_drop: ALL`, `read_only`,
`tmpfs`). `systemd` (user dédié, `Restart=on-failure`, exemples commentés). `.dockerignore`.

### 6.7 `security-and-hardening.md` [G]
Volet sécurité OSS **de-personnalisé** (extrait des principes du mainteneur, reformulé en
règles universelles d'exporter) :
- **Jamais de secret dans une métrique ou un label** : pas de mots de passe, tokens, clés API,
  passphrases, chemins de certificats exposés via `/metrics` (endpoint public non
  authentifié). Filtrage/omission côté parsing.
- **Conservatisme sur les défauts** : ne pas durcir un défaut existant sauf vuln critique
  exploitable sans action utilisateur ; tout changement de comportement par défaut = breaking
  change documenté.
- **Warnings au démarrage** en configuration exposée (ex : pas de TLS/auth sur une adresse
  non-loopback) — visibles, non fatals.
- **Config de durcissement optionnelle** (TLS/BasicAuth via `--web.config.file`), documentée,
  non imposée.
- Chaîne d'appro : renvoie vers §6.5 (cosign/SBOM/Trivy/govulncheck) et §6.6 (non-root,
  distroless, compose durci).

### 6.8 `docs-and-governance.md` [G]
Docs **en lockstep avec `/metrics`** (`metrics.md`, `configuration.md`,
`validation-checklist.md` copiable). README structuré (+ section Security & supply chain avec
recettes cosign/SBOM/distroless). **`CONTRIBUTING.md` = Definition of Done** (build → test
coverage non décroissante → lint 0 → cluster test → workload → validation par métrique → logs →
screenshots → CI locale ; + règles nouveaux collectors + anonymisation + Common Pitfalls).
`SECURITY.md`, `CHANGELOG.md` (impact opérateur par entrée).

---

## 7. Gouvernance DU PLUGIN (racine du dépôt)

Fichiers à écrire pour le dépôt du plugin lui-même :
- **CLAUDE.md** — règles de contribution au plugin, **de-personnalisées** (§7bis) : convention
  de commits, **anglais pour tout artefact public**, pas de code mort (`make deadcode`-style),
  règle des deux phases pour refactoring à risque, discipline [G]/[S], comment tester
  (`claude plugin validate`, `--plugin-dir`, `/reload-plugins`), la **règle de re-sync**
  formulée **génériquement** (« re-dériver les templates depuis une implémentation de référence
  de production quand les pratiques évoluent » — **sans nommer aucune source**), et le rappel de
  la contrainte « zéro mention de source » (§2) avec sa vérif grep.
  *(La correspondance concrète source→template reste dans ce design doc uniquement — §6.4,
  §11.2.)*
- **ROADMAP.md** — jalons : v0.1 (MVP : skill + `/new-prometheus-exporter` produisant un dépôt
  qui `make build` + `make check` verts avec 1 collector d'exemple) → v0.2 (variantes
  cache/background + reviewer) → v1.0 (marketplace + doc complète).
- **TODO.md** — backlog opérationnel dérivé du plan d'implémentation.
- **README.md**, **CHANGELOG.md**, **LICENSE**.

---

## 7bis. Frontière principes universels vs personnels (auto-portance)

Décision : les principes d'ingénierie OSS sont **extraits de-personnalisés** et encodés dans
le plugin ; les préférences propres au mainteneur restent dehors. Le plugin ne dépend d'aucun
`CLAUDE.md`/profil personnel.

**ENCODÉ (principe universel) → emplacement :**

| Principe | Emplacement |
|---|---|
| Non-régression testée (test qui échoue avant fix) | Definition of Done (`CONTRIBUTING.md.tmpl`) + SKILL |
| Respect des couches (métier ≠ I/O) | `collector-pattern.md` (`Data` I/O vs `Parse` pure) |
| Erreurs au bon niveau (pas d'avalage silencieux) | `collector-pattern.md` (`Collect` log+return, 0 métrique) |
| Extensibilité sans toucher le cœur (registres > listes) | `project-scaffold.md` (registry map-driven) |
| Pas de code mort | CLAUDE.md racine + `CONTRIBUTING.md.tmpl` |
| Conservatisme sur les défauts (breaking documenté) | `security-and-hardening.md` + `prometheus-principles.md` |
| Sécu : jamais de secret en métrique, warnings, config opt. | `security-and-hardening.md` |
| Réflexes perf (structure indexée, files bornées) | `collector-pattern.md` (perf checklist) |
| CI/CD : triggers explicites, guard matrice vide, `&&` | `cicd-and-release.md` |
| Règle des deux phases (refactoring à risque) | CLAUDE.md racine |
| **Anglais** pour artefacts publics (commits/PR/issues/docs) | `CONTRIBUTING.md.tmpl` + SKILL |
| Ton avec contributeurs (« not closing the PR ») | `CONTRIBUTING.md.tmpl` |

**EXCLU (personnel, hors sujet exporter) :** RTK ; français pour les échanges de travail (on
garde uniquement « anglais pour le public ») ; livrables `.md` téléchargeables/jamais inline ;
système de mémoire perso ; chemins/identité du mainteneur.

*(Frontière **confirmée** par le mainteneur.)*

---

## 8. Composants exécutables

### 8.1 Slash command `commands/new-prometheus-exporter.md`
Prompt qui : (1) collecte/déduit les 6 variables (§5), (2) crée l'arborescence dépôt depuis
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/`, (3) substitue les variables,
(4) `git init` + premier commit conventionnel, (5) lance/indique `make build` pour prouver la
compilation, (6) pointe vers la boucle « ajouter un collector » du skill.
Invocation : `/prometheus-exporter:new-prometheus-exporter <name>` (namespace plugin ; forme
courte si non ambiguë — détail de nommage mineur).

### 8.2 Subagent `agents/exporter-reviewer.md`
Rôle : audit **spécifique exporter** — Definition of Done respectée, conventions Prometheus
(naming/types/labels), séparation [G]/[S], cardinalité maîtrisée (flags présents), **triade de
tests présente pour chaque collector**, self-instrumentation câblée, docs en lockstep avec
`/metrics`.
**Design retenu (analysé — recommandé).** `exporter-reviewer` est **auto-suffisant** et
**n'appelle pas** les autres reviewers (deux raisons : un subagent de plugin n'imbrique pas de
façon fiable subagents/commandes ; et `/code-review`/`pr-review-toolkit` sont des outils
externes au plugin → dépendre d'eux violerait l'auto-portance). Il couvre **uniquement** le
delta exporter (Definition of Done, naming/types/labels Prometheus, [G]/[S], cardinalité,
triade de tests par collector, self-instrumentation, pas de secret en métrique, docs en
lockstep). Son prompt affirme explicitement qu'il **ne duplique pas** la revue générique.
C'est **l'étape d'audit du SKILL** (§9.6) qui dispatche en parallèle : `exporter-reviewer`
(toujours dispo) + — **si présents** — `/code-review` et `pr-review-toolkit` (enhancement
optionnel, jamais une dépendance).
Frontmatter : `name`, `description`, `tools` restreints (lecture + Bash pour `make check`),
`model`.

---

## 9. Workflow encodé dans SKILL.md

Déclencheurs : « créer / scaffolder / durcir / auditer un exporter Prometheus ».
1. **context7 d'abord** — conventions Prometheus à jour avant tout code.
2. **Scaffold** — `/new-prometheus-exporter <name>` (6 variables).
3. **Boucle par métrique** — Data → Parse → **triade de tests** → Collect. Jamais de métrique
   partielle sur erreur.
4. **Durcissement** — Makefile containerisé, `make check` **vert** (preuve avant affirmation).
5. **Release/CI + docs** — workflows + GoReleaser + Definition of Done ; docs en lockstep.
6. **Audit** (§9.6) — dispatch parallèle : `exporter-reviewer` (toujours) + `/code-review` +
   `pr-review-toolkit` **si présents** (optionnels, jamais requis).

---

## 10. Critères de succès

- `/new-prometheus-exporter foo` produit un dépôt qui **build** (`make build`) et passe
  **`make check`** avec ≥ 1 collector d'exemple + triade de tests verte.
- Le skill référence explicitement la doc Prometheus officielle (context7) et sépare [G]/[S].
- Les 8 fichiers de référence couvrent l'intégralité de l'anatomie de maturité inventoriée.
- `exporter-reviewer` produit un rapport actionnable (gaps Definition of Done / conventions).
- `claude plugin validate .` passe ; le plugin est chargeable via `--plugin-dir`.
- **Auto-portance** : le plugin ne dépend d'aucun `CLAUDE.md`/profil personnel ; les principes
  OSS universels sont encodés (§7bis), les préférences personnelles exclues.
- **Zéro mention de source** : `grep -ri -e slurm -e <maintainer-handle>` sur l'arbre du plugin
  hors `docs/design/` retourne 0 (contrainte §2).
- Rien n'est committé dans le repo `slurm_exporter`.

---

## 11. Risques / points ouverts

1. **Reviewer** (§8.2) : **résolu** — `exporter-reviewer` auto-suffisant, ne rappelle pas les
   autres ; dispatch parallèle par le SKILL, reviewers génériques optionnels. (Recommandation
   analysée et retenue.)
2. **Fidélité + correction des templates** : les assets sont dérivés des fichiers **réels** de
   `slurm_exporter` (copie + généralisation [G]), pas réécrits de mémoire — sinon dérive.
   **Principe : le plugin distille ET corrige la source ; il ne la recopie pas aveuglément.**
   Là où la source a des incohérences connues (ex : Makefile container-first à moitié, versions
   périmées — cf. §6.4), le template applique la version corrigée. Le CLAUDE.md du plugin
   encode la procédure de re-sync **et** la liste des écarts volontaires vs la source.
3. **Nommage d'invocation** de la commande (`/prometheus-exporter:new-prometheus-exporter` vs
   forme courte) — détail mineur, tranché à l'implémentation.
4. **Maintenance** : le plugin fige un instantané des bonnes pratiques ; note de re-sync
   obligatoire dans README + CLAUDE.md du plugin.
5. **Frontière principes universels/personnels** (§7bis) : **confirmée**.
