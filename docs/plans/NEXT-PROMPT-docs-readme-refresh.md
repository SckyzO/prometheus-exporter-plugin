# Prompt pour la prochaine session

Copie tout ce qui suit la ligne de séparation.

---

Mets à jour la documentation d'accueil du plugin `prometheus-exporter`, qui a
cinq versions de retard sur le code.

Utilise la skill `writing-docs` pour la rédaction, puis `humanizer` en passe
finale.

## L'état du problème, vérifié

`README.md` décrit le plugin tel qu'il était en v0.3. Les compteurs ci-dessous
ont été relevés sur le fichier, pas estimés :

- il cite `--target-model multi` et **ignore `multi-instance`** (v0.5) :
  zéro occurrence dans tout le fichier
- il mentionne `--config.file` une fois (ligne 57) mais **ni le rechargement de
  configuration** (v0.7) **ni le plafond de concurrence**
  `--exporter.max-requests-per-target` (v0.7), zéro occurrence
- il ne dit rien de la **v0.8** : ni le journal de projet, ni `samples/`, ni le
  `CLAUDE.md` livré dans chaque dépôt scaffoldé, ni le bloc de collecteurs
  régénéré dans leur `README.md`
- attention aux faux positifs si tu greps : `reload` (ligne 144) est
  `/reload-plugins`, la commande Claude Code, pas le rechargement de
  configuration ; `CLAUDE.md` (ligne 132) est celui de **ce** dépôt, pas celui
  qui est généré
- son diagramme Mermaid ne montre que le pipeline des quatre commandes. Il est
  structurellement juste mais ne dit rien des trois modèles de cible, ni de la
  surface d'exploitation (SIGHUP, `/-/reload`, `--web.enable-lifecycle`), ni de
  l'état durable que les quatre commandes se transmettent depuis la v0.8.

`main` est à jour par ailleurs : la couche de références
(`skills/prometheus-exporter/references/`) et les docs templatées
(`skills/prometheus-exporter/assets/docs/`) ont été resynchronisées pour le
rechargement, le plafond et le journal. **Vérifie-le plutôt que de me croire** :
ce sont ces deux endroits qui ont produit le plus de prose fausse pendant les
épics v0.7 et v0.8.

## Périmètre

1. **`README.md`** : le rattrapage v0.4 vers v0.8. Couche de configuration YAML,
   `multi-instance`, identifiants par module, rechargement, plafond de
   concurrence, puis le journal de projet et ce qu'il entraîne. Le README est la
   porte d'entrée : il doit dire ce que le plugin fait aujourd'hui, pas raconter
   son histoire.
2. **La surface v0.8, qui est celle qu'un lecteur verra en premier** parce
   qu'elle change ce qu'il trouve dans son propre dépôt :
   - `docs/exporter-journal.md`, **commité**, lu à l'entrée et complété à la
     sortie par les quatre commandes ;
   - `samples/`, **gitignoré sauf son README**, pour le matériau brut capturé
     sur la cible ;
   - un `CLAUDE.md` écrit une fois au scaffold dans le dépôt généré ;
   - un bloc de collecteurs régénéré dans le `README.md` du dépôt généré.

   Le bénéfice à énoncer, parce que c'est la raison d'être de la version :
   entre deux collecteurs, `/clear` devient le geste **recommandé** au lieu
   d'être destructeur.
3. **Le diagramme Mermaid**. Décide s'il en faut un ou deux : le pipeline de
   commandes existant, plus éventuellement une comparaison des trois modèles de
   cible. Deux petits diagrammes justes valent mieux qu'un gros qui mélange deux
   questions. Les artefacts publiés rendent Mermaid nativement.
4. **`CLAUDE.md`** si quelque chose y est devenu faux. Le vérifier, pas le
   réécrire par principe.
5. **Passe `humanizer`** sur ce que tu as touché, en dernier geste de rédaction
   mais **avant** la relecture ci-dessous. L'ordre compte : `humanizer` réécrit
   de la prose, donc il doit passer avant le contrôle factuel, jamais après,
   sinon il peut réintroduire une erreur que plus personne ne revérifie.

