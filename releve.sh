#!/usr/bin/env bash
# Relevé forensique — lanceur court.
#
#   git clone https://github.com/edwinfranck/stumper-forensics.git
#   cd stumper-forensics
#   chmod +x releve.sh
#   sudo ./releve.sh
#
# Les dates de l'épreuve se règlent dans epreuve.conf (ou en argument).
# Tout argument supplémentaire est passé tel quel à stumper_forensics.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/epreuve.conf" ] && . "$HERE/epreuve.conf"
START="${START:-}"; END="${END:-}"; SIGNATURES="${SIGNATURES:-}"

[ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"

if [ -z "$START" ]; then
  echo "Renseigner START (et idéalement END) dans $HERE/epreuve.conf" >&2
  echo "  ex. START='2026-09-16 10:00'" >&2
  exit 1
fi

# rapport : sur une clé USB si on en trouve une inscriptible, sinon à côté du script
OUT=""
for m in /media/*/* /run/media/*/* /mnt/*; do
  [ -d "$m" ] && [ -w "$m" ] && { OUT="$m/releve-$(hostname)-$(date +%Y%m%d-%H%M%S)"; break; }
done
if [ -z "$OUT" ]; then
  OUT="$HERE/releve-$(hostname)-$(date +%Y%m%d-%H%M%S)"
  echo "!! Aucune clé USB inscriptible trouvée."
  echo "!! Le rapport ira dans $OUT — donc sur le disque examiné."
  echo "!! Brancher une clé est préférable : on n'écrit pas sur la pièce à conviction."
  printf '   Continuer quand même ? [o/N] '
  read -r r </dev/tty || r=""
  case "$r" in [oOyY]*) ;; *) echo "abandon."; exit 2 ;; esac
fi

SIG_ARGS=()
for s in $SIGNATURES; do SIG_ARGS+=(--signature "$s"); done
END_ARGS=(); [ -n "$END" ] && END_ARGS=(--end "$END")

echo "Relevé en cours — rapport : $OUT"
exec "$HERE/stumper_forensics.sh" \
  --start "$START" "${END_ARGS[@]}" "${SIG_ARGS[@]}" --out "$OUT" "$@"
