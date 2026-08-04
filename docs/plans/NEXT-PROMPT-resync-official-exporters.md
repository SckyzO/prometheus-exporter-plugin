# Prompt pour la prochaine session

Copie tout ce qui suit la ligne de séparation.

---

Élargis la base de référence du plugin `prometheus-exporter`. Aujourd'hui
tout ce qu'il enseigne dérive d'**un seul** exporter, récent et maintenu par
moi. Je veux qu'il s'appuie aussi sur les exporters officiels de
l'écosystème, qui ont dix ans de production derrière eux.

C'est un épic, pas une passe. Commence par me proposer un découpage avant
d'écrire quoi que ce soit.

## L'état, vérifié

`docs/design/re-sync.md` est le document de correspondance
source → template. Lis-le **en entier** avant de commencer, en particulier :

- **§1 « The reference »** : la référence unique actuelle, son chemin local,
  sa licence, et pourquoi la dérivation part de fichiers réels plutôt que de
  mémoire.
- **§2** : la table de correspondance fichier par fichier, avec la marque
  **[D]** (dérivé) ou **[N]** (nouveau, sans équivalent).
- **§3 et §4** : les corrections et déviations délibérées appliquées
  par-dessus la copie. Elles doivent survivre à toute re-dérivation.
- **§5** : les versions épinglées héritées, avec la consigne de les
  re-vérifier au prochain re-sync. Elles n'ont pas été re-vérifiées depuis.
- **§6** : la procédure de re-dérivation en six étapes. **Elle existe déjà
  et fait autorité.** Ta tâche l'applique, elle ne la remplace pas.

Douze références sous `skills/prometheus-exporter/references/`.

## Les quatre exporters visés

`node_exporter`, `blackbox_exporter`, `snmp_exporter`, `ipmi_exporter`.

Ils couvrent presque exactement la matrice du plugin, ce qui n'est pas un
hasard et rend la comparaison utile :

| Exporter | Modèle de cible | Saveur |
|---|---|---|
| `node_exporter` | single | http (lecture locale) |
| `blackbox_exporter` | multi (`/probe?target=`) | http |
| `snmp_exporter` | multi + `modules:` | http |
| `ipmi_exporter` | proche du wrapper CLI | cli |