Hors périmètre : `docs/design/` et `docs/plans/` sont mon historique de travail,
jamais chargés par le plugin. Ne les réécris pas.

## Quatre faits à ne pas se tromper, ils ont coûté cher

**Le rechargement n'achète PAS la rotation d'identifiants.** `prometheus/common`
relit déjà `password_file`, `bearer_token_file`,
`authorization.credentials_file`, `ca_file`, `cert_file` et `key_file` à chaque
requête sortante, sans aucun rechargement. Ce que le rechargement achète, c'est
la **forme** de la configuration : une instance ou un module ajouté, retiré,
ré-adressé, ré-étiqueté, ré-pointé, plus un secret écrit **inline**. Le ROADMAP
affirmait le contraire et a été corrigé ; ne réintroduis pas l'erreur.

**Le défaut fermé de `POST /-/reload` est la posture de Prometheus, pas celle de
blackbox ni de snmp.** Ces deux-là exposent le leur **sans garde**. Cette erreur
d'attribution a été écrite deux fois pendant l'épic, dans le CHANGELOG puis dans
le ROADMAP, et corrigée deux fois.

**Le journal est commité, `samples/` ne l'est pas, et c'est délibéré des deux
côtés.** Le journal est suivi par git parce qu'un fichier non suivi est détruit
par `git clean -xdf`, commande de routine, et qu'un journal qui disparaît sans
bruit est pire qu'un journal absent. `samples/` est ignoré parce qu'il contient
de la sortie **non anonymisée** de la cible, qui peut porter des hôtes, des
tenants et des identifiants, et de la documentation fournisseur dont la
redistribution n'est pas au dépôt généré de trancher. Son `README.md` est le
seul fichier suivi, pour que le dossier survive à un clone.

**Rien ne sort de `samples/`.** La fixture anonymisée sous
`internal/collector/testdata/` en est **dérivée**, l'original reste : une seule
capture alimente souvent plusieurs collecteurs, et le collecteur n°12, trois
sessions plus tard, doit pouvoir la relire sans re-solliciter la machine.

## Ce que le rechargement refuse, et qui doit être dit

