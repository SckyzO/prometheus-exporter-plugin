# Prompt pour la prochaine session : fermer #49, puis la phase 2 du budget de file

Copie tout ce qui suit la ligne de séparation.

---

v0.10.0 est sortie. Ce qui suit ferme ce qu'elle a laissé ouvert, puis attaque
le seul chantier qui referme un défaut mesuré sur du matériel réel.

## Lis ça en premier, dans cet ordre

1. `ROADMAP.md`, section v0.10 (marquée released, avec les deux items qu'elle a
   produits laissés ouverts) puis v0.11.
2. Le `CLAUDE.md` racine, **en entier**, avant la première modification. Il a
   une section neuve sur les blocs conditionnels : lis-la même si tu crois
   savoir, c'est la couture qui gouverne désormais tout gabarit.
3. `docs/plans/README.md` pour savoir où vit le travail ouvert.

Ne relis pas le journal terrain. Ce qui devait en sortir est dans `ROADMAP.md`
et dans le `CHANGELOG.md` de 0.10.0.

## L'état, à vérifier en ouvrant

- Dernier tag : **v0.10.0** sur `7dedef1`. `plugin.json` à 0.10.0.
- **PR #49 ouverte, CI verte, PAS mergée** : la couture de conditionnement.
  Deux relectures adverses, 7 puis 4 blocages, tous corrigés. Une troisième
  était recommandée et n'a pas eu lieu.
- **PR #50 ouverte**, triviale : l'index des plans.
- Aucune autre branche en cours.

## Ce qu'il reste, ordonné par valeur

### 1. Fermer #49

Une troisième relecture adverse, par un sous-agent qui n'a écrit ni le diff ni
les deux remédiations. Le taux ne descend pas assez vite pour merger sur parole :
7 puis 4 blocages, et **la deuxième passe a trouvé que la première remédiation
avait introduit quatre nouveaux défauts de la classe qu'elle corrigeait**.

Consignes prioritaires pour cette relecture : les quatre remédiations de la
deuxième passe (personne ne les a relues), et une chasse aux sur-suppressions
dans le rendu des quatre combinaisons, pas dans les gabarits.

Merge #50 quand tu veux, elle ne touche que `docs/plans/`.

### 2. Phase 2 du budget de file — le plus rentable

La phase 1 a séparé l'attente de la requête dans `Client.Fetch`. **Elle n'a pas
bougé la famine**, et c'est mesuré, pas supposé : sur le balayage de 19
collecteurs à plafond 1, avant 4 réussis / 14 affamés / 1 échoué en requête,
après 5 / 14 / 0. Ce qui a changé, c'est la nature de l'échec, plus son taux.

La raison est arithmétique : les trois constructeurs posent tous
`acquireTimeout` égal au timeout de requête (`client.go.tmpl:131`, `:154`,
`:267`, ce dernier le lisant sur `hc.Timeout`). Tant que l'attente vaut la
requête, le collecteur en fond de file est coupé au même instant.

**Le travail :** rendre le budget d'attente dimensionnable indépendamment du
budget de requête. Des minutes contre des secondes.

Deux choses à trancher avant d'écrire, et elles sont à toi :

- **La surface.** Un drapeau global, un drapeau par collecteur, une clé de
  configuration ? Le plafond lui-même est global
  (`--exporter.max-requests-per-target`) alors que les timeouts sont par
  collecteur ; l'attente ressemble plutôt au plafond qu'au timeout.
- **Le défaut.** Le laisser sur le timeout de requête (rien ne change sans
  action) ou le bouger (le plafond 1 devient utilisable, mais c'est un
  changement de comportement pour les exporters déjà échafaudés).

C'est un changement de surface de configuration **et** potentiellement un
déplacement de défaut. La règle des deux phases s'applique donc à nouveau, à
l'intérieur de ce chantier.

**Le critère d'acceptation est un chiffre, pas une intention.** Le balayage
existe déjà en forme jetable ; refais-le et montre les trois colonnes avant et
après. Si le 14 ne bouge pas, la phase 2 n'a pas eu lieu, quel que soit le
diff.

