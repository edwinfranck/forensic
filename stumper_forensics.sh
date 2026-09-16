#!/usr/bin/env bash
#
# stumper_forensics.sh — relevé forensique LECTURE SEULE sur poste étudiant (Ubuntu 22/24)
#
# But : établir si le sujet d'un stumper, ou une implémentation de ce sujet,
#       existait sur la machine AVANT l'ouverture de l'épreuve.
#       Le script ne conclut pas à la fraude : il produit des faits horodatés
#       (Access / Modify / Change / Birth), des empreintes et une chronologie.
#
# Il n'écrit RIEN en dehors de son dossier de rapport. Aucune suppression,
# aucune modification, aucun accès réseau.
#
# Usage :
#   sudo ./stumper_forensics.sh --start '2026-09-11 09:30' --end '2026-09-11 13:00' \
#        --user etudiant --out /media/cle/releve --deep
#
#   --start TS     début de l'épreuve (tout format accepté par date -d). Requis en pratique.
#   --end   TS     fin de l'épreuve (défaut : maintenant)
#   --user  NAME   compte à examiner (défaut : le propriétaire de /home le plus récent, sinon SUDO_USER)
#   --out   DIR    dossier du rapport (défaut : ./releve-<host>-<date>)
#   --root  DIR    racine supplémentaire à balayer (répétable : clés USB, /mnt/...)
#   --deep         active les sondes lourdes : inodes supprimés (debugfs), journal ext4
#   --quick        saute la recherche par contenu sur tout le disque
#   --max-repos N  plafond de dépôts git examinés en détail (défaut 200)
#   --signature S  motif de contenu supplémentaire (répétable)
#
set -uo pipefail
export LC_ALL=C

# ---------------------------------------------------------------- paramètres
START=""; END=""; TARGET_USER=""; OUT=""; DEEP=0; QUICK=0; MAX_REPOS=200
EXTRA_ROOTS=(); EXTRA_SIGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --start)     START="${2:-}"; shift 2 ;;
    --end)       END="${2:-}"; shift 2 ;;
    --user)      TARGET_USER="${2:-}"; shift 2 ;;
    --out)       OUT="${2:-}"; shift 2 ;;
    --root)      EXTRA_ROOTS+=("${2:-}"); shift 2 ;;
    --signature) EXTRA_SIGS+=("${2:-}"); shift 2 ;;
    --deep)      DEEP=1; shift ;;
    --quick)     QUICK=1; shift ;;
    --max-repos) MAX_REPOS="${2:-200}"; shift 2 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *)           echo "option inconnue : $1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------- sujet recherché
# Noms de fichiers révélateurs (insensible à la casse, motifs find -iname)
NAME_PATTERNS=(
  '*fractal*'
  '*duostumper*'
  '*stumper*'
  'G-CPE-210*'
  'B-CPE-210*'
  'main.c'
  'fractal.c'
  'fractals.h'
  'pattern.c'
)

# Les deux fichiers que le Makefile du rendu déclare mais qui n'ont JAMAIS été
# poussés : s'ils existent sur le poste, c'est la pièce maîtresse.
MISSING_FILES=( 'main.c' 'fractal.c' )

# Signatures de contenu propres à cette implémentation
SIGNATURES=(
  'build_fractal'
  'pattern_at'
  'pattern_parse'
  'pattern_destroy'
  'measure_pattern'
  'close_segment'
  'ft_putstr_fd'
  'B-CPE-210 Fractals'
  'ERROR_EXIT'
  'fractals 0 chain1 chain2'
)
SIGNATURES+=( "${EXTRA_SIGS[@]+"${EXTRA_SIGS[@]}"}" )

# Empreintes sha256 des fichiers effectivement rendus sur le dépôt
declare -A KNOWN_SHA=(
  [fd4babcd9db5b255c8757428464a97e5719fe4d920e4d49bc882e25eb6a3f63f]="fractals.h (rendu stumper6-4)"
  [d0583e78bd2a6b369dc614c54b298e994efca7c3c521e4ed43cdaedb1fcf89f0]="pattern.c  (rendu stumper6-4)"
  [5207d685a7571922f7e537747eb8ca1a3eaf6ffd879e0d187d26ef8814d0217f]="utils.c    (rendu stumper6-4)"
  [4857bc442d24f5f13479d808ac670acd73f831135fd3ef136226d18a1e263b10]="Makefile   (rendu stumper6-4)"
)
# Empreintes git blob des mêmes fichiers (permet de les retrouver dans
# n'importe quel dépôt git du poste, même supprimés de l'arbre de travail)
KNOWN_BLOBS=(
  '1df53caae71ab9f3dc393339d053462f80fb090e Makefile'
  'b4b5c302f8bafced5b3bc38847b917372af1cde3 fractals.h'
  '04447f392dd0654d422239dbc6435e7a2bddf42a pattern.c'
  '5ca82d28633945e3eef5c77dfe3d12086f8d30fa utils.c'
)

# ------------------------------------------------------------ initialisation
HOST="$(hostname 2>/dev/null || echo inconnu)"
STAMP="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT" ] || OUT="./releve-${HOST}-${STAMP}"
mkdir -p "$OUT/copies" || { echo "impossible de créer $OUT" >&2; exit 1; }
OUT="$(cd "$OUT" && pwd)"
REPORT="$OUT/RAPPORT.md"
TIMELINE="$OUT/chronologie.tsv"
HITS="$OUT/candidats.txt"
: > "$HITS"

if [ -z "$TARGET_USER" ]; then
  TARGET_USER="${SUDO_USER:-$(id -un)}"
fi
HOMEDIR="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$HOMEDIR" ] || HOMEDIR="/home/$TARGET_USER"

START_EPOCH=0; END_EPOCH=$(date +%s)
if [ -n "$START" ]; then
  START_EPOCH="$(date -d "$START" +%s 2>/dev/null || echo 0)"
  [ "$START_EPOCH" = 0 ] && { echo "date de début illisible : $START" >&2; exit 1; }
fi
if [ -n "$END" ]; then
  END_EPOCH="$(date -d "$END" +%s 2>/dev/null || echo 0)"
  [ "$END_EPOCH" = 0 ] && { echo "date de fin illisible : $END" >&2; exit 1; }
fi

AM_ROOT=0; [ "$(id -u)" = 0 ] && AM_ROOT=1

