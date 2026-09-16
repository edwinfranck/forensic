#!/usr/bin/env bash
#
# forensic.sh — relevé forensique LECTURE SEULE sur poste étudiant.
#
# Établit si un rendu, ou une implémentation du sujet, existait sur la machine
# AVANT l'ouverture de l'épreuve. Le script NE CONCLUT PAS : il produit des faits
# horodatés (Access / Modify / Change / Birth), des empreintes, une chronologie.
#
# Il n'écrit rien hors de son dossier de rapport. Aucune suppression, aucune
# modification, aucun accès réseau.
#
set -uo pipefail
export LC_ALL=C
VERSION="2.0"

# ─────────────────────────────────────────────────────────────── paramètres
START=""; END=""; TARGET_USER=""; OUT=""
DEEP=0; QUICK=0; ALL_FS=0; MAX_REPOS=200
EXTRA_ROOTS=(); SIGS=(); NAMES=(); REPOS_REF=()

usage() {
  cat <<'__HELP__'
forensic.sh — relevé forensique lecture seule sur poste étudiant

USAGE
  sudo ./forensic.sh --start '2026-09-16 10:00' [options]

OBLIGATOIRE
  --start TS        heure d'ouverture de l'épreuve (tout format `date -d`).
                    Sans elle, aucun classement d'antériorité n'est possible.

PÉRIMÈTRE
  --end TS          heure de fin de l'épreuve (défaut : maintenant)
  --user NAME       compte à examiner (défaut : SUDO_USER, sinon /home le plus récent)
  --root DIR        racine supplémentaire à balayer, répétable (clé USB, disque externe)
  --all             balayer tout le système de fichiers (défaut : zones étudiant)

CIBLAGE (tout est optionnel — sans rien, le script reste générique)
  --repo DIR        dépôt rendu par l'étudiant : le script en déduit seul les noms
                    de fichiers et les symboles à rechercher. Répétable.
  --name MOTIF      motif de nom de fichier supplémentaire, répétable (ex. '*cesar*')
  --signature MOT   motif de contenu supplémentaire, répétable (ex. 'write_crypt')

PROFONDEUR
  --deep            inodes supprimés (debugfs), journal ext4, instantanés btrfs
  --quick           saute la recherche par contenu (~1 min au lieu de ~10)
  --max-repos N     plafond de dépôts git examinés (défaut 200)

SORTIE
  --out DIR         dossier du rapport — sur la clé USB du staff de préférence

PROCÉDURE
  Étudiant présent et informé, second membre du staff témoin, rapport écrit hors
  du disque du poste, procès-verbal signé. Le script ne conclut pas.
__HELP__
}

while [ $# -gt 0 ]; do
  case "$1" in
    --start)      START="${2:-}"; shift 2 ;;
    --end)        END="${2:-}"; shift 2 ;;
    --user)       TARGET_USER="${2:-}"; shift 2 ;;
    --out)        OUT="${2:-}"; shift 2 ;;
    --root)       EXTRA_ROOTS+=("${2:-}"); shift 2 ;;
    --repo)       REPOS_REF+=("${2:-}"); shift 2 ;;
    --name)       NAMES+=("${2:-}"); shift 2 ;;
    --signature)  SIGS+=("${2:-}"); shift 2 ;;
    --all)        ALL_FS=1; shift ;;
    --deep)       DEEP=1; shift ;;
    --quick)      QUICK=1; shift ;;
    --max-repos)  MAX_REPOS="${2:-200}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "option inconnue : $1" >&2; echo "  --help pour l'aide" >&2; exit 1 ;;
  esac
done

[ -n "$START" ] || { echo "ERREUR : --start est obligatoire." >&2; echo; usage; exit 1; }
START_EPOCH=$(date -d "$START" +%s 2>/dev/null) || { echo "ERREUR : --start illisible : $START" >&2; exit 1; }
if [ -n "$END" ]; then
  END_EPOCH=$(date -d "$END" +%s 2>/dev/null) || { echo "ERREUR : --end illisible : $END" >&2; exit 1; }
else
  END_EPOCH=$(date +%s)
fi

# ─────────────────────────────────────────────────────────── compte examiné
if [ -z "$TARGET_USER" ]; then
  TARGET_USER="${SUDO_USER:-}"
  [ -z "$TARGET_USER" ] && TARGET_USER="$(ls -td /home/*/ 2>/dev/null | head -1 | xargs -r basename)"
fi
HOMEDIR="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$HOMEDIR" ] || HOMEDIR="/home/$TARGET_USER"