**À vérifier, pas à croire** : je pense qu'ils sont tous en Apache-2.0, ce
qui changerait le calcul de dérivation par rapport à la référence actuelle
en GPL-3.0 (voir `re-sync.md` §1, qui explique pourquoi le `LICENSE` du
plugin n'a **pas** été copié de la référence). Confirme chaque licence à la
source avant de dériver quoi que ce soit, et dis-moi si l'une diverge.

## Un piège qui casserait le build

Ces quatre noms **sont déjà cités** dans les artefacts livrés, à dessein :
`node_exporter` dans 3 fichiers, `snmp_exporter` et `blackbox_exporter` dans
1 chacun, plus `postgres_exporter` / `mysqld_exporter` / `sql_exporter` dans
4 chacun. Ce sont des précédents d'écosystème invoqués pour justifier une
convention adoptée par le plugin.

**Ils ne doivent jamais entrer dans `SOURCE_TERMS`**, la liste noire de
`test/zero-source-grep.sh` (aujourd'hui `slurm ts4500 sacct sinfo`). Le
faire ferait échouer le build sur une citation correcte. L'en-tête du script
et `CLAUDE.md` le disent tous les deux ; ne les contredis pas.

En revanche, si tu dérives depuis un nouvel exporter de référence **privé ou
spécifique**, ses noms propres, eux, doivent rejoindre la liste noire. Deux
règles pour ajouter un terme, toutes deux apprises à la dure et consignées
dans l'en-tête du script : il doit être absent de tout artefact livré
aujourd'hui, et assez spécifique pour survivre à une correspondance de
sous-chaîne insensible à la casse et sans limite de mot.

## La vraie question de conception

`re-sync.md` §1 suppose **une** référence. Passer à plusieurs est un
changement de structure du document, pas un ajout de paragraphe : la table
§2 devient une matrice, et il faut décider ce qui se passe quand deux
références divergent sur le même point.

Propose-moi la forme avant de l'écrire. Mon instinct, à contredire si tu vois
mieux : garder §2 telle quelle pour la référence d'origine, et ajouter une
section par exporter officiel qui ne consigne que les **écarts** constatés,
avec pour chacun un verdict explicite (adopté / rejeté / déjà couvert) et sa
raison.

## Ce que je veux en sortie

Pas une réécriture des templates. Un **rapport d'écarts** d'abord, sur lequel
je tranche, puis les changements que j'aurai validés.

Pour chaque écart : ce que fait l'exporter officiel, ce que fait ce plugin,
et lequel des deux a raison. Les trois cas m'intéressent également, y compris
« le plugin fait mieux » : c'est aussi un résultat, et il mérite d'être
consigné dans `re-sync.md` §4 comme déviation délibérée.

Priorité aux domaines où dix ans de production font une vraie différence :
la forme du collecteur, la gestion des erreurs de scrape, les conventions de
nommage et de labels, le contrat de `/probe`, la posture des endpoints
mutants, et la structure du fichier de configuration.

## Contraintes dures

- **Anglais** pour tout artefact livré : `README.md`, `CLAUDE.md`, `docs/`,
  `skills/`, `commands/`, `agents/`. `docs/design/` et `docs/plans/` sont mon
  historique de travail et peuvent rester en français.
- **Aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013)** sous `skills/`
  ni `commands/`, ni dans `README.md` ni dans `docs/*.md`.
- **Les commandes s'écrivent toujours `/prometheus-exporter:<nom>`.** La
  forme nue ne résout pas. 243 occurrences ont été corrigées le 01/08 ; ne
  les réintroduis pas.
- **Conventional Commits avec scope.** Jamais de trailer `Claude-Session:`,
  de `Co-Authored-By: Claude`, ni aucune mention d'assistance IA.
- **Aucune source de données, préfixe de métrique, chemin d'endpoint ou
  identité de mainteneur en dur** dans un template : ce sont des `@@VAR@@`.
- **Règle des deux phases** pour tout ce qui touche le moteur de templating,
  la couture des collecteurs ou le contrat du registre.

## Garde-fous

- `sh test/zero-source-grep.sh`
- `claude plugin validate .`
- `sh test/golden-smoke.sh --all` **si tu touches quoi que ce soit sous
  `assets/` ou `test/`**. Vérifie avec `git diff --name-only` ce que tu as
  réellement modifié, et dis-le.

**Ne déclare jamais un garde-fou vert sans l'avoir lancé tel quel.** Un
sous-ensemble assemblé à la main a laissé passer une cellule rouge deux fois.
Si Docker est tombé, dis-le et arrête-toi plutôt que de conclure sur un
argument de construction.

## Pièges de méthode, constatés sur les deux dernières sessions

- **Ce prompt est ma reconstitution.** Il a déjà eu des faits périmés d'une
  version sur l'autre. Vérifie contre le code, jamais contre moi.
- **`CHANGELOG.md` et `ROADMAP.md` ne font pas autorité non plus.** Les deux
  ont porté des affirmations fausses corrigées plus tard. Ce sont des
  indices sur où chercher, jamais des preuves.
- **Ne surestime jamais la couverture de test.** `golden-smoke` prouve les
  artefacts côté scaffold ; il ne prouve rien de ce que les commandes font,
  qui est de la prose exécutée par un modèle. Le `### Notes` du CHANGELOG le
  dit noir sur blanc.
- **Ne reflow jamais un frontmatter YAML.** `claude plugin validate` ne
  l'attrape pas : une passe de rewrap a plié `argument-hint` et
  `disable-model-invocation` dans le champ `description` sans que rien ne
  proteste.
- **Corrige la source, pas seulement le dérivé.** Deux faits faux corrigés
  dans le README sont restés dans le CHANGELOG dont le README avait été
  écrit, prêts à revenir.

## Une relecture séparée, une fois écrit

Avant de me proposer quoi que ce soit, **fais relire le rapport d'écarts par
des yeux neufs qui ne l'ont pas écrit** : un sous-agent dédié, avec pour
seule consigne de vérifier chaque affirmation contre le code des deux côtés,
le plugin et l'exporter officiel. Sur les deux dernières sessions, la
majorité des vrais défauts venaient de la spec ou du plan, pas de
l'exécution, et plusieurs corrections ont introduit leur propre défaut.

## Contexte utile

- État de départ, PRs ouvertes et décisions en attente :
  `docs/plans/2026-08-01-session-handoff.md`. **Lis-le en premier.**
- La CI tourne en ~9 min (matrice de 6 cellules golden en parallèle).
- Le dernier tag est `v0.8.0`. Une `v0.8.1` est prête mais non taggée.

Travaille sur une branche, pas sur `main`. Propose-moi le découpage avant
d'écrire, puis une PR par tranche.
