# Relevé de friction — session tapelibrary exporter

Tenu **en direct pendant** la session d'usage, pas reconstitué après.

## Pourquoi ce fichier existe

Le plan initial était : à la fin de la session tapelibrary, relire tout
l'historique et en extraire les défauts. Ça ne marche pas. Une session longue
est compactée ou clearée avant la fin, et l'historique relisible n'est plus
celui qui s'est passé. Les défauts intéressants sont les petits frottements,
et c'est précisément ce qu'un résumé écrase.

Le journal de projet ne couvre pas ce besoin : il enregistre les **décisions**,
pas les **frictions**.

Donc : une ligne au moment où l'accroc arrive. Trente secondes sur le coup,
irrécupérable ensuite.

## Format

| # | Commande | Attendu | Obtenu | Contournement manuel |
|---|---|---|---|---|
| 1 | | | | |

Une ligne par accroc, même mineur. Surtout les mineurs : ce sont ceux qu'on
oublie et qui reviennent à chaque exporter.

## Pistes déjà ouvertes, à confirmer ou infirmer par le relevé

### `/prometheus-exporter:add-collector` propose des choix erronés

Hypothèse de l'utilisateur : un appel context7 avant de formuler les questions
supprimerait les propositions fausses.

À borner avant d'en faire une tâche, parce que context7 ne couvre pas tout :

- **Si les mauvaises propositions portent sur des formes d'API** (un type de
  collecteur, une option de `client_golang` ou d'`exporter-toolkit`, une
  convention Prometheus), alors oui, un check context7 les corrigerait, et la
  règle context7-d'abord du profil s'applique déjà sans être suivie ici.
- **Si elles portent sur la source de données elle-même** (quels endpoints,
  quels champs, quel format), context7 n'en sait rien. Le vrai correctif est
  alors en amont, probablement dans ce que
  `/prometheus-exporter:design-exporter` a capturé ou pas.

**Un seul exemple concret tranche.** Le noter en entier dans le tableau :
la question posée telle quelle, l'option fausse, et pourquoi elle était fausse.

### Le récapitulatif de fin de commande

Conçu dans `NEXT-PROMPT-session-exit-summary.md`. La session tapelibrary est le
premier vrai test de son utilité : noter à chaque fin de commande ce qu'on
aurait voulu y lire et qui n'y était pas.

## À la fin de la session

Analyser ce relevé plus la mémoire projet, classer chaque entrée en défaut du
plugin / manque de doc / attente mal calibrée, et n'en tirer que ce qui est
reproductible. Une friction vécue une fois n'est pas encore un défaut.

---

## Piste tranchée : les questions de nommage nom-contre-label

**Constat utilisateur.** `/prometheus-exporter:add-collector` demande
régulièrement s'il faut `<metric>_read` ou `<metric>{stat="read"}`. Idem pour
`temp` / `humidity`, `avg`, `percent`. Hypothèse initiale : un appel context7
avant de poser la question le corrigerait.

**Vérifié dans le code : non, et c'est plus intéressant que ça.**

`references/prometheus-principles.md:64-66` enseigne **déjà** la règle, en
citant `writing_exporters` : ne pas cuire une dimension de label dans le nom,
`http_requests_total{method="get"}` plutôt que `http_requests_get_total`,
**« except when the resulting cardinality genuinely requires separate
metrics »**. La doc a donc déjà tranché le cas `read`. La chercher ne
changerait rien : elle est là.

**Cause réelle 1 : la clause d'exception n'a aucun test.** « Sauf quand la
cardinalité l'exige vraiment » est un jugement sans procédure, et face à un
jugement sans procédure le modèle demande. La procédure officielle qui
trancherait est absente de la référence (grep : zéro occurrence de la règle
empirique) :

> soit `sum()`, soit `avg()` sur toutes les dimensions d'une métrique doit
> avoir un sens, même si ce n'est pas toujours utile.

**CORRECTION du 2026-08-03, après vérification.** J'avais écrit ici que la
règle tranchait mécaniquement : `sum(read + write)` étant un total d'I/O
valide, ce serait **un label**. C'est faux, et c'est le contre-exemple que ce
relevé était censé chercher.

Vérifié dans le clone de `node_exporter` v1.12.1 et confirmé indépendamment
via context7 (`/prometheus/node_exporter`) :