# Sans fenêtre d'épreuve, le relevé collecte mais ne classe rien : aucune
# antériorité ne peut être établie. Autant le dire avant dix minutes de balayage.
if [ -z "$START" ]; then
  printf '\n' >&2
  printf '  ATTENTION : aucun --start fourni.\n' >&2
  printf '  Le relevé va tout collecter, mais ne pourra classer aucun fichier\n' >&2
  printf '  comme antérieur à l épreuve. Relancez avec par exemple :\n' >&2
  printf "      --start '2026-09-11 09:30'\n" >&2
  printf '  Pour un essai rapide, ajoutez --quick (saute la lecture de contenu).\n' >&2
  printf '\n  Poursuite dans 5 s — Ctrl-C pour reprendre.\n\n' >&2
  sleep 5
fi

say() { printf '%s\n' "$*" >&2; }
out() { printf '%s\n' "$*" >> "$REPORT"; }
sec() { out ""; out "## $*"; out ""; say "  -> $*"; }
sub() { out ""; out "### $*"; out ""; }
pre() { out '```'; cat >> "$REPORT"; out '```'; }
run() { out '```'; { "$@" 2>&1 || true; } >> "$REPORT"; out '```'; }

# Arborescences exclues du balayage (pseudo-systèmes, images, caches inutiles)
PRUNE=( /proc /sys /dev /run /snap /var/lib/docker /var/lib/snapd \
        /var/cache /usr/share/doc /usr/lib/modules /sys/kernel )
