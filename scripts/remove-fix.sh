#!/usr/bin/env bash
# Remove the workaround installed by apply-fix.sh and rebuild the initramfs. Takes effect at the next boot.
#
#   sudo ./remove-fix.sh [--conf FILE] [--no-initramfs] [--dry-run]
set -u
. "$(dirname "$0")/lib.sh"

conf="$DEFAULT_CONF"; do_initramfs=1; dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --conf)         conf="${2:-}"; shift 2 ;;
    --no-initramfs) do_initramfs=0; shift ;;
    --dry-run)      dry_run=1; shift ;;
    -h | --help)    sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)              die "Option inconnue : $1" "Unknown option: $1" ;;
  esac
done

if [ ! -e "$conf" ]; then
  say "Rien à retirer : $conf n'existe pas." "Nothing to remove: $conf does not exist."
  exit 0
fi

say "Fichier à supprimer : $conf" "File to delete: $conf"
grep -v '^#' "$conf" | sed 's/^/  /'
if [ "$dry_run" = 1 ]; then
  say "(--dry-run : rien n'a été modifié)" "(--dry-run: nothing was changed)"
  exit 0
fi

[ -w "$(dirname "$conf")" ] || need_root
rm -f "$conf"
if [ "$do_initramfs" = 1 ]; then rebuild_initramfs || true; fi
say "Fait. Le contournement disparaît au prochain démarrage (la carte retrouve son comportement d'origine)." \
    "Done. The workaround disappears at the next boot (the card goes back to its original behaviour)."
