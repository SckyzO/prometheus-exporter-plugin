# Audit du CHANGELOG — writing-docs + humanizer

Date : 2026-07-31. Portée : `CHANGELOG.md` entier (9 sections, 0.1.0 → 0.8.0).
Méthode : règle de fer `writing-docs` (chaque fait concret vérifié contre le
code, jamais contre le prompt ni contre une autre prose), puis passe
`humanizer` sur le registre.

Le registre visé est technique et référentiel. La section « personnalité » de
`humanizer` ne s'applique donc pas : neutre et plat *est* la bonne voix
humaine ici. Aucune opinion ni première personne à injecter.

---

## 1. Défauts factuels (writing-docs)

Deux affirmations fausses, toutes deux dans la section `0.8.0`, toutes deux
vérifiées contre `skills/prometheus-exporter/references/project-journal.md`.

### F1 — « All four commands read it on entry » (ligne 13)

> **A project journal, `docs/exporter-journal.md`, in every scaffolded
> exporter.** All four commands read it on entry and complete it on exit

Faux pour deux commandes sur quatre.

| Preuve | Contenu |
|---|---|
| `project-journal.md:232` | « `/new-prometheus-exporter` **has no journal to read on entry** » |
| `project-journal.md` §Lifecycle | `/design-exporter -> ./exporter-design-brief.md (cwd, name unchanged)` |

`/design-exporter` s'exécute avant qu'aucun dépôt n'existe : il écrit un
brief dans le répertoire courant, il ne lit pas un journal commité.
`/new-prometheus-exporter` n'a rien à lire non plus : il déplace le brief
après le scaffold.

La phrase se contredit elle-même deux lignes plus bas, qui dit correctement
« `/design-exporter` **opens it as the architecture brief** ».

**Correction proposée :**

> `/add-collector` and `/generate-dashboard` read it on entry and complete
> it on exit, and the two commands that precede them create it:

### F2 — « Eight frozen section headers with one owner each » (ligne 20)

Vrai de la colonne *Created by* uniquement. La table
`project-journal.md:162-171` a deux colonnes de propriété, et trois lignes
contredisent « un propriétaire chacune » :

| Section | Completed by |
|---|---|
| `## Provenance` | **nobody** |
| `## Session log` | **all four** |
| `## Open questions / assumptions` | **all four** |

**Correction proposée :** « Eight frozen section headers, each created by
exactly one command ».

### Ce que ces deux défauts ont en commun

**Ce sont exactement les deux erreurs que la relecture à yeux neufs avait
attrapées dans le README.** Le README a été corrigé, la source ne l'a pas
été : le CHANGELOG était ma source pour rédiger le README, donc les deux
fautes viennent d'ici et y sont restées.

C'est le vrai enseignement de cet audit. Corriger un dérivé sans remonter à
la source garantit la réapparition du défaut à la prochaine rédaction qui
s'appuiera dessus.

---

## 2. Affirmations vérifiées correctes

Contrôlées et non retenues, listées pour que le prochain audit ne les
recontrôle pas :

| Affirmation | Preuve |
|---|---|
| « brings it into the repository **in the initial commit** » | `project-journal.md:233-234` : écrit après le scaffold et **avant** ce commit |
| « this skill's **twelfth** reference » | 12 fichiers dans `references/` |
| « `FileSecret.Immutable` reports false » | `http_config.go:817` |
| label `outcome` = `success`/`error`, même convention que `CommandDuration` | `code/cli/execute.go.tmpl:13` |
| La section `### Notes` sur la couverture de test | Exacte, et **plus prudente que ne l'était le README** : elle énumère les artefacts scaffold sans y ranger le journal |

La section `### Notes` mérite d'être signalée à l'endroit : elle dit
explicitement ce que la release ne prouve pas, n'y range pas le journal parmi
les artefacts couverts par la matrice golden, et écrit « No test in this
repository can exercise any of it, and none is claimed to ». C'est le
paragraphe le plus honnête du fichier.

---

## 3. Prose (humanizer)

### Tirets cadratins : rien à faire

| Section | Cadratins |
|---|---|
| 0.4.0 → **0.8.0** | **0** |
| 0.1.0 → 0.3.0 | 19 au total |

Les 19 sont tous antérieurs à la passe de dé-dashage, dans des sections
publiées. Aucun dans les cinq sections récentes. Ne pas réécrire un
historique publié pour une contrainte adoptée après coup.

### Le vrai défaut : la longueur de phrase, et elle empire

Phrase la plus longue, par section :

| Section | Mots |
|---|---|
| 0.8.0 | **148** |
| 0.7.0 | 136 |
| 0.6.0 | 62 |
| 0.5.0 | 101 |
| 0.4.0 | 80 |

Deux passages concentrent le problème dans `0.8.0` :

- **La puce du journal** (lignes 12-31) : vingt lignes sans respiration, avec
  une énumération à quatre branches enchâssée dans une phrase qui portait
  déjà deux propositions.
- **La puce `request_wait_seconds`** (lignes 55-65) : une seule phrase de
  onze lignes, qui empile la raison du report depuis v0.7.0, le comportement
  d'`Acquire`, la convention de label, l'initialisation au package init, et
  le comportement d'un `HistogramVec` face à une combinaison jamais observée.

Ce n'est pas un tell d'IA, c'est de la densité. Mais un CHANGELOG se lit en
diagonale au moment d'un upgrade, et une phrase de 148 mots ne se lit pas en
diagonale.

### Faux positifs : ne pas corriger

- **Les en-têtes gras en tête de puce** (`humanizer` §16). Style maison,
  constant sur les neuf sections. La cohérence prime sur la règle générique.
- **« do exactly what they did before this release »** (§30, prose ancrée sur
  le diff). `humanizer` exempte explicitement les changelogs : un journal de
  versions *est* par nature relatif à une version.
- **Le ton neutre et sans opinion** (§ personnalité). Correct pour ce
  registre, à préserver.

### Signes d'écriture humaine à protéger

`humanizer` demande de les préserver, et ce fichier en est dense : le
comportement de disparition de série d'un `HistogramVec`, `Acquire` qui
observe sur les deux chemins, la fenêtre de péremption de cinq minutes, le
raisonnement pré-1.0 sur les migrations retirées en v0.6.0. Détail
spécifique, difficile à fabriquer, et arbitrages assumés plutôt que
résolus proprement. Un aplatissement stylistique détruirait ça.

---

## 4. Recommandation

1. **Corriger F1 et F2** dans la section `0.8.0`. Ce sont des faits faux sur
   le comportement des commandes, dans la section la plus lue du fichier.
2. **Scinder les deux puces trop denses**, sans les raccourcir : même
   contenu, phrases coupées.
3. **Ne rien toucher** dans `0.1.0` → `0.3.0`.

Note sur le tag : `v0.8.0` est déjà posé. Corriger le CHANGELOG sur `main`
après coup fait diverger `git show v0.8.0:CHANGELOG.md` de `main`. C'est
normal pour un changelog et ça ne justifie pas de déplacer un tag publié,
mais autant le savoir avant de le constater.
