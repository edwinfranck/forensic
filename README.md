# stumper-forensics

Relevé forensique **lecture seule** sur poste étudiant (Ubuntu 22/24).

Objet : établir si le sujet d'un stumper, ou une implémentation de ce sujet,
existait sur la machine **avant** l'ouverture de l'épreuve.

> Le script **ne conclut pas**. Il produit des faits horodatés (Access / Modify /
> Change / Birth), des empreintes et une chronologie. La conclusion est une décision
> humaine, prise en soutenance, **avec l'étudiant**.

## Avant de lancer — non négociable

| Règle | Pourquoi |
|---|---|
| L'étudiant est **présent et informé** | un relevé fait à son insu n'est pas opposable |
| Un **second membre du staff** assiste | un témoin, deux signatures au procès-verbal |
| Le rapport s'écrit **hors du disque du poste** | on n'ajoute pas d'écriture sur la pièce |
| On ne supprime, ne déplace, ne corrige **rien** | le script est en lecture seule, restons-le |

La procédure complète, la lecture des quatre dates et les objections à prévoir :
**[PROCEDURE.md](PROCEDURE.md)**.

## Lancer sur le poste de l'étudiant

Le script n'a **rien à installer** et n'écrit rien sur le disque du poste : il est
exécuté depuis le flux réseau, et son rapport part sur la clé USB du staff.

```bash
# 1. brancher la clé du staff, repérer son point de montage (ex. /media/staff/CLE)
# 2. une seule commande, rien n'atterrit sur le disque du poste :

curl -sL https://raw.githubusercontent.com/edwinfranck/stumper-forensics/main/stumper_forensics.sh \
  | sudo bash -s -- \
      --start '2026-09-16 10:00' \
      --end   '2026-09-16 14:00' \
      --out   /media/staff/CLE/releve-poste12 \
      --deep
```

> `--start` est **l'option qui fait tout le travail** : sans l'heure d'ouverture de
> l'épreuve, aucun classement d'antériorité n'est possible.

Sans réseau sur le poste, copier `stumper_forensics.sh` sur la clé et le lancer
depuis la clé — jamais depuis le disque du poste.

## Options

| Option | Rôle |
|---|---|
| `--start TS` | heure d'ouverture de l'épreuve. **Requise en pratique.** |
| `--end TS` | heure de fin (défaut : maintenant) |
| `--user NAME` | compte à examiner (défaut : `SUDO_USER`) |
| `--out DIR` | dossier du rapport — **sur la clé** |
| `--root DIR` | racine supplémentaire, répétable : clé de l'étudiant, disque externe |
| `--signature S` | motif de contenu supplémentaire, répétable |
| `--deep` | inodes supprimés (`debugfs lsdel`), journal ext4, instantanés btrfs |
| `--quick` | saute la recherche par contenu (~1 min au lieu de ~10) |

## Ce que produit le relevé

```
RAPPORT.md         le document à lire et à joindre au dossier
chronologie.tsv    une ligne par fichier candidat, à ouvrir en tableur
candidats.txt      liste brute des chemins retenus
copies/            historiques shell, corbeille, bases VS Code et navigateurs
```

L'indice le plus parlant n'est pas un `Birth` ancien, c'est **`IMPORTE-DATES-PRESERVEES`** :
`Modify` plus ancien que `Birth`, donc un contenu plus vieux que l'inode qui le porte.
Signature d'un `cp -p`, d'un `tar -x`, d'un `git clone`, d'une copie depuis une clé —
**le fichier a été apporté, pas écrit sur place.**

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

**L'absence de trace ne prouve rien.** Un `rm` suivi d'écritures, ou un travail fait sur
une autre machine, ne laisse rien derrière lui.

## Procès-verbal

À consigner et faire signer à la fin : date, heure, lieu, numéro du poste ; noms du staff
et de l'étudiant ; `sha256sum RAPPORT.md chronologie.tsv` ; la déclaration de l'étudiant
telle qu'il la formule. Conserver la clé, ne rien modifier sur le poste après le relevé.
