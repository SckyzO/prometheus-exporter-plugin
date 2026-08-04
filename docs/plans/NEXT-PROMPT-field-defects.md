# Prompt pour la prochaine session : les défauts remontés du terrain

Copie tout ce qui suit la ligne de séparation.

---

Corrige les défauts que l'usage réel du plugin a révélés. Ils sont tous
consignés, tous vérifiés contre le code, et tous accompagnés de leur emplacement
exact : ne les re-dérive pas, vérifie-les et traite-les.

## Lis ça en premier, dans cet ordre

1. `docs/plans/README.md` : l'index, et surtout où vit le travail ouvert.
2. `docs/plans/2026-08-03-friction-log-tapelibrary.md` **en entier**. C'est la
   source de cette tâche. Il contient les constats, leur vérification, et une
   correction que j'ai dû faire à ma propre recommandation.
3. `docs/plans/2026-08-01-session-handoff-2.md` : l'état du dépôt.
4. Le `CLAUDE.md` racine, en entier, avant la première modification.

## L'état, à vérifier en ouvrant

Deux PRs étaient vertes et non mergées à la clôture de la session précédente :
**#29** (la couture de résultat des collecteurs) et **#30** (le suivi git de
`docs/plans/`). Si elles ne sont pas mergées, merge-les d'abord : #29 a déjà
corrigé un des défauts de la liste ci-dessous et le reste s'appuie dessus.

## Ce qu'il y a à faire, groupé et ordonné

### PR A — les trois manques TLS/proxy, plus deux pièges d'opérateur

Le plus rentable : ça vient d'une douleur réelle, ça coûte de la prose, et ça
part dans chaque exporter échafaudé.

| Manque | Vérifié à |
|---|---|
| `insecure_skip_verify` apparaît une seule fois, commenté à `false`, sans un mot sur ce qu'on concède en le basculant | `assets/config.example.yml.tmpl:97` |
| `subjectAltName`, le CN, le retrait du repli en Go 1.15 : **zéro occurrence** dans tout `skills/` | grep |
| `proxy_url` absent de l'exemple alors que le champ existe en amont | `prometheus/common@v0.70.1/config/http_config.go:1678` |

Le troisième est le plus bête : `http_client_config` **est** un
`promconfig.HTTPClientConfig`, donc `proxy_url` marche déjà. Il est juste
invisible pour qui ne lit pas la source d'une dépendance.

Le second est le plus coûteux en temps perdu. Un certificat sans `subjectAltName`
n'est validable par aucun client Go depuis que Go 1.15 a retiré le repli sur le
CN, et **`ca_file` n'y peut rien** : le problème n'est pas la chaîne de
confiance mais l'absence du nom. Le seul contournement côté client est
`insecure_skip_verify: true`, donc un risque accepté, pas une configuration. Le
vrai correctif est de réémettre le certificat côté équipement. Dis-le.

Ajoute aussi à `assets/docs/validation-checklist.md.tmpl` deux pièges de
diagnostic, qui sont des gestes d'opérateur et pas des principes, donc leur
place est là et pas dans une référence :

- **`curl -k` n'est pas un test valable pour un client Go.** OpenSSL honore
  encore le CN, donc curl réussit là où Go échoue, et l'opérateur conclut que
  le certificat va bien.
- **`proxychains` ne proxifie pas un binaire Go, et le fait silencieusement.**
  Pas d'erreur, la connexion part en direct.

Aucun des deux n'est spécifique à un domaine : ils frappent tout exporter Go
parlant à un équipement dont le certificat est ancien.

### PR B — les questions de nommage que `/add-collector` repose sans cesse

Lis **la section « Piste tranchée » du relevé en entier**, y compris la
correction que j'ai dû y faire, avant d'écrire une ligne. J'y ai d'abord
recommandé une règle qui donne une réponse **fausse** sur le cas le plus
courant.

Le constat : la commande demande sans cesse s'il faut `<metric>_read` ou
`<metric>{stat="read"}`, et pour `temp`/`humidity`, `avg`, `percent`.

La cause n'est pas un manque de doc. `references/prometheus-principles.md:64-66`
enseigne déjà la règle en citant `writing_exporters`, avec une clause
d'exception, **et cette clause n'a aucun test**. Face à un jugement sans
procédure, le modèle demande.

Le correctif tient en trois morceaux, et **le deuxième est indispensable** :

