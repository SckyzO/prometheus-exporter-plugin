# Prompt pour la prochaine session

Copie tout ce qui suit la ligne de séparation.

---

Implémente la **phase 1** de la couture de résultat des collecteurs :
`StatusTracker` doit pouvoir lire le résultat qu'un collecteur *déclare*, au
lieu de le deviner à partir du nombre de métriques qu'il a émises.

La conception existe déjà et fait autorité :
`docs/design/2026-08-01-collector-outcome-seam-design.md`. **Ta tâche
l'applique, elle ne la remplace pas.** Mais elle laisse cinq questions
ouvertes, et elles se tranchent **avant** d'écrire du code, pas dans une
description de PR.

## Lis ça en premier, dans cet ordre

1. `docs/plans/2026-08-01-session-handoff-2.md` : l'état du dépôt.
2. `docs/design/2026-08-01-collector-outcome-seam-design.md` : la conception,
   **en entier**, y compris §5 (les cinq questions) et §6 (definition of done).
3. `docs/design/2026-08-01-official-exporter-gap-report.md` §8.2 : les deux
   verdicts que ça implémente, avec leurs citations `fichier:ligne` des deux
   côtés.
4. Le `CLAUDE.md` racine, en entier, avant la première modification.

## L'état, vérifié le 2026-08-01

- `main` à `0d5320a`, tag **`v0.8.1`** posée et poussée, CI verte.
- **Une PR ouverte, #27**, qui porte le design doc lui-même. Si elle n'est pas
  mergée quand tu commences, merge-la d'abord : ton travail s'y appuie.
- Cinq verdicts adoptés sur dix sont déjà implémentés (#24, #25, #26). Celui-ci
  est le sixième et le plus gros.

## Le piège qui a déjà fait tomber une session

`ErrNoData` de `node_exporter` **ne veut pas dire « légitimement vide »**. Il
veut dire « la source de données est absente », et ses ~40 sites d'usage sont
tous des correspondances `os.ErrNotExist`. Un collecteur légitimement vide
retourne `nil` et est rapporté **`success = 1` avec zéro métrique**.

Le premier jet du rapport d'écarts a affirmé le contraire, après avoir lu
`execute()` correctement. Vérifier le code ne protège pas d'en tirer la
mauvaise conclusion. Donc : la forme à adopter est **le retour d'erreur**, et
la sentinelle est une question séparée dont la réponse par défaut est non.

## Ce que tu dois trancher avant de coder

Les cinq questions de §5. Présente-moi tes réponses avec leur raison, et
attends mon accord. Celle qui compte le plus est la cinquième : faut-il un
contrôle à la **compilation** sur `Add`, pour qu'un collecteur qui a voulu
implémenter l'interface mais s'est trompé de signature casse le build au lieu
de retomber silencieusement sur la règle du compte. C'est le point où la
phase 1 peut régresser sans bruit.

## Règle des deux phases, non négociable

Elle touche la couture des collecteurs, que le `CLAUDE.md` racine nomme
explicitement. **Les collecteurs des exporters déjà échafaudés sont du code
tiers**, écrit par leurs auteurs, compilé contre le `StatusTracker` livré. Si
`Add` cesse d'accepter un `prometheus.Collector`, leur build casse sur une mise
à jour qu'ils n'ont pas demandée, dans un fichier qu'ils ont écrit eux-mêmes.

Phase 1 ajoute la nouvelle forme **à côté** de l'ancienne, qui reste le
repli. La suppression du repli est une phase 2, dans une release séparée.

## Les consommateurs de la couture, vérifiés par grep

Trois appels réels à `tracker.Add`, plus deux mentions en commentaire :

- `assets/mains/single/main.go.tmpl:231`
- `assets/internal/probe/probe.go.tmpl:353`
- `assets/internal/instance/instance.go.tmpl:281`
- commentaires : `assets/code/{http/client.go.tmpl:28,cli/execute.go.tmpl:25}`

Plus les deux collecteurs d'exemple, les deux variantes background, les triades
de tests, `commands/add-collector.md` (qui connaît les identifiants exacts) et
`references/collector-pattern.md`. Re-grep, ne me crois pas.

## Contraintes dures

- **Anglais** pour tout artefact livré. `docs/design/` et `docs/plans/` sont mon
  historique de travail et peuvent rester en français.
- **Aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013)** sous `skills/` ni
  `commands/`, ni dans `README.md` ni dans `docs/*.md`. Vérifie avant de
  committer : j'en ai introduit un la dernière fois et c'est ma propre
  vérification qui l'a attrapé.
- **Les commandes s'écrivent toujours `/prometheus-exporter:<nom>`.**
- **Conventional Commits avec scope.** Jamais de mention d'assistance IA.
- **Aucune source de données, préfixe de métrique, chemin d'endpoint ou
  identité de mainteneur en dur** dans un template : ce sont des `@@VAR@@`.

## Garde-fous

- `sh test/zero-source-grep.sh`
- `claude plugin validate .`
- `sh test/golden-smoke.sh --all` — **obligatoire ici**, tu touches `assets/`.
  Compte ~10 min, six cellules.

**Ne déclare jamais un garde-fou vert sans l'avoir lancé tel quel.** Et vérifie
avec `git diff --name-only` ce que tu as réellement modifié, puis dis-le.

## Les tests, et ce que j'attends précisément

Un test par résultat, chacun rouge avant le changement et vert après :

1. Un collecteur qui n'émet rien **et déclare le succès** doit lire
   `collector_success=1`. C'est le faux positif qu'on corrige.
2. Un collecteur qui émet une partie de ses séries **puis échoue** doit lire
   `collector_success=0`, en conservant les séries déjà émises. C'est le faux
   négatif, le plus dangereux des deux.
3. Un `prometheus.Collector` nu, inchangé, doit continuer à passer par le
   tracker exactement comme avant. **C'est toute la promesse de la phase 1** :
   si ce test n'existe pas, rien ne prouve qu'on n'a pas cassé les exporters
   déjà livrés.

Si tu ne peux pas tester quelque chose, dis-le explicitement au lieu de le
passer sous silence. J'ai accepté deux non-tests documentés dans la session
précédente ; je préfère ça à une affirmation creuse.

## Une relecture séparée, avant de me présenter le résultat

Fais relire le diff par un sous-agent dédié qui ne l'a pas écrit, avec pour
consigne de chercher en priorité : un chemin où la nouvelle interface est
silencieusement ignorée, un endroit où l'ancienne forme cesse de marcher, et
toute affirmation du type « ça ne change rien pour les exporters existants »
qui ne serait pas prouvée par un test.

Sur les deux dernières sessions, cette passe a tué le résultat principal d'un
rapport et réfuté trois affirmations flatteuses. Elle n'est pas décorative.

## À faire en fin de tâche

- Mettre à jour `re-sync.md` §4.6 : la verrue qu'elle consigne est corrigée,
  donc l'entrée doit le **dire**, pas disparaître. Ajouter aussi la correction
  de §2 sur ce que `ErrNoData` signifie réellement.
- `references/collector-pattern.md` et `commands/add-collector.md` en lockstep
  avec les templates, en indiquant que l'ancienne forme marche toujours.
- Une entrée CHANGELOG.

## Ce qui attend après, si tu as le temps

Quatre verdicts adoptés restent, listés dans la passation avec leur coût. Les
deux additifs (`--config.check`, compteur sur sonde refusée) sont du même
profil de risque que la PR #26. Les deux autres changent un comportement livré
et méritent leur propre annonce.

Travaille sur une branche, pas sur `main`. Une PR pour cette tâche.