OUT="${OUT:-./releve-$(hostname 2>/dev/null || echo poste)-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT/copies" || { echo "ERREUR : impossible d'écrire dans $OUT" >&2; exit 1; }
OUT="$(cd "$OUT" && pwd)"
REPORT="$OUT/RAPPORT.md"; TIMELINE="$OUT/chronologie.tsv"; CAND="$OUT/candidats.txt"
: > "$REPORT"; : > "$CAND"

# ───────────────────────────────────────────────────── affichage et journal
T0=$(date +%s); PHASE_T0=$T0; PHASE_N=0; NPHASES=11
is_tty() { [ -t 2 ]; }
c() { is_tty && printf '\033[%sm' "$1" >&2 || true; }
say()  { printf '%s\n' "$*" >&2; }
hr()   { say "────────────────────────────────────────────────────────────────"; }
el()   { local s=$(( $(date +%s) - T0 )); printf '%02d:%02d' $((s/60)) $((s%60)); }
phase() {
  PHASE_N=$((PHASE_N+1)); PHASE_T0=$(date +%s)
  say ""
  c '1;36'; printf '[%s] ── phase %d/%d ── %s\n' "$(el)" "$PHASE_N" "$NPHASES" "$*" >&2; c '0'
  out ""; out "## $PHASE_N. $*"; out ""
}
step() { c '0;36'; printf '   · %s' "$*" >&2; c '0'; printf '\n' >&2; }
# tick : ligne réécrite en place, prouve que ça avance
TICK_LAST=0
tick() {
  is_tty || return 0
  local now; now=$(date +%s)
  [ $((now - TICK_LAST)) -ge 1 ] || return 0
  TICK_LAST=$now
  printf '\r     %-70s' "$*" >&2
}
tickend() { is_tty && printf '\r%-78s\r' '' >&2 || true; }
done_phase() {
  local d=$(( $(date +%s) - PHASE_T0 ))
  c '0;32'; printf '     ✓ %s (%ds)\n' "$*" "$d" >&2; c '0'
}
warn() { c '1;33'; printf '     ! %s\n' "$*" >&2; c '0'; }
out()  { printf '%s\n' "$*" >> "$REPORT"; }
sub()  { out ""; out "### $*"; out ""; }
pre()  { out '```'; cat >> "$REPORT"; out '```'; }
run()  { out '```'; { "$@" 2>&1 || true; } >> "$REPORT"; out '```'; }

