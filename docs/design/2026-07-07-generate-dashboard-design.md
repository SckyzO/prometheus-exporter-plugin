# Spec de design — commande `/generate-dashboard` (v0.2)

- **Date** : 2026-07-07
- **Statut** : design validé (brainstorm), prêt pour le plan d'implémentation
- **Épic** : v0.2, après `discovery-inputs` et `background-refresh` (déjà mergées local)
- **Source de vérité amont** : `docs/design/2026-07-02-prometheus-exporter-plugin-design.md`
  §8.4 (qui réserve le fichier `commands/generate-dashboard.md`) et
  `skills/prometheus-exporter/references/dashboards-and-alerts.md` §« The business
  dashboard is v0.2 ». Cette spec **développe** §8.4, elle ne la contredit pas.

---

## 1. Objectif & périmètre

`/generate-dashboard [name]` génère **1..N dashboards Grafana métier** pour un
exporter **déjà scaffoldé**, via un **dialogue de design** RED/USE **entièrement
ancré dans `docs/metrics.md`**, puis matérialise des JSON Grafana concrets sous
`monitoring/grafana/`.

- Complète le **dashboard de santé** livré en v0.1 (`monitoring/grafana/health-dashboard.json`) ;
  **ne le modifie jamais**.
- **Design-led** : la commande ne recopie pas le JSON santé — elle mène un mini-brainstorm
  (audience, méthode, décomposition, métriques clés, variables, drill-down) *avant* de générer.
- **Ancrée `metrics.md`** : `metrics.md` n'est pas seulement la liste des noms de
  métriques, c'est le **substrat qui pilote tout le dialogue** (voir §5). La commande ne
  demande jamais à l'utilisateur ce qu'elle peut lire dans `metrics.md`.

### Non-goals (YAGNI — explicitement hors périmètre v0.2)

- Pas de **provisioning Grafana** ni de datasource auto (dépend de la topologie Grafana
  de l'utilisateur — même posture que le dashboard santé).
- Pas de **service Grafana** ajouté à `docker-compose.yml`.
- Pas de flag `--quick` (génération zéro-question) — reporté, fast-follow possible.
- Pas d'**alerting** généré ici (c'est le rôle de `monitoring/prometheus/alerts.yml`).
- Pas de **matrice multi-versions** maintenue dans le plugin : **une** version Grafana
  cible par invocation.
