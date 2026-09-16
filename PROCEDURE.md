# Relevé forensique sur poste étudiant — mode d'emploi

Objet : établir si le sujet d'un stumper, ou une implémentation de ce sujet,
existait sur la machine **avant** l'ouverture de l'épreuve.

Le script `stumper_forensics.sh` **ne conclut pas**. Il produit des faits horodatés.
La conclusion reste une décision humaine, prise en soutenance, avec l'étudiant.

---

## 1. Avant de toucher au poste

| Règle | Pourquoi |
|---|---|
| L'étudiant est **présent** et informé | un relevé fait à son insu n'est pas opposable |
| Un **second membre du staff** assiste | un témoin, et deux signatures sur le procès-verbal |
| Le rapport est écrit sur une **clé USB**, pas sur le disque du poste | on n'ajoute pas d'écriture sur la pièce à conviction |
| On ne supprime, ne déplace, ne corrige **rien** | le script est en lecture seule, restons-le |

Si l'enjeu est disciplinaire lourd, **ne pas travailler sur la machine vivante** :
faire une image disque (`dd` / `dcfldd` depuis un live USB) et analyser la copie.
Chaque démarrage du poste écrase des traces.

---

## 2. Lancer le relevé

```bash
# la clé USB est montée sur /media/staff/CLE
sudo /media/staff/CLE/stumper_forensics.sh \
     --start '2026-09-11 09:30' \
     --end   '2026-09-11 13:00' \
     --user  etudiant \
     --out   /media/staff/CLE/releve-poste12 \
     --deep
```

| Option | Rôle |
|---|---|
| `--start` | **l'option qui fait tout le travail** : heure d'ouverture de l'épreuve. Sans elle, aucun classement d'antériorité n'est possible. |
| `--end` | heure de fin (défaut : maintenant) |
| `--user` | compte de l'étudiant (défaut : `SUDO_USER`) |
| `--out` | dossier du rapport — **sur la clé** |
| `--deep` | inodes supprimés (`debugfs lsdel`), journal ext4, instantanés btrfs |
| `--quick` | saute la recherche par contenu (relevé en ~1 min au lieu de ~10) |
| `--root DIR` | racine supplémentaire : clé USB de l'étudiant, disque externe |
| `--signature S` | motif de contenu supplémentaire (répétable) |

`sudo` est nécessaire pour les journaux système, les inodes supprimés et la
lecture des dossiers des autres comptes. Sans `sudo` le script tourne quand même,
en annonçant ce qu'il ne peut pas voir.

---

## 3. Lire le résultat

Le dossier de sortie contient :

```
RAPPORT.md         le document à lire et à joindre au dossier
chronologie.tsv    tableau : une ligne par fichier candidat, à ouvrir en tableur
candidats.txt      liste brute des chemins retenus
copies/            historiques shell, corbeille, bases VS Code et navigateurs
```

### Les quatre dates, et ce qu'elles disent

| Date | Nom `stat` | Ce qu'elle marque |
|---|---|---|
| **Access** | `%x` | dernière **lecture** du contenu |
| **Modify** | `%y` | dernière **écriture du contenu** |
| **Change** | `%z` | dernière écriture des **métadonnées** : renommage, droits, propriétaire, déplacement |
| **Birth** | `%w` | **création de l'inode** sur cette partition |

`Birth` n'existe que sur ext4, btrfs, xfs (v5) et f2fs. Sur une clé FAT, il n'y en a pas.

### Les indices que le script pose dans la colonne `indices`

| Indice | Lecture |
|---|---|
| `INODE-ANTERIEUR-EPREUVE` | le fichier **était déjà sur la machine** avant l'épreuve |
| `CONTENU-ANTERIEUR-EPREUVE` | le contenu a été **écrit** avant l'épreuve |
| `IMPORTE-DATES-PRESERVEES` | `Modify` est **plus ancien que `Birth`** : contenu plus vieux que l'inode qui le porte. Signature d'un `cp -p`, d'un `tar -x`, d'un `rsync -a`, d'un `git clone`, d'une copie depuis une clé. **Le fichier a été apporté, pas écrit sur place.** |
| `MODIFIE-APRES-CREATION` | retouché après création — le cas normal d'un fichier sur lequel on travaille |
| `METADONNEES-APRES-ECRITURE` | `Change` > `Modify` : **renommé, déplacé ou droits changés** sans que le contenu bouge |

### La colonne `zone`

`ETUDIANT` — le fichier est dans le domicile du compte, `/tmp`, `/media`, `/mnt`,
ou lui appartient. `SYSTEME` — il vient de `/usr`, `/opt`, `/var`, `/etc`…

