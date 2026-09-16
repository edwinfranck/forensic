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
DEEP=0; QUICK=0; ALL_FS=0; MAX_REPOS=200; EXP_YEAR=""; EXP_MODULE=""; WITH_PV=0
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

MARQUEURS DE PROVENANCE (analyse du code lui-même)
  --year YYYY       année attendue dans l'en-tête EPITECH
                    (défaut : année de --start)
  --module CODE     module attendu, ex. G-CPE-210. Borne la recherche à ce
                    module et signale tout fichier qui en porte un autre.
  --pv              ajoute au rapport les objections à prévoir et le
                    procès-verbal (absents par défaut)

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
    --year)       EXP_YEAR="${2:-}"; shift 2 ;;
    --module)     EXP_MODULE="${2:-}"; shift 2 ;;
    --pv)         WITH_PV=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "option inconnue : $1" >&2; echo "  --help pour l'aide" >&2; exit 1 ;;
  esac
done

if [ -n "$START" ]; then
  START_EPOCH=$(date -d "$START" +%s 2>/dev/null) || { echo "ERREUR : --start illisible : $START" >&2; exit 1; }
else
  START_EPOCH=""   # déduit plus bas des rendus détectés
fi
if [ -n "$END" ]; then
  END_EPOCH=$(date -d "$END" +%s 2>/dev/null) || { echo "ERREUR : --end illisible : $END" >&2; exit 1; }
else
  END_EPOCH=""
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
T0=$(date +%s); PHASE_T0=$T0; PHASE_N=0; NPHASES=13
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
  # noms trop répandus : ils matchent tous les projets du disque, donc ils
  # ne discriminent rien. On ne garde que les noms propres au rendu.
  local GENERIC='^(main|utils|util|my|tools|tool|common|config|types|error|errors|init|parse|parser|print|printer|display|str|string|list|helper|helpers|lib|core|app|test|tests)\.(c|h|cpp|hpp|py)$|^(Makefile|CMakeLists\.txt|makefile)$'
  local kept=0 skipped=0
  while IFS= read -r f; do
    base="$(basename "$f")"
    case "$base" in
      *.c|*.h|*.cpp|*.hpp|*.py)
        if printf '%s' "$base" | grep -qE "$GENERIC"; then
          skipped=$((skipped+1))
        else
          NAMES+=("$base"); kept=$((kept+1))
        fi ;;
    esac
  done < <(git -C "$r" ls-files 2>/dev/null || find "$r" -maxdepth 3 -type f)
  [ "$skipped" -gt 0 ] && step "  $kept nom(s) distinctif(s) retenu(s), $skipped générique(s) écarté(s)"
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
# ───────────────────────────────── autodétection : rendus + fenêtre d'épreuve
say ""
c '1;37'; say " forensic.sh v$VERSION — relevé lecture seule"; c '0'
hr

