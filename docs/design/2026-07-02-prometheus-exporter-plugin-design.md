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

À partir d'un **design d'architecture** (source, saveur d'I/O, collectors — §6.0) et de
quelques variables (`name`, `namespace`, `module`, `data source`, `port`, `licence`, `owner`
— §5), on obtient un dépôt d'exporter **buildable, testé, documenté, releasable**, sans
réinventer le pattern collector, la toolchain, la CI/CD, ni la discipline docs.

Observabilité livrée avec l'exporter (§6.9) : **alerting Prometheus** (règles de santé) +
**dashboard Grafana de santé** en v0.1 ; **dashboard métier** via commande guidée
`/generate-dashboard` en v0.2. Frontière affichée : *alerting = Prometheus (cœur) ; dashboards
= Grafana (extension délimitée)*.

Non-objectifs (YAGNI v1) :
- Pas de support multi-langage (Go uniquement ; couche principes séparable pour extension
  future — §2).
- Pas de dashboard **métier** en v0.1 (seulement le dashboard de **santé** générique ; le
  métier passe par `/generate-dashboard` en v0.2).
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
conservent que le [G] ; le [S] (source de données, préfixe métrique, parsing) devient des
variables ou des trous à remplir.

**Principe « architecture d'abord, API-first ».** Le choix de la source de données est une
**décision d'architecture**, pas un défaut technique. Le plugin comporte une **phase de design
d'architecture** (référence `exporter-architecture.md` + étape 0 du workflow, §9) qui tourne
**avant** le scaffold. Ordre de préférence des sources enseigné : **REST/API > gRPC > DB > CLI
(dernier recours)**. `slurm_exporter` wrappe une CLI pour raison *historique* (API Slurm alors
pauvres) — ce n'est **pas** le défaut recommandé. Le principe réutilisable est **« la frontière
d'I/O est une dépendance mockable »** (var/interface pour la testabilité), décliné en **3
saveurs** : **HTTP/REST (défaut recommandé)**, **DB**, **CLI**. La saveur est choisie à
l'archi puis matérialisée par **sélection de répertoire** de templates (§5bis), pas par des
conditionnels dans les fichiers. La phase archi couvre aussi **single-target vs multi-target**
(Prometheus recommande le *multi-target exporter pattern* `?target=` pour les exporters
réseau/API), la découpe en collectors et le budget de cardinalité.

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

**Principe release host-agnostic (important).** La **discipline de versioning est
universelle** et ne dépend d'aucune forge : **SemVer**, **tags git `v*`**, **CHANGELOG**
(Keep-a-Changelog), **Conventional Commits**, injection `version.*` en ldflags, et
**GoReleaser** (`goreleaser build` / `release --snapshot` tournent **en local, sans GitHub**).
La **couche livraison GitHub est optionnelle (opt-out)** : `.github/workflows/*` (Actions),
publication GHCR, scorecard/dependabot, templates issues/PR. Le scaffold demande la **forge**
(`github` | `none` | autre — variable `@@FORGE@@`) : si `none`, `.github/` est **omis** et le
chemin « release local via GoReleaser + tag git » est documenté (analogue au fallback natif du
Makefile). Un exporter sans GitHub reste **versionné, changelogué et releasable**.

---

## 3. Nature & emballage (décidé)

**Plugin Claude Code** `prometheus-exporter`, versionné et partageable, contenant **4
composants en v0.1** (+ un 5e en v0.2) :

1. **Skill** `prometheus-exporter` — le savoir + le workflow (SKILL.md routeur + `references/`
   + `assets/`), incluant la **phase 0 de design d'architecture**.
2. **Slash command** `/new-prometheus-exporter <name>` — scaffolde un dépôt d'exporter complet
   (saveur d'I/O choisie à l'archi, licence choisie) depuis les templates.
3. **Slash command** `/add-collector <name>` — ajoute un collector + sa triade de tests à un
   exporter existant (l'action la plus répétée). Réutilise les mêmes templates `code/<saveur>/`.
4. **Subagent** `exporter-reviewer` — audite un exporter sur les critères **spécifiques
   exporter** (Definition of Done, conventions Prometheus, séparation [G]/[S], cardinalité,
   triade de tests présente, **docs-check**, alertes de santé). Auto-suffisant, **dispatché en
   parallèle** de `/code-review` et `pr-review-toolkit` par le workflow (§8.3).
5. *(v0.2)* **Slash command** `/generate-dashboard` — design-led, génère un dashboard Grafana
   **métier** (§8.4). Le scaffold v0.1 livre déjà l'alerting Prometheus + un dashboard de
   **santé** générique (§6.9).

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
prometheus-exporter-plugin/               # racine du dépôt (git) — EST sa propre marketplace
  .claude-plugin/
    plugin.json                           # manifeste : name, version, description, author, license, keywords
    marketplace.json                      # self-marketplace : liste ce plugin (source = ce repo) → install par des tiers
  CLAUDE.md                               # règles de contribution AU PLUGIN (voir §7)
  README.md                               # présentation, install, dev loop (SANS mention de source — §2)
  ROADMAP.md                              # jalons (v0.1 MVP → v1.0)
  TODO.md                                 # backlog opérationnel
  CHANGELOG.md                            # Keep-a-Changelog
  LICENSE
  docs/
    design/2026-07-02-prometheus-exporter-plugin-design.md   # ce spec
  commands/
    new-prometheus-exporter.md            # slash command de scaffolding (repo complet)
    add-collector.md                      # slash command : ajoute un collector + sa triade de tests
    generate-dashboard.md                 # (v0.2) mini-brainstorm design → dashboard Grafana métier
  agents/
    exporter-reviewer.md                  # subagent d'audit exporter-spécifique
  skills/
    prometheus-exporter/
      SKILL.md                            # routeur : quand/comment, checklist, context7-first
      references/
        exporter-architecture.md          # ÉTAPE 0 : choix source (API-first), single/multi-target, découpe, cardinalité
        prometheus-principles.md          # conventions officielles (source context7)
        collector-pattern.md              # frontière I/O mockable (3 saveurs) + 5 pièces + triade de tests
        project-scaffold.md               # layout, main.go registry, flags auto, endpoints, shutdown
        makefile-and-tooling.md           # toolchain containerisée, targets, golangci, scripts
        cicd-and-release.md               # workflows, GoReleaser, cosign/SBOM, dependabot, CODEOWNERS
        packaging-and-ops.md              # Dockerfile dual, compose durci, systemd
        security-and-hardening.md         # sécu OSS de-personnalisée : jamais de secret en métrique, warnings, config opt.
        dashboards-and-alerts.md          # alerting Prometheus (santé) + frontière Grafana + méthode design dashboard (RED/USE)
        docs-and-governance.md            # jeu de docs, Definition of Done + docs-check métriques, SECURITY/CHANGELOG/CONTRIBUTING
      assets/                             # templates matérialisés par les commandes (délimiteur @@VAR@@, §5bis)
        scaffold.sh                       # substitution @@VAR@@ + renommage de chemins + sélection de saveur (sh+sed, sans moteur)
        code/
          common/     status_tracker.go.tmpl, execute.go.tmpl (helper commun), main.go.tmpl, go.mod.tmpl
          http/       collector.go.tmpl, collector_test.go.tmpl, client.go.tmpl (frontière HTTP mockable) — SAVEUR DÉFAUT
          cli/        collector.go.tmpl, collector_test.go.tmpl, parser_test.go.tmpl, execute.go.tmpl (var Execute)
          db/         collector.go.tmpl, collector_test.go.tmpl, client.go.tmpl (frontière DB mockable)
          variants/   cache.go.tmpl, background_collector.go.tmpl (options avancées, toutes saveurs)
        build/      Makefile.tmpl, .golangci.yml,
                    scripts/docker/tools/{Dockerfile.tmpl, goreport.sh, deps-report.sh}
        release/    .goreleaser.yaml.tmpl, .goreleaser.dev.yaml.tmpl   # TOUJOURS (host-agnostic)
                    github/{workflows/{ci,release,dev-release,govulncheck,trivy-scan,scorecard}.yml(.tmpl),
                            dependabot.yml.tmpl, CODEOWNERS.tmpl}      # CONDITIONNEL @@FORGE@@==github
        packaging/  Dockerfile.tmpl, Dockerfile.minimal.tmpl,
                    docker-compose.yml.tmpl, docker-compose.minimal.yml.tmpl,
                    .dockerignore, systemd.service.tmpl
        docs/       README.md.tmpl, CONTRIBUTING.md.tmpl (Definition of Done),
                    SECURITY.md.tmpl, CHANGELOG.md.tmpl,
                    docs/{configuration,development,release-process,validation-checklist}.md.tmpl
                    # metrics.md + metrics-examples.md = GÉNÉRÉS/validés depuis le code (docs-check), pas templatés
        monitoring/ prometheus/{alerts.yml.tmpl (santé + métier), rules.yml.tmpl (recording rules)},
                    grafana/{health-dashboard.json.tmpl (self-instrumentation)}, README.md.tmpl
        licenses/   LICENSE-apache-2.0.txt, LICENSE-mit.txt, LICENSE-gpl-3.0.txt, LICENSE-bsd-3.txt
        github/     ISSUE_TEMPLATE/{bug_report,feature_request,question}.yml,
                    pull_request_template.md                           # CONDITIONNEL @@FORGE@@==github
```

> Distinction importante : **deux niveaux de gouvernance**.
> - Le `CLAUDE.md`/`ROADMAP.md`/`TODO.md` **à la racine** régissent le développement **du
>   plugin lui-même**.
> - Les templates `docs/` sous `assets/` produisent la gouvernance **de l'exporter généré**.

---

## 5. Variables de templating

Délimiteur **`@@VAR@@`** (§5bis — choisi pour ne pas collisionner avec les accolades
légitimes des templates : GoReleaser `{{ }}`, Actions `${{ }}`, Docker `${ }`).

| Variable | Rôle | Exemple |
|---|---|---|
| `@@EXPORTER_NAME@@` | nom binaire / dépôt | `redis_exporter` |
| `@@NAMESPACE@@` | préfixe métrique Prometheus | `redis` |
| `@@MODULE_PATH@@` | chemin de module Go | `github.com/user/redis_exporter` |
| `@@IO_FLAVOR@@` | saveur de frontière I/O (choisie à l'archi) | `http` \| `db` \| `cli` |
| `@@DATA_SOURCE@@` | endpoint/commande interrogé (1er collector) | `http://localhost:9121` |
| `@@DEFAULT_PORT@@` | port d'écoute par défaut (voir alloc. officielle) | `9121` |
| `@@LICENSE@@` | licence (choisie au scaffold, défaut Apache-2.0) | `Apache-2.0` |
| `@@FORGE@@` | forge d'hébergement (conditionne `.github/`) | `github` \| `none` |
| `@@OWNER@@` | attribution, CODEOWNERS, OCI labels | `<owner>` |

`/new-prometheus-exporter <name>` collecte/déduit ces variables (dont **saveur** issue de la
phase archi et **licence** via prompt §8.1) puis matérialise l'arborescence.

---

## 5bis. Mécanisme de templating (tranché via context7)

**Contexte / contrainte.** Les templates contiennent **massivement des accolades légitimes** :
GoReleaser (`{{ .Version }}`), GitHub Actions (`${{ github.sha }}`), Docker/compose (`${VAR}`).
Un moteur à accolades collisionne donc avec ce contenu.

**Preuves context7 :**
- *cookiecutter* (Jinja `{{}}`) impose `{% raw %}…{% endraw %}` ou `_copy_without_render` pour
  chaque accolade littérale → ingérable ici.
- *hay-kot/scaffold* (Go `text/template`) impose des **délimiteurs custom par glob** (ex `[[ ]]`
  pour `.goreleaser`) pour la même raison.

**Décision.** Délimiteur **sentinelle global `@@VAR@@`**, sans moteur de template :
- Substitution par un **script `scaffold.sh` bundlé** (`sh` + `sed`), référencé via
  `${CLAUDE_PLUGIN_ROOT}` → **zéro dépendance runtime** (pas de Python/cookiecutter/Go-template
  → cohérent auto-portance).
- Le script **renomme aussi les composants de chemin** templatés (`cmd/@@EXPORTER_NAME@@/`).
- **Saveur d'I/O = sélection de répertoire** (`code/http|db|cli/`), **pas** de conditionnels
  dans les fichiers → déterministe, testable.
- Avantage : un `.tmpl` avec `@@OWNER@@` reste un fichier **lisible et valide** tel quel.
- `@@...@@` n'apparaît dans aucun langage cible → collision impossible ; vérifiable par grep.

---

## 6. Contenu détaillé des références (le savoir enseigné)

### 6.0 `exporter-architecture.md` [G] — ÉTAPE 0, avant tout code
Guide de **design d'architecture** de l'exporter (§9 étape 0) :
- **Choix de la source** dans l'ordre **REST/API > gRPC > DB > CLI (dernier recours)** ;
  **context7 sur l'API cible** pour connaître endpoints/format. Justifier CLI si retenu (cas
  legacy façon Slurm).
- **Single-target vs multi-target** : rappeler le *multi-target exporter pattern* de Prometheus
  (`/probe?target=`) pour les exporters réseau/API interrogeant N instances, vs le modèle
  single-target (l'exporter tourne à côté de sa cible). Fork d'archi structurant → dicte la
  saveur et le `main.go`.
- **Frontière d'I/O mockable** : la saveur (`http`/`db`/`cli`) découle de la source ; principe =
  dépendance injectable pour la testabilité.
- **Découpe en collectors** + **budget de cardinalité** (quelles séries, combien, quels flags
  de réduction) — avant d'écrire une ligne.
- **Alertes métier candidates** : pour chaque collector, quelles conditions fonctionnelles
  alerter (« ce que fait l'appli ») — matérialisées ensuite par `/add-collector` (§6.9).
Sortie de l'étape : saveur d'I/O, liste de collectors, modèle single/multi-target, alertes
candidates → inputs du scaffold.

### 6.1 `prometheus-principles.md` [G]
Source **context7 d'abord** (`prometheus.io` *Writing Exporters* + *Metric and label naming*).
Naming (`namespace_subsystem_unit`, `_total`/`_seconds`/`_bytes`, pas d'unité en label) ;
types (Gauge/Counter/Histogram + **note explicite** sur le pattern « const-Gauge pour tout »
observé et ses limites vs sémantique Counter stricte) ; labels basse cardinalité ; cardinalité
maîtrisée par flags ; OpenMetrics ; self-instrumentation `_exporter_*`.

### 6.2 `collector-pattern.md` [G]
**Frontière d'I/O mockable — 3 saveurs** (le principe, pas l'implémentation) :
- **HTTP/REST (défaut)** : un `client` injectable (interface) → mock en test via un
  `httptest.Server` ou un double d'interface.
- **DB** : un `client`/`querier` injectable → mock via interface ou sqlmock.
- **CLI (legacy)** : `var Execute` mockable (le pattern de la source) → swap de la var en test.
Les **5 pièces** (`@@Name@@Data`/fetch I/O → `Parse@@Name@@` pure → `@@Name@@GetMetrics` glue →
`@@Name@@Collector` struct de descs → `New@@Name@@Collector`) + `Describe`/`Collect` (sur
erreur : log + `return`, **0 métrique** → StatusTracker marque l'échec). La pièce 1 varie selon
la saveur ; les pièces 2-5 sont identiques. **Triade de tests** par collector : parser (fixture),
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

### 6.5 `cicd-and-release.md` [G] — host-agnostic (§2)
**Versioning universel (toujours, sans forge) :** SemVer, tags git `v*`, **CHANGELOG**
(Keep-a-Changelog, impact opérateur par entrée), **Conventional Commits**, ldflags `version.*`.
**GoReleaser** (config `.goreleaser.yaml`) : multi-OS/arch CGO off, checksums, **SBOM
CycloneDX**, **cosign keyless**, `dockers_v2` multi-arch dual-variant, tags flottants gated
`Prerelease==""`. `goreleaser build` / `release --snapshot` tournent **en local** → un dépôt
**sans GitHub** reste versionné et releasable (release manuelle sur tag).
**Couche GitHub (opt-out, `@@FORGE@@ == github`) :** workflows (actions **pinnées SHA**,
least-privilege) `ci`, `release`, `dev-release`, `govulncheck`, `trivy-scan`, `scorecard` ;
`dependabot.yml` ; `CODEOWNERS` ; templates issues/PR. **Omis si `@@FORGE@@ == none`**, avec
doc du chemin release local.

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
**Répartition template vs généré** (analyse de la source) : **templatés** (structure [G] forte)
= `development.md` (make targets identiques), `release-process.md` (flow tag→GoReleaser→RC→CI),
`validation-checklist.md` (structure Command/Expected/If-fails + étapes génériques),
`configuration.md` (sections communes exporter-toolkit) ; **générés+validés depuis le code** =
`metrics.md` et `metrics-examples.md` (via `docs-check` / capture `/metrics` du golden test) ;
**stub** = `roadmap.md`, `CHANGELOG.md`.
Docs **en lockstep avec `/metrics`** (`metrics.md`, `configuration.md`,
`validation-checklist.md` copiable). README structuré (+ section Security & supply chain avec
recettes cosign/SBOM/distroless). **`CONTRIBUTING.md` = Definition of Done** (build → test
coverage non décroissante → lint 0 → **`make docs-check`** → cluster/cible de test → workload →
validation par métrique → logs → screenshots → CI locale ; + règles nouveaux collectors +
anonymisation + Common Pitfalls). `SECURITY.md`, `CHANGELOG.md` (impact opérateur par entrée).

**Validation des docs métriques (contrôle, pas intention).** `docs/metrics.md` doit documenter
**toute** métrique + labels, et un check **`make docs-check`** (test Go) **gather** les
descripteurs enregistrés (`prometheus.NewRegistry()` + `Gather()`, Execute/clients mockés) et :
- **échoue** si une métrique ou un label **cité dans `docs/metrics.md` n'existe pas** dans le
  code (la doc ne peut pas mentir) ;
- **warn** (option : échoue) sur toute métrique **du code non documentée**.
Intégré à la Definition of Done, au golden test du plugin (§11) et vérifié par
`exporter-reviewer` (§8.3).

### 6.9 `dashboards-and-alerts.md` [G]
**Frontière affichée : alerting = Prometheus (cœur) ; dashboards = Grafana (extension).**

**Alerting Prometheus (v0.1) — santé + métier.** Deux niveaux :
1. **Santé** (générique) : basé sur la self-instrumentation de tout exporter — `up == 0`,
   `@@NAMESPACE@@_exporter_collector_success == 0`, durée de scrape anormale.
2. **Métier** (« ce que fait l'appli ») : alertes **fonctionnelles** sur les métriques des
   collectors (ex. saturation d'une ressource, profondeur de file, taux d'erreur). **Proposées
   par la phase archi et `/add-collector`** au fil de la création des collectors.

**Pattern d'alerting encodé** (tiré d'une implémentation de référence de production) :
- **deux paliers** `severity: warning|critical` à seuils croissants, avec `for:` pour lisser ;
- labels **portables/site-neutres** (`severity`, `component`) — team/runbook/dashboard via
  `external_labels` ou routage Alertmanager, **pas** en dur dans le fichier ;
- **recording rules** (`rules.yml`) pour pré-calculer ratios/taux, avec **garde anti-NaN**
  (`… / (rate(...) > 0)`) ;
- seuils = **défauts raisonnables documentés**, « à ajuster à la taille ».
- PromQL **validée contre des métriques existantes** (même exigence anti-mensonge que
  `docs-check`) — vérifiée par le golden test et `exporter-reviewer`.

**Dashboards Grafana :**
- **Santé (v0.1)** : `monitoring/grafana/health-dashboard.json` — templatable car la
  self-instrumentation est identique d'un exporter à l'autre (seul le namespace/job varie).
- **Métier (v0.2)** : via `/generate-dashboard` (§8.4) — **design-led**, pas copie :
  mini-brainstorm (audience, méthode **RED/USE**, métriques clés, variables/templating,
  drill-down) → JSON Grafana. S'appuie sur le skill `dataviz` si présent.

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
- **ROADMAP.md** — jalons : **v0.1** (MVP : skill + phase archi + `/new-prometheus-exporter` +
  `/add-collector` + `exporter-reviewer`, **saveurs HTTP+CLI**, `monitoring/` = alertes de santé
  Prometheus + dashboard de santé Grafana, `make docs-check`, dépôt `make build`+`make check`
  verts, CI plugin + golden test) → **v0.2** (saveur **DB**, `/generate-dashboard` métier
  design-led, variantes cache/background, multi-target avancé) → **v1.0** (marketplace + doc
  complète).
- **TODO.md** — backlog opérationnel dérivé du plan d'implémentation.
- **README.md** — présentation + positionnement (premier plugin de *création* d'exporters) +
  dev loop **et** une section **« Distribution & install »** concrète :
  - `/plugin marketplace add <owner/repo>` puis `/plugin install prometheus-exporter@<mkt>` ;
  update / désinstall ; **épinglage de version** via tag git `v*` ;
  - **partage équipe** : déclarer la marketplace + activer le plugin dans un `settings.json`
  partagé (auto-install) ;
  - **note de confiance** : installer un plugin exécute du code (provenance / tags).
- **CHANGELOG.md**, **LICENSE**.

**Dogfooding (cohérence).** Le dépôt du plugin applique lui-même sa propre prédication :
**tags git `v*` + CHANGELOG + CI** (validate + golden test) — release host-agnostic (§2). Les
utilisateurs épinglent une version via le tag.

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
Prompt qui : (0) **exige la phase archi** (§6.0) faite → récupère saveur d'I/O + liste de
collectors + modèle single/multi-target ; (1) collecte/déduit les variables (§5), **dont la
forge** `@@FORGE@@` (`github`|`none`) qui conditionne `.github/` (§6.5) ; **(1b)
propose la licence** — choix commenté « simple », **défaut Apache-2.0** (norme
Prometheus/node_exporter) : Apache-2.0 (permissive + clause brevets, défaut écosystème), MIT
(permissive minimale), GPL-3.0 (copyleft fort), BSD-3 (permissive) ; (2) invoque
`${CLAUDE_PLUGIN_ROOT}/skills/prometheus-exporter/assets/scaffold.sh` qui copie l'arbre,
**sélectionne `code/<saveur>/`**, substitue les `@@VAR@@`, renomme les chemins, pose la bonne
`LICENSE` depuis `licenses/` ; (3) `git init` + premier commit conventionnel ; (4)
lance/indique `make build` + `make check` pour **prouver** compilation et gate ; (5) pointe
vers `/add-collector` pour la suite. **Refuse d'écraser** un dossier cible non vide.
Invocation : `/prometheus-exporter:new-prometheus-exporter <name>` (namespace plugin ; forme
courte si non ambiguë — détail mineur).

### 8.2 Slash command `commands/add-collector.md`
Ajoute **un** collector à un exporter existant (l'action la plus répétée). Prompt qui :
(1) détecte la saveur d'I/O du repo courant (ou la demande), (2) demande nom du collector +
source/endpoint + métriques visées, (3) matérialise `code/<saveur>/collector.go.tmpl` +
`collector_test.go.tmpl` (**triade de tests**) via `scaffold.sh`, (4) enregistre le collector
dans le registry map-driven de `main.go` (+ flag `--[no-]collector.<name>`), (5) **propose des
alertes métier** (§6.9) pour les nouvelles métriques dans `monitoring/prometheus/alerts.yml`
(pattern paliers/for/labels portables), (6) rappelle la mise à jour de `docs/metrics.md`
(lockstep) et lance `make test` + `make docs-check`. Idempotent : refuse si le collector
existe déjà.

### 8.3 Subagent `agents/exporter-reviewer.md`
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
C'est **l'étape d'audit du SKILL** (§9 étape 6) qui dispatche en parallèle : `exporter-reviewer`
(toujours dispo) + — **si présents** — `/code-review` et `pr-review-toolkit` (enhancement
optionnel, jamais une dépendance).
Frontmatter : `name`, `description`, `tools` restreints (lecture + Bash pour `make check`),
`model`. **Vérifie aussi** `make docs-check` (docs métriques non menteuses) et la présence des
règles d'alerte de santé.

### 8.4 Slash command `commands/generate-dashboard.md` (v0.2)
Sort **volontairement** du périmètre Prometheus (→ Grafana). Prompt qui lance un
**mini-brainstorm de design** (audience, méthode **RED/USE**, métriques clés de l'exporter lues
depuis le code/`metrics.md`, variables/templating, drill-down) puis génère un **JSON Grafana**
métier. PromQL basée uniquement sur des métriques **existantes**. S'appuie sur `dataviz` si
présent. Le dashboard de **santé** générique, lui, est livré dès le scaffold (v0.1, §6.9).

---

## 9. Workflow encodé dans SKILL.md

Déclencheurs : « créer / scaffolder / durcir / auditer un exporter Prometheus ».
0. **Design d'architecture** (§6.0) — **avant tout code** : choix de la source (**API-first**),
   single vs multi-target, découpe en collectors, budget de cardinalité. context7 sur l'API
   cible. Sortie : saveur d'I/O + liste de collectors.
1. **context7 d'abord** — conventions Prometheus à jour (naming/types/labels).
2. **Scaffold** — `/new-prometheus-exporter <name>` (saveur + licence choisies).
3. **Boucle par collector** — `/add-collector <name>` : fetch/Data → Parse → **triade de
   tests** → Collect. Jamais de métrique partielle sur erreur.
4. **Durcissement** — Makefile container-first, `make check` **vert** + `make docs-check`
   (docs métriques non menteuses) (preuve avant affirmation).
5. **Release/CI + docs + observabilité** — workflows + GoReleaser + Definition of Done ; docs
   en lockstep ; `monitoring/` (alertes de santé Prometheus + dashboard de santé Grafana).
   Dashboard métier = `/generate-dashboard` (v0.2).
6. **Audit** — dispatch parallèle : `exporter-reviewer` (toujours) + `/code-review` +
   `pr-review-toolkit` **si présents** (optionnels, jamais requis).

---

## 10. Critères de succès

- `/new-prometheus-exporter foo` produit, **pour la saveur HTTP (défaut)**, un dépôt qui
  **build** (`make build`) et passe **`make check`** avec ≥ 1 collector d'exemple + triade de
  tests verte. Idem au moins pour la saveur `cli` en v0.1.
- `/add-collector bar` ajoute un collector + sa triade et `make test` reste vert.
- La phase 0 (design d'archi) est présente et **API-first** ; la licence est **choisie**
  (défaut Apache-2.0).
- Le skill référence explicitement la doc Prometheus officielle (context7) et sépare [G]/[S].
- Les 10 fichiers de référence couvrent l'anatomie de maturité + la phase archi + observabilité.
- **`make docs-check` vert** : aucune métrique/label documenté(e) absent(e) du code.
- Le dépôt généré contient `monitoring/` : alertes Prometheus **santé + métier** (paliers
  warning/critical, `for`, labels portables) + recording rules + dashboard de santé Grafana,
  PromQL basée sur des métriques **existantes** (validée par golden test + reviewer).
- `scaffold.sh` n'a **aucune dépendance runtime** hors `sh`/`sed` ; substitution `@@VAR@@`
  vérifiable (aucun `@@…@@` résiduel dans un repo généré).
- `exporter-reviewer` produit un rapport actionnable (gaps Definition of Done / conventions).
- `claude plugin validate .` passe ; le plugin est chargeable via `--plugin-dir`.
- **Auto-portance** : le plugin ne dépend d'aucun `CLAUDE.md`/profil personnel ; les principes
  OSS universels sont encodés (§7bis), les préférences personnelles exclues.
- **Zéro mention de source** : `grep -ri -e slurm -e <maintainer-handle>` sur l'arbre du plugin
  hors `docs/design/` retourne 0 (contrainte §2).
- **Release host-agnostic** : `@@FORGE@@ == none` produit un dépôt **sans `.github/`** mais
  toujours versionné (tags `v*`, CHANGELOG) et releasable en local (`goreleaser release
  --snapshot`). Le golden test couvre les deux forges.
- Rien n'est committé dans le repo `slurm_exporter`.

---

## 11. Risques / points ouverts

### Décisions résolues (relecture)
- **Axe 1 — frontière I/O** : **progressif, API-first**. Principe « frontière mockable », 3
  saveurs (HTTP défaut / DB / CLI), choisies à la **phase archi** (§6.0), matérialisées par
  répertoire (§5bis). v0.1 : HTTP + CLI ; DB en v0.2.
- **Axe 2 — templating** : **`@@VAR@@` + `scaffold.sh` (sh/sed), sans moteur** (§5bis, via
  context7).
- **Axe 6 — add-collector** : **`/add-collector` dès v0.1** (§8.2).
- **Licence** : variable `@@LICENSE@@`, **choix proposé** au scaffold, défaut **Apache-2.0**
  (norme Prometheus/node_exporter) (§8.1).
- **Reviewer** (§8.3) : auto-suffisant, dispatch parallèle, reviewers génériques optionnels.
- **Observabilité** (§6.9) : alerting Prometheus (santé) + dashboard Grafana de santé en
  **v0.1** ; dashboard métier design-led via `/generate-dashboard` en **v0.2**. Frontière
  Prometheus/Grafana affichée.
- **Docs métriques validées** (§6.8) : `make docs-check` — la doc ne peut mentir (métriques/
  labels documentés ⊆ code). Dans Definition of Done + golden test + reviewer.
- **Release host-agnostic** (§6.5) : versioning universel (SemVer/tags/CHANGELOG/GoReleaser
  local) ; couche GitHub Actions **opt-out** via `@@FORGE@@`. Un exporter sans GitHub reste
  versionné et releasable.
- **Frontière universel/personnel** (§7bis) : confirmée.

### Améliorations intégrées au plan (fold)
- **CI du plugin + golden smoke test** : la CI du dépôt plugin lance `claude plugin validate`,
  le **grep zéro-source**, et un **scaffold jetable → `make build` + `make check` + `make
  docs-check`** (par saveur) pour garantir que les templates produisent un repo valide, avec
  docs non menteuses et `monitoring/` cohérent (anti bit-rot).
- **`docs/design/re-sync.md`** (exclu du grep) : porte la correspondance concrète
  source→template + la procédure ; le CLAUDE.md racine y renvoie **génériquement**.
- **Distribution opérationnelle** : `marketplace.json` self-hébergé (le dépôt EST sa
  marketplace), section README « install » (`/plugin marketplace add` + `/plugin install`),
  versioning du plugin par tags `v*` (dogfooding), partage équipe via `settings.json`.
- **Divers** : refus d'écrasement (§8.1), pointeur alloc. de ports Prometheus officielle,
  `.gitignore` du repo plugin, principe « la référence explique le POURQUOI, le template EST
  l'artefact » (anti-dérive doc/template).

### Risques restants
- **Nommage d'invocation** (`/prometheus-exporter:new-prometheus-exporter` vs forme courte) —
  détail mineur, tranché à l'implémentation.
- **Fidélité + correction des templates** : dérivés des fichiers **réels** de la source (copie +
  généralisation [G]), pas de mémoire ; **le plugin distille ET corrige** (Makefile, versions —
  §6.4). Re-sync + écarts volontaires documentés dans `docs/design/re-sync.md`.
- **Volume v0.1** : 2 saveurs (HTTP+CLI) × triade × golden test = périmètre MVP conséquent ;
  la ROADMAP séquence pour livrer HTTP d'abord, CLI ensuite, DB en v0.2.