# Expression de prune construite en TABLEAU. Surtout pas en chaîne réinjectée
# sans guillemets : une parenthèse collée à son argument et find rejette toute
# l'expression — en silence si stderr est jeté. Le relevé rendrait alors zéro
# fichier sans que personne ne s'en aperçoive.
PRUNE_EXPR=()
for _p in "${PRUNE[@]}"; do
  [ ${#PRUNE_EXPR[@]} -gt 0 ] && PRUNE_EXPR+=( -o )
  PRUNE_EXPR+=( -path "$_p" )
done

# Racines réelles à balayer : tout système de fichiers local monté.
# On ne se repose pas sur "find / -xdev" : si /home, /data ou une clé USB est un
# montage distinct, -xdev depuis / les sauterait en silence.
SCAN_ROOTS=()
while IFS= read -r mp; do
  [ -n "$mp" ] && SCAN_ROOTS+=( "$mp" )
done < <(findmnt -rno TARGET -t ext2,ext3,ext4,btrfs,xfs,f2fs,jfs,reiserfs,vfat,ntfs,ntfs3,exfat,ecryptfs,zfs 2>/dev/null | sort -u)
[ ${#SCAN_ROOTS[@]} -gt 0 ] || SCAN_ROOTS=( / )
HOME_MP="$(findmnt -no TARGET -T "$HOMEDIR" 2>/dev/null || echo /)"
case " ${SCAN_ROOTS[*]} " in *" $HOME_MP "*) ;; *) SCAN_ROOTS+=( "$HOME_MP" ) ;; esac
SCAN_ROOTS+=( "${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"}" )

# scan_find <arguments find> — applique find à chaque racine, hors pseudo-systèmes
scan_find() {
  local r
  for r in "${SCAN_ROOTS[@]}"; do
    [ -d "$r" ] || continue
    find "$r" -xdev \( "${PRUNE_EXPR[@]}" \) -prune -o "$@" 2>/dev/null
  done
}

# Garde-fou. Un balayage qui rend zéro fichier doit vouloir dire "rien sur ce
# poste", jamais "l'expression de find était cassée". On le vérifie sur un
# fichier témoin AVANT de relever quoi que ce soit.
touch "$OUT/.selftest" 2>/dev/null
if [ -z "$(find "$OUT" -maxdepth 1 -xdev \( "${PRUNE_EXPR[@]}" \) -prune -o -name '.selftest' -print 2>/dev/null)" ]; then
  say "ERREUR : find n'accepte pas l'expression de balayage sur ce système."
  say "         Un relevé vide serait trompeur. Interruption."
  find "$OUT" -maxdepth 1 -xdev \( "${PRUNE_EXPR[@]}" \) -prune -o -name '.selftest' -print
  rm -f "$OUT/.selftest"
  exit 3
fi
rm -f "$OUT/.selftest"

# ===========================================================================
out "# Relevé forensique — poste \`$HOST\`"
out ""
out "| | |"
out "|---|---|"
out "| Machine | \`$HOST\` |"
out "| Compte examiné | \`$TARGET_USER\` (\`$HOMEDIR\`) |"
out "| Relevé lancé le | $(date -Is) |"
out "| Fenêtre d'épreuve | $( [ "$START_EPOCH" -gt 0 ] && date -d "@$START_EPOCH" -Is || echo 'non bornée') → $(date -d "@$END_EPOCH" -Is) |"
out "| Privilèges | $( [ $AM_ROOT = 1 ] && echo root || echo 'utilisateur (sondes disque indisponibles)') |"
out "| Sondes lourdes | $( [ $DEEP = 1 ] && echo activées || echo 'désactivées (--deep)') |"
out ""
out "> Relevé **en lecture seule**. Aucun fichier du poste n'a été modifié ni supprimé."
out "> Un fichier dont la date de **naissance (Birth) est antérieure au début de l'épreuve**"
out "> et dont le contenu correspond au sujet est un fait à verser au dossier, pas une conclusion."
out ""
[ $AM_ROOT = 0 ] && out "**Attention :** lancé sans \`sudo\`. Les inodes supprimés, le journal ext4 et les journaux système ne seront pas relevés."

# ---------------------------------------------------------------- phase 0
sec "0. Identité et état du système"
sub "Système"
run sh -c 'cat /etc/os-release 2>/dev/null; echo; uname -a; echo; uptime'
sub "Horloge — une horloge trafiquée invalide toutes les dates qui suivent"
run sh -c 'timedatectl 2>/dev/null; echo; date -Is; echo; hwclock -r 2>/dev/null || echo "(hwclock indisponible)"'
sub "Comptes et sessions"
run sh -c 'getent passwd | awk -F: "\$3>=1000 && \$3<65534"; echo "--- connexions ---"; last -F 2>/dev/null | head -40; echo "--- session en cours ---"; who -a 2>/dev/null'
sub "Systèmes de fichiers montés (support de la date de naissance)"
run sh -c 'findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || mount'
out ""
out "_Note : \`relatime\` (défaut Ubuntu) ne rafraîchit la date d'accès que si elle est"
out "plus ancienne que la modification ou vieille de plus de 24 h. Une date d'accès"
out "récente reste donc significative, mais son absence ne prouve rien._"

# ---------------------------------------------------------------- phase 1
# On copie d'abord ce qui est volatil ou que le balayage pourrait altérer.
sec "1. Sources volatiles (copiées avant tout balayage)"

copy_if() {  # copy_if <src> <nom-destination>
  [ -e "$1" ] || return 0
  cp -a --no-preserve=mode "$1" "$OUT/copies/$2" 2>/dev/null \
    && out "- copié : \`$1\` → \`copies/$2\`" \
    || out "- illisible : \`$1\`"
}

sub "Historiques de commandes"
for h in .bash_history .zsh_history .zhistory .local/share/fish/fish_history .python_history .sh_history; do
  copy_if "$HOMEDIR/$h" "$(echo "$h" | tr '/' '_')"
done
out ""
out "Lignes en rapport avec le sujet :"
out '```'
for h in "$HOMEDIR"/.bash_history "$HOMEDIR"/.zsh_history "$HOMEDIR"/.zhistory; do
  [ -r "$h" ] || continue
  grep -n -i -E 'fractal|stumper|G-CPE-210|B-CPE-210|epiclang|pattern\.c|main\.c' "$h" 2>/dev/null \
    | sed "s|^|$(basename "$h"):|" >> "$REPORT"
done
out '```'
out ""
out "_Dans \`.zsh_history\`, une ligne \`: <epoch>:<durée>;<commande>\` donne l'heure exacte"
out "de la commande. \`.bash_history\` n'horodate que si \`HISTTIMEFORMAT\` était défini._"
sub "Horodatage des historiques eux-mêmes"
out '```'
for h in "$HOMEDIR"/.bash_history "$HOMEDIR"/.zsh_history; do
  [ -e "$h" ] && stat --printf='%n\n  Access: %x\n  Modify: %y\n  Change: %z\n  Birth : %w\n' "$h" >> "$REPORT" 2>/dev/null
done
out '```'

sub "Corbeille — les fichiers supprimés et leur date de suppression"
TRASH="$HOMEDIR/.local/share/Trash"
if [ -d "$TRASH" ]; then
  out '```'
  { ls -la "$TRASH/files" 2>/dev/null; echo; echo "--- fiches de suppression ---";
    for i in "$TRASH"/info/*.trashinfo; do
      [ -r "$i" ] || continue
      echo "### $(basename "$i")"; cat "$i"
    done; } >> "$REPORT" 2>&1
  out '```'
  cp -a --no-preserve=mode "$TRASH/info" "$OUT/copies/Trash-info" 2>/dev/null && out "- fiches copiées dans \`copies/Trash-info/\`"
  for t in "$TRASH"/files/*; do
    [ -e "$t" ] && printf '%s\n' "$t" >> "$HITS"
  done
else
  out "_Pas de corbeille pour ce compte._"
fi
out ""
out "Autres corbeilles (supports amovibles) :"
run sh -c 'find /media /mnt -maxdepth 4 -name ".Trash-*" -o -maxdepth 4 -name ".Trash" 2>/dev/null | head -20'

sub "Fichiers récemment ouverts (GTK / GNOME) — horodatés à la visite"
REC="$HOMEDIR/.local/share/recently-used.xbel"
copy_if "$REC" "recently-used.xbel"
if [ -r "$REC" ]; then
  out ""
  out "Entrées en rapport avec le sujet :"
  out '```'
  grep -o 'href="[^"]*"[^>]*added="[^"]*"[^>]*modified="[^"]*"' "$REC" 2>/dev/null \
    | grep -i -E 'fractal|stumper|CPE-210' | head -40 >> "$REPORT"
  out '```'
fi

sub "Fichiers supprimés mais encore ouverts par un processus"
run sh -c 'lsof +L1 2>/dev/null | head -40 || echo "(lsof absent)"'

# ---------------------------------------------------------------- phase 2
sec "2. Recherche par nom de fichier"
out "Racines balayées (un montage = une racine) : \`${SCAN_ROOTS[*]}\`"
out ""
NAME_EXPR=()
for p in "${NAME_PATTERNS[@]}"; do
  [ ${#NAME_EXPR[@]} -gt 0 ] && NAME_EXPR+=( -o )
  NAME_EXPR+=( -iname "$p" )
done
scan_find \( "${NAME_EXPR[@]}" \) -print | sort -u > "$OUT/.names.txt"
wc -l < "$OUT/.names.txt" | xargs -I{} echo "{} chemin(s) trouvé(s) par nom." >> "$REPORT"
out '```'
head -300 "$OUT/.names.txt" >> "$REPORT"
out '```'
cat "$OUT/.names.txt" >> "$HITS"

sub "Chasse ciblée : les fichiers déclarés au Makefile mais jamais rendus"
out "Le \`Makefile\` du rendu déclare \`main.c\` et \`fractal.c\`. Ni l'un ni l'autre"
out "n'apparaît dans l'historique du dépôt. Leur présence sur le poste, avec le"
out "contenu du sujet, établirait qu'un projet complet existait hors dépôt."
out ""
out '```'
for mf in "${MISSING_FILES[@]}"; do
  echo "=== $mf ==="
  scan_find -iname "$mf" -type f | sort -u | while read -r f; do
    if grep -q -i -E 'fractal|build_fractal|pattern_at|"#"|@' "$f" 2>/dev/null; then
      printf '%s\n' "$f"
      stat --printf='    Birth : %w\n    Modify: %y\n    Size  : %s\n' "$f" 2>/dev/null
      printf '%s\n' "$f" >> "$HITS"
    fi
  done
done >> "$REPORT" 2>&1
out '```'

# ---------------------------------------------------------------- phase 3
if [ $QUICK = 0 ]; then
  sec "3. Recherche par contenu (signatures de l'implémentation)"
  out "Motifs recherchés : \`$(printf '%s ' "${SIGNATURES[@]}")\`"
  out ""
  SIG_EXPR=""
  for s in "${SIGNATURES[@]}"; do
    [ -n "$s" ] || continue
    [ -n "$SIG_EXPR" ] && SIG_EXPR="$SIG_EXPR|"
    SIG_EXPR="$SIG_EXPR$(printf '%s' "$s" | sed 's/[][\\.*^$(){}?+|/]/\\&/g')"
  done
  # On ne lit pas tout le disque : on sélectionne d'abord les fichiers
  # susceptibles de porter du code ou des notes, puis on ne grep que ceux-là.
  # Lire chaque octet de chaque fichier prend des heures et l'étudiant attend.
  say "     (sélection des fichiers à lire…)"
  scan_find -type f -size -5M \( \
      -iname '*.c'  -o -iname '*.h'   -o -iname '*.cpp' -o -iname '*.hpp' \
   -o -iname '*.cc' -o -iname '*.hh'  -o -iname 'Makefile*' -o -iname '*.mk' \
   -o -iname '*.md' -o -iname '*.txt' -o -iname '*.sh'  -o -iname '*.py' \
   -o -iname '*.json' -o -iname '*.log' -o -iname '*.patch' -o -iname '*.diff' \
   -o -iname '*.orig' -o -iname '*.rej' -o -iname '*~'  -o -iname '.*.sw?' \
   -o -iname '*.bak' -o -iname '*.save' -o -iname '*.tmp' \
      \) -print0 2>/dev/null > "$OUT/.cand0" || true
  NCAND=$(tr -dc '\0' < "$OUT/.cand0" | wc -c)
  say "     ($NCAND fichiers à lire)"
  out "_$NCAND fichiers texte retenus pour la lecture (sources, en-têtes, Makefile,"
  out "notes, scripts, sauvegardes d'éditeur), taille < 5 Mo._"
  out ""
  out '```'
  xargs -0 -r grep -lI --binary-files=without-match -E "$SIG_EXPR" < "$OUT/.cand0" 2>/dev/null \
    | sort -u > "$OUT/.content.txt"
  head -200 "$OUT/.content.txt" >> "$REPORT"
  out '```'
  rm -f "$OUT/.cand0"
  out ""
  out "$(wc -l < "$OUT/.content.txt") fichier(s) contiennent une signature."
  cat "$OUT/.content.txt" >> "$HITS"

  sub "Extraits datés des correspondances les plus fortes"
  out '```'
  head -40 "$OUT/.content.txt" | while read -r f; do
    [ -r "$f" ] || continue
    echo "════ $f"
    stat --printf='  Access: %x\n  Modify: %y\n  Change: %z\n  Birth : %w\n' "$f" 2>/dev/null
    grep -n -m4 -E "$SIG_EXPR" "$f" 2>/dev/null | sed 's/^/  /'
    echo
  done >> "$REPORT" 2>&1
  out '```'
else
  sec "3. Recherche par contenu — sautée (--quick)"
fi

# ---------------------------------------------------------------- phase 4
sec "4. Horodatage complet des candidats"
out "Pour chaque candidat : **Access** (dernière lecture), **Modify** (dernière"
out "écriture du contenu), **Change** (dernière écriture des métadonnées : droits,"
out "nom, propriétaire) et **Birth** (création de l'inode)."
out ""
out "Lectures utiles :"
out ""
out "- \`Modify\` > \`Birth\` → le fichier a été **modifié après sa création**."
out "- \`Change\` > \`Modify\` → **renommé, déplacé ou droits changés** après la dernière écriture."
out "- \`Birth\` **avant le début de l'épreuve** → le fichier **préexistait**."
out "- \`Birth\` postérieur mais \`Modify\` antérieur → contenu **importé** (copie préservant les dates, \`cp -p\`, \`tar -p\`, \`git clone\`, clé USB)."
out ""

printf 'birth_epoch\tbirth\taccess\tmodify\tchange\tmtime_epoch\tinode\tliens\ttaille\tproprietaire\tdroits\tzone\tindices\tsha256\tchemin\n' > "$TIMELINE"
sort -u "$HITS" | while IFS= read -r f; do
  [ -f "$f" ] || continue
  # Un seul appel à stat. En onze appels séparés, 600 candidats coûtaient
  # 6600 forks pour rien.
  IFS='|' read -r bE mE cE aT mT cT bT ino lnk sz own perm < <(
    stat --printf='%W|%Y|%Z|%x|%y|%z|%w|%i|%h|%s|%U:%G|%A\n' "$f" 2>/dev/null)
  : "${bE:=0}"; : "${mE:=0}"; : "${cE:=0}"
  tags=""
  add() { tags="${tags:+$tags,}$1"; }
  if [ "$START_EPOCH" -gt 0 ]; then
    [ "$bE" -gt 0 ] && [ "$bE" -lt "$START_EPOCH" ] && add "INODE-ANTERIEUR-EPREUVE"
    [ "$mE" -gt 0 ] && [ "$mE" -lt "$START_EPOCH" ] && add "CONTENU-ANTERIEUR-EPREUVE"
  fi
  # contenu plus vieux que l'inode : copie preservant les dates, extraction, clone
  [ "$bE" -gt 0 ] && [ "$mE" -gt 0 ] && [ "$mE" -lt "$bE" ] && add "IMPORTE-DATES-PRESERVEES"
  [ "$bE" -gt 0 ] && [ "$mE" -gt "$bE" ] && add "MODIFIE-APRES-CREATION"
  [ "$cE" -gt 0 ] && [ "$mE" -gt 0 ] && [ "$cE" -gt "$mE" ] && add "METADONNEES-APRES-ECRITURE"
  [ -n "$tags" ] || tags="-"
  # Zone. Un main.c livré par cmake dans /usr/share n'apprend rien sur l'étudiant :
  # sans ce tri, les fichiers du système noient les siens dans le rapport.
  case "$f" in
    "$HOMEDIR"/*|/home/*|/tmp/*|/var/tmp/*|/media/*|/mnt/*|/root/*|/srv/*|/data/*) zone="ETUDIANT" ;;
    /usr/*|/opt/*|/var/*|/etc/*|/snap/*|/boot/*|/lib/*|/bin/*|/sbin/*)             zone="SYSTEME"  ;;
    *) if [ "${own%%:*}" = "$TARGET_USER" ]; then zone="ETUDIANT"; else zone="SYSTEME"; fi ;;
  esac
  sum="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$bE" "${bT:--}" "${aT:--}" "${mT:--}" "${cT:--}" "$mE" "${ino:--}" "${lnk:--}" \
    "${sz:--}" "${own:--}" "${perm:--}" "$zone" "$tags" "${sum:--}" "$f" >> "$TIMELINE"
done
out "Chronologie complète : \`chronologie.tsv\` ($(( $(wc -l < "$TIMELINE") - 1 )) entrées)."
out ""
sub "Relevé détaillé (sortie brute de stat)"
out '```'
sort -u "$HITS" | head -120 | while IFS= read -r f; do
  [ -e "$f" ] && { stat "$f" 2>/dev/null; echo; }
done >> "$REPORT"
out '```'

sub "Candidats antérieurs à l'épreuve"
if [ "$START_EPOCH" -gt 0 ]; then
  out "Seuls les fichiers de la **zone étudiant** sont listés ici (domicile, \`/tmp\`,"
  out "supports amovibles, ou possédés par le compte). Ceux du système — \`/usr\`,"
  out "\`/opt\`, \`/var\` — restent dans \`chronologie.tsv\` mais n'apprennent rien :"
  out "un \`main.c\` livré par cmake n'a aucun rapport avec l'épreuve."
  out ""
  out "**a. Inode créé avant l'épreuve** — le fichier était déjà là."
  out '```'
  awk -F'\t' 'NR>1 && $12=="ETUDIANT" && $13 ~ /INODE-ANTERIEUR-EPREUVE/ {printf "%s\n  Birth : %s\n  Modify: %s\n  Access: %s\n  Indices: %s\n\n", $15, $2, $4, $3, $13}' "$TIMELINE" | head -300 >> "$REPORT"
  echo "(fin)" >> "$REPORT"
  out '```'
  out ""
  out "**b. Contenu écrit avant l'épreuve alors que l'inode est postérieur** — copie"
  out "préservant les dates : le fichier a été **apporté** sur le poste, pas écrit dessus."
  out '```'
  awk -F'\t' 'NR>1 && $12=="ETUDIANT" && $13 ~ /IMPORTE-DATES-PRESERVEES/ {printf "%s\n  Birth (inode)   : %s\n  Modify (contenu): %s\n  Change          : %s\n  Indices: %s\n\n", $15, $2, $4, $5, $13}' "$TIMELINE" | head -300 >> "$REPORT"
  echo "(fin)" >> "$REPORT"
  out '```'
  na=$(awk -F'\t' 'NR>1 && $12=="ETUDIANT" && $13 ~ /INODE-ANTERIEUR-EPREUVE/' "$TIMELINE" | wc -l)
  nb=$(awk -F'\t' 'NR>1 && $12=="ETUDIANT" && $13 ~ /IMPORTE-DATES-PRESERVEES/' "$TIMELINE" | wc -l)
  nc=$(awk -F'\t' 'NR>1 && $12=="ETUDIANT" && $13 ~ /CONTENU-ANTERIEUR-EPREUVE/' "$TIMELINE" | wc -l)
  nsys=$(awk -F'\t' 'NR>1 && $12=="SYSTEME"' "$TIMELINE" | wc -l)
  out ""
  out "| Indice (zone étudiant) | Nombre |"
  out "|---|---|"
  out "| Inode créé avant l'épreuve | **$na** |"
  out "| Contenu daté d'avant l'épreuve | **$nc** |"
  out "| Importé avec dates préservées | **$nb** |"
  out ""
  out "_($nsys candidats en zone système, écartés de ce décompte.)_"
else
  out "_Aucune fenêtre d'épreuve fournie (\`--start\`) : classement impossible._"
fi

sub "Correspondance d'empreinte avec les fichiers rendus"
out '```'
awk -F'\t' 'NR>1 {print $14"\t"$15}' "$TIMELINE" | while IFS=$'\t' read -r sum path; do
  for k in "${!KNOWN_SHA[@]}"; do
    [ "$sum" = "$k" ] && printf 'IDENTIQUE AU RENDU — %s\n    %s\n' "${KNOWN_SHA[$k]}" "$path"
  done
done >> "$REPORT"
echo "(fin)" >> "$REPORT"
out '```'

sub "Fichiers modifiés après création, ou renommés/déplacés après écriture"
out '```'
awk -F'\t' 'NR>1 && $12=="ETUDIANT" && $13 ~ /MODIFIE-APRES-CREATION|METADONNEES-APRES-ECRITURE/ {
  printf "%s\n  Birth  %s\n  Modify %s\n  Change %s\n  -> %s\n\n", $15, $2, $4, $5, $13;
}' "$TIMELINE" | head -200 >> "$REPORT"
out '```'
out ""
out "_\`METADONNEES-CHANGEES-APRES-ECRITURE\` est la trace d'un \`mv\`, d'un \`chmod\`"
out "ou d'une copie : le contenu n'a pas bougé, l'inode oui._"

# ---------------------------------------------------------------- phase 5
sec "5. Dépôts git présents sur le poste"
scan_find -type d -name .git -not -path '*/node_modules/*' -print | sort -u > "$OUT/.gitdirs.txt"
NGIT=$(wc -l < "$OUT/.gitdirs.txt")
out "$NGIT dépôt(s) trouvé(s) sur le poste."
out ""

# On trie AVANT d'ouvrir quoi que ce soit. Un grep récursif sur l'arbre de
# travail de chaque dépôt, puis deux git fsck, sur un poste qui en compte
# plusieurs centaines, tourne pendant des heures sans rien apprendre.
say "     (sélection des dépôts pertinents parmi $NGIT…)"
: > "$OUT/.gitrelevant.txt"
while IFS= read -r g; do
  repo="$(dirname "$g")"
  keep=0
  case "$repo" in
    *fractal*|*stumper*|*CPE-210*|*cpe*|*[Tt]ek*|"$HOMEDIR"/[Dd]ocuments/*) keep=1 ;;
  esac
  # un fichier porteur de signature (phase 3) situé dans ce dépôt
  if [ $keep -eq 0 ] && [ -s "$OUT/.content.txt" ]; then
    grep -q "^$repo/" "$OUT/.content.txt" 2>/dev/null && keep=1
  fi
  # un nom de fichier révélateur dans l'index — lecture d'index, pas de l'arbre
  if [ $keep -eq 0 ]; then
    git -C "$repo" ls-files 2>/dev/null | grep -qiE 'fractal|stumper|pattern\.c' && keep=1
  fi
  [ $keep -eq 1 ] && printf '%s\n' "$g" >> "$OUT/.gitrelevant.txt"
done < "$OUT/.gitdirs.txt"
NREL=$(wc -l < "$OUT/.gitrelevant.txt")
say "     ($NREL dépôts retenus)"
out "**$NREL dépôt(s) retenus** pour examen détaillé : ceux dont le chemin, l'index"
out "ou le contenu touche au sujet. Les autres sont écartés — les lister tous"
out "n'apprendrait rien et coûterait des heures."
out ""
if [ "$NREL" -gt "$MAX_REPOS" ]; then
  out "_Plafonné à $MAX_REPOS dépôts (\`--max-repos\` pour changer)._"
  head -n "$MAX_REPOS" "$OUT/.gitrelevant.txt" > "$OUT/.gitrel2" && mv "$OUT/.gitrel2" "$OUT/.gitrelevant.txt"
  NREL="$MAX_REPOS"
fi

IREPO=0
while IFS= read -r g; do
  repo="$(dirname "$g")"
  IREPO=$((IREPO+1))
  say "     dépôt $IREPO/$NREL : $repo"
  sub "Dépôt \`$repo\`"
  out '```'
  {
    echo "--- origine ---"; git -C "$repo" remote -v 2>/dev/null
    echo "--- branches ---"; git -C "$repo" branch -avv 2>/dev/null
    echo "--- historique (auteur ET committeur) ---"
    git -C "$repo" log --all --date=iso-strict \
        --format='%h | A:%ad %an <%ae> | C:%cd %cn <%ce> | %s' 2>/dev/null | head -60
    echo "--- reflog : ce que HEAD a vraiment traversé, y compris réécritures ---"
    git -C "$repo" reflog --date=iso 2>/dev/null | head -60
    echo "--- remises (stash) ---"; git -C "$repo" stash list --date=iso 2>/dev/null
    echo "--- fichiers suivis ---"; git -C "$repo" ls-files 2>/dev/null | head -60
    echo "--- non suivis / ignorés (le projet complet s'y cache souvent) ---"
    git -C "$repo" status --porcelain --untracked-files=all --ignored 2>/dev/null | head -60
    echo "--- date de création du dépôt ---"
    stat --printf='  .git      Birth: %w  Modify: %y\n' "$g" 2>/dev/null
    stat --printf='  .git/config Birth: %w  Modify: %y\n' "$g/config" 2>/dev/null
    [ -f "$g/index" ] && stat --printf='  .git/index  Birth: %w  Modify: %y\n' "$g/index" 2>/dev/null
    echo "--- objets orphelins : commits/blobs abandonnés, souvent le vrai projet ---"
    timeout 60 git -C "$repo" fsck --unreachable --dangling --no-reflogs 2>/dev/null | head -40
    echo "--- recherche des blobs du rendu dans ce dépôt ---"
  } >> "$REPORT" 2>&1
  for kb in "${KNOWN_BLOBS[@]}"; do
    bh="${kb%% *}"; bn="${kb#* }"
    if git -C "$repo" cat-file -e "$bh" 2>/dev/null; then
      echo "  PRESENT : blob $bh ($bn) existe dans ce dépôt" >> "$REPORT"
      git -C "$repo" log --all --oneline --find-object="$bh" 2>/dev/null | sed 's/^/    introduit par /' >> "$REPORT"
    fi
  done
  out '```'
done < "$OUT/.gitrelevant.txt"

sub "Contenu des objets orphelins portant une signature"
out "_Un blob orphelin contenant \`build_fractal\` prouve que le fichier a existé"
out "dans un dépôt du poste puis en a été retiré._"
out '```'
while IFS= read -r g; do
  repo="$(dirname "$g")"
  timeout 60 git -C "$repo" fsck --unreachable --dangling --no-reflogs 2>/dev/null \
  | awk '$2=="blob"{print $3}' | head -200 | while read -r b; do
      if git -C "$repo" cat-file -p "$b" 2>/dev/null | grep -qI -E 'build_fractal|pattern_at|B-CPE-210 Fractals'; then
        echo "════ $repo : blob orphelin $b"
        git -C "$repo" cat-file -p "$b" 2>/dev/null | head -15 | sed 's/^/  /'
        echo
      fi
    done
done < "$OUT/.gitrelevant.txt" >> "$REPORT" 2>&1
echo "(fin)" >> "$REPORT"
out '```'

# ---------------------------------------------------------------- phase 6
sec "6. Traces d'éditeurs et d'environnements de développement"
sub "VS Code — fichiers et dossiers récemment ouverts"
for base in "$HOMEDIR/.config/Code" "$HOMEDIR/.config/Code - OSS" "$HOMEDIR/.config/VSCodium" "$HOMEDIR/.vscode-server"; do
  [ -d "$base" ] || continue
  out "Base : \`$base\`"
  out '```'
  DB="$base/User/globalStorage/state.vscdb"
  if [ -r "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    cp -a --no-preserve=mode "$DB" "$OUT/copies/state.vscdb" 2>/dev/null
    sqlite3 "file:$OUT/copies/state.vscdb?mode=ro" \
      "select value from ItemTable where key like '%history.recentlyOpenedPathsList%';" 2>/dev/null \
      | tr ',' '\n' | grep -o 'file:///[^"]*' | head -60 >> "$REPORT"
  else
    echo "(state.vscdb illisible ou sqlite3 absent — la copie est dans copies/ pour analyse ultérieure)"  >> "$REPORT"
    [ -r "$DB" ] && cp -a --no-preserve=mode "$DB" "$OUT/copies/state.vscdb" 2>/dev/null
  fi
  echo "--- espaces de travail, datés ---" >> "$REPORT"
  find "$base/User/workspaceStorage" -maxdepth 2 -name 'workspace.json' 2>/dev/null | while read -r w; do
    printf '%s\n' "$(cat "$w" 2>/dev/null)" >> "$REPORT"
    stat --printf='    Birth: %w  Modify: %y\n' "$w" 2>/dev/null >> "$REPORT"
  done
  echo "--- sauvegardes automatiques et fichiers non enregistrés ---" >> "$REPORT"
  find "$base/User" -path '*backups*' -o -path '*History*' 2>/dev/null | head -40 >> "$REPORT"
  out '```'
done
out ""
out "_\`User/History/\` de VS Code garde des versions successives de chaque fichier édité,"
out "avec leur horodatage : c'est souvent la meilleure chronologie de rédaction disponible._"
sub "Historique local VS Code portant une signature"
out '```'
for base in "$HOMEDIR/.config/Code" "$HOMEDIR/.config/VSCodium"; do
  [ -d "$base/User/History" ] || continue
  grep -rlI -E 'build_fractal|pattern_at|B-CPE-210 Fractals' "$base/User/History" 2>/dev/null | head -40 | while read -r f; do
    echo "════ $f"
    stat --printf='  Birth : %w\n  Modify: %y\n' "$f" 2>/dev/null
    [ -r "$(dirname "$f")/entries.json" ] && head -c 600 "$(dirname "$f")/entries.json" && echo
    echo
  done
done >> "$REPORT" 2>&1
echo "(fin)" >> "$REPORT"
out '```'

sub "Vim / Neovim"
out '```'
{ for v in "$HOMEDIR/.viminfo" "$HOMEDIR/.local/state/nvim/shada/main.shada" "$HOMEDIR/.local/share/nvim/shada/main.shada"; do
    [ -r "$v" ] || continue
    echo "════ $v"; stat --printf='  Modify: %y\n' "$v"
    strings "$v" 2>/dev/null | grep -i -E 'fractal|stumper|CPE-210|main\.c|pattern\.c' | head -30
  done
  echo "--- fichiers d'annulation (undo) : historique d'édition persistant ---"
  find "$HOMEDIR/.vim" "$HOMEDIR/.local/share/nvim" "$HOMEDIR/.local/state/nvim" \
       -name '*undo*' -o -name '*.un~' 2>/dev/null | head -40
  echo "--- swap / backup laissés par un éditeur ---"
  find "$HOMEDIR" /tmp -maxdepth 6 \( -name '.*.sw[a-p]' -o -name '*~' -o -name '*.orig' \) 2>/dev/null \
    | grep -i -E 'fractal|main|pattern|util' | head -30
} >> "$REPORT" 2>&1
out '```'

sub "Autres environnements"
run sh -c 'ls -la ~/.config/JetBrains ~/.local/share/JetBrains 2>/dev/null | head -30; echo; ls -la ~/.config/sublime-text* 2>/dev/null | head -10; echo; ls -la ~/.emacs.d/ 2>/dev/null | head -10'

# ---------------------------------------------------------------- phase 7
sec "7. Provenance externe"
sub "Téléchargements du navigateur (dates et URL d'origine)"
out '```'
{
  for p in "$HOMEDIR"/.mozilla/firefox/*/places.sqlite "$HOMEDIR"/snap/firefox/common/.mozilla/firefox/*/places.sqlite; do
    [ -r "$p" ] || continue
    echo "════ Firefox : $p"
    if command -v sqlite3 >/dev/null 2>&1; then
      cp -a --no-preserve=mode "$p" "$OUT/copies/places.sqlite" 2>/dev/null
      sqlite3 "file:$OUT/copies/places.sqlite?mode=ro" \
        "select datetime(p.last_visit_date/1000000,'unixepoch','localtime'), p.url from moz_places p where p.url like '%fractal%' or p.url like '%stumper%' or p.url like '%CPE-210%' or p.url like '%intra.epitech%' order by 1 desc limit 60;" 2>/dev/null
    else
      echo "(sqlite3 absent — copie faite)"
    fi
  done
  for p in "$HOMEDIR"/.config/google-chrome/*/History "$HOMEDIR"/.config/chromium/*/History; do
    [ -r "$p" ] || continue
    echo "════ Chromium/Chrome : $p"
    if command -v sqlite3 >/dev/null 2>&1; then
      cp -a --no-preserve=mode "$p" "$OUT/copies/chrome-History" 2>/dev/null
      sqlite3 "file:$OUT/copies/chrome-History?mode=ro" \
        "select datetime(start_time/1000000-11644473600,'unixepoch','localtime'), target_path, tab_url from downloads order by 1 desc limit 60;" 2>/dev/null
    fi
  done
} >> "$REPORT" 2>&1
out '```'

sub "Dossier Téléchargements"
out '```'
for d in "$HOMEDIR/Downloads" "$HOMEDIR/Téléchargements"; do
  [ -d "$d" ] || continue
  find "$d" -maxdepth 3 -type f -printf '%TY-%Tm-%Td %TH:%TM  %s\t%p\n' 2>/dev/null | sort -r | head -60
done >> "$REPORT" 2>&1
out '```'

sub "Archives contenant le sujet ou son code"
out '```'
scan_find \( -iname '*.zip' -o -iname '*.tar*' -o -iname '*.tgz' -o -iname '*.rar' -o -iname '*.7z' \) -print \
| sort -u | head -400 | while read -r a; do
    lst=""
    case "$a" in
      *.zip) command -v unzip >/dev/null && lst="$(unzip -l "$a" 2>/dev/null)" ;;
      *.tar|*.tar.*|*.tgz) lst="$(tar -tf "$a" 2>/dev/null)" ;;
      *.7z) command -v 7z >/dev/null && lst="$(7z l "$a" 2>/dev/null)" ;;
      *.rar) command -v unrar >/dev/null && lst="$(unrar l "$a" 2>/dev/null)" ;;
    esac
    if printf '%s' "$lst" | grep -qi -E 'fractal|stumper|CPE-210'; then
      echo "════ $a"
      stat --printf='  Birth : %w\n  Modify: %y\n  Access: %x\n' "$a" 2>/dev/null
      printf '%s\n' "$lst" | grep -i -E 'fractal|stumper|CPE-210' | head -20 | sed 's/^/    /'
      echo
      printf '%s\n' "$a" >> "$HITS"
    fi
  done >> "$REPORT" 2>&1
echo "(fin)" >> "$REPORT"
out '```'

sub "Dossiers de synchronisation en nuage et supports amovibles"
run sh -c 'ls -la ~/Dropbox ~/"Google Drive" ~/OneDrive ~/Nextcloud ~/ownCloud 2>/dev/null | head -40; echo "--- points de montage ---"; ls -la /media/* /mnt/* 2>/dev/null | head -40'

# ---------------------------------------------------------------- phase 8
sec "8. Journaux système — branchements, montages, changements d'heure"
if [ $AM_ROOT = 1 ]; then
  out '```'
  { echo "--- démarrages ---"; journalctl --list-boots 2>/dev/null | tail -10
    echo; echo "--- clés USB et disques branchés ---"
    journalctl -k --no-pager 2>/dev/null | grep -i -E 'usb-storage|USB Mass Storage|sd[b-z]:|new (high|full|super)-speed USB' | tail -60
    echo; echo "--- montages ---"
    journalctl --no-pager 2>/dev/null | grep -i -E 'mount|udisks|gvfs' | tail -60
    echo; echo "--- changements d'heure (une horloge reculée fausse les dates) ---"
    journalctl --no-pager 2>/dev/null | grep -i -E 'time has been changed|System clock|RTC time|timedated|ntp' | tail -40
    echo; echo "--- activité pendant la fenêtre d'épreuve ---"
    [ "$START_EPOCH" -gt 0 ] && journalctl --no-pager --since "@$START_EPOCH" --until "@$END_EPOCH" 2>/dev/null | tail -200
  } >> "$REPORT" 2>&1
  out '```'
  sub "Anciens journaux sur disque"
  run sh -c 'ls -la /var/log/ | head -40; echo; for f in /var/log/syslog /var/log/kern.log /var/log/auth.log; do [ -r "$f" ] && { echo "════ $f"; grep -i -E "usb-storage|sd[b-z]|mount" "$f" 2>/dev/null | tail -20; }; done'
else
  out "_Sondes journal indisponibles sans \`sudo\`._"
fi

# ---------------------------------------------------------------- phase 9
sec "9. Inodes supprimés et journal du système de fichiers"
if [ $DEEP = 1 ] && [ $AM_ROOT = 1 ]; then
  DEV="$(findmnt -no SOURCE -T "$HOMEDIR" 2>/dev/null)"
  FST="$(findmnt -no FSTYPE -T "$HOMEDIR" 2>/dev/null)"
  out "Partition de \`$HOMEDIR\` : \`$DEV\` (\`$FST\`)"
  out ""
  case "$FST" in
    ext2|ext3|ext4)
      if command -v debugfs >/dev/null 2>&1; then
        sub "Inodes supprimés (debugfs lsdel)"
        out "_L'heure de suppression figure en clair. Un inode supprimé pendant"
        out "l'épreuve, de la taille d'un fichier source, est un fait notable._"
        out '```'
        debugfs -R "lsdel" "$DEV" 2>&1 | head -120 >> "$REPORT"
        out '```'
        sub "Journal ext4 — écritures récentes de métadonnées"
        out '```'
        debugfs -R "logdump -O -S" "$DEV" 2>/dev/null | head -80 >> "$REPORT"
        out '```'
        out ""
        out "_Pour récupérer le contenu d'un inode listé : \`debugfs -R 'dump <NUM> /dest' $DEV\`"
        out "(à faire sur une copie du disque, jamais sur la partition montée en écriture)._"
      else
        out "_\`debugfs\` absent : \`apt-get install e2fsprogs\`._"
      fi
      if command -v ext4magic >/dev/null 2>&1 && [ "$START_EPOCH" -gt 0 ]; then
        sub "ext4magic — fichiers supprimés depuis le début de l'épreuve"
        out '```'
        ext4magic "$DEV" -a "$START_EPOCH" -f / -l 2>&1 | head -120 >> "$REPORT"
        out '```'
      fi
      ;;
    btrfs)
      sub "Instantanés btrfs — un instantané antérieur contient l'état d'avant l'épreuve"
      run sh -c "btrfs subvolume list -t / 2>/dev/null; echo; btrfs subvolume show / 2>/dev/null"
      ;;
    *)
      out "_Système de fichiers \`$FST\` : pas de sonde d'inodes supprimés prévue._" ;;
  esac
  sub "Espace non alloué — chaînes en rapport avec le sujet"
  out "_Sonde de dernier recours, lente. À lancer sur une image disque, pas en production._"
  out '```'
  echo "Commande à lancer manuellement sur une copie du disque :" >> "$REPORT"
  echo "  sudo dd if=$DEV bs=4M status=progress | strings -t d -n 8 | grep -n -E 'build_fractal|pattern_at|B-CPE-210 Fractals'" >> "$REPORT"
  out '```'
else
  out "_Sondes lourdes non lancées (il faut \`--deep\` **et** \`sudo\`)._"
  out ""
  out "Elles relèvent : inodes supprimés avec leur heure de suppression (\`debugfs lsdel\`),"
  out "journal ext4, instantanés btrfs, et chaînes présentes dans l'espace non alloué."
fi

# ---------------------------------------------------------------- phase 10
sec "10. Synthèse"
PRE=0
[ "$START_EPOCH" -gt 0 ] && PRE=$(awk -F'\t' 'NR>1 && $12=="ETUDIANT" && $13 ~ /ANTERIEUR-EPREUVE|IMPORTE-DATES-PRESERVEES/' "$TIMELINE" | wc -l)
TOT=$(( $(wc -l < "$TIMELINE") - 1 ))
out "| Mesure | Valeur |"
out "|---|---|"
out "| Candidats horodatés | $TOT |"
out "| Dont en zone étudiant | $(awk -F'\t' 'NR>1 && $12=="ETUDIANT"' "$TIMELINE" | wc -l) |"
out "| Portant un indice d'antériorité (zone étudiant) | **$PRE** |"
out "| Dépôts git sur le poste | $(wc -l < "$OUT/.gitdirs.txt") (dont $(wc -l < "$OUT/.gitrelevant.txt") examinés) |"
out "| Trouvés par nom | $(wc -l < "$OUT/.names.txt") |"
out "| Trouvés par contenu | $( [ -f "$OUT/.content.txt" ] && wc -l < "$OUT/.content.txt" || echo 'n/a (--quick)') |"
out ""
sub "Les dix contenus les plus anciens (zone étudiant)"
out '```'
{ printf 'BIRTH\tMODIFY\tINDICES\tCHEMIN\n'
  awk -F'\t' 'NR>1 && $12=="ETUDIANT" && $6>0 {print $6"\t"$2"\t"$4"\t"$13"\t"$15}' "$TIMELINE" \
    | sort -n | head -10 | cut -f2-; } | column -t -s$'\t' >> "$REPORT" 2>/dev/null
out '```'
out ""
out "### Ce que le relevé ne dit pas"
out ""
out "- Une date de naissance antérieure à l'épreuve peut venir d'une copie préservant"
out "  les dates (\`cp -p\`, \`tar -p\`, \`rsync -a\`, \`git clone\`) : l'inode est neuf,"
out "  la date affichée est ancienne. Croiser avec \`Change\` et l'ordre des inodes."
out "- Une date d'accès récente sur un fichier ancien peut venir de ce relevé lui-même"
out "  ou d'un antivirus, d'une indexation, d'une sauvegarde."
out "- L'absence de trace n'est pas une preuve d'absence : un \`rm\` suivi d'écritures,"
out "  ou un travail fait sur une autre machine, ne laisse rien ici."
out ""
out "### À joindre au dossier"
out ""
out "1. \`RAPPORT.md\` — ce document."
out "2. \`chronologie.tsv\` — à ouvrir en tableur, tri par \`birth_epoch\`."
out "3. \`copies/\` — historiques, corbeille, bases d'éditeurs et de navigateurs."
out "4. \`candidats.txt\` — la liste brute des chemins retenus."
out ""
out "---"
out "_Relevé terminé le $(date -Is). Généré par \`stumper_forensics.sh\`._"

sort -u "$HITS" -o "$HITS"
rm -f "$OUT/.names.txt" "$OUT/.content.txt" "$OUT/.gitdirs.txt" "$OUT/.gitrelevant.txt" 2>/dev/null
chmod -R a+r "$OUT" 2>/dev/null

say ""
say "══════════════════════════════════════════════════════════"
say " Relevé terminé."
say "   Rapport      : $REPORT"
say "   Chronologie  : $TIMELINE"
say "   Candidats    : $TOT dont $PRE antérieurs à l'épreuve"
say "══════════════════════════════════════════════════════════"
