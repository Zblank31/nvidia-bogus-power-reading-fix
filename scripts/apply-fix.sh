#!/usr/bin/env bash
# apply-fix.sh — installs the workaround for ONE GPU: writes a modprobe option for the NVIDIA module and rebuilds the initramfs.
# Installe le contournement pour UNE carte : écrit une option modprobe pour le module NVIDIA et reconstruit l'initramfs.
#
# What it writes (example):   options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:09:00.0;RmPmgrPmuOverride=1;"
# Effect: for that GPU only, the driver firmware stops using the PMU-based power management (power readings AND power limit).
# READ THE README FIRST (side effects, when NOT to use it).
#
# Usage : sudo ./apply-fix.sh --bus 0000:09:00.0          (find your address with: ./apply-fix.sh --list)
#   --list            list the NVIDIA GPUs and their PCI addresses, then exit
#   --bus ADDR        PCI address of the card to fix (09:00.0 or 0000:09:00.0)
#   --key K=V         registry key to set instead of the default (advanced)   [default: RmPmgrPmuOverride=1]
#   --conf FILE       configuration file to write                              [default: /etc/modprobe.d/nvidia-bogus-power-fix.conf]
#   --no-initramfs    do not rebuild the initramfs (e.g. if your distro loads nvidia from the root filesystem)
#   --dry-run         show what would be done, change nothing (no root needed)
#   --yes             do not ask for confirmation
set -u
. "$(dirname "$0")/lib.sh"

BUS=""; KEY="$DEFAULT_KEY"; CONF="$DEFAULT_CONF"; DRY=0; YES=0; INITRAMFS=1; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bus) BUS="${2:-}"; shift 2;;
    --key) KEY="${2:-}"; shift 2;;
    --conf) CONF="${2:-}"; shift 2;;
    --no-initramfs) INITRAMFS=0; shift;;
    --dry-run) DRY=1; shift;;
    --yes) YES=1; shift;;
    --list) LIST=1; shift;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "Option inconnue : $1 (voir --help)" "Unknown option: $1 (see --help)";;
  esac
done

command -v lspci >/dev/null 2>&1 || die "lspci introuvable (paquet pciutils)." "lspci not found (package pciutils)."
GPUS=$(list_gpus)
if [ "$LIST" = 1 ] || [ -z "$BUS" ]; then
  t "Cartes NVIDIA trouvées (adresse PCI, identifiant, nom) :" "NVIDIA GPUs found (PCI address, ID, name):"
  [ -n "$GPUS" ] && echo "$GPUS" | sed 's/^/  /' || t "  (aucune)" "  (none)"
  if [ "$LIST" = 1 ]; then exit 0; fi
  if [ "$(echo "$GPUS" | grep -c .)" = 1 ]; then BUS=${GPUS%% *}; t "Une seule carte : j'utilise $BUS." "Only one GPU: using $BUS."
  else die "Précise la carte à corriger avec --bus (voir la liste ci-dessus)." "Say which card to fix with --bus (see the list above)."; fi
fi

BUS=$(normalize_bus "$BUS") || die "Adresse PCI invalide (attendu : 09:00.0 ou 0000:09:00.0)." "Invalid PCI address (expected 09:00.0 or 0000:09:00.0)."
echo "$GPUS" | grep -q "^$BUS " || die "$BUS n'est pas une carte NVIDIA de cette machine (voir --list)." "$BUS is not an NVIDIA GPU of this machine (see --list)."
[[ $KEY =~ ^[A-Za-z0-9_]+=[A-Za-z0-9_x]+$ ]] || die "Clé invalide : $KEY (attendu NOM=valeur)." "Invalid key: $KEY (expected NAME=value)."
LINE="options nvidia NVreg_RegistryDwordsPerDevice=\"pci=${BUS};${KEY};\""

t "" ""
t "Carte à corriger : $(echo "$GPUS" | grep "^$BUS ")" "GPU to fix: $(echo "$GPUS" | grep "^$BUS ")"
t "Fichier         : $CONF" "File           : $CONF"
t "Contenu         : $LINE" "Content        : $LINE"
t "" ""
t "Effets de bord : cette carte n'aura plus de lecture de puissance ni de limite de puissance (nvidia-smi affichera N/A)." "Side effects: that card will have no power reading and no power limit (nvidia-smi will show N/A)."
t "Ne l'applique PAS si la consommation affichée est réelle (compare avec un wattmètre de prise : voir le README)." "Do NOT apply it if the displayed power draw is real (compare with a wall power meter: see the README)."

if [ "$DRY" = 1 ]; then t "(--dry-run : rien n'a été modifié)" "(--dry-run: nothing was changed)"; exit 0; fi
[ -w "$(dirname "$CONF")" ] || need_root   # root is only needed when the target directory is not writable
if [ "$YES" != 1 ]; then
  if [ "$FR" = 1 ]; then read -r -p "Continuer ? [o/N] " a; case "$a" in o|O|oui|OUI|y|Y|yes) ;; *) echo "Annulé."; exit 1;; esac
  else read -r -p "Continue? [y/N] " a; case "$a" in y|Y|yes|YES|o|O|oui) ;; *) echo "Cancelled."; exit 1;; esac; fi
fi

{
  echo "# NVIDIA bogus power reading workaround — installed $(date '+%F %T') by scripts/apply-fix.sh"
  echo "# Remove with scripts/remove-fix.sh (then rebuild the initramfs and reboot)."
  echo "$LINE"
} > "$CONF" || die "Impossible d'écrire $CONF." "Cannot write $CONF."
chmod 644 "$CONF"
t "Fichier écrit : $CONF" "File written: $CONF"

# does modprobe see it?
if command -v modprobe >/dev/null 2>&1 && ! modprobe -C "$(dirname "$CONF")" -c 2>/dev/null | grep -qF "pci=${BUS};${KEY};"; then
  rm -f "$CONF"; die "modprobe ne voit pas l'option (fichier retiré). Ce n'est pas normal : ouvre un ticket." "modprobe does not see the option (file removed). That is not normal: please open an issue."
fi

if [ "$INITRAMFS" = 1 ]; then
  rebuild_initramfs || t "(l'initramfs n'a pas pu être reconstruit automatiquement)" "(the initramfs could not be rebuilt automatically)"
fi
t "" ""
t "Fait. REDÉMARRE, puis lance ./verify.sh --bus $BUS pour vérifier." "Done. REBOOT, then run ./verify.sh --bus $BUS to check."
t "Retour arrière : sudo ./remove-fix.sh" "Undo: sudo ./remove-fix.sh"
