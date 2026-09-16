# forensic

Relevé forensique **lecture seule** sur poste étudiant.

Établit si un rendu, ou une implémentation du sujet, existait sur la machine
**avant** l'ouverture de l'épreuve.

> Le script **ne conclut pas**. Il produit des faits horodatés — Access, Modify,
> Change, Birth — des empreintes et une chronologie. La conclusion est une décision
> humaine, prise en soutenance, **avec l'étudiant**.

## Lancer

```bash
git clone https://github.com/edwinfranck/forensic.git
cd forensic
chmod +x forensic.sh
sudo ./forensic.sh --start '2026-09-16 10:00'
```

`--start` est la seule option obligatoire : sans l'heure d'ouverture de l'épreuve,
aucun classement d'antériorité n'est possible.

Le relevé affiche sa progression phase par phase — il ne reste jamais muet — et se
termine sur un tableau de synthèse.

### Ciblage automatique

Passez le dépôt rendu par l'étudiant : le script en déduit seul les noms de fichiers
et les symboles à rechercher.

```bash
sudo ./forensic.sh --start '2026-09-16 10:00' --repo /home/etudiant/mon-rendu
```

Sans `--repo`, il reste **générique** : sources tous langages, archives, PDF.

### Options

| Option | Rôle |
|---|---|
| `--start TS` | **obligatoire** — ouverture de l'épreuve (tout format `date -d`) |
| `--end TS` | fin de l'épreuve (défaut : maintenant) |
| `--user NAME` | compte examiné (défaut : `SUDO_USER`) |
| `--repo DIR` | dépôt rendu — déduit noms et signatures. Répétable |
| `--name MOTIF` | motif de nom supplémentaire, répétable |
| `--signature MOT` | motif de contenu supplémentaire, répétable |
| `--root DIR` | racine supplémentaire, répétable (clé de l'étudiant, disque externe) |
| `--all` | balayer tout le disque (défaut : zones étudiant) |
| `--out DIR` | dossier du rapport — sur la clé USB du staff de préférence |
| `--year YYYY` | année attendue dans l'en-tête EPITECH (défaut : année de `--start`) |
| `--module CODE` | module attendu, ex. `G-CPE-210` |
| `--deep` | inodes supprimés (`debugfs`), journal ext4, instantanés btrfs |
| `--quick` | saute la recherche par contenu (~1 min au lieu de ~10) |

## Avant de lancer — non négociable

| Règle | Pourquoi |
|---|---|
| L'étudiant est **présent et informé** | un relevé fait à son insu n'est pas opposable |
| Un **second membre du staff** assiste | un témoin, deux signatures au procès-verbal |
| Le rapport s'écrit **hors du disque du poste** (`--out /media/...`) | on n'ajoute pas d'écriture sur la pièce |
| On ne supprime, ne déplace, ne corrige **rien** | le script est en lecture seule, restons-le |

Si l'enjeu est disciplinaire lourd, ne pas travailler sur la machine vivante : faire
une image disque depuis un live USB et analyser la copie. Chaque démarrage écrase des traces.

## Marqueurs de provenance dans le code

Le relevé lit aussi **le code lui-même**. Trois marqueurs, dont aucun ne conclut seul :
c'est leur **concentration sur un même fichier ou un même auteur** qui parle.

| Marqueur | Ce qu'il signale |
|---|---|
| `ANNEE-INATTENDUE` | l'en-tête `EPITECH PROJECT, AAAA` ne porte pas l'année attendue. Le tampon est posé par le greffon d'éditeur **à la création du fichier** : une autre année veut dire que le fichier, ou le modèle dont il est issu, est plus ancien. |
| `MODULE-INATTENDU` | l'en-tête porte un autre module que celui de l'épreuve. Un `B-CPE-210` dans un projet `G-CPE-210` vient d'un modèle recopié. |
| `PREFIXE-FT` | `ft_*` est la convention de nommage de **42** ; Epitech utilise `my_*`. |

```bash
sudo ./forensic.sh --start '2026-09-16 10:00' --year 2026 --module G-CPE-210
```

Les fichiers sont classés **par nombre de marqueurs décroissant** : celui qui les porte
tous les trois arrive en tête.

```
ANNEE  MODULE        ft_  my_  CHEMIN / ANOMALIES
2024   B-CPE-210       3    0  .../stumper6-4/utils.c
                                 -> [3 marqueur(s)] ANNEE-INATTENDUE(2024),MODULE-INATTENDU(B-CPE-210),PREFIXE-FT(3)
```

## Ce que produit le relevé

```
analyse.txt        LE RÉSUMÉ À LIRE — texte brut, tout y est
RAPPORT.md         le document détaillé, à joindre au dossier
chronologie.tsv    une ligne par fichier candidat, à ouvrir en tableur
candidats.txt      liste brute des chemins retenus
copies/            historiques shell, corbeille, bases VS Code et navigateurs
```

`analyse.txt` reprend en cinq sections : les dates des fichiers, les marqueurs de
provenance, les candidats les plus parlants, ce que le relevé n'établit pas, et les
empreintes pour le procès-verbal.

### Les quatre dates

| Date | `stat` | Ce qu'elle marque |
|---|---|---|
| **Access** | `%x` | dernière **lecture** du contenu |
| **Modify** | `%y` | dernière **écriture du contenu** |
| **Change** | `%z` | dernière écriture des **métadonnées** : renommage, droits, déplacement |
| **Birth** | `%w` | **création de l'inode** sur cette partition |

`Birth` n'existe que sur ext4, btrfs, xfs (v5) et f2fs. Sur une clé FAT, il n'y en a pas.

### Les indices

| Indice | Lecture |
|---|---|
| `INODE-ANTERIEUR-EPREUVE` | le fichier **était déjà sur la machine** avant l'épreuve |
| `CONTENU-ANTERIEUR-EPREUVE` | le contenu a été **écrit** avant l'épreuve |
| `IMPORTE-DATES-PRESERVEES` | `Modify` **plus ancien que** `Birth` : contenu plus vieux que l'inode. Signature d'un `cp -p`, `tar -x`, `rsync -a`, `git clone`, copie depuis une clé. **Le fichier a été apporté, pas écrit sur place.** |
| `ECRIT-PENDANT-EPREUVE` | contenu écrit dans la fenêtre — le cas normal |
| `MODIFIE-APRES-CREATION` | retouché après création — le cas normal |
| `METADONNEES-APRES-ECRITURE` | `Change` > `Modify` : **renommé, déplacé ou droits changés** |

Le cas le plus parlant n'est pas un `Birth` ancien — c'est **`IMPORTE-DATES-PRESERVEES`**.
Un étudiant qui écrit son code pendant l'épreuve produit des fichiers dont `Modify` suit
`Birth` de quelques minutes. Un fichier dont le contenu est daté de juin alors que l'inode
est né le jour de l'épreuve n'a pas été écrit ce jour-là.

### La colonne `zone`

`ETUDIANT` : le fichier est dans le domicile du compte, `/tmp`, `/media`, `/mnt`, ou lui
appartient. `SYSTEME` : `/usr`, `/opt`, `/var`, `/etc`…

**Seule la zone étudiant se lit.** Sans ce tri, une Ubuntu ordinaire remonte des centaines
de `main.c` livrés par cmake ou les paquets de développement, tous « antérieurs » et tous
sans le moindre rapport.

## Objections à prévoir

Elles sont légitimes, et le rapport les reprend.

- **« J'ai copié mes fichiers depuis ma clé. »** Recevable. Ce qui compte est la date du
  **contenu** sur la clé : la relever aussi (`--root /media/...`).
- **« Un `cp -p` garde les vieilles dates. »** Exact — c'est précisément ce que
  `IMPORTE-DATES-PRESERVEES` désigne. Il ne dit pas « fraude », il dit « ce contenu est
  plus vieux que son inode ».
- **« L'horloge était fausse. »** Vérifiable : le rapport relève `timedatectl` et les
  changements d'heure au journal.
- **« Ces dates viennent de votre scan. »** Non pour `Modify`, `Change` et `Birth`, qu'une
  lecture ne touche pas. Possiblement oui pour `Access` : le rapport le dit.

**L'absence de trace ne prouve rien.** Un `rm` suivi d'écritures, ou un travail fait sur
une autre machine, ne laisse rien derrière lui.

## À faire d'abord, sans toucher au poste

Souvent suffisant, et sans aucun risque :

1. Heure de création du dépôt sur GitHub vs ouverture de l'épreuve
   (`gh api repos/ORG/REPO --jq .created_at`).
2. Dates **auteur** *et* **committeur** de chaque commit — un écart trahit un
   `git commit --date`, un `rebase` ou un import.
3. Le rendu compile-t-il ? Un rendu sans binaire ne peut pas avoir obtenu 100 % à une
   moulinette qui exécute le binaire.
4. L'année de l'en-tête EPITECH — le tampon est posé à la création du fichier.
5. Les conventions de nommage : `ft_` est la convention *42*, Epitech utilise `my_`.
6. `git fsck --unreachable` — un blob orphelin contenant du code prouve qu'il a existé
   dans le dépôt puis en a été retiré.

## Procès-verbal

À consigner et faire signer : date, heure, lieu, numéro du poste ; noms du staff et de
l'étudiant ; `sha256sum RAPPORT.md chronologie.tsv` ; la déclaration de l'étudiant telle
qu'il la formule. Conserver la clé, ne rien modifier sur le poste après le relevé.