**Deux choses à ne pas casser**, les mêmes qu'en phase 1 :
- Le refus au boot de `code/http/wiring/client_build.frag` garde le chemin
  `single`+http, où `c.timeout` vaut 0. Vérifie qu'il reste nécessaire *et*
  suffisant après ton changement.
- `@@NAMESPACE@@_exporter_request_wait_seconds` est observé dans
  `Limiter.Acquire` et n'encadre que l'attente. Vérifie qu'il mesure toujours
  ce qu'il prétend, et que le texte d'aide dit toujours vrai.

### 3. La stack de démo Prometheus + Grafana

Débloquée par le montage de config de #49. La forme est décidée, ne la
redébats pas :

- Un **troisième** fichier, `docker-compose.demo.yml`, plus une cible
  `make demo-up`. Jamais une modification de `docker-compose.yml` :
  `make docker-run` veut dire « lance mon exporter » et le changer touche tous
  les utilisateurs existants. `docker-compose.minimal.yml` désigne l'**image**
  (distroless), pas le nombre de services ; ne réutilise pas cet axe.
- Prometheus charge les `alerts.yml` / `rules.yml` générés.
- Grafana provisionné, et le point qui décide si ça pourrit : le provider de
  dashboards pointe sur le **répertoire** `monitoring/grafana/`, jamais une
  énumération de fichiers. Sinon `/prometheus-exporter:generate-dashboard`
  produit N dashboards que personne ne charge, et on a recréé le problème un
  cran plus loin.

Bénéfice secondaire, et il est gros : c'est le seul endroit où
`monitoring/rules.yml`, livré par chaque scaffold et écrit par rien, devient
enfin exercé.

### 4. Les cinq verdicts adoptés non implémentés

`docs/design/2026-08-01-official-exporter-gap-report.md`. Indépendants les uns
des autres, chacun borné. C'est le seul lot de cette liste qui se parallélise
proprement.

## Sur les sous-agents

Tu peux paralléliser, mais pas les quatre de la même façon.

- **Oui** pour les cinq verdicts (indépendants, bornés, déjà spécifiés) et pour
  un premier jet de la stack de démo (additive, forme décidée).
- **Non** pour la phase 2 du budget de file : déplacement de défaut plus surface
  de configuration, sur du code déjà déployé. C'est exactement ce que la règle
  des deux phases dit de faire délibérément et de faire relire.
- **Jamais le même agent auteur et relecteur.** C'est d'où vient toute la valeur
  observée jusqu'ici.
- **Worktrees isolés** dès que deux chantiers touchent `assets/`. Et interdis
  aux sous-agents d'éditer `ROADMAP.md` : ils y toucheront tous, le conflit est
  garanti. Fais-le toi-même à la fin.

## Contraintes dures

- Anglais pour tout artefact livré. `docs/design/` et `docs/plans/` sont mon
  historique de travail et peuvent rester en français.
- Aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013) sous `skills/` ni
  `commands/`, ni dans `README.md` ni dans `docs/*.md`. Vérifie ton propre diff.
- Les commandes s'écrivent toujours `/prometheus-exporter:<nom>`.
- Conventional Commits avec scope. Jamais de mention d'assistance IA.
- Aucune source de données, préfixe de métrique, chemin d'endpoint ou identité
  de mainteneur en dur dans un gabarit : ce sont des `@@VAR@@`.
- Texte vrai d'un modèle de cible et faux d'un autre : ce n'est pas une
  variable, c'est un **bloc conditionnel**. La grammaire et ses quatre règles
  sont dans le `CLAUDE.md` racine.
- Ne reflow jamais un frontmatter YAML dans `commands/`.

## Garde-fous

- `sh test/zero-source-grep.sh`
- `claude plugin validate .`
- `sh test/golden-smoke.sh --all` si tu touches quoi que ce soit sous `assets/`
  ou `test/`. Compte ~10 min. Il joue désormais le chemin d'installation
  complet sur multi-instance : il décommente le bloc `instances:` du
  `config.example.yml` livré, démarre le binaire, scrape, et vérifie que le
  corps porte les instances déclarées.