- une section `flags:` modifiée refuse le rechargement entier, en nommant les
  clés (kingpin ne parse qu'une fois)
- en `multi-instance`, un changement du **jeu de clés** de labels d'instance est
  refusé avec « redémarrage requis » (un registre Prometheus ne libère jamais la
  dimension de noms de labels d'une famille de métriques). Un changement de
  **valeur** de label passe à chaud, sans redémarrer le sondeur.
- `single` n'a pas de rechargement du tout, et la doc doit pointer vers
  `password_file` plutôt que de laisser croire à un manque.

## Ce que le journal refuse, et qui ne doit PAS être surestimé

**Le journal ne refuse jamais rien.** Absent ou illisible, chaque commande fait
exactement ce qu'elle faisait avant qu'il existe et va jusqu'au bout. C'est la
garantie de compatibilité pour tout exporter scaffoldé avant la v0.8 : ne la
présente pas comme une dégradation, c'est le contrat.

**Et surtout, ne surestime pas la couverture.** La moitié « protocole » de la
v0.8 (lecture à l'entrée, réconciliation, dégradation, dérivation de fixture
depuis `samples/`, régénération du bloc README) est de la **prose exécutée par
un modèle**, qu'aucun test de ce dépôt ne peut exercer. Le `golden-smoke` prouve
les artefacts côté scaffold, pas le protocole. Le `### Notes` du `CHANGELOG.md`
le dit noir sur blanc : si tu écris quoi que ce soit sur la fiabilité du
journal dans le README, aligne-toi dessus, ne le vends pas comme testé.

## Contraintes dures

- **Anglais** pour tout artefact livré : `README.md`, `CLAUDE.md`,
  `skills/`, `commands/`, `agents/`.
- **Aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013)** sous `skills/`
  ni `commands/`. `README.md` faisait partie du lot de dé-dashage : ne l'y
  réintroduis pas. (`ROADMAP.md` en contient 6, préexistants et hors garde-fou.)
- **Conventional Commits avec scope**. **Jamais** de trailer `Claude-Session:`,
  de `Co-Authored-By: Claude`, ni aucune mention d'assistance IA dans un message
  de commit. Ce défaut est apparu deux fois pendant l'épic v0.7.
- Aucune source de données, préfixe de métrique, chemin d'endpoint ou identité de
  mainteneur en dur dans un template : ce sont des variables `@@VAR@@`.

## Garde-fous à faire passer

- `sh test/zero-source-grep.sh`
- `claude plugin validate .`
- `sh test/golden-smoke.sh --all` si tu touches quoi que ce soit sous `assets/`
  ou `test/`. Le README seul ne l'exige pas : vérifie avec
  `git diff --name-only` ce que tu as réellement modifié, et dis-le.

**Un piège de méthode, constaté cinq fois sur les deux épics** : ne déclare
jamais un garde-fou vert sans l'avoir lancé tel quel. Un sous-ensemble assemblé
à la main (`go build` + `go vet` au lieu de `golden-smoke.sh`) a laissé passer
une cellule rouge en CI deux fois de suite. Si un outil manque dans ton `PATH`,
le Makefile le route par une image Docker : c'est ça qu'il faut faire marcher,
pas un substitut plus faible. Et si Docker Desktop est tombé, dis-le et arrête-toi
plutôt que de conclure sur un argument de construction : c'est arrivé pendant la
v0.8, la bonne réponse a été de ne rien commiter.

## Contexte utile

- État : `main`, **v0.8 mergée et poussée, CI verte, mais pas encore taggée**.
  Le dernier tag est `v0.7.0`. Arbre propre, aucune PR ouverte.
- Le `CHANGELOG.md` a une section `## [Unreleased]` qui décrit toute la v0.8 :
  c'est ta meilleure source pour savoir ce que le README doit rattraper.
- La CI tourne en ~9 min (matrice de 6 cellules golden en parallèle).
- Douze références sous `skills/prometheus-exporter/references/`, pas onze : la
  v0.8 a ajouté `project-journal.md`, qui possède le format et le protocole du
  journal.
- Il reste au ROADMAP : en v0.8 les registres enfants par instance (le journal
  est livré), en v0.9 une commande d'alertes Prometheus.
- Les mineurs différés de la v0.8 et leurs rulings sont dans
  `docs/plans/2026-07-31-v08-deferred-minors.md`. Ce README en est un : il y est
  listé comme traité à part, dans sa propre tâche, c'est-à-dire celle-ci.

## Une relecture séparée, une fois écrit

Quand le texte est prêt et avant de me proposer la PR, **fais-le relire par des
yeux neufs qui n'ont pas écrit la prose** : un sous-agent dédié, avec pour seule
consigne de vérifier chaque affirmation factuelle contre le code et pas contre
ce prompt. Ce prompt est ma reconstitution, il a déjà eu cinq faits périmés
d'une version sur l'autre, et il en aura d'autres.

Ce que la relecture doit chercher en priorité, parce que c'est là que la prose
de documentation ment le plus facilement :

- une capacité annoncée qui n'existe que sur un modèle de cible ou une saveur,
  présentée comme générale ;
- un drapeau, un chemin ou un nom de fichier cité de mémoire et jamais ouvert ;
- une couverture de test suggérée qui n'existe pas, en particulier sur la
  moitié protocole de la v0.8 ;
- un diagramme Mermaid juste sur la forme mais qui répond à une autre question
  que celle qu'un nouveau lecteur se pose ;
- et l'inverse du rattrapage : une phrase qui décrit un état passé au présent,
  ce qui est exactement le défaut que le README a aujourd'hui.

Sur les deux épics précédents, la majorité des vrais défauts venaient de la
spec ou du plan, pas de l'exécution, et plusieurs corrections ont introduit leur
propre défaut, attrapé seulement par une relecture ciblée du diff de correction.
Une passe de relecture sur un README n'est pas du zèle, c'est le seul garde-fou
qui existe pour de la prose.

Travaille sur une branche, pas sur `main`. Propose-moi une PR quand la CI est
verte **et** que cette relecture est passée.
