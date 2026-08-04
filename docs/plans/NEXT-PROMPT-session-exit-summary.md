# Prompt pour une prochaine session : le récapitulatif de fin de commande

Copie tout ce qui suit la ligne de séparation.

---

Ajoute un **récapitulatif de fin** commun aux quatre commandes du plugin.
Aujourd'hui chacune se termine comme elle veut, et l'utilisateur doit relire la
conversation pour savoir ce qui a réellement été fait et ce qu'il doit faire
avant de rouvrir une session.

## La forme, à respecter telle quelle

Un tableau unique, une ligne par élément, une colonne de statut portée par un
emoji. Pas trois tableaux, pas de sections vides.

```
## Session summary — /prometheus-exporter:add-collector

| | What | Detail |
|---|---|---|
| ✅ | Collector `queue` added | 5 metrics, 3 tests green |
| ✅ | Docs in lockstep | `make docs-check` green |
| ✅ | Journal updated | 2 sections completed |
| ⚠️ | Cardinality not observed | budget says 400 series, unverified against a real target |
| ⛔ | Nothing committed | 7 files in the working tree |

### Before the next session

1. **Commit the working tree.** A `/clear` now loses which files this session
   touched; the journal records the decisions, not the diff.
2. **Scrape a real target once** and check the series count against the
   cardinality budget in the journal.
```

La seconde section n'apparaît **que** s'il existe au moins une ligne `⛔` ou
`⚠️`. Une session propre s'arrête au tableau.

## La sémantique des quatre marqueurs, qui est le vrai sujet

Un emoji qui décore ne vaut rien. Ceux-ci portent une information que
l'utilisateur ne peut pas déduire autrement :

| | Sens | Condition d'emploi |
|---|---|---|
| ✅ | fait **et vérifié** | la commande a lancé quelque chose et vu le résultat. La colonne Detail cite la preuve |
| ⚠️ | fait, **non vérifié** | l'action est faite mais rien ne l'a prouvée, ou elle demande un jugement humain |
| ⛔ | **bloquant** | la session suivante partira sur un état faux si ce n'est pas traité |
| 📋 | prévu, pas commencé | reste au plan, n'appelle aucune action immédiate |

**La règle qui fait tout tenir : `✅` exige une preuve.** Si la commande n'a pas
réellement lancé le test, la ligne est `⚠️`, pas `✅`. C'est la même discipline
que le reste du dépôt applique aux garde-fous, et elle compte davantage ici :
une commande est de la prose exécutée par un modèle, donc rien ne l'empêche
structurellement d'affirmer un succès qu'elle n'a pas constaté. Le `### Notes`
du CHANGELOG le dit déjà noir sur blanc.

**`⛔` doit rester rare.** Il est réservé à ce qui casse la session suivante :
un arbre de travail non commité, un secret absent sans lequel le collecteur ne
tourne pas, un garde-fou rouge. Pas « pense à relire ». Si tout devient
bloquant, plus rien ne l'est.

## Le récapitulatif est une **vue**, pas une seconde source

C'est la contrainte de conception la plus importante, et elle vient d'un défaut
que ce dépôt a déjà produit trois fois : un dérivé écrit à côté de sa source,
puis corrigé d'un seul côté.

Tout ce qui apparaît dans le tableau doit **déjà** être dans
`docs/exporter-journal.md`. Le récapitulatif le rend lisible en fin de session,
il ne l'invente pas. Concrètement : la commande écrit le journal d'abord, puis
compose le tableau à partir de ce qu'elle vient d'écrire. Jamais l'inverse, et
jamais une ligne du tableau sans contrepartie au journal.

Corollaire : **aucun emoji dans le journal**. Le journal est un fichier de
données relu par la commande suivante, le récapitulatif est un rendu terminal.
Mélanger les deux rendrait le journal plus dur à reconcilier.

## Les quatre commandes, et leurs différences réelles

Vérifie-les dans le code plutôt que de me croire, mais de mémoire :

- **`/prometheus-exporter:design-exporter`** tourne **avant** qu'un dépôt
  existe. Pas d'état git à inspecter, pas de tests à lancer. Son
  récapitulatif est presque tout en `📋`, et son bloquant typique est « le
  brief est dans le répertoire courant, pas encore dans un dépôt ».
- **`/prometheus-exporter:new-prometheus-exporter`** produit un dépôt neuf avec
  un commit initial. Son bloquant typique concerne le remote et le premier push.
- **`/prometheus-exporter:add-collector`** et
  **`/prometheus-exporter:generate-dashboard`** travaillent sur un dépôt
  existant. Ce sont les deux qui peuvent réellement laisser un arbre sale.

Le tableau ne change pas de forme entre elles. Seules les lignes changent.

## Où ça vit

Une seule définition, consommée par les quatre. `references/project-journal.md`
possède déjà le format du journal, le tableau de propriété des sections et les
règles de réconciliation que les quatre commandes partagent : c'est le seul
endroit cohérent. Ajouter un cinquième fichier créerait exactement le type de
duplication que la règle « pas de code mort » refuse.

Chaque commande gagne alors un appel à cette définition en sortie, pas une
copie du gabarit.

## Contraintes dures