1. Enseigner la règle empirique officielle (« soit `sum()`, soit `avg()` sur
   toutes les dimensions doit avoir un sens ») **en disant explicitement
   qu'elle ne tranche que dans un sens** : `sum()` absurde impose des métriques
   séparées, `sum()` sensé n'impose rien.
2. Ajouter le point de contrôle qui manquait : **regarder ce que fait un
   exporter officiel du même domaine avant de conclure.** context7 d'abord
   (`/prometheus/node_exporter` a répondu correctement au test), clone à froid
   sur tag en repli, discipline déjà écrite dans `re-sync.md` §1.3.
3. Faire appliquer les deux par `/prometheus-exporter:design-exporter`, **une
   fois par exporter**, et enregistrer les arbitrages dans le journal à côté du
   vocabulaire de labels, pour que `/prometheus-exporter:add-collector` les
   lise au lieu de redemander.

**Sans le point 2, le correctif est pire que le défaut.** La règle seule dit
« un label » pour read/write, alors que `node_exporter` livre
`node_tape_read_bytes_total` et `node_tape_written_bytes_total`, en noms
séparés, dans le domaine exact où la question s'est posée. Une question vaut
mieux qu'une réponse fausse et confiante.

### PR C — la section « Open questions » du journal pourrit par conception

`references/project-journal.md:151` définit `## Open questions / assumptions`,
et la ligne 176 la déclare `mutable`, complétée par les quatre commandes.
**Aucune convention de statut.** Mesuré sur le terrain après quelques jours :
39 entrées, 643 lignes, dont 4 marquées résolues alors qu'un tiers l'était.

Conséquence réelle, pas théorique : une entrée consignait comme blocage vivant
un fichier de règles entier rejeté par Prometheus. Le correctif avait en fait
été appliqué depuis longtemps.

Correctif, tel que le terrain l'a résolu : **pas de second fichier** — deux
endroits à tenir garantit la dérive. Trois tags posés sur place, `[OPEN]`,
`[RESOLVED]`, `[ACCEPTED]`, plus un index en tête. `grep "\[OPEN\]"` répond
alors à « qu'est-ce qui reste ».

**Attention :** le journal a huit en-têtes de section figés et une commande qui
cherche `## Cardinality budget` doit trouver cette chaîne exacte. Un tag par
entrée ne touche pas les en-têtes, donc ça devrait passer, mais vérifie-le
plutôt que de le supposer.

### PR D — `promtool` absent de `make check`, à chiffrer avant de coder

**Vérifié : zéro occurrence dans `assets/Makefile.tmpl`.** Le harnais du plugin
l'utilise 56 fois dans `test/golden-smoke.sh`, donc le *template* est validé,
mais le dépôt généré n'a aucun moyen de vérifier `monitoring/prometheus/alerts.yml`
après que son auteur l'a édité. Or le plugin lui dit explicitement de
décommenter et d'adapter des règles.

Et le contrôle doit être le bon : valider expression par expression ne suffit
pas. Le terrain a eu 67 expressions valides et croyait le fichier sain, alors
que seul un chargement complet (`rulefmt.ParseFile`, ce qu'utilise
`promtool check rules`) voit aussi les **templates d'annotations**.

**Chiffre d'abord.** L'image d'outils est un `golang:<ver>-alpine`, donc
ajouter `promtool` veut dire y embarquer un binaire de plus ou une seconde
image, et ça touche `scripts/docker/tools/Dockerfile.tmpl` qui est la **source
unique de la version Go** dans tout le projet. Présente-moi le coût avant
d'écrire quoi que ce soit. Si c'est cher, dis-le et propose l'alternative.

### PR E — un exporter échafaudé ne sait pas quelle version se donner

**Vérifié : aucune consigne nulle part.** Zéro occurrence de `v0.1.0` ou de la
moindre indication de version de départ dans
`assets/docs/release-process.md.tmpl`, `assets/CHANGELOG.md.tmpl` ou
`commands/new-prometheus-exporter.md`. Le CHANGELOG échafaudé cite SemVer et ne
dit jamais où commencer, alors qu'il déroule ensuite une procédure de release
complète.

**Ce qu'il faut écrire : démarrer à `v0.1.0`, jamais à `1.0.0`.** Et la raison
compte plus que la règle, parce qu'elle est spécifique aux exporters.