Le rapport ne raisonne que sur la zone étudiant. Sans ce tri, une Ubuntu ordinaire
remonte des centaines de `main.c` livrés par cmake, ghostscript ou les paquets de
développement, tous « antérieurs à l'épreuve » et tous sans le moindre rapport avec
elle. La zone système reste dans `chronologie.tsv` si besoin de la consulter.

Le cas le plus parlant n'est pas `Birth` ancien — c'est **`IMPORTE-DATES-PRESERVEES`**.
Un étudiant qui écrit son code pendant l'épreuve produit des fichiers dont `Modify`
suit `Birth` de quelques minutes. Un fichier dont le contenu est daté de juin alors
que l'inode est né à 11 h 46 le jour de l'épreuve n'a pas été écrit ce jour-là.

---

## 4. Ce que le script relève, section par section

| § | Contenu |
|---|---|
| 0 | système, **horloge** (une horloge reculée fausse tout le reste), comptes, connexions, montages |
| 1 | sources volatiles copiées **en premier** : historiques shell, corbeille et ses dates de suppression, fichiers récemment ouverts, fichiers supprimés encore ouverts par un processus |
| 2 | recherche par nom + **chasse ciblée sur `main.c` et `fractal.c`**, les deux fichiers que le `Makefile` du rendu déclare et qui n'ont jamais été poussés |
| 3 | recherche par **contenu** : `build_fractal`, `pattern_at`, `ft_putstr_fd`, `B-CPE-210 Fractals`… |
| 4 | **horodatage complet** de chaque candidat + empreinte sha256 + comparaison avec les fichiers effectivement rendus |
| 5 | **dépôts git du poste** : origines, historique auteur *et* committeur, `reflog`, remises, fichiers ignorés, et surtout **objets orphelins** — un blob abandonné contenant `build_fractal` prouve que le fichier a existé dans un dépôt puis en a été retiré |
| 6 | **traces d'éditeurs** : `User/History/` de VS Code garde les versions successives de chaque fichier édité, horodatées — c'est souvent la meilleure chronologie de rédaction disponible ; `.viminfo`, fichiers d'annulation, swap |
| 7 | **provenance** : téléchargements du navigateur avec URL et date, dossier Téléchargements, archives contenant le sujet, dossiers de synchronisation en nuage |
| 8 | **journaux système** : branchements de clés USB, montages, **changements d'heure** |
| 9 | `--deep` : **inodes supprimés avec leur heure de suppression**, journal ext4, instantanés btrfs |

---

## 5. Les objections auxquelles il faut s'attendre

Elles sont légitimes. Le rapport les reprend en fin de document.

- **« J'ai copié mes fichiers depuis ma clé, c'est tout. »** — Recevable en soi.
  Ce qui compte alors est la date du **contenu** sur la clé, pas la copie. Relever
  la clé aussi (`--root /media/...`).
- **« Un `cp -p` garde les vieilles dates. »** — Exact, et c'est justement ce que
  l'indice `IMPORTE-DATES-PRESERVEES` désigne : il ne dit pas « fraude », il dit
  « ce contenu est plus vieux que son inode ».
- **« L'horloge de la machine était fausse. »** — Vérifiable : §0 relève `timedatectl`
  et §8 les changements d'heure au journal.
- **« Ces dates viennent de votre propre scan. »** — Non pour `Modify`, `Change` et
  `Birth`, qu'une lecture ne touche pas. Oui possiblement pour `Access` : le rapport
  le dit explicitement.

**L'absence de trace ne prouve rien.** Un `rm` suivi d'écritures, ou un travail fait
sur une autre machine, ne laisse rien derrière lui.

---

## 6. Ce qui se vérifie sans toucher au poste

À faire en premier, c'est rapide et souvent suffisant :

1. **L'heure de création du dépôt sur GitHub** comparée à l'heure d'ouverture de l'épreuve
   (`gh api repos/ORG/REPO --jq .created_at`).
2. **Les dates auteur *et* committeur** de chaque commit : un écart entre les deux
   trahit un `git commit --date`, un `rebase` ou un import.
3. **Le rendu compile-t-il ?** Un rendu qui ne produit pas de binaire ne peut pas
   avoir obtenu 100 % à une moulinette qui exécute le binaire.
4. **L'en-tête EPITECH** : le tampon d'année est posé par le greffon d'éditeur au
   moment de la création. Une année qui n'est pas l'année en cours veut dire que le
   fichier — ou le modèle dont il est issu — est plus ancien.
5. **Les conventions de nommage** : `ft_` est la convention *42*, Epitech utilise `my_`.

---

## 7. Procès-verbal

À la fin du relevé, consigner et faire signer :

- date, heure, lieu, numéro du poste ;
- noms du staff présent et de l'étudiant ;
- empreinte du rapport : `sha256sum RAPPORT.md chronologie.tsv` ;
- déclaration de l'étudiant, telle qu'il la formule.

Conserver la clé. Ne rien modifier sur le poste après le relevé.
