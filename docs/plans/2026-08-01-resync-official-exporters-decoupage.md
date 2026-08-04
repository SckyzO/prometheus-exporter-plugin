# Découpage proposé : élargir la base de référence aux exporters officiels

Réponse à `NEXT-PROMPT-resync-official-exporters.md`. Rien n'est écrit dans
les artefacts livrés tant que ce découpage n'est pas tranché.

## 0. Vérifications faites avant d'écrire ce document

### L'état du dépôt, conforme à la passation

`5d8b5ca`, tag `v0.8.0`, `plugin.json` à `0.8.0`, PRs #17 / #18 / #19
ouvertes et `MERGEABLE`, arbre propre hors `docs/plans/`. Rien à corriger.

### Les licences : trois sur quatre seulement

Vérifiées à la source via l'API GitHub, fichier `LICENSE` de chaque dépôt.

| Exporter | Dépôt | Licence | Dernier tag |
|---|---|---|---|
| `node_exporter` | `prometheus/node_exporter` | Apache-2.0 | `v1.12.1` |
| `blackbox_exporter` | `prometheus/blackbox_exporter` | Apache-2.0 | `v0.28.0` |
| `snmp_exporter` | `prometheus/snmp_exporter` | Apache-2.0 | `v0.30.1` |
| `ipmi_exporter` | `prometheus-community/ipmi_exporter` | **MIT** | `v1.10.1` |

`ipmi_exporter` n'est pas en Apache-2.0. En-tête réel du fichier :

```
The MIT License
Copyright (c) 2019-2021 SoundCloud Ltd. and the IPMI exporter developers
Copyright (c) 2021 The Prometheus Authors
```

Conséquence pratique : nulle. MIT et Apache-2.0 sont tous deux permissifs,
et les quatre sont **moins** contraignants que la référence actuelle en
GPL-3.0. Le calcul de dérivation se détend, il ne se durcit pas. Ce qui reste
vrai quelle que soit la licence, c'est la discipline [G]/[S] : on adopte une
**forme**, jamais un bloc de texte. Une forme ne déclenche aucune obligation
d'attribution, ni sous MIT ni sous Apache-2.0. Si un verdict devait un jour
recopier un bloc substantiel, c'est là que la clause de notice s'appliquerait,
et il faudrait le consigner explicitement. À ce stade, aucun verdict de ce
type n'est prévu.

### Les citations existantes : le piège est réel, et plus large qu'annoncé

Le prompt annonçait `node_exporter` dans 3 fichiers, `snmp_exporter` et
`blackbox_exporter` dans 1 chacun. Compté sur l'arbre, hors `.git/`,
`docs/` et `.superpowers/` :

| Terme | Fichiers livrés | Où |
|---|---|---|
| `node_exporter` | 5 | `CLAUDE.md`, `assets/mains/single/main.go.tmpl`, `references/prometheus-principles.md`, `references/project-scaffold.md`, le gate lui-même |
| `blackbox_exporter` | 4 | `CLAUDE.md`, `ROADMAP.md`, `CHANGELOG.md`, le gate |
| `snmp_exporter` | 4 | idem |
| `ipmi_exporter` | 2 | `CLAUDE.md`, le gate |
| `postgres_exporter` | 8 | + `references/{exporter-architecture,collector-pattern}.md`, `commands/{new-prometheus-exporter,design-exporter}.md` |
| `sql_exporter` | 8 | idem |
| `mysqld_exporter` | 6 | idem, sans `CLAUDE.md` ni le gate |

La conclusion du prompt est bonne et se renforce : ces noms n'entrent
**jamais** dans `SOURCE_TERMS`. `node_exporter` est même cité dans un
template Go livré (`mains/single/main.go.tmpl:243`), donc dans le code de
chaque exporter généré. Le denylister casserait le build sur une citation
juste, et le casserait chez les tiers.

`SOURCE_TERMS` reste `slurm ts4500 sacct sinfo`. Aucun des quatre exporters
visés n'est privé ni spécifique : cet épic n'ajoute aucun terme.

### `re-sync.md` a dérivé de l'arbre qu'il décrit

C'est le point qui change le découpage. Le document est la source de vérité
de la correspondance source vers template, et plusieurs de ses lignes ne
décrivent plus le dépôt :