En SemVer, `1.0.0` est une promesse de stabilité d'API. Pour un exporter,
**l'API ce sont les noms de métriques et les labels** — précisément ce qui bouge
pendant qu'on ajoute des collecteurs et qu'on découvre la cible. Partir en 1.0
avant d'avoir observé la vraie cardinalité et confronté les noms au réel, c'est
se verrouiller sur des noms qu'on voudra changer, et chaque changement devient
alors un breaking change qui casse les dashboards et les alertes des opérateurs.

Le cas qui a soulevé la question est net : dix-huit collecteurs, **aucune
métrique encore observée sur une vraie machine**, budget de cardinalité dérivé
des fixtures. Un `1.0.0` là serait une promesse intenable.

La 1.0 se pose quand la surface de métriques a cessé de bouger et qu'elle a
tourné assez longtemps contre du réel pour qu'on fasse confiance aux noms. Dis
ce critère, pas seulement le numéro de départ.

Place naturelle : `assets/docs/release-process.md.tmpl`, qui possède déjà la
procédure, avec un renvoi depuis `assets/CHANGELOG.md.tmpl`. Vérifie qu'aucun
autre artefact ne contredit déjà la règle avant d'écrire.

## Contraintes dures

- **Anglais** pour tout artefact livré. `docs/design/` et `docs/plans/` sont mon
  historique de travail et peuvent rester en français.
- **Aucun tiret cadratin (U+2014) ni demi-cadratin (U+2013)** sous `skills/` ni
  `commands/`, ni dans `README.md` ni dans `docs/*.md`. Vérifie ton propre diff
  avant de committer : j'en ai introduit un la semaine dernière et c'est ma
  propre vérification qui l'a attrapé.
- **Les commandes s'écrivent toujours `/prometheus-exporter:<nom>`.**
- **Conventional Commits avec scope.** Jamais de mention d'assistance IA.
- **Aucune source de données, préfixe de métrique, chemin d'endpoint ou
  identité de mainteneur en dur** dans un template : ce sont des `@@VAR@@`.
- **Ne reflow jamais un frontmatter YAML** dans `commands/`.
  `claude plugin validate` ne l'attrape pas.

## Garde-fous

- `sh test/zero-source-grep.sh`
- `claude plugin validate .`
- `sh test/golden-smoke.sh --all` **si tu touches quoi que ce soit sous
  `assets/` ou `test/`**. Compte ~10 min. Vérifie avec `git diff --name-only`
  ce que tu as réellement modifié, et dis-le.

**Ne déclare jamais un garde-fou vert sans l'avoir lancé tel quel.**

## Pièges de méthode, tous constatés cette semaine

- **Vérifier le code ne protège pas d'en tirer la mauvaise conclusion.** Trois
  fois, un raisonnement propre à partir d'une lecture correcte a donné une
  conclusion fausse : `ErrNoData`, trois affirmations « le plugin fait mieux »,
  et la règle read/write. Confronte à un second signal.
- **Les affirmations flatteuses et les négatifs universels sont les moins
  fiables** : personne n'a intérêt à les challenger. Un négatif universel se
  réfute par un seul contre-exemple, alors cherche-le.
- **Corrige la source, pas seulement le dérivé.** Une même règle vivait dans
  huit fichiers la dernière fois ; en corriger trois a laissé cinq mensonges
  livrés. Grep le dépôt entier avant de conclure qu'une règle est à jour.
- **Un garde-fou peut contourner un défaut au lieu de le voir.**
  `golden-smoke.sh:604` passe toujours `--config.file`, ce qui a masqué un
  `--version` cassé pendant des semaines. Quand tu ajoutes une assertion,
  demande-toi ce qu'elle ne peut pas voir.

## Une relecture séparée, avant de me présenter quoi que ce soit

Fais relire le diff par un sous-agent dédié qui ne l'a pas écrit. Consigne
prioritaire : chercher la prose devenue fausse **ailleurs** dans le dépôt, et
toute affirmation « ça ne change rien pour les exporters existants » qui ne
serait pas prouvée.

Sur les trois dernières sessions, cette passe a tué un résultat principal,
réfuté trois affirmations flatteuses, et trouvé un blocage qui aurait cassé le
build de tout exporter échafaudé avant le changement. Elle n'est pas
décorative.

Travaille sur une branche. Une PR par groupe ci-dessus, dans l'ordre A, B, C,
puis D après chiffrage.