# ──────────────────────────────────────────────── ciblage déduit des rendus
derive_from_repo() {
  local r="$1" f base sym
  [ -d "$r" ] || { warn "dépôt introuvable : $r"; return; }
  step "analyse du rendu $(basename "$r")"
  while IFS= read -r f; do
    base="$(basename "$f")"
    case "$base" in
      *.c|*.h|*.cpp|*.hpp|*.py|Makefile|CMakeLists.txt) NAMES+=("$base") ;;
    esac
  done < <(git -C "$r" ls-files 2>/dev/null || find "$r" -maxdepth 3 -type f)
  # symboles : noms de fonctions et macros définis dans le rendu
  while IFS= read -r sym; do
    [ ${#sym} -ge 5 ] && SIGS+=("$sym")
  done < <(grep -rhoE '^[a-zA-Z_][a-zA-Z0-9_ \*]*\b([a-z_][a-z0-9_]{4,})\(' "$r" 2>/dev/null \
            | grep -oE '[a-z_][a-z0-9_]{4,}\(' | tr -d '(' | sort -u | head -40)
  while IFS= read -r sym; do
    SIGS+=("$sym")
  done < <(grep -rhoE '#[[:space:]]*define[[:space:]]+[A-Z_][A-Z0-9_]{3,}' "$r" 2>/dev/null \
            | awk '{print $NF}' | sort -u | head -20)
}

# ─────────────────────────────────────────────────────────── en-tête rapport
out "# Relevé forensique — poste \`$(hostname 2>/dev/null || echo inconnu)\`"
out ""
out "| | |"
out "|---|---|"
out "| Script | forensic.sh v$VERSION |"
out "| Relevé effectué le | $(date '+%Y-%m-%d %H:%M:%S %Z') |"
out "| Compte examiné | \`$TARGET_USER\` (\`$HOMEDIR\`) |"
out "| Fenêtre de l'épreuve | $(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S') → $(date -d "@$END_EPOCH" '+%Y-%m-%d %H:%M:%S') |"
out "| Périmètre | $([ $ALL_FS -eq 1 ] && echo 'tout le système de fichiers' || echo 'zones étudiant') |"
out "| Recherche par contenu | $([ $QUICK -eq 1 ] && echo 'sautée (--quick)' || echo 'active') |"
out "| Sondes lourdes | $([ $DEEP -eq 1 ] && echo 'actives (--deep)' || echo 'inactives') |"
out ""
out "> Ce document **ne conclut pas**. Il présente des faits horodatés."
out "> La conclusion est une décision humaine, prise en soutenance, avec l'étudiant."
out ""

say ""
c '1;37'; say " forensic.sh v$VERSION — relevé lecture seule"; c '0'
hr
say "  compte examiné : $TARGET_USER  ($HOMEDIR)"
say "  épreuve        : $(date -d "@$START_EPOCH" '+%F %T') → $(date -d "@$END_EPOCH" '+%F %T')"
say "  rapport        : $REPORT"
[ "$(id -u)" -eq 0 ] || warn "sans sudo : journaux système, inodes supprimés et autres comptes seront inaccessibles"
hr

# ═══════════════════════════════════════════════════════════════════ phase 1
phase "Ciblage — ce que l'on cherche"

for r in "${REPOS_REF[@]:-}"; do [ -n "$r" ] && derive_from_repo "$r"; done

# motifs de nom par défaut : générique, tous langages
if [ ${#NAMES[@]} -eq 0 ]; then
  NAMES=( '*.c' '*.h' '*.cpp' '*.hpp' '*.py' '*.java' '*.js' '*.ts' '*.sh'
          'Makefile' 'CMakeLists.txt' '*.zip' '*.tar.gz' '*.tgz' '*.rar' '*.7z' '*.pdf' )
  step "aucun --repo ni --name : motifs génériques (sources, archives, PDF)"
fi
# dédoublonnage
mapfile -t NAMES < <(printf '%s\n' "${NAMES[@]}" | sort -u)
[ ${#SIGS[@]} -gt 0 ] && mapfile -t SIGS < <(printf '%s\n' "${SIGS[@]}" | sort -u)

step "${#NAMES[@]} motif(s) de nom, ${#SIGS[@]} signature(s) de contenu"
sub "Motifs de nom de fichier"
printf '%s\n' "${NAMES[@]}" | pre
if [ ${#SIGS[@]} -gt 0 ]; then
  sub "Signatures de contenu"
  printf '%s\n' "${SIGS[@]}" | pre
else
  out "_Aucune signature de contenu fournie : la recherche §4 ne portera que sur les noms._"
  out "_Passer \`--repo <dépôt-rendu>\` pour que le script déduise seul les symboles à chercher._"
fi

# racines balayées
ROOTS=()
if [ $ALL_FS -eq 1 ]; then
  ROOTS=( / )
else
  for d in "$HOMEDIR" /tmp /var/tmp /media /mnt /run/media /srv; do
    [ -d "$d" ] && ROOTS+=("$d")
  done
fi
for d in "${EXTRA_ROOTS[@]:-}"; do [ -n "$d" ] && [ -d "$d" ] && ROOTS+=("$d"); done
mapfile -t ROOTS < <(printf '%s\n' "${ROOTS[@]}" | sort -u)
step "racines balayées : ${ROOTS[*]}"
sub "Racines balayées"
printf '%s\n' "${ROOTS[@]}" | pre
done_phase "ciblage défini"

# ═══════════════════════════════════════════════════════════════════ phase 2
phase "Système, horloge et comptes"
say "     (une horloge reculée fausse tout le reste du relevé)"

sub "Horloge"
run timedatectl
sub "Système"
{ uname -a; echo; [ -r /etc/os-release ] && cat /etc/os-release; } | pre
sub "Comptes ayant un répertoire personnel"
ls -ld /home/*/ 2>/dev/null | pre
sub "Connexions récentes"
run last -n 25
sub "Montages"
run findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS
done_phase "contexte relevé"

# ═══════════════════════════════════════════════════════════════════ phase 3
phase "Sources volatiles — copiées avant tout balayage"
say "     (ce qui s'efface au prochain redémarrage ou à la prochaine commande)"

copy_if() { [ -e "$1" ] && cp -a "$1" "$OUT/copies/$2" 2>/dev/null && return 0 || return 1; }

n=0
for h in "$HOMEDIR"/.bash_history "$HOMEDIR"/.zsh_history "$HOMEDIR"/.local/share/fish/fish_history; do
  [ -r "$h" ] || continue
  copy_if "$h" "$(basename "$h")" && n=$((n+1))
done
step "$n historique(s) shell copié(s)"

sub "Corbeille — fichiers et dates de suppression"
TRASH="$HOMEDIR/.local/share/Trash"
if [ -d "$TRASH" ]; then
  cp -a "$TRASH" "$OUT/copies/Trash" 2>/dev/null || true
  { grep -H 'DeletionDate\|Path' "$TRASH"/info/*.trashinfo 2>/dev/null | head -100 || echo "(vide)"; } | pre
  step "corbeille copiée"
else
  out "_Aucune corbeille._"
fi

sub "Fichiers récemment ouverts (recently-used.xbel)"
REC="$HOMEDIR/.local/share/recently-used.xbel"
if [ -r "$REC" ]; then
  copy_if "$REC" "recently-used.xbel"
  grep -oE 'href="[^"]+"|modified="[^"]+"' "$REC" 2>/dev/null | head -80 | pre
  step "liste des fichiers récents copiée"
else
  out "_Absent._"
fi

sub "Fichiers supprimés encore ouverts par un processus"
if [ "$(id -u)" -eq 0 ]; then
  { ls -l /proc/*/fd 2>/dev/null | grep -i 'deleted' | head -40 || echo "(aucun)"; } | pre
else
  out "_Nécessite sudo._"
fi
done_phase "sources volatiles sauvegardées"

# ═══════════════════════════════════════════════════════════════════ phase 4
phase "Recherche des fichiers candidats"

PRUNE=( -name proc -o -name sys -o -name dev -o -name run
        -o -name node_modules -o -name .cache -o -name .git
        -o -name snap -o -name .venv -o -name venv -o -name __pycache__
        -o -name .npm -o -name .cargo -o -name .rustup -o -name .gradle )

FIND_NAME=()
for p in "${NAMES[@]}"; do FIND_NAME+=( -iname "$p" -o ); done
unset 'FIND_NAME[${#FIND_NAME[@]}-1]'

RAW="$OUT/.raw_candidates"; : > "$RAW"
for root in "${ROOTS[@]}"; do
  step "balayage de $root"
  cnt=0
  while IFS= read -r f; do
    printf '%s\n' "$f" >> "$RAW"
    cnt=$((cnt+1))
    [ $((cnt % 25)) -eq 0 ] && tick "$root — $cnt fichiers retenus… ($(el))"
  done < <(find "$root" -xdev \( "${PRUNE[@]}" \) -prune -o -type f \( "${FIND_NAME[@]}" \) -print 2>/dev/null)
  tickend
  say "       $root : $cnt fichier(s)"
done
sort -u "$RAW" -o "$RAW"
NRAW=$(wc -l < "$RAW")
done_phase "$NRAW fichier(s) candidat(s) par le nom"

# recherche par contenu
NSIG=0
if [ $QUICK -eq 0 ] && [ ${#SIGS[@]} -gt 0 ]; then
  step "recherche par contenu sur $NRAW fichiers (${#SIGS[@]} signatures)"
  SIGRE="$(printf '%s|' "${SIGS[@]}" | sed 's/|$//')"
  i=0
  while IFS= read -r f; do
    i=$((i+1))
    [ $((i % 50)) -eq 0 ] && tick "contenu : $i/$NRAW analysés, $NSIG correspondance(s)… ($(el))"
    if grep -qlE "$SIGRE" "$f" 2>/dev/null; then
      printf '%s\n' "$f" >> "$RAW.sig"; NSIG=$((NSIG+1))
    fi
  done < "$RAW"
  tickend
  [ -f "$RAW.sig" ] && cat "$RAW.sig" >> "$RAW" && sort -u "$RAW" -o "$RAW"
  done_phase "$NSIG fichier(s) contenant une signature"
elif [ $QUICK -eq 1 ]; then
  warn "recherche par contenu sautée (--quick)"
  out "_Recherche par contenu sautée (\`--quick\`)._"
else
  warn "aucune signature de contenu : recherche par nom seulement"
  out "_Aucune signature fournie ; recherche par nom seulement. Voir \`--repo\`._"
fi
cp "$RAW" "$CAND"

# ═══════════════════════════════════════════════════════════════════ phase 5
phase "Horodatage de chaque candidat"
say "     (Birth = création de l'inode, Modify = écriture du contenu)"

printf 'birth_epoch\tbirth\taccess\tmodify\tchange\tmtime_epoch\tinode\ttaille\tproprietaire\tzone\tindices\tsha256\tchemin\n' > "$TIMELINE"

i=0; NPRE=0; NIMP=0; NIN=0
while IFS= read -r f; do
  i=$((i+1))
  [ $((i % 20)) -eq 0 ] && tick "horodatage : $i/$NRAW  ($(el))"
  s=$(stat -c '%W|%X|%Y|%Z|%i|%s|%U' "$f" 2>/dev/null) || continue
  IFS='|' read -r bE aE mE cE ino sz own <<< "$s"
  [ "$bE" = "0" ] || [ "$bE" = "-" ] && bE=""
  case "$f" in
    "$HOMEDIR"/*|/tmp/*|/var/tmp/*|/media/*|/mnt/*|/run/media/*|/srv/*) zone="ETUDIANT" ;;
    *) zone="SYSTEME"; [ "$own" = "$TARGET_USER" ] && zone="ETUDIANT" ;;
  esac
  ind=""
  [ -n "$bE" ] && [ "$bE" -lt "$START_EPOCH" ] && { ind="$ind,INODE-ANTERIEUR-EPREUVE"; NPRE=$((NPRE+1)); }
  [ "$mE" -lt "$START_EPOCH" ] && ind="$ind,CONTENU-ANTERIEUR-EPREUVE"
  [ -n "$bE" ] && [ "$mE" -lt "$bE" ] && { ind="$ind,IMPORTE-DATES-PRESERVEES"; NIMP=$((NIMP+1)); }
  [ -n "$bE" ] && [ "$mE" -gt "$bE" ] && ind="$ind,MODIFIE-APRES-CREATION"
  [ "$cE" -gt "$mE" ] && ind="$ind,METADONNEES-APRES-ECRITURE"
  [ "$mE" -ge "$START_EPOCH" ] && [ "$mE" -le "$END_EPOCH" ] && { ind="$ind,ECRIT-PENDANT-EPREUVE"; NIN=$((NIN+1)); }
  ind="${ind#,}"; [ -z "$ind" ] && ind="-"
  h=$(sha256sum "$f" 2>/dev/null | cut -c1-16); [ -z "$h" ] && h="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${bE:-0}" "$([ -n "$bE" ] && date -d "@$bE" '+%F %T' || echo '-')" \
    "$(date -d "@$aE" '+%F %T')" "$(date -d "@$mE" '+%F %T')" "$(date -d "@$cE" '+%F %T')" \
    "$mE" "$ino" "$sz" "$own" "$zone" "$ind" "$h" "$f" >> "$TIMELINE"
done < "$RAW"
tickend
done_phase "$i fichier(s) horodaté(s) — $NPRE inode(s) antérieur(s), $NIMP importé(s)"

# ═══════════════════════════════════════════════════════════════════ phase 6
phase "Dépôts git présents sur le poste"

mapfile -t GITS < <(find "${ROOTS[@]}" -xdev -maxdepth 6 -type d -name .git 2>/dev/null | head -"$MAX_REPOS")
step "${#GITS[@]} dépôt(s) trouvé(s)"
ng=0
for g in "${GITS[@]:-}"; do
  [ -n "$g" ] || continue
  repo="$(dirname "$g")"; ng=$((ng+1))
  tick "dépôt $ng/${#GITS[@]} : $(basename "$repo")  ($(el))"
  sub "\`$repo\`"
  {
    echo "origine : $(git -C "$repo" config --get remote.origin.url 2>/dev/null || echo '(aucune)')"
    echo "branche : $(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
    echo
    echo "-- commits (auteur | committeur) --"
    git -C "$repo" log --all -n 30 --date=iso \
        --pretty='%h  A:%ad %an  |  C:%cd %cn  |  %s' 2>/dev/null || echo '(illisible)'
    echo
    echo "-- objets inatteignables (code retiré de l'index) --"
    git -C "$repo" fsck --unreachable 2>/dev/null | head -20 || echo '(aucun)'
    echo
    echo "-- reflog --"
    git -C "$repo" reflog --date=iso -n 20 2>/dev/null || echo '(aucun)'
  } | pre
done
tickend
done_phase "$ng dépôt(s) examiné(s)"

# ═══════════════════════════════════════════════════════════════════ phase 7
phase "Traces d'éditeurs"
say "     (l'historique VS Code est souvent la meilleure chronologie de rédaction)"

VSH="$HOMEDIR/.config/Code/User/History"
if [ -d "$VSH" ]; then
  nh=$(find "$VSH" -type f 2>/dev/null | wc -l)
  cp -a "$VSH" "$OUT/copies/vscode-History" 2>/dev/null || true
  step "historique VS Code : $nh entrée(s) copiée(s)"
  sub "VS Code — entrées antérieures à l'épreuve"
  find "$VSH" -type f -newermt "@0" ! -newermt "@$START_EPOCH" -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null \
    | sort | head -60 | pre
else
  out "_Pas d'historique VS Code._"
fi
for v in "$HOMEDIR/.viminfo" "$HOMEDIR/.local/state/nvim/shada"; do
  [ -e "$v" ] && { cp -a "$v" "$OUT/copies/" 2>/dev/null; step "copié : $(basename "$v")"; }
done
sub "Fichiers d'échange et d'annulation"
find "$HOMEDIR" -xdev -maxdepth 6 \( -name '*.swp' -o -name '*.un~' -o -name '*~' \) \
     -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort | head -40 | pre
done_phase "traces d'éditeurs relevées"

# ═══════════════════════════════════════════════════════════════════ phase 8
phase "Provenance externe — téléchargements, archives, nuage"

sub "Téléchargements des navigateurs"
found=0
for db in "$HOMEDIR"/.mozilla/firefox/*/places.sqlite "$HOMEDIR"/.config/*/Default/History; do
  [ -r "$db" ] || continue
  cp -a "$db" "$OUT/copies/$(basename "$(dirname "$db")")-$(basename "$db")" 2>/dev/null && found=1
done
[ $found -eq 1 ] && step "bases de navigateur copiées (à ouvrir en sqlite)" \
                 || out "_Aucune base de navigateur lisible._"

sub "Dossier Téléchargements"
for d in "$HOMEDIR/Downloads" "$HOMEDIR/Téléchargements"; do
  [ -d "$d" ] && ls -la --time-style=long-iso "$d" 2>/dev/null | head -40 | pre
done

sub "Dossiers de synchronisation en nuage"
find "$HOMEDIR" -xdev -maxdepth 3 -type d \
     \( -iname '*drive*' -o -iname '*dropbox*' -o -iname '*onedrive*' -o -iname '*nextcloud*' -o -iname '*mega*' \) \
     2>/dev/null | head -20 | pre
done_phase "provenance relevée"

# ═══════════════════════════════════════════════════════════════════ phase 9
phase "Journaux système — clés USB, montages, changements d'heure"
if [ "$(id -u)" -eq 0 ]; then
  sub "Branchements de périphériques de stockage"
  { journalctl -k --since "@$((START_EPOCH-86400))" 2>/dev/null \
      | grep -iE 'usb-storage|sd [a-z]|Attached SCSI|Mounted|new .* USB device' | head -60 || echo '(rien)'; } | pre
  sub "Changements d'heure"
  { journalctl --since "@$((START_EPOCH-86400))" 2>/dev/null \
      | grep -iE 'time has been changed|System clock|ntp|timedate' | head -40 || echo '(rien)'; } | pre
  done_phase "journaux relevés"
else
  warn "sans sudo : journaux système inaccessibles"
  out "_Nécessite sudo._"
fi

# ═══════════════════════════════════════════════════════════════════ phase 10
if [ $DEEP -eq 1 ]; then
  phase "Sondes profondes — inodes supprimés, journal du système de fichiers"
  if [ "$(id -u)" -eq 0 ]; then
    for dev in $(lsblk -nrpo NAME,FSTYPE 2>/dev/null | awk '$2=="ext4"{print $1}'); do
      step "debugfs lsdel sur $dev"
      sub "Inodes supprimés — \`$dev\`"
      { timeout 120 debugfs -R 'lsdel' "$dev" 2>/dev/null | head -60 || echo '(indisponible)'; } | pre
    done
    for dev in $(lsblk -nrpo NAME,FSTYPE 2>/dev/null | awk '$2=="btrfs"{print $1}'); do
      sub "Instantanés btrfs — \`$dev\`"
      { btrfs subvolume list / 2>/dev/null | head -40 || echo '(indisponible)'; } | pre
    done
    done_phase "sondes profondes terminées"
  else
    warn "sans sudo : sondes profondes impossibles"
  fi
else
  phase "Sondes profondes — non demandées"
  out "_Non activées. Relancer avec \`--deep\` pour les inodes supprimés et le journal ext4._"
  done_phase "sautées"
fi

# ════════════════════════════════════════════════════════════════ synthèse
phase "Synthèse"

TOT=$(( $(wc -l < "$TIMELINE") - 1 ))
cnt() { awk -F'\t' -v k="$1" 'NR>1 && $11 ~ k {n++} END{print n+0}' "$TIMELINE"; }
cntz() { awk -F'\t' -v k="$1" 'NR>1 && $10=="ETUDIANT" && $11 ~ k {n++} END{print n+0}' "$TIMELINE"; }
NETU=$(awk -F'\t' 'NR>1 && $10=="ETUDIANT"{n++} END{print n+0}' "$TIMELINE")

A_INODE=$(cnt 'INODE-ANTERIEUR-EPREUVE');      AZ_INODE=$(cntz 'INODE-ANTERIEUR-EPREUVE')
A_CONT=$(cnt 'CONTENU-ANTERIEUR-EPREUVE');     AZ_CONT=$(cntz 'CONTENU-ANTERIEUR-EPREUVE')
A_IMP=$(cnt 'IMPORTE-DATES-PRESERVEES');       AZ_IMP=$(cntz 'IMPORTE-DATES-PRESERVEES')
A_PEND=$(cnt 'ECRIT-PENDANT-EPREUVE');         AZ_PEND=$(cntz 'ECRIT-PENDANT-EPREUVE')
A_META=$(cnt 'METADONNEES-APRES-ECRITURE');    AZ_META=$(cntz 'METADONNEES-APRES-ECRITURE')

out "### Vue d'ensemble"
out ""
out "| | Total | **Zone étudiant** |"
out "|---|---:|---:|"
out "| Fichiers candidats retenus | $TOT | **$NETU** |"
out "| Inode créé **avant** l'épreuve | $A_INODE | **$AZ_INODE** |"
out "| Contenu écrit **avant** l'épreuve | $A_CONT | **$AZ_CONT** |"
out "| **Importé, dates préservées** | $A_IMP | **$AZ_IMP** |"
out "| Écrit **pendant** l'épreuve | $A_PEND | **$AZ_PEND** |"
out "| Métadonnées modifiées après écriture | $A_META | **$AZ_META** |"
out ""
out "> Seule la colonne **zone étudiant** se lit. La zone système remonte des centaines de"
out "> fichiers livrés par les paquets de développement, tous antérieurs et sans rapport."
out ""
out "### Comment lire chaque indice"
out ""
out "| Indice | Lecture |"
out "|---|---|"
out "| \`INODE-ANTERIEUR-EPREUVE\` | le fichier **était déjà sur la machine** avant l'épreuve |"
out "| \`CONTENU-ANTERIEUR-EPREUVE\` | le contenu a été **écrit** avant l'épreuve |"
out "| \`IMPORTE-DATES-PRESERVEES\` | \`Modify\` **plus ancien que** \`Birth\` : contenu plus vieux que l'inode qui le porte. Signature d'un \`cp -p\`, \`tar -x\`, \`rsync -a\`, \`git clone\`, copie depuis une clé. **Le fichier a été apporté, pas écrit sur place.** |"
out "| \`ECRIT-PENDANT-EPREUVE\` | contenu écrit dans la fenêtre de l'épreuve — le cas normal |"
out "| \`MODIFIE-APRES-CREATION\` | retouché après création — le cas normal d'un fichier travaillé |"
out "| \`METADONNEES-APRES-ECRITURE\` | \`Change\` > \`Modify\` : **renommé, déplacé ou droits changés** sans que le contenu bouge |"
out ""

# ── tableau détaillé : les candidats les plus parlants
out "### Candidats les plus parlants — zone étudiant"
out ""
out "Triés par antériorité du contenu. \`IMPORTE-DATES-PRESERVEES\` en premier."
out ""
out "| # | Écrit le (Modify) | Créé le (Birth) | Taille | Indices | sha256 | Chemin |"
out "|--:|---|---|--:|---|---|---|"
awk -F'\t' -v s="$START_EPOCH" '
  NR>1 && $10=="ETUDIANT" && ($11 ~ /IMPORTE|ANTERIEUR/) {
    prio = ($11 ~ /IMPORTE/) ? 0 : 1
    printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", prio, $6, $4, $2, $8, $11, $12, $13
  }' "$TIMELINE" \
| sort -t$'\t' -k1,1n -k2,2n | head -40 \
| awk -F'\t' '{ printf "| %d | %s | %s | %s | `%s` | `%s` | `%s` |\n", NR, $3, $4, $5, $6, $7, $8 }' >> "$REPORT"
NSHOWN=$(awk -F'\t' 'NR>1 && $10=="ETUDIANT" && ($11 ~ /IMPORTE|ANTERIEUR/)' "$TIMELINE" | wc -l)
out ""
if [ "$NSHOWN" -eq 0 ]; then
  out "**Aucun fichier de la zone étudiant n'est antérieur à l'épreuve ni importé.**"
  out "Tout ce qui a été trouvé a été écrit pendant la fenêtre de l'épreuve."
else
  out "_$NSHOWN fichier(s) concerné(s) ; les 40 premiers sont listés. Tableau complet : \`chronologie.tsv\`._"
fi
out ""

# ── répartition par extension
out "### Répartition des candidats par type — zone étudiant"
out ""
out "| Extension | Fichiers | dont antérieurs | dont importés |"
out "|---|--:|--:|--:|"
awk -F'\t' '
  NR>1 && $10=="ETUDIANT" {
    n=split($13,p,"/"); f=p[n]
    if (match(f, /\.[A-Za-z0-9]+$/)) e=substr(f, RSTART)
    else if (f ~ /^[Mm]akefile/)      e="Makefile"
    else if (f == "CMakeLists.txt")   e="CMakeLists"
    else                              e="(sans extension)"
    t[e]++
    if ($11 ~ /ANTERIEUR/) a[e]++
    if ($11 ~ /IMPORTE/)   i[e]++
  }
  END { for (e in t) printf "| `%s` | %d | %d | %d |\n", e, t[e], a[e]+0, i[e]+0 }' "$TIMELINE" \
| sort -t'|' -k3,3nr | head -20 >> "$REPORT"
out ""

# ── objections
out "### Objections à prévoir"
out ""
out "| Objection | Réponse |"
out "|---|---|"
out "| « J'ai copié mes fichiers depuis ma clé. » | Recevable. Ce qui compte est la date du **contenu** sur la clé : la relever aussi (\`--root /media/...\`). |"
out "| « Un \`cp -p\` garde les vieilles dates. » | Exact — c'est précisément ce que \`IMPORTE-DATES-PRESERVEES\` désigne. Il ne dit pas « fraude », il dit « ce contenu est plus vieux que son inode ». |"
out "| « L'horloge de la machine était fausse. » | Vérifiable : §2 relève \`timedatectl\`, §9 les changements d'heure au journal. |"
out "| « Ces dates viennent de votre scan. » | Non pour \`Modify\`, \`Change\` et \`Birth\`, qu'une lecture ne touche pas. Possiblement oui pour \`Access\` : c'est dit ici explicitement. |"
out ""
out "**L'absence de trace ne prouve rien.** Un \`rm\` suivi d'écritures, ou un travail fait"
out "sur une autre machine, ne laisse rien derrière lui."
out ""
out "### Procès-verbal"
out ""
out "À consigner et faire signer : date, heure, lieu, numéro du poste ; noms du staff présent"
out "et de l'étudiant ; empreintes ci-dessous ; déclaration de l'étudiant telle qu'il la formule."
out ""
{ cd "$OUT" && sha256sum RAPPORT.md chronologie.tsv candidats.txt 2>/dev/null; } | pre

rm -f "$RAW" "$RAW.sig" 2>/dev/null
done_phase "synthèse écrite"

# ──────────────────────────────────────────────────── récapitulatif console
say ""
c '1;37'; hr
printf ' RELEVÉ TERMINÉ en %s\n' "$(el)" >&2
hr; c '0'
printf '\n' >&2
row() { # row <libellé> <total> <étudiant>
  # LC_ALL=C : ${#s} compte des octets. Les octets de continuation UTF-8 (0x80-0xBF)
  # valent exactement bytes-chars : on élargit le gabarit d'autant.
  local cont
  cont=$(printf '%s' "$1" | od -An -tu1 | tr -s ' ' '\n' | awk '$1>=128 && $1<192 {n++} END{print n+0}')
  printf "   %-$(( 40 + cont ))s %8s %8s\n" "$1" "$2" "$3" >&2
}
row '' 'TOTAL' 'ÉTUDIANT'
printf '   %s %8s %8s\n' '----------------------------------------' '--------' '--------' >&2
row "Fichiers candidats"                    "$TOT"     "$NETU"
row "Inode antérieur à l'épreuve"           "$A_INODE" "$AZ_INODE"
row "Contenu antérieur à l'épreuve"         "$A_CONT"  "$AZ_CONT"
c '1;33'
row "IMPORTÉ (dates préservées)"            "$A_IMP"   "$AZ_IMP"
c '0'
row "Écrit pendant l'épreuve"               "$A_PEND"  "$AZ_PEND"
row "Métadonnées modifiées après écriture"  "$A_META"  "$AZ_META"
printf '\n' >&2
if [ "$AZ_IMP" -gt 0 ]; then
  c '1;33'; printf '   ! %s fichier(s) de la zone etudiant portent des dates preservees.\n' "$AZ_IMP" >&2
  printf '     %s\n' "C'est l'indice le plus parlant du releve - voir le tableau du rapport." >&2; c '0'
elif [ "$AZ_CONT" -gt 0 ]; then
  printf '   %s %s\n' "$AZ_CONT" "fichier(s) de la zone etudiant ont un contenu anterieur a l'epreuve." >&2
else
  c '0;32'; printf '   %s\n' "Aucun fichier de la zone etudiant n'est anterieur ni importe." >&2; c '0'
fi
printf '\n' >&2
printf '   Rapport      %s\n' "$REPORT" >&2
printf '   Chronologie  %s\n' "$TIMELINE" >&2
printf '   Copies       %s/copies\n' "$OUT" >&2
printf '\n' >&2
printf '   %s\n' "Le releve ne conclut pas. La conclusion se prend en soutenance, avec l'etudiant." >&2
printf '\n' >&2