- Ne **re-scaffolde jamais** le repo (`scaffold.sh` n'est jamais invoqué).

---

## 2. Invariants & contraintes (héritées du plugin)

- **grep=0** : `commands/generate-dashboard.md` et tout asset sous `skills/` ne
  contiennent **aucune** occurrence de `slurm`/`sacct` ni du handle mainteneur
  (`test/zero-source-grep.sh`, bloquant). Les JSON générés dans un repo scaffoldé
  doivent aussi être propres (vérifié par `golden-smoke.sh` sur l'arbre généré).
- **Auto-portance** : la commande **ne dépend d'aucun `CLAUDE.md`/profil perso**.
  `context7` et `dataviz` sont des **améliorations si présentes, jamais requises**
  (même échelle de dégradation que `/design-exporter`).
- **Documenté ⊆ dashboard** : la commande ne référence **que** des métriques présentes
  dans `docs/metrics.md`. Renforce la discipline anti-mensonge de `make docs-check`.
- **Repo déjà scaffoldé** : la commande lit de **vraies valeurs** (aucun `@@VAR@@`
  résiduel) et écrit de vrais fichiers — comme `/add-collector`, pas comme `scaffold.sh`.
- **Format exportable** (voir §6) : dashboards « Export for sharing externally »,
  datasource paramétrée, importables partout sans uid en dur.

---

## 3. Entrées

| Entrée | Source dans le repo scaffoldé | Rôle |
|---|---|---|
| Métriques (nom, type, labels, description) | `docs/metrics.md` (tables par collecteur) | Substrat du dialogue + PromQL |
| `namespace` | `const namespace = "<literal>"` dans `cmd/*/main.go` | Préfixe des noms de métriques, uid |
| Saveur I/O | présence de `internal/collector/client.go` (http) ou `execute.go` (cli) | Confirmer que c'est un exporter scaffoldé |
| Version Grafana cible | **dialogue** (§5) | `schemaVersion`, modèle de panels, réf datasource |
| Brief d'architecture (optionnel) | `exporter-design-brief.md` s'il existe | Seed le dialogue (audience, SLI, cardinalité) |

**Parsing `metrics.md`** : réutiliser le contrat des regex de
`internal/collector/docs_check_test.go` (`parseMetricsDoc` : nom entre backticks,
type ∈ Gauge/Counter/Histogram/Summary, labels backtickés séparés par virgule ou `-`).
La section `## Self-instrumentation` est **exclue** (déjà couverte par le dashboard santé).

---

## 4. Flux de la commande (calqué sur `/add-collector`)

0. **Confirmer le repo & la saveur.** Vérifier que c'est un exporter scaffoldé
   (présence de `cmd/*/main.go`, `internal/collector/`, `docs/metrics.md`). Sinon,
   refuser et rediriger vers `/new-prometheus-exporter`. Ne jamais demander ce qui est
   lisible dans le repo.
1. **Lire les vraies valeurs & parser `metrics.md`.** Extraire `namespace`, la liste des
   collecteurs et, par collecteur, les métriques (nom/type/labels/description). Exclure
   le self-instrumentation. Charger `exporter-design-brief.md` s'il est présent.
2. **Dialogue de design** (§5) — produit un **descripteur de décomposition** (quels
   dashboards, quels panels, quelles variables, quels liens).
3. **Générer.** Backbone déterministe (§6) → baseline valide ; puis enrichissement
   interactif (context7 + dialogue + `dataviz` si présent) par-dessus.
4. **Mettre à jour le wiring.** Ajouter les dashboards générés à la liste de
   `monitoring/README.md` (import Grafana). Ne pas toucher au compose ni au santé.
5. **Vérifier & montrer.** Lancer les validations déterministes (§10) et **afficher la
   vraie sortie** : JSON bien-formés + chaque `expr` ⊆ `metrics.md`.
6. **What's next.** Message de commit suggéré, rappel d'import dans Grafana, note que la
   régénération est sûre (§7).

---

## 5. Le dialogue de design — ancré `metrics.md`

Le « dialogue complet » (choix retenu) : chaque étape est **pré-remplie par ce que
`metrics.md` implique**, l'utilisateur **confirme/ajuste**. Ordre :

1. **Version Grafana cible** *(tôt)* — 11 / 12 / 13 / … Conditionne `schemaVersion`, le
   modèle de panels, la forme de la réf datasource, **et** le lookup context7. Défaut
   proposé = dernière majeure stable (résolue via context7 au runtime) ; fallback = le
   baseline du santé.
2. **Audience** — ops on-call / capacity / owner. Peut motiver plusieurs dashboards.
   Si un brief existe, sa section audience seed cette étape.
3. **Méthode par préoccupation** — **RED** (services à requêtes : rate/erreurs/durée)
   vs **USE** (ressources : utilisation/saturation/erreurs). **Inférée des `Type`** de
   `metrics.md` (counters + histogram de durée ⇒ RED ; gauges d'utilisation ⇒ USE),
   confirmée.
4. **Décomposition 1..N** *(étape clé — la raison du dialogue)* — **dérivée du groupement
   par collecteur** de `metrics.md` : peu de collecteurs ⇒ **1 dashboard** (une *row* par
   collecteur) ; beaucoup / familles distinctes / audiences distinctes ⇒ **overview +
   drill-downs par domaine**, liés. La commande **propose** le découpage lu depuis
   `metrics.md` ; l'utilisateur restructure.
5. **Sélection des SLI** — candidats **surgis des lignes** de `metrics.md` ; toutes les
   métriques ne méritent pas un panel.
6. **Variables de template** — la **colonne labels** de `metrics.md` alimente les
   candidats. `metrics.md` **ne porte pas la cardinalité** ⇒ la commande **demande**
   quels labels sont des dimensions de partitionnement (faible cardinalité) ; défaut
   **conservateur**, aucune variable auto sur un label à haute cardinalité présumée.
   `datasource` + `job` (multi-select, `includeAll`) systématiques, comme le santé.
7. **Unités & seuils** — **absents de `metrics.md`** ⇒ inférés des **suffixes de nom**
   Prometheus (`_seconds`/`_bytes`/`_total`/`_ratio`/`_info`) et des bonnes pratiques
   context7 ; confirmés.
8. **Drill-down / liens** — si N dashboards, comment ils se lient (dashboard links + data
   links), en s'appuyant sur des **uid déterministes** (§6).

Si `exporter-design-brief.md` est présent, ses sections (audience, business-alert
candidates, budget cardinalité) **seed** les étapes 2/5/6 au lieu de tout re-demander
(même pattern que `/new-prometheus-exporter` consommant le brief).

---

## 6. Génération — backbone déterministe + enrichissement context7

**Principe central : un plancher déterministe et testé, un plafond LLM interactif et sûr.**

### 6.1 Backbone déterministe (le plancher, testable)

Un **générateur déterministe partagé**, livré dans le plugin, **invoqué par la commande
et par le golden test** (source unique, pas de dérive).

- **Entrée** : chemin du repo (lit `docs/metrics.md` + `namespace`), version Grafana
  cible, descripteur de décomposition (issu du dialogue ; défaut trivial = 1 dashboard,
  1 panel par métrique documentée).
- **Sortie** : 1..N dashboards Grafana **exportables valides**, **un panel par métrique
  métier documentée**, PromQL **type-correcte** (§6.3).
- **Déterministe** : aucune question, aucun appel context7, aucun LLM. Donc **rejouable en
  CI**.
- **Tech (à finaliser au plan)** : script `bash` + `jq`, **container-first** (native →
  docker → podman → erreur explicite), cohérent avec `scaffold.sh` et le golden. Chemin
  pressenti : `skills/prometheus-exporter/scripts/…` (référencé via `${CLAUDE_PLUGIN_ROOT}`).

### 6.2 Enrichissement interactif (le plafond, non testé mais sûr)

Par-dessus le baseline, en interactif seulement :

- **context7** — une fois la version connue : `resolve-library-id grafana` →
  `query-docs` pour (a) le **schéma JSON de la version** (`schemaVersion` exact, modèle
  de panels) et (b) les **bonnes pratiques dataviz** (choix de panel par type, unités,
  seuils, `by (job, instance)`).
- **dialogue** — sélection/pruning des SLI, structuration RED/USE, décomposition,
  variables, unités, liens.
- **`dataviz`** — si le skill est présent, polissage de la mise en forme.

Le plafond **ne peut pas casser l'invariant anti-mensonge** : il part d'un plancher où
chaque `expr` ⊆ `metrics.md`, et n'ajoute jamais de métrique hors `metrics.md`.

### 6.3 Règles de génération (plancher & plafond)

- **Format exportable** : wrapper `__inputs`/`__requires`, datasource paramétrée
  `${DS_PROMETHEUS}` (jamais un uid en dur), plus les variables `datasource` + `job`
  comme le santé. Importable partout.
- **uid déterministes** : `<namespace>-<slug>` (ex. le santé utilise
  `@@NAMESPACE@@-exporter-health`). **Indispensable** car en format exportable Grafana
  régénère les uid à l'import — sans uid stables, les **liens drill-down casseraient**.
  Stables aussi à la régénération (§7).
- **Provenance** : `tags: ["generated"]` + une note de provenance (ex. dans la
  `description` du dashboard) pour distinguer les dashboards générés des dashboards
  hand-made.
- **PromQL par `Type`** : `rate()` sur counters, `histogram_quantile()` sur histograms
  (le `_bucket` est **synthétisé** à partir du parent + `Type=Histogram`, car `metrics.md`
  ne liste pas les `_bucket`), `avg`/`max` (pas `sum`) sur gauges de saturation ; fenêtres
  en **`$__rate_interval`** (pas `[5m]` en dur). Agrégations `by (job, instance)`
  multi-instance-safe, comme le santé.
- **`schemaVersion`** : selon la version cible (résolu via context7 ; baseline connu = 38,
  celui du santé ≈ Grafana 10). Un `schemaVersion` plus ancien s'importe quand même
  (Grafana auto-migre) — le santé qui reste à son baseline n'est donc pas un problème.

---

## 7. Régénération vs édits manuels

Re-lancer la commande (ex. après `/add-collector`) ne doit **jamais** détruire
silencieusement des personnalisations.

- **Idempotent par uid** : un dashboard régénéré réutilise son uid `<namespace>-<slug>`.
- **Détection** : repérer les fichiers déjà générés (tag `generated` / note de provenance).
- **Diff + confirmation avant écrasement** : montrer ce qui change, demander confirmation
  avant d'écraser un fichier généré. Un fichier **hand-made** (sans le tag) n'est jamais
  écrasé sans accord explicite.
- **Jamais `scaffold.sh`** (adaptation fichier-par-fichier, pas de re-scaffold).

---

## 8. Sortie & wiring

- **Fichiers** : `monitoring/grafana/<slug>.json` (JSON concrets, sans `@@VAR@@`), à côté
  de `health-dashboard.json`.
- **Pas de provisioning auto, pas de service Grafana en compose** — miroir de la posture
  du santé (« dépend de ta topologie Grafana » = hors scope).
- **`monitoring/README.md`** : ajouter les dashboards générés à la liste d'import (UI /
  API / provisioning fichier), sans prétendre qu'ils sont provisionnés automatiquement.

---

## 9. Auto-portance / dégradation gracieuse

| Dépendance | Présente | Absente |
|---|---|---|
| `context7` | dashboards ancrés dans la vraie doc de la version | **baseline connu + warning** « non vérifié contre Grafana X » |
| `dataviz` | polissage de mise en forme | génération sans, aucun blocage |
| `exporter-design-brief.md` | seed le dialogue | dialogue complet à froid |

Aucune de ces dépendances n'est dure. La commande produit toujours au moins le **plancher
déterministe valide**.

---

## 10. Tests / non-régression

**Il n'existe aucun validateur de JSON Grafana dans le harness** (`promtool` valide les
règles PromQL, pas les dashboards) → on crée l'outillage.

- **Sous-check golden** (miroir du sous-check mécanique `/add-collector` dans
  `test/golden-smoke.sh`) : sur un repo scaffoldé, **invoquer le backbone déterministe**
  (§6.1) puis asserter :
  1. **JSON bien-formé** (`jq empty`) sur chaque dashboard généré.
  2. **Anti-mensonge** : chaque panel `expr` ne référence **que** des métriques présentes
     dans `docs/metrics.md` (l'analogue dashboard de la barre PromQL de `docs-check`).
  3. **Propreté** : aucun `slurm`/handle, aucun `@@VAR@@` résiduel dans les JSON générés.
- **Cellule** : au minimum `http`/`none` (comme le sous-check add-collector) ; idéalement
  couvrir aussi `cli`.
- **Cas limite testé** : repo **sans métrique métier documentée** (que du
  self-instrumentation) ⇒ le backbone **refuse proprement** (sortie non-zéro + message),
  pas un dashboard vide.

Contrainte de testabilité : context7 (MCP interactif) est **absent en headless** ⇒ le
golden ne teste **que** le plancher déterministe, jamais l'enrichissement context7. C'est
voulu : le plafond LLM est contourné par le golden exactement comme le dialogue lui-même.

---

## 11. Cas limites (le flux doit les gérer)

- Repo **non scaffoldé** ⇒ refus + redirection `/new-prometheus-exporter`.
- **Zéro métrique métier documentée** ⇒ refus poli « ajoute des collecteurs / documente
  d'abord avec `make docs-check` ».
- **Histogram** ⇒ `_bucket` synthétisé pour `histogram_quantile()`.
- Métrique **émise par le code mais absente de `metrics.md`** ⇒ **warning** (« documente-la
  d'abord »), jamais devinée (la commande ne lit pas le `.go` pour inventer des métriques).
- **`Type` non vérifié par `docs-check`** (informatif) ⇒ le plancher fait confiance à
  `metrics.md` ; le plafond LLM peut recouper le constructeur `.go` en interactif si un
  `Type` semble faux, mais ce n'est pas requis.

---

## 12. Artefacts livrés (pour le plan)

- **`commands/generate-dashboard.md`** *(nouveau, EN, grep=0)* — la commande, style
  `/add-collector` (frontmatter `description`/`argument-hint`/`disable-model-invocation:true`,
  étapes numérotées, refus idempotent, « what's next »).
- **Backbone déterministe** *(nouveau, sous `skills/prometheus-exporter/scripts/…`,
  grep=0)* — générateur `bash`+`jq` container-first (§6.1).
- **Hook golden** — sous-check dans `test/golden-smoke.sh` (§10).
- **`skills/prometheus-exporter/references/dashboards-and-alerts.md`** — faire basculer
  la section « v0.2 — not shipped » vers « livré », décrire le flux réel.
- **`skills/prometheus-exporter/SKILL.md`** — mettre à jour la mention « future
  `/generate-dashboard` ».
- **`ROADMAP.md`** — déplacer l'item de v0.2-à-faire vers livré/unreleased.
- **`CHANGELOG.md`** — entrée sous `## [Unreleased]`.
- **`monitoring/README.md.tmpl`** — la mention `/generate-dashboard` existe déjà en
  forward-reference ; l'aligner sur le comportement réel si besoin.

---

## 13. Découpage pressenti en tâches (indicatif — le plan tranche)

1. Backbone déterministe : parsing `metrics.md` → modèle interne (nom/type/labels).
2. Backbone : émission d'un dashboard exportable baseline (1 panel/métrique, PromQL
   type-correcte, uid déterministe, wrapper exportable) — **avec tests unitaires**.
3. Backbone : décomposition N dashboards + liens drill-down (uid stables).
4. Hook golden (jq empty + anti-mensonge + propreté + cas « zéro métrique »).
5. `commands/generate-dashboard.md` : flux, dialogue ancré `metrics.md`, invocation du
   backbone, enrichissement context7/dataviz, régénération diff+confirm.
6. Consommation du brief `exporter-design-brief.md` (si présent).
7. Docs : bascule `dashboards-and-alerts.md` + SKILL + ROADMAP + CHANGELOG.

---

## 14. Questions ouvertes / hypothèses

- **Tech exacte du backbone** (`bash`+`jq` vs petit helper Go) : tranchée au plan ;
  recommandation `bash`+`jq` container-first pour cohérence avec `scaffold.sh`/golden.
- **Chemin exact** du backbone sous `skills/prometheus-exporter/` : tranché au plan.
- **Couverture golden** `cli` en plus de `http`/`none` : souhaitée, à confirmer selon le
  coût CI.
- **`schemaVersion` exacts par majeure** : résolus via context7 à l'écriture des templates
  de panel, pas figés ici.