if [ ${#REPOS_REF[@]} -eq 0 ]; then
  say "  recherche des rendus Epitech sur le poste…"
  mapfile -t DETECTED < <(
    find "$HOMEDIR" /media /mnt /run/media -xdev -maxdepth 6 -type d -name .git 2>/dev/null |
    while IFS= read -r d; do
      repo="${d%/.git}"
      url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)
      if printf '%s %s' "$url" "$(basename "$repo")" \
         | grep -qiE 'epitech|\b[A-Z]-[A-Z]{2,4}-[0-9]{3}'; then printf '%s\n' "$repo"; fi
    done | sort -u)
  if [ "${#DETECTED[@]}" -gt 0 ] && [ -n "${DETECTED[0]:-}" ]; then
    # les plus récemment travaillés d'abord : sur un poste étudiant il y en a un,
    # sur un poste de correcteur il y en a des centaines.
    mapfile -t DETECTED < <(
      for r in "${DETECTED[@]}"; do
        t=$(git -C "$r" log --all --format=%at 2>/dev/null | sort -n | tail -1)
        printf '%s\t%s\n' "${t:-0}" "$r"
      done | sort -rn | cut -f2-)
    # code module du dépôt le plus récent : on s'y tient. Sur un poste de
    # correcteur, cela écarte les projets d'autres modules (PSU, RPG, OOP…).
    if [ -z "$EXP_MODULE" ]; then
      EXP_MODULE=$(basename "${DETECTED[0]}" | grep -oE '\b[A-Z]-[A-Z]{2,4}-[0-9]{3}\b' | head -1)
    fi
    if [ -n "$EXP_MODULE" ]; then
      MKEEP=()
      for r in "${DETECTED[@]}"; do
        basename "$r" | grep -q "$EXP_MODULE" && MKEEP+=("$r")
      done
      if [ ${#MKEEP[@]} -gt 0 ]; then
        [ ${#MKEEP[@]} -lt ${#DETECTED[@]} ] && \
          say "  module de l'épreuve : $EXP_MODULE — $(( ${#DETECTED[@]} - ${#MKEEP[@]} )) dépôt(s) d'autres modules écarté(s)"
        DETECTED=("${MKEEP[@]}")
      fi
    fi
    NDET=${#DETECTED[@]}
    # une épreuve tient dans une journée : on ne garde que les dépôts travaillés
    # dans les 48 h du plus récent. Écarte les projets au long cours.
    NEWEST=$(git -C "${DETECTED[0]}" log --all --format=%at 2>/dev/null | sort -n | tail -1)
    if [ -n "$NEWEST" ]; then
      KEEP=()
      for r in "${DETECTED[@]}"; do
        t=$(git -C "$r" log --all --format=%at 2>/dev/null | sort -n | tail -1)
        [ -n "$t" ] && [ "$(date -d "@$t" +%F)" = "$(date -d "@$NEWEST" +%F)" ] && KEEP+=("$r")
      done
      [ ${#KEEP[@]} -gt 0 ] && DETECTED=("${KEEP[@]}")
    fi
    if [ "$NDET" -gt ${#DETECTED[@]} ]; then
      say "  $NDET rendus détectés, ${#DETECTED[@]} retenu(s) (travaillés le $(date -d "@$NEWEST" +%F)) :"
      say "     (--repo pour choisir explicitement)"
    else
      say "  $NDET rendu(s) détecté(s) :"
    fi
    if [ ${#DETECTED[@]} -gt 8 ]; then DETECTED=("${DETECTED[@]:0:8}"); fi
    for r in "${DETECTED[@]}"; do
      say "     $(basename "$r")  [dernier commit $(git -C "$r" log -1 --format=%ad --date=format:'%F %H:%M' 2>/dev/null || echo '?')]"
    done
    REPOS_REF=("${DETECTED[@]}")
  else
    say "  aucun rendu Epitech détecté sur le poste."
  fi
fi

if [ -z "$START_EPOCH" ] && [ "${#REPOS_REF[@]}" -gt 0 ]; then
  LAST=""
  for r in "${REPOS_REF[@]}"; do
    [ -d "$r" ] || continue
    l=$(git -C "$r" log --all --format=%at 2>/dev/null | sort -n | tail -1)
    [ -n "$l" ] && { [ -z "$LAST" ] || [ "$l" -gt "$LAST" ]; } && LAST="$l"
  done
  if [ -n "$LAST" ]; then
    # une épreuve tient dans une journée : on prend le jour du dernier commit,
    # puis le premier commit de CE jour comme borne basse.
    DAY=$(date -d "@$LAST" '+%Y-%m-%d')
    FIRSTDAY=""
    for r in "${REPOS_REF[@]}"; do
      [ -d "$r" ] || continue
      f=$(git -C "$r" log --all --format=%at 2>/dev/null \
          | awk -v d="$(date -d "$DAY 00:00:00" +%s)" -v e="$(date -d "$DAY 23:59:59" +%s)" \
                '$1>=d && $1<=e' | sort -n | head -1)
      [ -n "$f" ] && { [ -z "$FIRSTDAY" ] || [ "$f" -lt "$FIRSTDAY" ]; } && FIRSTDAY="$f"
    done
    if [ -n "$FIRSTDAY" ]; then
      START_EPOCH=$(( FIRSTDAY - 3600 ))   # une heure de marge avant le 1er commit
    else
      START_EPOCH=$(date -d "$DAY 00:00:00" +%s)
    fi
    [ -z "$END_EPOCH" ] && END_EPOCH="$LAST"
    say ""
    say "  fenêtre déduite de l'historique git des rendus :"
    say "     $(date -d "@$START_EPOCH" '+%F %T')  ->  $(date -d "@$END_EPOCH" '+%F %T')"
    say "     (--start / --end pour l'imposer)"
  fi
fi

if [ -z "$START_EPOCH" ] && [ -t 0 ]; then
  say ""
  printf "  Heure d'ouverture de l'épreuve [ex. 2026-09-16 10:00] : " >&2
  read -r _ans </dev/tty || _ans=""
  [ -n "$_ans" ] && START_EPOCH=$(date -d "$_ans" +%s 2>/dev/null)
fi
if [ -z "$START_EPOCH" ]; then
  warn "impossible de déterminer l'heure d'ouverture de l'épreuve."
  warn "relancer avec --start '2026-09-16 10:00'"
  exit 1
fi
[ -z "$END_EPOCH" ] && END_EPOCH=$(date +%s)
[ -n "$EXP_YEAR" ] || EXP_YEAR="$(date -d "@$START_EPOCH" +%Y)"

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
out "| Année attendue en en-tête | $EXP_YEAR |"
out "| Module attendu | ${EXP_MODULE:-_non précisé (\`--module\`)_} |"
out ""
out "> Ce document **ne conclut pas**. Il présente des faits horodatés."
out "> La conclusion est une décision humaine, prise en soutenance, avec l'étudiant."
out ""

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
  warn "aucun rendu détecté et aucun --name : repli générique, balayage large."
  warn "préférer --repo <dépôt-rendu> : le ciblage devient précis et rapide."
fi

# le NAME du Makefile de chaque rendu : c'est le binaire qu'on cherche
for r in "${REPOS_REF[@]:-}"; do
  [ -n "$r" ] && [ -f "$r/Makefile" ] || continue
  bn=$(sed -n 's/^[[:space:]]*NAME[[:space:]]*[:+?]*=[[:space:]]*//p' "$r/Makefile" 2>/dev/null \
       | head -1 | tr -d " \t")
  if [ -n "$bn" ]; then
    NAMES+=("$bn"); SIGS+=("$bn")
    step "binaire cherché : $bn  (déclaré par $(basename "$r"))"
  fi
done
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
        -o -name .npm -o -name .cargo -o -name .rustup -o -name .gradle
        -o -name vendor -o -name .nvm -o -name .m2 -o -name .pub-cache
        -o -name site-packages -o -name dist-packages -o -name .conda
        -o -name .mozilla -o -name .steam -o -name .gem -o -name .docker
        -o -name cmake-build-debug -o -name .platformio -o -name .vscode-server )

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
if [ "$NRAW" -gt 20000 ]; then
  warn "$NRAW candidats — ciblage trop large pour être exploitable."
  warn "passer --repo <dépôt-rendu>. Je garde les 20000 plus récents."
  xargs -d '\n' -r ls -td < "$RAW" 2>/dev/null | head -20000 > "$RAW.cap" || true
  [ -s "$RAW.cap" ] && mv "$RAW.cap" "$RAW"
  NRAW=$(wc -l < "$RAW")
fi
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

step "lecture des métadonnées en un seul passage (stat groupé)"
# %W naissance, %X accès, %Y modif, %Z changement, %i inode, %s taille, %U proprio
xargs -d '\n' -r stat -c '%W|%X|%Y|%Z|%i|%s|%U|%n' < "$RAW" > "$RAW.stat" 2>/dev/null || true
NSTAT=$(wc -l < "$RAW.stat")
step "$NSTAT fichier(s) lus — classement"

LC_ALL=C awk -F'|' -v S="$START_EPOCH" -v E="$END_EPOCH" -v H="$HOMEDIR" -v U="$TARGET_USER" '
function fmt(t) { return (t>0) ? strftime("%Y-%m-%d %H:%M:%S", t) : "-" }
{
  bE=$1+0; aE=$2+0; mE=$3+0; cE=$4+0; ino=$5; sz=$6; own=$7
  path=$8; for (k=9; k<=NF; k++) path = path "|" $k
  zone = "SYSTEME"
  if (index(path,H)==1 || index(path,"/tmp/")==1 || index(path,"/var/tmp/")==1 ||
      index(path,"/media/")==1 || index(path,"/mnt/")==1 || index(path,"/run/media/")==1 ||
      index(path,"/srv/")==1 || own==U) zone="ETUDIANT"
  ind=""
  if (bE>0 && bE<S) { ind=ind ",INODE-ANTERIEUR-EPREUVE"; npre++ }
  if (mE<S)         ind=ind ",CONTENU-ANTERIEUR-EPREUVE"
  if (bE>0 && mE<bE){ ind=ind ",IMPORTE-DATES-PRESERVEES"; nimp++ }
  if (bE>0 && mE>bE)  ind=ind ",MODIFIE-APRES-CREATION"
  if (cE>mE)          ind=ind ",METADONNEES-APRES-ECRITURE"
  if (mE>=S && mE<=E){ ind=ind ",ECRIT-PENDANT-EPREUVE"; nin++ }
  sub(/^,/,"",ind); if (ind=="") ind="-"
  printf "%d\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
    bE, fmt(bE), fmt(aE), fmt(mE), fmt(cE), mE, ino, sz, own, zone, ind, "-", path
}
END { printf "%d %d %d\n", npre, nimp, nin > "/dev/stderr" }
' "$RAW.stat" >> "$TIMELINE" 2> "$RAW.counts"

read -r NPRE NIMP NIN < "$RAW.counts"
NPRE=${NPRE:-0}; NIMP=${NIMP:-0}; NIN=${NIN:-0}
i=$(( $(wc -l < "$TIMELINE") - 1 ))

# sha256 seulement sur ce qui est signalé, et sous 20 Mo : l'empreinte ne sert
# qu'aux pièces qu'on cite, pas aux 150000 fichiers du disque
step "empreintes des fichiers signalés uniquement"
awk -F'\t' 'NR>1 && $10=="ETUDIANT" && $11 ~ /IMPORTE|ANTERIEUR/ {print $13}' "$TIMELINE" > "$RAW.tohash"
NHASH=$(wc -l < "$RAW.tohash")
if [ "$NHASH" -gt 0 ] && [ "$NHASH" -le 5000 ]; then
  : > "$RAW.hashes"
  while IFS= read -r f; do
    [ -f "$f" ] && [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -le 20971520 ] || continue
    printf '%s\t%s\n' "$(sha256sum "$f" 2>/dev/null | cut -c1-16)" "$f" >> "$RAW.hashes"
  done < "$RAW.tohash"
  LC_ALL=C awk -F'\t' 'NR==FNR{h[$2]=$1; next}
    FNR==1{print; next}
    { if ($13 in h) $12=h[$13]; print }' OFS='\t' "$RAW.hashes" "$TIMELINE" > "$TIMELINE.new" \
    && mv "$TIMELINE.new" "$TIMELINE"
  step "$(wc -l < "$RAW.hashes") empreinte(s) calculée(s)"
else
  [ "$NHASH" -gt 5000 ] && warn "$NHASH fichiers signalés : empreintes sautées (ciblage trop large)"
fi
rm -f "$RAW.stat" "$RAW.counts" "$RAW.tohash" "$RAW.hashes" 2>/dev/null
tickend
done_phase "$i fichier(s) horodaté(s) — $NPRE inode(s) antérieur(s), $NIMP importé(s)"

# ═══════════════════════════════════════════════════════════════════ phase 6
phase "Dépôts git présents sur le poste"

if [ -n "$EXP_MODULE" ]; then
  mapfile -t GITS < <(find "${ROOTS[@]}" -xdev -maxdepth 6 -type d -name .git 2>/dev/null \
                      | grep -i "$EXP_MODULE" | head -"$MAX_REPOS")
  step "limité aux dépôts du module $EXP_MODULE"
else
  mapfile -t GITS < <(find "${ROOTS[@]}" -xdev -maxdepth 6 -type d -name .git 2>/dev/null | head -"$MAX_REPOS")
fi
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

# ══════════════════════════════════════════════════════════════ phase 10 bis
phase "Le rendu existe-t-il ailleurs sur le poste ?"
say "     (binaire compilé ou implémentation trouvée hors du dépôt rendu)"

HORS="$OUT/.horsdepot.tsv"
printf 'type\tinode_ne_le\tcontenu_du\tantérieur\trendu\tchemin\n' > "$HORS"
N_HORS=0

if [ ${#REPOS_REF[@]} -eq 0 ]; then
  out "_Aucun rendu de référence : passer \`--repo\`._"
  done_phase "sautée"
else
for r in "${REPOS_REF[@]}"; do
  [ -n "$r" ] && [ -d "$r" ] || continue
  rname=$(basename "$r")
  rreal=$(cd "$r" && pwd -P)

  # 1) le binaire déclaré par le Makefile, compilé ailleurs
  bn=$(sed -n 's/^[[:space:]]*NAME[[:space:]]*[:+?]*=[[:space:]]*//p' "$r/Makefile" 2>/dev/null \
       | head -1 | tr -d " \t")
  if [ -n "$bn" ]; then
    step "$rname : recherche d'un binaire « $bn » hors du dépôt"
    while IFS= read -r f; do
      case "$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)/" in "$rreal"/*) continue ;; esac
      file -b "$f" 2>/dev/null | grep -qi 'ELF.*executable\|ELF.*shared object' || continue
      st=$(stat -c '%W|%Y' "$f" 2>/dev/null) || continue
      bE=${st%|*}; mE=${st#*|}
      ant="non"; [ "$mE" -lt "$START_EPOCH" ] && ant="OUI"
      printf 'BINAIRE\t%s\t%s\t%s\t%s\t%s\n' \
        "$([ "$bE" -gt 0 ] 2>/dev/null && date -d "@$bE" '+%F %T' || echo '-')" \
        "$(date -d "@$mE" '+%F %T')" "$ant" "$rname" "$f" >> "$HORS"
      N_HORS=$((N_HORS+1))
    done < <(find "${ROOTS[@]}" -xdev \( "${PRUNE[@]}" \) -prune -o -type f -name "$bn" -print 2>/dev/null)
  fi

  # 2) les symboles propres au rendu, trouvés dans un fichier hors du dépôt
  syms=$(grep -rhoE '^[a-zA-Z_][a-zA-Z0-9_ \*]*\b([a-z_][a-z0-9_]{5,})\(' "$r" 2>/dev/null \
         | grep -oE '[a-z_][a-z0-9_]{5,}\(' | tr -d '(' \
         | grep -vE '^(printf|sprintf|fprintf|snprintf|strcmp|strlen|strdup|malloc|memset|memcpy|fgets|fopen|fclose|fwrite|scanf|sscanf|isalpha|islower|isupper|strtol|opendir|readdir|closedir|unlink|write|main)$' \
         | sort -u | head -25)
  [ -n "$syms" ] || continue
  # un symbole présent dans beaucoup de fichiers ne discrimine rien
  # (parse_options, read_file… existent dans openvpn comme ailleurs).
  # On mesure sa rareté sur le corpus et on ne garde que les rares.
  rare=""
  for sym in $syms; do
    df=$(grep -lE "\\b$sym\\b" $(cat "$CAND") 2>/dev/null | wc -l)
    [ "$df" -le 2 ] && rare="$rare $sym"
  done
  rare=$(printf '%s' "$rare" | tr -s ' ')
  if [ -z "$(printf '%s' "$rare" | tr -d ' ')" ]; then
    step "$rname : aucun symbole discriminant (tous trop répandus)"
    continue
  fi
  SRE=$(printf '%s|' $rare | sed 's/|$//')
  step "$rname : $(printf '%s' "$rare" | wc -w) symbole(s) discriminant(s) recherchés hors du dépôt"
  while IFS= read -r f; do
    case "$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)/" in "$rreal"/*) continue ;; esac
    nm=$(grep -ohE "\b($SRE)\b" "$f" 2>/dev/null | sort -u | wc -l); nm=${nm:-0}
    [ "$nm" -ge 3 ] || continue
    st=$(stat -c '%W|%Y' "$f" 2>/dev/null) || continue
    bE=${st%|*}; mE=${st#*|}
    ant="non"; [ "$mE" -lt "$START_EPOCH" ] && ant="OUI"
    printf 'SOURCE(%s symboles propres)\t%s\t%s\t%s\t%s\t%s\n' "$nm" \
      "$([ "$bE" -gt 0 ] 2>/dev/null && date -d "@$bE" '+%F %T' || echo '-')" \
      "$(date -d "@$mE" '+%F %T')" "$ant" "$rname" "$f" >> "$HORS"
    N_HORS=$((N_HORS+1))
  done < "$CAND"
done

N_HORS_ANT=$(awk -F'\t' 'NR>1 && $4=="OUI"' "$HORS" | wc -l)
out "On cherche, **hors du dépôt rendu**, le binaire que son \`Makefile\` déclare et les"
out "fonctions qu'il définit. Un exemplaire trouvé ailleurs **et antérieur à l'épreuve**"
out "est le fait le plus direct que ce relevé puisse produire."
out ""
out "| | |"
out "|---|---:|"
out "| Exemplaires trouvés hors du rendu | **$N_HORS** |"
out "| dont **antérieurs à l'épreuve** | **$N_HORS_ANT** |"
out ""
if [ "$N_HORS" -gt 0 ]; then
  out "| Type | Inode né le | Contenu du | Antérieur | Rendu concerné | Chemin |"
  out "|---|---|---|:-:|---|---|"
  sort -t$'\t' -k4,4r -k3,3 "$HORS" | awk -F'\t' 'NR>0 && $1!="type" {
      printf "| %s | %s | %s | %s | `%s` | `%s` |\n",$1,$2,$3,$4,$5,$6 }' | head -50 >> "$REPORT"
  out ""
  [ "$N_HORS_ANT" -gt 0 ] && out "> **$N_HORS_ANT exemplaire(s) antérieur(s) à l'épreuve.** À faire constater à l'étudiant, et à lui faire expliquer."
else
  out "**Rien trouvé hors du dépôt rendu.** Ni binaire compilé, ni fichier reprenant les"
  out "fonctions du rendu. C'est un résultat, pas une absence de résultat : sur ce poste,"
  out "le code du rendu n'existe qu'à un seul endroit."
fi
out ""
done_phase "$N_HORS exemplaire(s) hors dépôt, dont $N_HORS_ANT antérieur(s)"
fi

# ══════════════════════════════════════════════════════════════════ phase 11
phase "Marqueurs de provenance dans le code"
say "     (en-tête EPITECH, module, convention de nommage ft_ / my_)"

MARK="$OUT/.markers.tsv"
printf 'annee\tmodule\tft\tmy\tanomalies\tchemin\n' > "$MARK"

# fichiers source de la zone étudiant, + ceux des dépôts passés en --repo
{
  awk -F'\t' 'NR>1 && $10=="ETUDIANT" {print $13}' "$TIMELINE"
  for r in "${REPOS_REF[@]:-}"; do
    [ -n "$r" ] && [ -d "$r" ] && find "$r" -type f \( -name '*.c' -o -name '*.h' \) 2>/dev/null
  done
} | grep -E '\.(c|h|cpp|hpp)$' | sort -u > "$MARK.files"

NMARKF=$(wc -l < "$MARK.files")
step "$NMARKF fichier(s) source à analyser"

i=0; N_YEAR=0; N_MOD=0; N_FT=0
while IFS= read -r f; do
  i=$((i+1))
  [ $((i % 25)) -eq 0 ] && tick "marqueurs : $i/$NMARKF  ($(el))"
  [ -r "$f" ] || continue
  head -c 8000 "$f" > "$MARK.head" 2>/dev/null || continue

  yrs=$(grep -oE 'EPITECH PROJECT, *[0-9]{4}' "$MARK.head" 2>/dev/null \
        | grep -oE '[0-9]{4}' | sort -u | paste -sd',' -)
  mods=$(grep -oE '\b[A-Z]-[A-Z]{2,4}-[0-9]{3}\b' "$MARK.head" 2>/dev/null \
        | sort -u | paste -sd',' -)
  ft=$(grep -coE '\bft_[a-z_0-9]+' "$f" 2>/dev/null); ft=${ft:-0}
  my=$(grep -coE '\bmy_[a-z_0-9]+' "$f" 2>/dev/null); my=${my:-0}

  an=""
  if [ -n "$yrs" ]; then
    case ",$yrs," in
      *",$EXP_YEAR,"*) ;;
      *) an="$an,ANNEE-INATTENDUE($yrs)"; N_YEAR=$((N_YEAR+1)) ;;
    esac
  fi
  if [ -n "$EXP_MODULE" ] && [ -n "$mods" ]; then
    case ",$mods," in
      *",$EXP_MODULE,"*) ;;
      *) an="$an,MODULE-INATTENDU($mods)"; N_MOD=$((N_MOD+1)) ;;
    esac
  fi
  if [ "$ft" -gt 0 ]; then an="$an,PREFIXE-FT($ft)"; N_FT=$((N_FT+1)); fi
  an="${an#,}"; [ -z "$an" ] && an="-"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${yrs:--}" "${mods:--}" "$ft" "$my" "$an" "$f" >> "$MARK"
done < "$MARK.files"
tickend
rm -f "$MARK.head"

N_ANO=$(awk -F'\t' 'NR>1 && $5!="-"' "$MARK" | wc -l)
TOT_FT=$(awk -F'\t' 'NR>1 {n+=$3} END{print n+0}' "$MARK")
TOT_MY=$(awk -F'\t' 'NR>1 {n+=$4} END{print n+0}' "$MARK")

out "Trois marqueurs, lus dans le code lui-même. Aucun ne conclut seul ;"
out "c'est leur **concentration sur un même auteur ou un même fichier** qui parle."
out ""
out "| Marqueur | Ce qu'il signale |"
out "|---|---|"
out "| \`ANNEE-INATTENDUE\` | l'en-tête \`EPITECH PROJECT, AAAA\` ne porte pas $EXP_YEAR. Le tampon d'année est posé par le greffon d'éditeur **à la création du fichier** : une autre année veut dire que le fichier, ou le modèle dont il est issu, est plus ancien. |"
out "| \`MODULE-INATTENDU\` | l'en-tête porte un autre module que \`${EXP_MODULE:-celui attendu}\`. Un \`B-CPE-210\` dans un projet \`G-CPE-210\` vient d'un modèle recopié. |"
out "| \`PREFIXE-FT\` | \`ft_*\` est la convention de nommage de **42** ; Epitech utilise \`my_*\`. |"
out ""
out "### Relevé global"
out ""
out "| | |"
out "|---|---:|"
out "| Fichiers source analysés | $NMARKF |"
out "| Année d'en-tête inattendue | **$N_YEAR** |"
out "| Module inattendu | **$N_MOD** |"
out "| Fichiers employant \`ft_\` | **$N_FT** |"
out "| Occurrences \`ft_\` / \`my_\` | $TOT_FT / $TOT_MY |"
out ""

if [ "$N_ANO" -gt 0 ]; then
  out "### Fichiers porteurs d'au moins un marqueur"
  out ""
  out "| Année | Module | \`ft_\` | \`my_\` | Anomalies | Chemin |"
  out "|---|---|--:|--:|---|---|"
  awk -F'\t' 'NR>1 && $5!="-" {n=split($5,a,","); printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n",n,$1,$2,$3,$4,$5,$6}' "$MARK" \
    | sort -t$'\t' -k1,1nr -k2,2 \
    | awk -F'\t' '{printf "| %s | %s | %s | %s | `%s` | `%s` |\n",$2,$3,$4,$5,$6,$7}' \
    | head -60 >> "$REPORT"
  out ""
  out "_$N_ANO fichier(s) concerné(s)._"
else
  out "**Aucun marqueur de provenance relevé.** En-têtes, modules et conventions de"
  out "nommage sont homogènes sur les $NMARKF fichiers analysés."
fi
out ""
out "### Répartition des années d'en-tête"
out ""
out "| Année | Fichiers |"
out "|---|--:|"
awk -F'\t' 'NR>1 && $1!="-" {split($1,y,","); for(k in y) n[y[k]]++}
            END{for(a in n) printf "| %s | %d |\n", a, n[a]}' "$MARK" | sort >> "$REPORT"
out ""
out "### Répartition des modules déclarés"
out ""
out "| Module | Fichiers |"
out "|---|--:|"
awk -F'\t' 'NR>1 && $2!="-" {split($2,m,","); for(k in m) n[m[k]]++}
            END{for(a in n) printf "| %s | %d |\n", a, n[a]}' "$MARK" | sort >> "$REPORT"
out ""

done_phase "$NMARKF fichier(s) analysés — $N_ANO porteur(s) de marqueur"

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

# ─────────────────────────────────────────────── analyse.txt (texte brut)
ANALYSE="$OUT/analyse.txt"
{
  echo "═══════════════════════════════════════════════════════════════════════"
  echo " ANALYSE FORENSIQUE — poste $(hostname 2>/dev/null || echo inconnu)"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo
  echo "  Relevé du      : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "  Compte examiné : $TARGET_USER  ($HOMEDIR)"
  echo "  Épreuve        : $(date -d "@$START_EPOCH" '+%F %T')  ->  $(date -d "@$END_EPOCH" '+%F %T')"
  echo "  Année attendue : $EXP_YEAR"
  echo "  Module attendu : ${EXP_MODULE:-(non précisé)}"
  echo "  Durée          : $(el)"
  echo
  echo "───────────────────────────────────────────────────────────────────────"
  echo " 1. DATES DES FICHIERS"
  echo "───────────────────────────────────────────────────────────────────────"
  echo
  printf '   %-42s %8s %8s\n' '' 'TOTAL' 'ETUDIANT'
  printf '   %-42s %8s %8s\n' '------------------------------------------' '--------' '--------'
  printf '   %-42s %8s %8s\n' 'Fichiers candidats'                    "$TOT"     "$NETU"
  printf '   %-42s %8s %8s\n' "Inode anterieur a l'epreuve"           "$A_INODE" "$AZ_INODE"
  printf '   %-42s %8s %8s\n' "Contenu anterieur a l'epreuve"         "$A_CONT"  "$AZ_CONT"
  printf '   %-42s %8s %8s\n' 'IMPORTE (dates preservees)'            "$A_IMP"   "$AZ_IMP"
  printf '   %-42s %8s %8s\n' "Ecrit pendant l'epreuve"               "$A_PEND"  "$AZ_PEND"
  printf '   %-42s %8s %8s\n' 'Metadonnees modifiees apres ecriture'  "$A_META"  "$AZ_META"
  echo
  echo "   IMPORTE-DATES-PRESERVEES est l'indice le plus parlant : le contenu"
  echo "   est plus vieux que l'inode qui le porte, donc le fichier a ete"
  echo "   apporte (cp -p, tar -x, git clone, cle USB) et non ecrit sur place."
  echo
  echo "───────────────────────────────────────────────────────────────────────"
  echo " 2. LE RENDU EXISTE-T-IL AILLEURS SUR LE POSTE ?"
  echo "───────────────────────────────────────────────────────────────────────"
  echo
  if [ -s "$HORS" ] && [ "${N_HORS:-0}" -gt 0 ]; then
    printf '   %-42s %8s\n' 'Exemplaires trouves hors du rendu'  "${N_HORS:-0}"
    printf '   %-42s %8s\n' "dont ANTERIEURS a l'epreuve"        "${N_HORS_ANT:-0}"
    echo
    printf '     %-22s %-19s %-9s %s\n' TYPE 'CONTENU DU' 'ANTERIEUR' 'CHEMIN'
    sort -t$'\t' -k4,4r -k3,3 "$HORS" | awk -F'\t' '$1!="type" {
        printf "     %-22s %-19s %-9s %s\n", $1, $3, $4, $6 }' | head -40
    echo
    if [ "${N_HORS_ANT:-0}" -gt 0 ]; then
      echo "   >> ${N_HORS_ANT} exemplaire(s) ANTERIEUR(S) a l'epreuve."
      echo "      C'est le fait le plus direct de ce releve : le code du rendu"
      echo "      existait deja sur la machine avant l'ouverture de l'epreuve."
      echo "      A faire constater a l'etudiant et a lui faire expliquer."
    fi
  else
    echo "   Rien trouve hors du depot rendu : ni binaire compile, ni fichier"
    echo "   reprenant les fonctions du rendu."
    echo "   C'est un resultat, pas une absence de resultat : sur ce poste, le"
    echo "   code du rendu n'existe qu'a un seul endroit."
  fi
  echo
  echo "───────────────────────────────────────────────────────────────────────"
  echo " 3. MARQUEURS DE PROVENANCE DANS LE CODE"
  echo "───────────────────────────────────────────────────────────────────────"
  echo
  printf '   %-42s %8s\n' 'Fichiers source analyses'      "$NMARKF"
  printf '   %-42s %8s\n' "Annee d'en-tete inattendue"    "$N_YEAR"
  printf '   %-42s %8s\n' 'Module inattendu'              "$N_MOD"
  printf '   %-42s %8s\n' 'Fichiers employant ft_'        "$N_FT"
  printf '   %-42s %8s\n' 'Occurrences ft_'               "$TOT_FT"
  printf '   %-42s %8s\n' 'Occurrences my_'               "$TOT_MY"
  echo
  echo "   Annees d'en-tete relevees :"
  awk -F'\t' 'NR>1 && $1!="-" {split($1,y,","); for(k in y) n[y[k]]++}
              END{for(a in n) printf "     %-8s %d fichier(s)\n", a, n[a]}' "$MARK" | sort
  echo
  echo "   Modules declares :"
  awk -F'\t' 'NR>1 && $2!="-" {split($2,m,","); for(k in m) n[m[k]]++}
              END{for(a in n) printf "     %-14s %d fichier(s)\n", a, n[a]}' "$MARK" | sort
  echo
  if [ "$N_ANO" -gt 0 ]; then
    echo "   Fichiers porteurs d'au moins un marqueur :"
    echo
    printf '     %-6s %-12s %4s %4s  %s\n' ANNEE MODULE 'ft_' 'my_' 'CHEMIN / ANOMALIES'
    awk -F'\t' 'NR>1 && $5!="-" {n=split($5,a,","); printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n",n,$1,$2,$3,$4,$5,$6}' "$MARK" \
    | sort -t$'\t' -k1,1nr -k2,2 | head -60 \
    | awk -F'\t' '{
        printf "     %-6s %-12s %4s %4s  %s\n", $2, $3, $4, $5, $7
        printf "     %-6s %-12s %4s %4s    -> [%s marqueur(s)] %s\n", "", "", "", "", $1, $6
      }' 
  else
    echo "   Aucun marqueur de provenance releve."
    echo "   En-tetes, modules et conventions de nommage sont homogenes."
  fi
  echo
  echo "───────────────────────────────────────────────────────────────────────"
  echo " 4. CANDIDATS LES PLUS PARLANTS — ZONE ETUDIANT"
  echo "───────────────────────────────────────────────────────────────────────"
  echo
  if [ "$NSHOWN" -eq 0 ]; then
    echo "   Aucun fichier de la zone etudiant n'est anterieur a l'epreuve"
    echo "   ni porteur de dates preservees."
  else
    printf '     %-19s %-19s %10s  %s\n' 'ECRIT LE (Modify)' 'CREE LE (Birth)' 'TAILLE' 'CHEMIN'
    awk -F'\t' '
      NR>1 && $10=="ETUDIANT" && ($11 ~ /IMPORTE|ANTERIEUR/) {
        prio = ($11 ~ /IMPORTE/) ? 0 : 1
        printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", prio, $6, $4, $2, $8, $11, $13
      }' "$TIMELINE" \
    | sort -t$'\t' -k1,1n -k2,2n | head -40 \
    | awk -F'\t' '{ printf "     %-19s %-19s %10s  %s\n", $3, $4, $5, $7; printf "     %-19s %-19s %10s    -> %s\n","","","",$6 }'
    echo
    echo "   $NSHOWN fichier(s) concerne(s) ; les 40 premiers sont listes."
    echo "   Tableau complet : chronologie.tsv"
  fi
  echo
  if [ "$WITH_PV" -eq 1 ]; then
  echo "───────────────────────────────────────────────────────────────────────"
  echo " 5. LIMITES ET PROCES-VERBAL"
  echo "───────────────────────────────────────────────────────────────────────"
  echo
  echo "   Ce releve date des fichiers ; il ne dit pas qui a ecrit le code."
  echo "   Objections a prevoir : copie depuis une cle (relever la cle avec"
  echo "   --root), cp -p qui preserve les dates (c'est ce que designe"
  echo "   IMPORTE-DATES-PRESERVEES), horloge faussee (verifiable au journal)."
  echo
  ( cd "$OUT" && sha256sum RAPPORT.md chronologie.tsv candidats.txt 2>/dev/null | sed 's/^/   /' )
  echo
  echo "   A faire signer : date, heure, lieu, poste ; noms du staff et de"
  echo "   l'etudiant ; les empreintes ci-dessus ; la declaration de l'etudiant."
  echo
  fi
  echo "═══════════════════════════════════════════════════════════════════════"
} > "$ANALYSE"

rm -f "$MARK.files" 2>/dev/null
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
c '1;37'; printf '   Analyse      %s\n' "$ANALYSE" >&2; c '0'
printf '   Rapport      %s\n' "$REPORT" >&2
printf '   Chronologie  %s\n' "$TIMELINE" >&2
printf '   Copies       %s/copies\n' "$OUT" >&2
printf '\n' >&2
printf '   %s\n' "Le releve ne conclut pas. La conclusion se prend en soutenance, avec l'etudiant." >&2
printf '\n' >&2
