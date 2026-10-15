#!/usr/bin/env bash
# Install the workaround for ONE card: write a modprobe option for the nvidia module, rebuild the initramfs.
#
# The file it writes looks like this (the address is the card's PCI address):
#   options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
# For that card only, the firmware then stops using the PMU's power management: no more power
# reading and no more power limit. Read the README (side effects, when NOT to use this) first.
#
#   sudo ./apply-fix.sh --bus 0000:09:00.0          find the address with: ./apply-fix.sh --list
#
#   --list           list the NVIDIA cards and their PCI addresses, then exit
#   --bus ADDR       card to fix, as 09:00.0 or 0000:09:00.0
#   --key K=V        registry key to set instead of the default       [RmPmgrPmuOverride=1]
#   --conf FILE      configuration file to write                      [/etc/modprobe.d/nvidia-bogus-power-fix.conf]
#   --no-initramfs   skip the initramfs rebuild (distros that load nvidia from the root filesystem)
#   --dry-run        print what would be done, change nothing (no root needed)
#   --yes            don't ask for confirmation
set -u
. "$(dirname "$0")/lib.sh"

bus=""; key="$DEFAULT_KEY"; conf="$DEFAULT_CONF"
dry_run=0; assume_yes=0; do_initramfs=1; list_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --bus)          bus="${2:-}"; shift 2 ;;
    --key)          key="${2:-}"; shift 2 ;;
    --conf)         conf="${2:-}"; shift 2 ;;
    --no-initramfs) do_initramfs=0; shift ;;
    --dry-run)      dry_run=1; shift ;;
    --yes)          assume_yes=1; shift ;;
    --list)         list_only=1; shift ;;
    -h | --help)    sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)              die "Option inconnue : $1 (voir --help)" "Unknown option: $1 (see --help)" ;;
  esac
done

command -v lspci >/dev/null 2>&1 || die "lspci introuvable (paquet pciutils)." "lspci not found (package pciutils)."
gpus=$(list_gpus)

# --list, or no --bus given: show the cards. With a single card we can pick it ourselves.
if [ "$list_only" = 1 ] || [ -z "$bus" ]; then
  say "Cartes NVIDIA trouvées (adresse PCI, identifiant, nom) :" "NVIDIA cards found (PCI address, ID, name):"
  if [ -n "$gpus" ]; then echo "$gpus" | sed 's/^/  /'; else say "  (aucune)" "  (none)"; fi
  [ "$list_only" = 1 ] && exit 0
  if [ "$(echo "$gpus" | grep -c .)" = 1 ]; then
    bus=${gpus%% *}
    say "Une seule carte : j'utilise $bus." "Only one card: using $bus."
  else
    die "Précise la carte à corriger avec --bus (voir la liste ci-dessus)." "Say which card to fix with --bus (see the list above)."
  fi
fi

bus=$(normalize_bus "$bus") || die "Adresse PCI invalide (attendu : 09:00.0 ou 0000:09:00.0)." "Invalid PCI address (expected 09:00.0 or 0000:09:00.0)."
echo "$gpus" | grep -q "^$bus " || die "$bus n'est pas une carte NVIDIA de cette machine (voir --list)." "$bus is not an NVIDIA card of this machine (see --list)."
[[ $key =~ ^[A-Za-z0-9_]+=[A-Za-z0-9_x]+$ ]] || die "Clé invalide : $key (attendu NOM=valeur)." "Invalid key: $key (expected NAME=value)."

# The quotes matter (modprobe.d would split on the semicolons otherwise) and so does the final ';'.
line="options nvidia NVreg_RegistryDwordsPerDevice=\"pci=${bus};${key};\""

echo
say "Carte à corriger : $(echo "$gpus" | grep "^$bus ")" "Card to fix: $(echo "$gpus" | grep "^$bus ")"
say "Fichier         : $conf" "File           : $conf"
say "Contenu         : $line" "Content        : $line"
echo
say "Effets de bord : cette carte n'aura plus de lecture de puissance ni de limite de puissance (nvidia-smi affichera N/A)." \
    "Side effects: that card will have no power reading and no power limit (nvidia-smi will show N/A)."
say "Ne l'applique PAS si la consommation affichée est réelle (compare avec un wattmètre de prise : voir le README)." \
    "Do NOT apply it if the displayed power draw is real (compare with a wall power meter: see the README)."

if [ "$dry_run" = 1 ]; then
  say "(--dry-run : rien n'a été modifié)" "(--dry-run: nothing was changed)"
  exit 0
fi

# only ask for root when the target directory isn't writable (lets the script be tested on a scratch directory)
[ -w "$(dirname "$conf")" ] || need_root

if [ "$assume_yes" != 1 ]; then
  if [ "$FR" = 1 ]; then
    read -r -p "Continuer ? [o/N] " answer
    case "$answer" in o | O | oui | OUI | y | Y | yes) ;; *) echo "Annulé."; exit 1 ;; esac
  else
    read -r -p "Continue? [y/N] " answer
    case "$answer" in y | Y | yes | YES | o | O | oui) ;; *) echo "Cancelled."; exit 1 ;; esac
  fi
fi

{
  echo "# NVIDIA bogus power reading workaround, installed $(date '+%F %T') by scripts/apply-fix.sh"
  echo "# Remove with scripts/remove-fix.sh (then rebuild the initramfs and reboot)."
  echo "$line"
} > "$conf" || die "Impossible d'écrire $conf." "Cannot write $conf."
chmod 644 "$conf"
say "Fichier écrit : $conf" "File written: $conf"

# Sanity check: does modprobe parse the line the way we meant it? If not, leave nothing behind.
if command -v modprobe >/dev/null 2>&1 && ! modprobe -C "$(dirname "$conf")" -c 2>/dev/null | grep -qF "pci=${bus};${key};"; then
  rm -f "$conf"
  die "modprobe ne voit pas l'option (fichier retiré). Ce n'est pas normal : ouvre un ticket." \
      "modprobe does not see the option (file removed). That is not normal: please open an issue."
fi

if [ "$do_initramfs" = 1 ]; then
  rebuild_initramfs || say "(l'initramfs n'a pas pu être reconstruit automatiquement)" "(the initramfs could not be rebuilt automatically)"
fi

echo
say "Fait. REDÉMARRE, puis lance ./verify.sh --bus $bus pour vérifier." "Done. REBOOT, then run ./verify.sh --bus $bus to check."
say "Retour arrière : sudo ./remove-fix.sh" "Undo: sudo ./remove-fix.sh"