- `sh test/scaffold_test.sh`, `sh test/scaffold_edge_test.sh`,
  `sh test/scaffold_multitarget_test.sh` : rapides, sans Go, et c'est là que
  vivent les propriétés du rendu par modèle.

Vérifie avec `git diff --name-only` ce que tu as réellement modifié, et dis-le.
Ne déclare jamais un garde-fou vert sans l'avoir lancé tel quel. Et ne change
jamais de branche pendant que golden-smoke tourne : il lit l'arbre de travail,
une session parallèle me l'a invalidé une fois.

## Pièges de méthode, tous constatés sur v0.10

- **Un garde-fou peut couvrir le chemin d'une façon qui ne peut pas voir le
  défaut.** Trois fois, toutes trouvées par une relecture, jamais par moi.
  `golden-smoke` passait toujours `--config.file`, ce qui a masqué un
  `--version` cassé pendant des semaines. Puis toutes mes assertions
  vérifiaient qu'un texte indésirable avait *disparu* et aucune que le texte
  désirable avait *survécu*, ce qui a laissé passer six sur-suppressions. Puis
  deux assertions étaient **structurellement incapables d'échouer sur leur
  propre sujet** : l'une ne regardait que le premier titre du document, l'autre
  était ancrée sur la deuxième ligne d'un retour à la ligne, qu'un reflow
  désactivait en silence.
- **Donc : mutation-teste chaque nouvelle assertion.** Réinjecte le défaut
  qu'elle nomme, vérifie qu'elle rougit. C'est ce qui a distingué les vraies
  des décoratives, et rien d'autre ne l'aurait fait.
- **Mesure avant d'affirmer.** J'ai présenté la phase 1 comme réglant la
  famine ; la mesure disait 14 sur 19 avant comme après. La relecture l'a
  réfutée, pas moi.
- **Une citation venue d'un outil de doc n'est pas du verbatim, et une
  recommandation que tu viens d'écrire n'est pas une source.** J'ai cité « la
  valeur que la documentation de ce scaffold recommande » pour un plafond de 1
  que rien ne recommandait avant mon propre diff. Vérifie chaque chaîne entre
  guillemets contre la source brute.
- **N'enseigne jamais une règle plus stricte que l'écosystème que tu cites.**
  Sur les tables d'états, `node_exporter` liste cinq valeurs là où systemd en
  définit huit, et `ipmi_exporter` écrit `NaN` : la règle qu'on enseigne est
  une recommandation qui nomme le désaccord, pas une norme.
- **Corrige la source, pas seulement le dérivé.** À chaque PR de cette série,
  la relecture a trouvé des sites manqués : cinq sites de prose périmée sur le
  budget de file, sept sur la couture de conditionnement.
- **Un correctif introduit ses propres défauts au même rythme.** La première
  remédiation de #49 a créé quatre défauts de la classe qu'elle corrigeait.
  Fais relire les remédiations, pas seulement les diffs d'origine.

## Une relecture séparée, avant de me présenter quoi que ce soit

Fais relire chaque diff par un sous-agent dédié qui ne l'a pas écrit.
Consignes prioritaires : chercher la prose devenue fausse ailleurs dans le
dépôt ; attaquer chaque affirmation factuelle en essayant de la réfuter ;
vérifier toute affirmation « ça ne change rien pour les exporters existants » ;
et pour toute assertion de test ajoutée, exiger la preuve qu'elle échoue quand
le défaut qu'elle nomme est réinjecté.

Sur v0.10 cette passe a trouvé : une affirmation centrale fausse et mesurable,
une citation fabriquée, une règle plus stricte que l'écosystème, deux
garde-fous incapables de voir leur propre défaut, un trou tabulation-contre-
espace où les deux moitiés du moteur n'étaient pas d'accord, et une régression
contre `main` livrée dans une PR de correction. Elle n'est pas décorative.

Travaille sur une branche. Une PR par point ci-dessus.
