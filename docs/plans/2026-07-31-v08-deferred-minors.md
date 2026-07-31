# v0.8 deferred minors

Ce que la v0.8 a livré en le sachant imparfait. Chaque ligne vient d'une revue
de tâche ou de la revue finale de branche, avec sa raison de ne pas avoir été
corrigée dans la release. Aucun de ces points ne casse un comportement.

Les items fermés pendant la livraison ne sont pas listés ici : le balayage de
la tâche 10 et la vague de correction finale en ont fermé une douzaine (la
liste de lecture de `/design-exporter`, le blockquote mal placé, `First
planned:`, le chemin nommé dans le bloc de reprise, le triple de labels
concret, l'étiquette « Move the brief. », le grep `Name: *`, la ligne de 123
caractères, la clause ambiguë sur `samples/`, `SKILL.md:96`/`:152`, le crédit
d'anonymisation, les « sections » de `/generate-dashboard`).

## Reste ouvert

### Documentation du plugin

- **Le `README.md` racine ne mentionne ni le journal, ni `samples/`, ni le
  `CLAUDE.md` généré.** Rien n'y est faux, mais « What it gives you » est
  désormais incomplet. Un `NEXT-PROMPT-docs-readme-refresh.md` existait déjà
  avant cette release ; le rafraîchissement peut accompagner le tag.
- **`ROADMAP.md:153`** dit « appears in none of the eleven reference
  documents », au présent, dans la section v0.6. La tâche 10 a délibérément
  refusé de passer le compte à douze : la phrase est l'énoncé du problème de
  ce jalon, et la dette est payée (`multi-instance` apparaît maintenant dans 8
  des 12 références), donc « twelve » serait devenu activement faux plutôt que
  rafraîchi. L'item mérite d'être clos ou reformulé, pas recompté.
- **`SKILL.md`, ligne d'index de `project-journal.md`**, ouvre sur « Every
  step: » là où les onze autres ouvrent sur « Step N: ». Défendable (le
  journal traverse les quatre commandes), signalé comme préférence de
  mainteneur.
- **La ligne d'index de `discovery-inputs.md`** ne mentionne plus le brief
  d'architecture, alors que ce fichier en possède toujours deux sections. Un
  lecteur de l'index seul ne saurait pas y chercher `## Provenance`.

### Cohérence entre fichiers, pré-existante

- **`exporter-architecture.md` compte les décisions à trois valeurs
  différentes** : « It produces four decisions » (`:5`), « These seven items »
  (`:396`, `:400`), pendant que `design-exporter.md` dit six. Antérieur à la
  v0.8, **parké avec ruling** : le « six » est cohérent avec la façon dont ce
  fichier traite déjà ses sous-questions non comptées (convention de
  crédentials, plafond de concurrence, et désormais `5b`). Mérite sa propre
  passe.

### Duplication assumée

- **`/add-collector` porte une copie inline de la liste de substitutions
  d'anonymisation.** Trois relecteurs se sont prononcés : deux pour le
  pointeur, un pour la copie. Gardée délibérément, parce que c'est le seul
  endroit du plugin où un modèle est invité à lire du matériau de production
  non anonymisé et à en écrire un fichier commité, donc la règle doit être au
  point d'usage. **Condition posée** : la copie a déjà dérivé de deux de ses
  sources à l'intérieur d'un seul commit, avant d'être complétée. Si elle
  dérive une fois de plus, la forme pointeur gagne.
- **`assets/CLAUDE.md.tmpl`, section « The gate »**, répète la liste des
  sous-vérifications de `make check` et `NATIVE=1`, tous deux déjà dans
  `CONTRIBUTING.md.tmpl:19,78`, dans un fichier dont l'en-tête dit que
  `CONTRIBUTING.md` est celui à lire. À resserrer en pointeur.

### Robustesse de test

- **L'assertion `check-ignore` de `golden-smoke.sh` peut faux-passer** sur un
  runner dont le `core.excludesFile` global filtre `*.json` : la moitié
  « README non ignoré » échouerait bruyamment, mais la moitié « fichier
  déposé ignoré » passerait pour la mauvaise raison. La CI est propre. Le
  durcissement tient en un token :
  `git -c core.excludesFile=/dev/null -C "$work" check-ignore`.
- **`/add-collector` ne dit pas comment apparier** l'en-tête *k* de
  `docs/metrics.md` avec la *k*-ième chaîne de registre de `cmd/*/main.go`.
  L'appariement positionnel tient (metrics.md insère avant
  `## Self-instrumentation`, le registre appende), mais l'invariant n'est
  écrit nulle part.

### Écart lettre/esprit dans le référentiel

- **`/add-collector` écrit le journal avant son garde-fou**, à l'étape 1
  (réconciliation), alors que `project-journal.md` dit « never before » et que
  la dérogation ne nomme que les deux commandes créatrices. La raison
  invoquée par la règle (« records an outcome that has not happened yet ») ne
  s'applique pas : une entrée de réconciliation recopie un état que le disque
  prouve déjà. La lettre est violée, l'esprit non. Une clause suffirait.
- **Le bloc de reprise de `/design-exporter` dévie sur deux lignes** que la
  dérogation ne couvre pas : « Review the brief, then it is safe to /clear: »
  au lieu de « Safe to /clear now: », et `./exporter-design-brief.md` au lieu
  de `docs/exporter-journal.md`. Les deux déviations sont *correctes* (il n'y
  a pas encore de journal) ; c'est la dérogation qui est trop étroite.

## Ce qu'aucun test ne couvre

Rappel, consigné aussi dans `CHANGELOG.md` : la moitié « protocole » de cette
release est de la prose exécutée par un modèle, hors de portée du harnais. Le
`golden-smoke` prouve les artefacts côté scaffold (`samples/` et son suivi
git, le `CLAUDE.md` généré et son vrai modèle/saveur, les marqueurs README
appariés, non vides et sous `## Metrics`). Il ne prouve ni la lecture à
l'entrée, ni la réconciliation, ni la dégradation, ni la dérivation de fixture
depuis `samples/`, ni la régénération du bloc README. Ces cinq-là ont été
vérifiés par relecture, dix revues de tâche et une revue de branche.