```
node_disk_read_bytes_total   node_disk_written_bytes_total
node_tape_read_bytes_total   node_tape_written_bytes_total   <- tapestats_linux.go
```

**Des noms séparés, aucun label `direction`**, y compris pour les lecteurs de
bande, c'est-à-dire le domaine exact de cette session.

Donc **la règle `sum()`/`avg()` est une condition nécessaire, pas une
procédure de décision** :

| Cas | `sum()` | Ce que la règle décide |
|---|---|---|
| temp / humidity | absurde | **tranché** : deux métriques |
| read / write | a un sens | **ne tranche rien** : un label serait permis, l'écosystème sépare quand même |

Ce qui départage read/write est ailleurs : la source expose deux compteurs
indépendants, et ce sont deux **mesures**, pas deux valeurs d'une dimension.
Le fait que node_exporter écrive `read` et `written`, pas `read` et `write`,
le trahit : ce ne sont même pas des chaînes parallèles.

`percent` reste couvert par la règle des unités de base, qui impose un ratio
0-1.

**Cause réelle 2 : la décision n'est retenue nulle part.** Le journal a bien
`Shared label vocabulary` sous `## Architecture decisions`, que
`references/project-journal.md:155` appelle « the highest-value line in the
file ». Mais elle liste des **noms de labels**, pas les arbitrages
nom-contre-label. Donc même si `/prometheus-exporter:design-exporter`
tranchait, `/prometheus-exporter:add-collector` n'aurait rien à hériter et
re-demanderait au collecteur suivant.

C'est exactement le même défaut que le `Safe to /clear` : une décision qui ne
vit que dans la conversation.

**Correctif proposé, en deux morceaux :**

1. Enseigner la règle `sum()`/`avg()` dans `prometheus-principles.md` comme
   **test de la clause d'exception**, en disant explicitement qu'elle ne
   tranche que dans un sens : `sum()` absurde impose des métriques séparées,
   `sum()` sensé n'impose rien.
2. **Ajouter le point de contrôle qui manquait** : avant de conclure, regarder
   ce que fait un exporter officiel du même domaine. context7 d'abord
   (`/prometheus/node_exporter` a répondu correctement au test), clone à froid
   sur tag en repli, discipline déjà écrite dans `re-sync.md` §1.3.
3. Faire appliquer les deux par `/prometheus-exporter:design-exporter`, **une
   fois par exporter**, et enregistrer les arbitrages dans le journal à côté du
   vocabulaire de labels, pour que `/prometheus-exporter:add-collector` les
   lise au lieu de demander. Si l'outil trouve mais que le journal ne retient
   pas, on a payé un appel réseau pour rien.

**Sans le point 2, le correctif serait pire que le défaut** : le plugin
répondrait « un label » avec assurance sur read/write, ce qui contredit
l'exporter canonique dans le domaine de cette session. Une question vaut mieux
qu'une réponse fausse et confiante.

**Sur le fetch au chargement du plugin : déconseillé.** Les conventions de
nommage Prometheus sont stables depuis dix ans. Un fetch par session ajoute
une dépendance réseau à une commande, et contredit la prémisse du plugin,
selon laquelle ce savoir est *enseigné* dans les références sur l'autorité de
`prometheus.io`. Le problème n'a jamais été l'accès à la doc.

**Ce que le relevé doit encore fournir :** un cas où ni la règle
`sum()`/`avg()` ni le précédent d'un exporter officiel ne tranchent. Le premier
contre-exemple cherché a été trouvé en une requête, donc il en reste
probablement d'autres.

---

## Retour de terrain : TLS, proxy, et ce qui manque au template

Remonté de la session tapelibrary, arrivée jusqu'au 401 sans avoir encore
observé une seule métrique sur une vraie machine.

### Le défaut rencontré, et pourquoi il est transférable

Un certificat sans `subjectAltName`. Aucun client Go ne peut le valider par le
nom depuis que Go 1.15 a retiré le repli sur le CN, et **`ca_file` n'y peut
rien** : le problème n'est pas la chaîne de confiance mais l'absence du nom
dans le certificat. Le seul contournement côté client est
`insecure_skip_verify: true`, donc un risque accepté, pas une configuration.

Le vrai correctif est sur la machine : réémettre le certificat avec un SAN.
Cinq minutes par librairie, et ça retransforme un risque accepté en connexion
vérifiée.

