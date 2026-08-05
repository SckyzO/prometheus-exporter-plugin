# Prompt pour la prochaine session : finir v0.10

Copie tout ce qui suit la ligne de séparation.

---

Finis le jalon v0.10. Il est déjà écrit, chiffré et sourcé dans `ROADMAP.md` :
ne le re-dérive pas, vérifie-le et traite-le.

## Lis ça en premier, dans cet ordre

1. `ROADMAP.md`, section **v0.10**, en entier. C'est la spécification.
2. Le `CLAUDE.md` racine, en entier, avant la première modification.
3. `docs/plans/README.md` pour savoir où vit le travail ouvert.

Ne relis pas les 2880 lignes du journal terrain. Tout ce qui devait en sortir
est déjà dans `ROADMAP.md` v0.10.

## L'état, à vérifier en ouvrant

- Dernier tag : **v0.9.0**. `plugin.json` à `0.9.0`.
- Arbre propre, **aucune PR ouverte**, tout est mergé sur `main`.
- Deux des cinq points de v0.10 sont déjà faits : la règle des deux jauges
  (#39) et `--version`/`--help` (#40). Les trois autres sont ci-dessous.

## Ce qu'il reste, ordonné par risque croissant

### 1. L'unité systemd ne démarre pas un build multi-instance

`assets/systemd/@@EXPORTER_NAME@@.service.tmpl:19` : l'`ExecStart` par défaut
ne porte pas `--config.file`, obligatoire sur ce modèle de cible. Les exemples
commentés en dessous couvrent TLS et les collecteurs, jamais celui-là. Un
opérateur multi-instance qui copie l'unité livrée obtient un service qui ne
démarre pas.

Additif, sans risque. Ajoute l'exemple et dis que le drapeau est **obligatoire**
sur multi-instance, facultatif ailleurs.

### 2. Le budget de file — la seule couture, deux phases obligatoires

**Lis le code avant de conclure, et lis le commentaire au-dessus.** Je m'y suis
trompé une fois dans l'autre sens : j'ai vu un commentaire délibéré de dix
lignes et j'ai classé le défaut « réfuté ». Il ne l'est pas.

`assets/code/http/client.go.tmpl`, dans `Fetch`, applique `c.timeout` au
contexte **avant** `acquire`. C'est délibéré et documenté : le ctx porte alors
l'unique échéance qui gouverne attente + requête, donc l'attente est imputée au
budget du collecteur au lieu de s'y ajouter.

**La prémisse est fausse dans le cas que le plugin recommande lui-même.** Elle
suppose que la file d'attente est une anomalie. Avec un plafond de 1, valeur
correcte pour une cible qui sérialise en interne, la file est l'**état normal**.
Mesuré sur du matériel réel : **14 collecteurs sur 19 affamés à chaque balayage,
en permanence** — les tickers de même intervalle tirent ensemble et
l'alignement ne se défait jamais tout seul.

Le correctif est une couture, pas un échange de lignes : **séparer le budget
d'attente du budget de requête**. Attente bornée par `acquireTimeout` (des
minutes), requête par `c.timeout` (des secondes). Pire des cas = la somme des
deux, bornée des deux côtés, et un collecteur qui n'obtient pas de créneau
échoue vite au lieu d'émettre une requête qu'il n'a pas le temps de finir.

**Règle des deux phases, non négociable ici.** Phase 1 : le nouveau réglage
existe et **vaut par défaut le timeout de requête**, donc aucun exporter déjà
échafaudé ne change de comportement. Phase 2, plus tard et séparément : bouger
le défaut. Ne fusionne pas les deux.

Deux choses à ne pas casser :
- `assets/code/http/wiring/client_build.frag` refuse déjà de démarrer si le
  plafond est activé avec un timeout non positif, *« the limiter wait would
  otherwise be unbounded »*. Ce refus doit rester vrai après ton changement.
- `@@NAMESPACE@@_exporter_request_wait_seconds` existe pour rendre la file
  visible. Vérifie qu'il mesure toujours ce qu'il prétend.

### 3. Le boot storm, et le cycle de vie qui bloque le correctif évident

Tous les collecteurs de fond tirent leur premier refresh en même temps.
Retarder `Start` est le correctif évident, et il est **dangereux tel que la
variante est écrite** :

```
assets/code/http/variants/background_collector.go.tmpl:110   done: make(chan struct{})   <- constructeur
assets/code/http/variants/background_collector.go.tmpl:121   defer close(c.done)         <- dans Start
```

Un `Start` qui ne tourne jamais (contexte annulé pendant le délai) laisse
`Done()` ouvert et fait pendre l'arrêt pour tout son budget. Corrige le cycle
de vie **avant** d'ajouter le moindre délai, ou trouve une autre forme
d'étalement. Dépend du point 2 : sans budget de file séparé, étaler ne suffit
pas.

