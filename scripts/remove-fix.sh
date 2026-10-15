#!/usr/bin/env bash
# remove-fix.sh — removes the workaround installed by apply-fix.sh and rebuilds the initramfs. Takes effect at the next boot.
# Retire le contournement installé par apply-fix.sh et reconstruit l'initramfs. Effet au prochain démarrage.
#
# Usage : sudo ./remove-fix.sh [--conf FILE] [--no-initramfs] [--dry-run]
set -u
. "$(dirname "$0")/lib.sh"
CONF="$DEFAULT_CONF"; INITRAMFS=1; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --conf) CONF="${2:-}"; shift 2;;
    --no-initramfs) INITRAMFS=0; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "Option inconnue : $1" "Unknown option: $1";;
  esac
done
if [ ! -e "$CONF" ]; then t "Rien à retirer : $CONF n'existe pas." "Nothing to remove: $CONF does not exist."; exit 0; fi
t "Fichier à supprimer : $CONF" "File to delete: $CONF"; grep -v '^#' "$CONF" | sed 's/^/  /'
if [ "$DRY" = 1 ]; then t "(--dry-run : rien n'a été modifié)" "(--dry-run: nothing was changed)"; exit 0; fi
[ -w "$(dirname "$CONF")" ] || need_root   # root is only needed when the target directory is not writable
rm -f "$CONF"
[ "$INITRAMFS" = 1 ] && { rebuild_initramfs || true; }
t "Fait. Le contournement disparaît au prochain démarrage (la carte retrouve son comportement d'origine)." "Done. The workaround disappears at the next boot (the card goes back to its original behaviour)."