- **Anglais** pour tout artefact livré : `references/`, `commands/`.
- **Aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013)** sous `skills/` ni
  `commands/`.
- **Les commandes s'écrivent toujours `/prometheus-exporter:<nom>`**, y compris
  dans le titre du récapitulatif.
- **Conventional Commits avec scope.**
- Les emoji sont dans la **sortie terminal** des commandes, jamais dans un
  fichier échafaudé.

## Garde-fous

- `sh test/zero-source-grep.sh`
- `claude plugin validate .`
- `sh test/golden-smoke.sh --all` **si tu touches quoi que ce soit sous
  `assets/` ou `test/`**. Vérifie avec `git diff --name-only` et dis-le.

**Ne reflow jamais un frontmatter YAML** dans `commands/`. `claude plugin
validate` ne l'attrape pas : une passe de rewrap a déjà plié `argument-hint` et
`disable-model-invocation` dans le champ `description` sans que rien ne proteste.

## Ce que je ne veux pas

- Un récapitulatif qui affirme `✅` sur ce qu'il n'a pas lancé.
- Des sections vides affichées pour la symétrie.
- Un emoji par ligne juste pour faire joli : quatre marqueurs, pas douze.
- Une seconde liste de « ce qui a été fait » qui pourrait diverger du journal.

## Une vérification avant de me le proposer

Le récapitulatif n'est pas testable par `golden-smoke`, qui prouve les artefacts
côté échafaudage et rien de ce que les commandes racontent. Donc dis-moi
explicitement ce que tu as vérifié à la main, et sur quelle commande, plutôt que
de conclure sur un argument de construction.

Travaille sur une branche. Une PR.

---

# Second volet, à traiter dans la même session : « Safe to /clear » ment quand une question est ouverte

## Le défaut, constaté à l'usage

Une commande termine en demandant un arbitrage, puis imprime dans la foulée le
bloc « Safe to /clear now: everything above is in docs/exporter-journal.md ».
Les deux affirmations sont honnêtes séparément et incohérentes ensemble : le
`/clear` détruit exactement le contexte dans lequel l'arbitrage vivait.

## La cause, vérifiée dans le code

`references/project-journal.md:361-368` pose trois conditions au bloc :
l'argument est lu du journal, le garde-fou est nommé et a déjà tourné, rien
n'est invoqué automatiquement. **Aucune ne concerne une question restée
ouverte.**

La règle raisonne sur l'état du **disque**, et elle est juste sur ce terrain.
Mais un arbitrage en attente ne vit ni sur le disque ni dans le journal : le
journal enregistre les décisions **prises**, pas les décisions **pendantes**.
Il ne vit que dans la conversation, donc « everything above is in
docs/exporter-journal.md » est littéralement faux dans ce cas.

Le bloc est imprimé par les quatre commandes :
`commands/{new-prometheus-exporter,add-collector,generate-dashboard}.md` avec
la clause complète, `commands/design-exporter.md:274` sous une forme allégée.

## La règle à ajouter, et sa forme

Une quatrième condition : **le bloc ne s'imprime pas s'il reste une décision
à la charge de l'utilisateur.** Deux cas, à traiter différemment plutôt qu'à
confondre :

**La question change ce qui a été écrit** (un nom de métrique, un label, une
variante de collecteur). Elle se résout **avant** la sortie. Pas de bloc
`/clear`, pas de récapitulatif de clôture : la commande n'a pas fini. Elle pose
la question, attend, applique, puis conclut normalement.

**La question est réellement différable** (un budget de cardinalité à valider
contre une vraie cible, un choix qui n'engage que le prochain collecteur).
Alors elle doit **rejoindre le journal** avant que le bloc s'imprime. Une fois
écrite, le `/clear` redevient sûr, parce que la phrase du bloc redevient vraie.

Ce qui est interdit dans tous les cas : une question qui n'existe que dans la
conversation **et** un bloc qui déclare tout sauvegardé.

## Le lien avec le récapitulatif du premier volet

C'est la même chose vue de l'autre bout. Une décision en attente est un `⛔` par
définition : la session suivante partira sur un état faux si elle n'est pas
traitée. Donc, mécaniquement :

> **une ligne `⛔` dans le tableau et le bloc « Safe to /clear » sont mutuellement
> exclusifs.**

Implémente les deux volets ensemble, pas l'un après l'autre : la règle
d'exclusion est ce qui rend le récapitulatif fiable, et le récapitulatif est ce
qui rend la règle vérifiable d'un coup d'œil.

## Ce qu'il faut vérifier avant de conclure

- Le journal a huit en-têtes de section figés. Si le second cas ci-dessus exige
  d'y écrire une question pendante, c'est un **changement de format**, donc à
  traiter avec la règle des deux phases et non glissé au passage. Regarde
  d'abord si une section existante peut l'accueillir sans en ajouter une.
- `/prometheus-exporter:design-exporter` n'a pas de garde-fou à nommer et
  pointe vers le brief, pas vers le journal. La règle s'y applique quand même,
  sur le brief.
- Rien de tout ça n'est testable par `golden-smoke`, qui prouve l'échafaudage
  et pas ce que les commandes racontent. Dis explicitement ce que tu as vérifié
  à la main et sur quelle commande.