### Deux pièges de diagnostic, coûteux et non évidents

- **`curl -k` n'est pas un test valable pour un client Go.** OpenSSL honore
  encore le CN, donc curl réussit là où Go échoue. Un opérateur qui teste avec
  curl conclut que le certificat va bien.
- **`proxychains` ne proxifie pas un binaire Go, et le fait silencieusement.**
  Pas d'erreur, la connexion part en direct.

Aucun des deux n'est spécifique aux bibliothèques de bandes : ils frappent tout
exporter Go parlant à un équipement dont le certificat est ancien.

### Ce que le plugin ne dit nulle part, vérifié par grep

1. **`insecure_skip_verify` apparaît une seule fois**
   (`assets/config.example.yml.tmpl:97`), commenté à `false`, sans un mot sur
   quand on le bascule, ce qu'on accepte en le faisant, ni comment documenter
   ce choix. Or la session a dû écrire ce bloc de justification à la main.
2. **`subjectAltName`, le CN, et le retrait du repli en Go 1.15 : zéro
   occurrence** dans tout `skills/`. C'est le piège qui a coûté le plus de
   temps et le plugin n'en dit rien.
3. **`proxy_url` n'apparaît pas dans `config.example.yml.tmpl`**, alors que le
   champ existe en amont (`prometheus/common@v0.70.1/config/http_config.go:1678`)
   et que `http_client_config` est justement un `promconfig.HTTPClientConfig`.
   La fonctionnalité est là, l'exemple ne la montre pas, donc elle est
   invisible pour qui ne lit pas la source d'une dépendance.

### Correctif proposé

Étendre le bloc `tls_config` commenté de `config.example.yml.tmpl` avec les
trois lignes manquantes (`proxy_url` à côté, `insecure_skip_verify` avec sa
contrepartie), et ajouter à `references/security-and-hardening.md` un
paragraphe court sur le certificat sans SAN : pourquoi `ca_file` ne sauve pas,
ce que `insecure_skip_verify` concède réellement, et que le correctif est
côté équipement.

Les deux pièges de diagnostic ont leur place dans le
`docs/validation-checklist.md` échafaudé, pas dans une référence : ce sont des
gestes d'opérateur, pas des principes.

### Ce que ça valide au passage

La conception du récapitulatif de fin de commande
(`NEXT-PROMPT-session-exit-summary.md`) prenait comme exemple inventé
`⚠️ Cardinality not observed | budget says N series, unverified against a real
target`. C'est arrivé pour de vrai : le journal de la session tapelibrary
précise que tous les chiffres du budget restent dérivés des fixtures. Le
marqueur `⚠️` a donc bien un cas d'usage réel, et pas seulement théorique.

---

## Le défaut le plus grave du terrain : un collecteur de fond est toujours « sain »

### Ce qui s'est passé

19 collecteurs verts, zéro donnée. Le critère de validation était
`collector_success >= 1`, et un collecteur de fond **émet toujours au moins sa
jauge de fraîcheur**. Il est donc sain à vide, par construction. La panne est
restée invisible.

### Ce n'est pas propre à cet exporter, c'est livré

Vérifié par grep sur les templates :

- `assets/docs/validation-checklist.md.tmpl` vérifie `collector_success`
  (lignes 175, 184-185) et ne mentionne **jamais** de jauge de fraîcheur :
  zéro occurrence de `freshness` ou `last_refresh`.
- `assets/monitoring/prometheus/alerts.yml.tmpl` alerte sur
  `collector_success == 0` (ligne 92) et `absent(...)` (ligne 75).
  **Aucune alerte de péremption.**

Donc le plugin livre les trois pièces suivantes, incohérentes entre elles :
une variante de collecteur de fond qui émet toujours sa jauge, une checklist
qui ne la regarde pas, un fichier d'alertes qui ne s'en sert pas. Tout exporter
échafaudé avec `--variant background` peut afficher une flotte verte sur des
données mortes.

### Le lien avec la couture de résultat, en cours

Le commentaire écrit le 2026-08-02 dans
`assets/code/{http,cli}/variants/background_collector.go.tmpl` dit :

> Alert on the freshness gauge going stale, not on collector_success.

