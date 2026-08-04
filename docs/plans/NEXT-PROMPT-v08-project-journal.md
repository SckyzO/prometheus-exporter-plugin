# Prompt pour la session v0.8

Copie tout ce qui suit la ligne de séparation.

---

Brainstorme la v0.8 du plugin `prometheus-exporter` : l'état durable que les
quatre commandes se transmettent.

Utilise la skill `superpowers:brainstorming`. Ne code rien avant que j'aie
validé un design.

## Le problème

Aujourd'hui une seule étape transmet quelque chose de durable :
`/design-exporter` écrit un brief d'architecture que `/new-prometheus-exporter`
lit. Après ça, plus rien. Les collecteurs restant à construire, le budget de
cardinalité, la convention d'identifiants choisie, ceux qui ont besoin de la
variante background : tout ne vit que dans la conversation. Une compaction ou un
`/clear` entre deux collecteurs perd des décisions déjà prises, alors que le
dépôt est à deux mètres.

C'est bloquant maintenant, pas plus tard : le premier vrai exporter à construire
avec ce plugin fait **15 collecteurs**, donc plusieurs sessions. Sans mémoire
entre elles, chaque session redécouvre ou contredit la précédente.

## Le périmètre, tel que je le vois, à challenger

Ce n'est pas trois fonctionnalités mais une seule question : **quel état durable
les quatre commandes lisent en entrée et écrivent en sortie ?** Le journal en est
le cas central. Deux autres sorties m'intéressent autant :

**1. Le journal lui-même.** Promouvoir le brief d'architecture en fichier que
chaque commande lit en entrée et complète en sortie. Ce qui doit y survivre :
les collecteurs faits et restants, le budget de cardinalité, la convention
d'identifiants, quels collecteurs sont en arrière-plan, le modèle de cible et
pourquoi. Il reshape le contrat des quatre commandes d'un coup.

**2. `docs/` et `test_data/`, déclarés dès l'étape 0.** `/design-exporter`
devrait dire à l'utilisateur de déposer sa documentation d'API dans `docs/` et
ses captures de sortie dans `test_data/`, en précisant que le plugin les
remplira lui-même s'il n'y en a pas.

`test_data/` est le plus rentable des deux. Aujourd'hui `/add-collector`
génère une fixture placeholder (`{"items": 3, "healthy": true}`) que
l'utilisateur doit remplacer à la main. Avec de vraies captures : les tests de
parsing pur partent de données réelles, et la sonde d'instance vivante (rung 4
de l'échelle de découverte) n'a plus besoin de re-solliciter la machine à chaque
session. Le premier exporter cible en a déjà, capturées à la main.

**3. Un `CLAUDE.md` et un `README` tenus à jour dans le dépôt généré**, au fil
des `/add-collector` plutôt qu'une seule fois au scaffold.

**Le piège à trancher là-dessus, et il est réel** : `CLAUDE.md` et `README` sont
des fichiers que l'utilisateur va éditer. Si le plugin les réécrit à chaque
`/add-collector`, il écrase son travail. Les options que je vois : section
balisée entre marqueurs, append-only, écriture unique au scaffold, ou proposer
un diff plutôt qu'écrire. Chacune a un coût différent. C'est une vraie décision
de design, pas un détail d'implémentation.

## Ce que je veux de toi

Pose-moi des questions une par une avant de proposer quoi que ce soit. En
particulier je n'ai pas d'avis arrêté sur : le format du journal (Markdown à
sections figées ? YAML ? les deux ?), s'il est commité ou gitignoré, ce qui se
passe quand il est absent ou corrompu, et si `/generate-dashboard` a quelque
chose à y lire ou écrire.

Challenge le périmètre. Si tu penses que ces trois morceaux ne devraient pas
tenir dans une seule version, dis-le et propose un découpage.

## Contexte du dépôt

- `main`, v0.7.0 taggée, arbre propre, aucune PR ouverte.
- Trois modèles de cible (`single`, `multi`, `multi-instance`), deux saveurs
  (`http`, `cli`), quatre commandes, un subagent, onze références.
- La v0.7 a livré le rechargement de configuration et un plafond de concurrence
  par cible. La v0.6 a **supprimé les migrations en place** de
  `/add-collector` : le plugin détecte un point d'extension (seam) périmé,
  refuse, et pointe vers la régénération. Toute la conception d'état durable doit
  vivre avec cette contrainte.
- Le second item de la v0.8 au ROADMAP (registres enfants par instance) est
  **hors périmètre de cette session** : sans rapport, il mérite la sienne.

## Contraintes dures

- **Anglais** pour tout artefact livré : `SKILL.md`, `references/`, `assets/`,
  `commands/`, `agents/`, `README.md`, `CLAUDE.md` racine. `docs/design/` et
  `docs/plans/` sont mes notes de travail et peuvent être en français.
- **Aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013)** sous `skills/` ni
  `commands/`. Garde-fou dur.
- **Conventional Commits avec scope.** **Jamais** de trailer `Claude-Session:`,
  de `Co-Authored-By: Claude`, ni aucune mention d'assistance IA dans un message
  de commit.
- Aucune source de données, préfixe de métrique, chemin d'endpoint ou identité de
  mainteneur en dur dans un template : variables `@@VAR@@`.
- Garde-fous : `sh test/zero-source-grep.sh`, `claude plugin validate .`, et
  `sh test/golden-smoke.sh` sur les cellules concernées. La CI tourne en ~9 min
  (matrice de 6 cellules).

## Trois leçons de la v0.7, chèrement acquises

1. **Ne déclare jamais un garde-fou vert sans l'avoir lancé tel quel.** Un
   sous-ensemble assemblé à la main a laissé passer une cellule rouge en CI deux
   fois. Si un outil manque de ton `PATH`, le Makefile le route par une image
   Docker : c'est ça qu'il faut faire marcher.
2. **Une assertion qui ne peut pas échouer n'est pas un test.** Trois ont été
   attrapées pendant la v0.7. Prouve chaque nouvelle assertion en cassant
   délibérément ce qu'elle garde.
3. **Le sous-ensemble de garde-fous que tu lances décide de ce que tu peux
   trouver.** Une Critical a survécu parce que deux cellules golden sur quatre
   avaient été lancées, et la cellule non lancée était la seule qui pouvait la
   voir.

## En attente, sans rapport avec cette session

Le prochain `chore(release)` doit consigner sous `### Changed` que
`..._exporter_request_wait_seconds` a gagné un label `outcome` après le tag
v0.7.0.

Travaille sur une branche, pas sur `main`.
