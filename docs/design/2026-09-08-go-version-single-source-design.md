# Une seule source de vérité pour la version Go, et un destinataire pour la dérive

> Design, 2026-09-08. Fait suite au bump d'urgence `1.26.5 → 1.26.8` (PR #54),
> qui déplace la valeur sans toucher à la structure. Ce document traite la
> structure.

## 1. Le problème, en trois faits mesurés

**La version de Go vit à six endroits**, pas un :

| Fichier | Forme |
|---|---|
| `assets/Dockerfile.tmpl` | `FROM golang:<v>-alpine@sha256:<digest>` |
| `assets/Dockerfile.minimal.tmpl` | idem |
| `assets/scripts/docker/tools/Dockerfile.tmpl` | idem |
| `assets/go.mod.tmpl` | `toolchain go<v>` |
| `assets/.github/workflows/release.yml.tmpl` | `go-version: '<v>'` |
| `assets/.github/workflows/dev-release.yml.tmpl` | `go-version: '<v>'` |

Deux d'entre eux portent le commentaire `# keep in sync with go.mod's
toolchain directive`. Un commentaire « keep in sync » est l'aveu d'une
duplication qu'on n'a pas su supprimer.

**Le README généré ment.** `assets/README.md.tmpl` affirme à l'utilisateur :
« The Go version used to build this exporter and its dev-tooling image is
pinned in exactly one place ». C'est faux, et c'est un mensonge *livré* :
il part dans chaque exportateur généré, sous une section « Security &
supply chain » qui lui donne l'autorité d'un engagement. Le `CLAUDE.md`
§[G]/[S] met cette classe de défaut au même niveau qu'un préfixe de métrique
en dur, et pour la même raison : le reste du fichier étant exact, celui-ci
est cru.

**Deux des six sites sont invisibles à Dependabot.** Son updater `gomod` ne
gère pas la directive `toolchain` ; son updater `github-actions` bump les
références `uses:`, pas la *valeur* d'un input `go-version:`. Conséquence dans
un exportateur généré dont l'image d'outils a été rafraîchie automatiquement :
`make check` (govulncheck, qui tourne dans cette image) repasse **au vert**,
pendant que les deux workflows de release continuent de compiler les
**binaires publiés** avec le toolchain vulnérable.

C'est le défaut central. Un rouge visible se traite ; un vert silencieux ne se
traite jamais, parce que personne ne le regarde. Et il touche tous les
exportateurs déjà générés, qu'aucune modification de `scaffold.sh` n'atteint.

## 2. Ce qui existe déjà, et qu'on ne reconstruit pas

Trois mécanismes sont en place et fonctionnent. Les redoubler serait du code
mort au sens du `CLAUDE.md`.

- **Le contrôle de dérive existe.** `.github/workflows/plugin-ci.yml` porte
  `cron: "0 6 * * 1"`, et `.github/dependabot.yml` le désigne nommément comme
  le mécanisme de fraîcheur des gabarits (« handled instead by the weekly
  `schedule:` on plugin-ci.yml »). Il a détecté la dérive tous les lundis
  depuis le 2026-08-17. **Il n'a jamais manqué de détection. Il a manqué de
  destinataire.**
- **Les exportateurs générés se rafraîchissent seuls.** Chacun embarque
  `dependabot.yml` sur `gomod`, `github-actions` et `docker` (racine et
  `/scripts/docker/tools`), en hebdomadaire, avec un cooldown de 7 jours.
- **`govulncheck` et `golangci-lint` sont en `@latest` délibérément**
  (`tools/Dockerfile.tmpl`, rationale en commentaire). La tension « scanner
  flottant contre toolchain épinglée » est voulue : c'est elle qui a produit
  le rouge. Le rouge est le système qui fonctionne.

## 3. Arbitrages rendus

**3.1 — Pas de résolution réseau dans `scaffold.sh`.** Envisagée, puis
écartée. Trois écrits du dépôt s'y opposent :

- l'en-tête de `scaffold.sh` interdit d'y ajouter une dépendance (« Do not add
  a dependency on bash, Python, Go, or any template engine here »), adossé au
  §5bis du design fondateur ; le fichier ne contient aujourd'hui aucun appel
  réseau ;
- le `dependabot.yml.tmpl` livré justifie son cooldown de 7 jours par le fait
  qu'une version fraîchement publiée, **et possiblement compromise**, doit
  avoir le temps d'être retirée. Résoudre `latest` au moment du scaffold prend
  une version publiée il y a peut-être dix minutes ;
- `README.md.tmpl` vend la reproductibilité (« Pinned toolchain »), que deux
  scaffolds de la même commande à deux dates différentes ruineraient.

Le gain aurait été d'au plus sept jours de fraîcheur sur les seules classes
que Dependabot couvre déjà, et rien sur les deux qu'il ne couvre pas.
**Les pins par défaut ne sont pas une préférence : c'est une contrainte
d'architecture.**

**3.2 — Le périmètre est la version de Go, et elle seule.** Restent
délibérément épinglés en dur, chacun pour une raison écrite :

| Épinglé | Pourquoi on n'y touche pas |
|---|---|
| `golangci-lint`, `govulncheck` | `@latest` **exprès** ; leur figer une version inverse une décision documentée et relève de la règle des deux phases |
| GoReleaser `2.16.0` | Gelé pour un motif *sémantique* : `dockers_v2` est encore expérimental amont, et le commentaire exige une revalidation par snapshot avant tout bump. Aucun résolveur « dernière version » ne sait rendre cet arbitrage |
| ~15 SHA d'actions GitHub | Couverts par le Dependabot de l'exportateur généré, et par celui du plugin pour ses propres workflows |
| `debian:13-slim` | Même couverture, et hors du défaut décrit en §1 |

**3.3 — Le plancher de langage ne bouge pas.** `go 1.26.0` dans `go.mod.tmpl`
est ce qu'un exportateur généré promet à qui le compile avec son propre
toolchain (`docs/development.md.tmpl` annonce « Go 1.26+ »). Le relever est un
changement cassant. Seule la directive `toolchain` suit les patchs.

## 4. Conception

### 4.1 Deux variables, valeurs par défaut portées par `scaffold.sh`

`@@GO_VERSION@@` (ex. `1.26.8`) et `@@GO_IMAGE_DIGEST@@` (ex.
`sha256:ce864e72…`), substituées sur les six sites.

Le moteur les encaisse tel quel : `sed_escape_repl` échappe déjà `\`, `&`
**et** `/`, donc un digest passe sans traitement particulier. Aucun changement
du moteur de templating.

`scaffold.sh` n'a aujourd'hui **aucun mécanisme de défaut** : chaque `--var`
doit être fourni par l'appelant. La conception ajoute un petit bloc de
variables *intégrées*, appliquées avant les `--var` de l'utilisateur et
surchargeables par elles.

Conséquence : **aucun site d'invocation ne change.** Un seul est livré
(`commands/new-prometheus-exporter.md`) ; tous les autres sont des harnais
(`test/scaffold_test.sh`, `scaffold_edge_test.sh`, `scaffold_multitarget_test.sh`,
`golden-smoke.sh`, plus `queue-budget-sweep.sh` une fois la PR #51 mergée).
Le reste des fichiers qui nomment `scaffold.sh` le *mentionnent* en commentaire
ou en documentation sans l'invoquer, et n'est donc pas concerné. La règle des
deux phases n'est pas déclenchée : aucun contrat d'appel n'est modifié.

Le mode d'échec est déjà bon et reste gratuit : le garde-fou de sentinelle
résiduelle sort en **exit 3** si un `@@…@@` survit à la substitution. Si le
défaut disparaissait un jour, le scaffold échouerait bruyamment au lieu de
livrer un `FROM golang:@@GO_VERSION@@`.

### 4.2 La phrase du README redevient vraie

`README.md.tmpl` cesse de désigner `scripts/docker/tools/Dockerfile` comme
l'unique source. Deux rédactions possibles — à trancher à l'implémentation :
soit la phrase nomme la vraie source unique (le défaut de `scaffold.sh`, qui
n'existe pas dans le dépôt généré), soit elle est reformulée pour dire ce qui
est vrai *dans le dépôt livré* : la version est cohérente sur six fichiers et
Dependabot en couvre quatre. **Ma préférence : la seconde.** Le lecteur du
README est l'opérateur de l'exportateur, pas celui du plugin ; lui parler
d'une variable de `scaffold.sh` qu'il ne verra jamais est une fuite d'abstraction.

Et la phrase doit dire ce que Dependabot **ne** couvre pas, faute de quoi elle
recrée le vert silencieux sous une autre forme.

### 4.3 Un destinataire pour la dérive

Le job planifié détecte déjà. Il lui manque quelqu'un à qui parler. **Pas une
PR automatique** : le miroir GitHub est un dépôt à commit unique force-pushé
depuis un dépôt canonique — c'est la raison pour laquelle les PRs Dependabot
#1 et #4 ont été fermées sans merge, et une PR ouverte par un job y subirait
exactement le même sort. Le précédent qui a fonctionné est un lot manuel avant
epic (PR #8), où chaque major a été analysée une par une.

La forme retenue est donc une **notification**, pas une remédiation
automatique. Le choix du canal reste ouvert (§7).

## 5. Non-régression : comment on le prouve

La propriété centrale est *byte-pour-byte* et donc directement testable.

1. **Invariance du rendu.** Rendre les six cellules de la matrice avant et
   après le changement, avec la même valeur de version : les arbres produits
   doivent être **identiques**. C'est l'assertion qui dit que la variabilisation
   n'a rien changé d'autre.
2. **Mouvement solidaire.** Changer la valeur par défaut, re-rendre, et
   vérifier que la nouvelle version apparaît sur les **six** sites et nulle
   part ailleurs. C'est l'assertion qui échouerait aujourd'hui, avant le
   changement — donc celle qui a un sens.
3. **Anti-retour du littéral.** Un contrôle qui échoue si une version de Go
   littérale (`1\.[0-9]+\.[0-9]+`) réapparaît dans un gabarit là où la variable
   doit être. C'est l'application de la discipline « asserter ce qui doit
   **survivre** » du `CLAUDE.md`, née des six sur-suppressions de la PR #49 :
   sans elle, un futur contributeur recolle un littéral et rien ne rougit.
4. **Mutation-test de chaque assertion ajoutée**, en réinjectant le défaut
   qu'elle nomme. Non négociable sur ce dépôt : sur les PRs #49 et #51, quatre
   garde-fous couvraient un chemin d'une façon qui ne pouvait pas voir le
   défaut, et chacun a été démasqué de cette façon.

`make vuln` reste le vrai gate ; le contrôle de fraîcheur ne devient pas
bloquant, sans quoi `main` rougirait à chaque release amont, y compris quand
aucune vulnérabilité n'est en jeu.

## 6. Ce que ce design ne fait pas

- Il ne répare pas les exportateurs **déjà générés**. Seul `docs/upgrading.md`
  (planifié en v0.11) leur parle. Le vert silencieux de §1 y est un défaut
  actif : ils doivent être invités explicitement à vérifier le `go-version:`
  de leurs workflows de release, pas seulement leur image d'outils.
- Il n'introduit aucun résolveur amont. Si un jour on en veut un, sa moitié
  faisable est établie : le digest d'une image se résout anonymement par un
  `HEAD` sur `registry-1.docker.io` avec un token public, et `go.dev/dl?mode=json`
  donne les versions — mais il faudra **filtrer la ligne mineure**, l'API
  renvoyant la dernière version publiée toutes lignes confondues.
- Il ne touche pas `go.sum`, fichier réel et non templaté : tout rafraîchissement
  de module exige de le régénérer avec Go, ce qu'aucun script de substitution
  ne peut faire.

## 7. Questions ouvertes

1. **Le canal de notification.** Une issue ouverte/actualisée par le job
   planifié ? Un échec de job non bloquant mais visible ? Autre chose ? La
   contrainte est qu'il doit atteindre le mainteneur sur le dépôt canonique,
   pas seulement sur le miroir. Quatre rouges hebdomadaires consécutifs n'ont
   alerté personne : c'est le vrai problème à résoudre, et il est plus
   organisationnel que technique.
2. **Rédaction de la phrase du README** — les deux options du §4.2.
3. **Faut-il variabiliser `debian:13-slim` par symétrie ?** Mon avis : non,
   YAGNI ; il n'apparaît qu'une fois et Dependabot le couvre. À confirmer.
