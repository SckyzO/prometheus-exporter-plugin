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

La branche `chore/v08-deferred-minors` (2026-07-31) en a fermé huit de plus,
listés en bas, regroupés en sept entrées (la dernière porte les deux écarts
lettre/esprit, fermés du même côté et du même commit). Ce qui reste ouvert
tient en trois lignes : une qui a déjà son propre prompt, deux parkées avec
ruling.

## Reste ouvert

### Documentation du plugin

- **Le `README.md` racine ne mentionne ni le journal, ni `samples/`, ni le
  `CLAUDE.md` généré.** Rien n'y est faux, mais « What it gives you » est
  désormais incomplet. Un `NEXT-PROMPT-docs-readme-refresh.md` existait déjà
  avant cette release ; le rafraîchissement peut accompagner le tag. Traité
  comme sa propre tâche, délibérément pas dans le lot ci-dessous.

### Cohérence entre fichiers, pré-existante

- **`exporter-architecture.md` compte les décisions à trois valeurs
  différentes** : « It produces four decisions » (`:5`), « These seven items »
  (`:396`, `:400`), pendant que `design-exporter.md` dit six. Antérieur à la
  v0.8, **parké avec ruling** : le « six » est cohérent avec la façon dont ce
  fichier traite déjà ses sous-questions non comptées (convention de
  crédentials, plafond de concurrence, et désormais `5b`). Mérite sa propre
  passe. Non touché par ce lot, le ruling tient.

### Duplication assumée

- **`/add-collector` porte une copie inline de la liste de substitutions
  d'anonymisation.** Trois relecteurs se sont prononcés : deux pour le
  pointeur, un pour la copie. Gardée délibérément, parce que c'est le seul
  endroit du plugin où un modèle est invité à lire du matériau de production
  non anonymisé et à en écrire un fichier commité, donc la règle doit être au
  point d'usage. **Condition posée** : la copie a déjà dérivé de deux de ses
  sources à l'intérieur d'un seul commit, avant d'être complétée. Si elle
  dérive une fois de plus, la forme pointeur gagne. Non touchée non plus, la
  condition reste armée.

## Fermé par `chore/v08-deferred-minors` (2026-07-31)

- **`ROADMAP.md:153`**, l'énoncé au présent du jalon v0.6 : reformulé au passé
  (« delivered »), sur la forme des autres items clos de la liste, sans
  recompter les douze références d'aujourd'hui. `f17b427`, complété par
  `d52765d` : la première rédaction disait « none of the eleven », ce que la
  phrase suivante contredisait déjà avant ce lot (v0.5 en avait ajouté deux
  au passage). `git grep -l multi-instance` par tag donne 2/11 à `v0.5.0`,
  6/11 à `v0.6.0`, 8/11 à `v0.7.0` : neuf manquaient, et la dette a été payée
  sur v0.6 **et** v0.7, pas sur v0.6 seule.
- **`SKILL.md`, ligne d'index de `project-journal.md`** : « Every step: »
  devient « Steps 0, 2, 3, 5: », les quatre étapes dont les commandes touchent
  réellement le journal. La colonne garde sa forme sans revendiquer les étapes
  1, 4 et 6. `2ad9481`.
- **`SKILL.md`, ligne d'index de `discovery-inputs.md`** : le brief revient par
  ses deux sections possédées (`## Provenance`, `## Open questions /
  assumptions`), jamais par le format que la v0.8 avait déplacé. `2ad9481`.
- **`assets/CLAUDE.md.tmpl`, section « The gate »** : resserrée en pointeur
  vers `CONTRIBUTING.md`. La liste des sous-vérifications et `NATIVE=1`
  disparaissent du template ; restent la commande et la règle (« pas de
  sous-ensemble »). `78f3289`.
- **L'assertion `check-ignore` de `golden-smoke.sh`** : les deux invocations
  passent par `git -c core.excludesFile=/dev/null`, le `.gitignore` du dépôt
  scaffoldé restant seul en vigueur. **RED refait** : `/samples/*` retiré de
  `.gitignore.tmpl`, la cellule `http/none` meurt bien sur l'assertion, avec
  et sans excludes global hostile ; la même cellule, non durcie et sous un
  excludes global qui filtre `*.json`, passait de bout en bout (`PASS`).
  `b1d0d6d`.
- **L'appariement du bloc README de `/add-collector`** : écrit en `d325e8f`,
  **faux à la première rédaction**, corrigé en `a35f0df`. La version livrée
  filtre les **deux** côtés avant d'apparier. Côté en-têtes, la règle
  existante (seuls les `## <Name>Collector` comptent). Côté registre, une
  règle symétrique qui manquait : sur le modèle `single`, l'auto-instrumentation
  est enregistrée par le même `register(...)`, donc la liste brute rendait deux
  noms de trop sur *tout* dépôt (`http_client_requests` /
  `http_client_request_wait` en http, `command_exec` / `command_exec_wait` en
  cli), ce qui déclenchait en permanence la clause « longueurs différentes » et
  aurait désactivé la régénération du bloc à chaque exécution. Le filtre porte
  sur la **forme de la closure** (un collecteur se construit par
  `collector.New<Name>Collector(...)` ; l'auto-instrumentation renvoie une
  variable de paquet déjà construite), jamais sur une liste de noms qui
  dériverait des fragments de wiring. S'ajoute une vérification par paire
  (en-tête minusculisé sans `Collector` == nom sans underscores), parce que
  l'invariant est tenu par la commande, pas garanti par les formats : les
  répertoires de travail du golden le montrent, ils appairent `example` avec
  `tape`. `a35f0df`.
- **Les deux écarts lettre/esprit du référentiel**, tous deux résolus côté
  `project-journal.md`, pas côté commandes : la réconciliation devient une
  dérogation de *timing* (elle recopie un état que le disque prouve, donc elle
  n'anticipe aucun résultat de gate), et la dérogation du bloc de reprise de
  `/design-exporter` couvre maintenant ses deux lignes correctes (le chemin
  `./exporter-design-brief.md` et la revue du brief avant le `/clear`).
  `23066ec`.

Gates de ce lot : `zero-source-grep`, `claude plugin validate`, les trois
suites `scaffold*_test.sh`, `golden-smoke --all` (six cellules, toutes vertes)
et le grep tirets longs sur `skills/` + `commands/`. Le tour de correction
(`a35f0df`, `d52765d`) ne touche ni `assets/` ni `test/`, donc la matrice ne
peut rien en observer et n'a pas été rejouée ; les autres gates l'ont été.

## Ce qu'aucun test ne couvre

Rappel, consigné aussi dans `CHANGELOG.md` : la moitié « protocole » de cette
release est de la prose exécutée par un modèle, hors de portée du harnais. Le
`golden-smoke` prouve les artefacts côté scaffold (`samples/` et son suivi
git, le `CLAUDE.md` généré et son vrai modèle/saveur, les marqueurs README
appariés, non vides et sous `## Metrics`). Il ne prouve ni la lecture à
l'entrée, ni la réconciliation, ni la dégradation, ni la dérivation de fixture
depuis `samples/`, ni la régénération du bloc README. Ces cinq-là ont été
vérifiés par relecture, dix revues de tâche et une revue de branche.