| § | Ce que dit `re-sync.md` | L'arbre aujourd'hui |
|---|---|---|
| 2.1 | `assets/cmd/@@EXPORTER_NAME@@/main.go.tmpl` | `assets/mains/{single,multi,multi-instance}/main.go.tmpl` ; `assets/cmd/@@EXPORTER_NAME@@/` ne contient plus que `security.go.tmpl` et son test |
| 2.4 | `golang:1.26.4-alpine` | `golang:1.26.5-alpine@sha256:0178a641...` |
| 3, correction #3 | « matchant `toolchain go1.26.4` » | `go.mod.tmpl` dit `toolchain go1.26.5` |
| 2.9 | « `references/*.md` (10 files) » | 12 fichiers |
| 2.9 | quatre composants exécutables (`new-prometheus-exporter`, `add-collector`, l'agent, `SKILL.md`) | 4 commandes (`+ design-exporter`, `+ generate-dashboard`), 1 agent, 1 `SKILL.md` |
| 7 | « exclut `docs/` », « SLURM-GREP » | seuls `docs/design/` et `docs/plans/` sont exemptés depuis #15 ; le gate s'appelle SOURCE-GREP |

Aucun de ces écarts n'est un bug fonctionnel. Tous sont des faits faux dans
le document qui doit servir de substrat à la matrice multi-références. Les
empiler sous une nouvelle structure les fige.

C'est exactement la leçon consignée dans la passation : *corriger un dérivé
sans remonter à la source garantit le retour du défaut*. Ici la source, c'est
`re-sync.md` §2.

### Un écart de fond, déjà pré-vérifié

`Update(ch chan<- prometheus.Metric) error` et `ErrNoData`, la forme de
collecteur de `node_exporter`, **n'apparaissent nulle part** sous `skills/`,
`commands/` ni `agents/`. `re-sync.md` §4.6 les nomme déjà comme « the
gold-standard fix [...] noted as future work, not done here ». Le chantier
est donc ouvert, documenté, et c'est le candidat numéro un du rapport.

À l'inverse, `/-/reload`, `/-/healthy` et `web.NewLandingPage` sont déjà
câblés (`internal/reload/`, les deux mains multi-cibles, `SECURITY.md.tmpl`).
Ce domaine produira surtout des verdicts « déjà couvert », ce qui est un
résultat utile et évite d'ouvrir un chantier fantôme.

### Le clone local de `snmp_exporter` ne convient pas tel quel

`~/Dev/work/apps_repo/exporters/snmp_exporter` existe, mais il est à
`v0.30.1-55-g8dd45e1` avec des fichiers non suivis dans `generator/`. Lire
une référence sale, 55 commits après son dernier tag, contredit §6.1 (« a
real, buildable reference ») et rend le rapport irreproductible.

Les quatre références seront clonées à froid, `--depth 1 --branch <tag>`,
dans le scratch de session, jamais dans `~/Dev/work/apps_repo/exporters/`.
Lecture seule, aucun commit, `git status` vérifié propre en fin de parcours
(§6.8). Le clone existant est laissé strictement tel quel.

## 1. La question de structure, et pourquoi je contredis l'instinct

L'instinct du prompt : garder §2 pour la référence d'origine, et ajouter
**une section par exporter officiel** ne consignant que les écarts.

Je propose l'axe inverse : **une section par domaine**, avec une colonne de
provenance nommant le ou les exporters qui exhibent l'écart.

La raison est concrète. Prends la forme de collecteur `Update(ch) error` :
elle est présente dans `node_exporter`, et sa logique de « pas de données
n'est pas une erreur » se retrouve sous une autre forme dans `snmp_exporter`
et `ipmi_exporter`. Découpé par exporter, ce seul écart s'écrit trois fois,
avec trois verdicts qui doivent rester d'accord entre eux pour toujours.
C'est la structure exacte qui a produit le bug README/CHANGELOG de la session
précédente : deux copies du même fait, une seule corrigée.

Découpé par domaine, l'écart s'écrit une fois, porte un verdict, et la
colonne de provenance dit lequel des quatre le démontre. La déduplication est
structurelle au lieu d'être une discipline de relecture.

Concrètement, `re-sync.md` deviendrait :

- **§1** passe au pluriel : un tableau des références, avec pour chacune le
  rôle (origine ou corroboration), la licence, le tag lu, et le chemin de
  lecture. La référence d'origine garde son statut particulier, celui dont
  les fichiers ont été *copiés*, là où les quatre officiels sont *comparés*.
- **§2 est intouchée.** Elle documente une dérivation par copie qui a
  réellement eu lieu, fichier par fichier. Aucun des quatre officiels ne
  produira de ligne `[D]` : on ne recopie rien.
- **§8, nouvelle** : le registre des écarts par domaine. Chaque entrée porte
  ce que fait l'officiel, ce que fait le plugin, la provenance, et un verdict
  parmi *adopté* / *rejeté* / *déjà couvert*, avec sa raison.
- **§4** accueille les verdicts « le plugin fait mieux » comme déviations
  délibérées numérotées, dans la continuité des vingt existantes. C'est déjà
  le rôle de la section, elle n'a pas besoin d'être modifiée pour ça.

Si tu préfères malgré tout l'axe par exporter, dis-le : le coût est une
règle de relecture supplémentaire, pas un blocage.

## 2. Le découpage

Trois PRs jusqu'au point de décision. L'implémentation ne commence qu'après
ton arbitrage sur le rapport.

### Préalable, hors épic

Merger #17, #18, #19 et poser `v0.8.1` avant de brancher. C'est la décision 1
de la passation, et ça évite de faire porter à cet épic une base non publiée.
Si tu préfères enchaîner tout de suite, la branche part de `5d8b5ca` sans
conséquence technique : les fichiers ne se recoupent pas. Dis-moi lequel.

### PR 1 : réconcilier `re-sync.md` avec l'arbre

`docs(re-sync): reconcile the mapping table with the current tree`

Les six écarts du tableau §0 ci-dessus, corrigés. Rien d'autre : pas de
multi-référence, pas de rapport d'écarts. Purement mécanique, chaque ligne
vérifiable contre un fichier réel.

Indépendante des deux suivantes, et mergeable seule. Elle a une valeur même
si tu arrêtes l'épic ici.

Garde-fous : `sh test/zero-source-grep.sh`, `claude plugin validate .`.
`golden-smoke` non requis (aucun fichier sous `assets/` ni `test/` touché,
vérifié à `git diff --name-only` avant de conclure).

### PR 2 : passer le modèle de référence au pluriel

`docs(re-sync): make the reference model plural`

§1 devient un tableau de références. Ajout du registre de provenance :
licences vérifiées (dont le MIT d'`ipmi_exporter`), tags lus, discipline de
clone à froid, et la note explicite que les noms des exporters publics
n'entrent jamais dans `SOURCE_TERMS`, avec le décompte de citations à
l'appui. §8 est créée vide, avec sa forme et la définition des trois verdicts.

Toujours aucun écart consigné : c'est le contenant, pas le contenu. Ça rend
la structure critiquable avant qu'on ait investi le travail de lecture.

Mêmes garde-fous que PR 1.

### PR 3 : le rapport d'écarts

`docs(design): gap report against four official exporters`

Le livrable sur lequel tu tranches. Produit en quatre tranches de lecture,
menées en parallèle, fusionnées en un seul rapport :

| Tranche | Domaine | Références lues |
|---|---|---|
| A | Forme du collecteur, gestion des erreurs de scrape, sémantique du « zéro série » | `node_exporter` (`collector/collector.go`, deux ou trois collecteurs représentatifs), `ipmi_exporter` |
| B | Conventions de nommage et de labels, auto-instrumentation | les quatre, plus `prometheus/client_golang` |
| C | Contrat `/probe`, modules, structure du fichier de configuration | `blackbox_exporter`, `snmp_exporter` |
| D | Posture des endpoints mutants, page d'accueil, wrapper CLI | `blackbox_exporter`, `ipmi_exporter` |

Chaque tranche lit des fichiers ciblés, pas le dépôt entier : `node_exporter`
seul pèse plus que tout ce plugin. Le rapport nomme les fichiers et les lignes
lus des deux côtés, pour qu'un tiers puisse refaire la vérification.

Puis, avant de te le présenter, une relecture par un sous-agent dédié qui ne
l'a pas écrit, avec pour seule consigne de vérifier chaque affirmation contre
le code des deux côtés. C'est la consigne explicite du prompt, et la session
précédente lui donne raison : la majorité des vrais défauts venaient de la
spec, pas de l'exécution.

Le rapport reste un document. Il ne modifie ni `assets/`, ni `references/`,
ni les commandes.

### PR 4 et suivantes : une par écart adopté

Inconnues tant que tu n'as pas tranché. Chacune porte un seul écart, avec son
test de non-régression, et applique la règle des deux phases si elle touche
au moteur de templating, à la couture des collecteurs ou au contrat du
registre. `Update(ch) error` en fait partie par construction : c'est un
changement de contrat de collecteur, donc phase 1 avec l'ancienne forme
maintenue par défaut.

`sh test/golden-smoke.sh --all` devient obligatoire dès cette étape.

## 3. Ce que ce découpage ne fait pas

- Il ne re-vérifie pas les pins de version de §5. C'est l'étape §6.5 de la
  procédure de re-dérivation, et elle est orthogonale : elle concerne la
  référence d'origine, pas les quatre officiels. Elle mérite sa propre PR,
  hors de cet épic. Si tu veux la voir dedans, elle s'insère entre PR 1 et
  PR 2 sans rien perturber.
- Il ne touche pas aux résidus connus de la passation (le gate qui lit les
  fichiers ignorés par git, `rules.yml` que rien n'écrit, la sous-vérification
  dashboard-backbone). Aucun n'est sur le chemin.
- Il ne re-dérive aucun template. La sortie de l'épic tel que découpé ici est
  un rapport plus les changements que tu auras validés, pas une réécriture.