### 4. Quatre savoirs jamais enseignés

Chacun trouvé en le rencontrant. Doc seule, mais ils valent un vrai
raisonnement, pas une ligne de plus dans une checklist :

- Un tableau d'états documenté est un **plancher, pas un plafond** : émettre un
  état observé absent de la liste comme sa propre série, avec un log nommant le
  champ, au lieu de laisser toutes les séries documentées à `0` — ce qui fait
  passer l'équipement pour sans état.
- Dériver un budget de cardinalité de **l'unité que compte réellement le
  compteur de la source**, pas de celle que l'endpoint semble renvoyer.
- **Sommer un compteur d'équipement sur une population qui peut rétrécir** se
  lit comme un reset de compteur quand elle rétrécit. À dire dans le help text.
- **Un compteur source qui sature** (une valeur au plafond de son type,
  répétée) est un plancher, pas une mesure, et ça change ce que veut dire une
  règle qui moyenne.

## Contraintes dures

- **Anglais** pour tout artefact livré. `docs/design/` et `docs/plans/` sont mon
  historique de travail et peuvent rester en français.
- **Aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013)** sous `skills/` ni
  `commands/`, ni dans `README.md` ni dans `docs/*.md`. Vérifie ton propre diff.
- **Les commandes s'écrivent toujours `/prometheus-exporter:<nom>`.**
- **Conventional Commits avec scope.** Jamais de mention d'assistance IA.
- **Aucune source de données, préfixe de métrique, chemin d'endpoint ou
  identité de mainteneur en dur** dans un template : ce sont des `@@VAR@@`.
- **Ne reflow jamais un frontmatter YAML** dans `commands/`.

## Garde-fous

- `sh test/zero-source-grep.sh`
- `claude plugin validate .`
- `sh test/golden-smoke.sh --all` **si tu touches quoi que ce soit sous
  `assets/` ou `test/`**. Compte ~10 min. Il inclut désormais `promtool` qui
  charge `alerts.yml`, et une assertion `--version`/`--help` sans
  `--config.file`. Vérifie avec `git diff --name-only` ce que tu as réellement
  modifié, et dis-le.

**Ne déclare jamais un garde-fou vert sans l'avoir lancé tel quel.** Et ne
change jamais de branche pendant qu'il tourne : golden-smoke lit l'arbre de
travail, je l'ai invalidé une fois comme ça.

## Pièges de méthode, tous constatés

- **Lire le code ne protège pas d'en tirer la mauvaise conclusion.** Cinq fois
  cette semaine. Le cas le plus instructif : j'ai lu un commentaire délibéré de
  dix lignes justifiant l'ordre timeout-avant-acquire et j'ai classé le défaut
  réfuté. Le commentaire était sincère et la prémisse fausse. **Une intention
  documentée n'est pas une intention qui tient.**
- **Une citation venue d'un outil de doc n'est pas du verbatim.** J'ai expédié
  une citation fabriquée dans une référence livrée, soudée depuis deux passages
  non adjacents, avec la formule de prudence retirée. Vérifie chaque chaîne
  entre guillemets contre la source brute.
- **N'enseigne jamais une règle plus stricte que l'écosystème que tu cites.**
  J'ai écrit qu'un renommage après 1.0 impose un major ; `node_exporter`
  supprime des métriques en mineur depuis 2020.
- **Corrige la source, pas seulement le dérivé.** À chaque PR de cette série,
  la relecture a trouvé des sites que j'avais manqués : six annoncés contre
  treize réels une fois.
- **Un garde-fou peut contourner un défaut au lieu de le voir.** `golden-smoke`
  passait toujours `--config.file`, ce qui a masqué un `--version` cassé
  pendant des semaines. Quand tu ajoutes une assertion, demande-toi ce qu'elle
  ne peut pas voir.

## Une relecture séparée, avant de me présenter quoi que ce soit

Fais relire chaque diff par un sous-agent dédié qui ne l'a pas écrit.
Consignes prioritaires : chercher la prose devenue fausse **ailleurs** dans le
dépôt ; attaquer chaque affirmation factuelle en essayant de la **réfuter** ;
et vérifier toute affirmation « ça ne change rien pour les exporters
existants », qui est exactement ce que la phase 1 du point 2 prétend.

Sur cette série, cette passe a trouvé une affirmation inversée sur le
déploiement le plus courant, une citation fabriquée, une règle plus stricte que
l'écosystème, et sept sites de prose périmée. Elle n'est pas décorative.

Travaille sur une branche. Une PR par point ci-dessus, dans l'ordre 1, 2, 3,
puis 4. Le point 2 seul peut mériter deux PRs si la phase 1 grossit.