Le terrain valide l'assertion, et montre en même temps qu'**aucun artefact
livré ne soutient la pratique recommandée**. Le commentaire pointe dans le
vide. C'est dans le périmètre de la couture, qui porte précisément sur ce que
« santé d'un collecteur » veut dire, donc à traiter dans la même PR.

### Correctif

1. Une règle d'alerte de péremption dans `alerts.yml.tmpl`, conditionnée à la
   présence de la jauge, comme les autres règles flavor-spécifiques déjà
   livrées commentées.
2. Une étape de la checklist qui vérifie la **valeur** de la jauge, pas
   seulement `collector_success`, avec la raison écrite noir sur blanc : un
   collecteur de fond est sain à vide.
3. Le commentaire de la variante pointe alors vers quelque chose de réel.

### La leçon transférable, telle que le terrain l'a formulée

Trois bugs d'affilée — authentification, timeouts, `--version` — qu'aucun des
337 tests ni `make check` ne pouvaient voir, **parce qu'ils testaient tous du
code contre des doublures**.

Et le trou n'était pas un manque de couverture : la checklist appelait déjà
`--version` avec le format attendu décrit en détail. Elle aurait attrapé le
bug. **Elle n'a simplement jamais été jouée.**

C'est le même motif que `test/golden-smoke.sh:604`, qui lance `--help` en
passant toujours `--config.file` et dont le commentaire (ligne 601) montre
qu'il connaissait l'ordonnancement : le garde-fou avait contourné le défaut au
lieu de le voir.

---

## Deux défauts de plus, remontés par le tri du journal

### 1. La section « Open questions » pourrit par conception

Après quelques jours d'usage : 39 entrées, 643 lignes, dont **4 seulement
marquées résolues** alors qu'un tiers l'était réellement. Trois natures
mélangées sans distinction visuelle — questions réellement ouvertes, questions
résolues enrichies au lieu d'être retirées, constats de session.

Conséquence mesurée sur le terrain : une entrée consignait comme blocage vivant
un fichier de règles entier rejeté par Prometheus, ce qui aurait rendu mortes
toutes les alertes ajoutées depuis. **Le correctif avait en fait été appliqué.**
Une todo list qu'on ne peut plus lire est pire qu'absente : elle fait croire à
des blocages qui n'existent plus.

**Vérifié côté plugin :** `references/project-journal.md:151` définit
`## Open questions / assumptions`, ligne 176 la déclare `mutable` et complétée
par les quatre commandes. **Aucune convention de statut.** Tout journal
échafaudé accumulera le même tas indifférencié.

**Correctif, tel que le terrain l'a résolu et qui vaut d'être généralisé :**
pas de second fichier — deux endroits à tenir garantit la dérive, et le journal
doit rester la source unique. Un tag de statut par entrée, posé sur place, plus
un index en tête. `grep "\[OPEN\]"` répond alors à « qu'est-ce qui reste » sans
lire la section entière.

Trois tags suffisent : `[OPEN]`, `[RESOLVED]`, `[ACCEPTED]`. Le troisième est le
gain discret : ce sont des décisions déjà prises qu'on relisait comme une todo
list.

### 2. Un exporter généré ne peut pas valider ses propres règles

**Vérifié : `promtool` n'apparaît pas une seule fois dans
`assets/Makefile.tmpl`.** Le harnais du plugin l'utilise 56 fois dans
`test/golden-smoke.sh`, donc le *template* est validé, mais le dépôt généré
n'a aucun moyen de vérifier `monitoring/prometheus/alerts.yml` après que son
auteur l'a édité. Or le plugin lui dit explicitement de décommenter et adapter
des règles.

**Et le contrôle doit être le bon.** Valider expression par expression ne suffit
pas : le terrain a eu 67 expressions valides et croyait le fichier sain, alors
que seul un chargement complet (`rulefmt.ParseFile`, ce qu'utilise
`promtool check rules`) voit aussi les **templates d'annotations**
(`$labels.__name__`, `humanizeTimestamp`). C'est un contrôle strictement plus
fort.

**Coût à évaluer avant de foncer :** l'image d'outils est un
`golang:<ver>-alpine`, donc ajouter `promtool` à `make check` veut dire y
embarquer un binaire de plus, ou une seconde image. Ce n'est pas gratuit et ça
touche `scripts/docker/tools/Dockerfile.tmpl`, qui est la source unique de la
version Go. À chiffrer, pas à improviser.
