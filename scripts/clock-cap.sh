#!/usr/bin/env bash
# Cap the maximum GPU clock of the fixed card at every boot, with a small systemd service.
#
# Why: with RmPmgrPmuOverride=1 nothing limits the power any more, and the fan is not regulated.
# A lower clock is a cheap safety net if the airflow ever gets worse. On the author's card,
# 1500 MHz instead of ~1950 gives ~20 TFLOPS instead of ~27 and ~50 C instead of ~68 C after 75 s.
#
# The lock set by "nvidia-smi -lgc" is forgotten at reboot and when the driver is reloaded,
# hence the service. To try a value first, without installing anything:
#   sudo nvidia-smi -i <index> -lgc 210,1500      (undo: sudo nvidia-smi -i <index> -rgc)
#
#   sudo ./clock-cap.sh --bus 0000:09:00.0 --max 1500 [--dry-run]
#   sudo ./clock-cap.sh --remove
set -u
. "$(dirname "$0")/lib.sh"

UNIT=/etc/systemd/system/gpu-clock-cap.service
bus=""; max=""; dry_run=0; remove=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bus)       bus="${2:-}"; shift 2 ;;
    --max)       max="${2:-}"; shift 2 ;;
    --remove)    remove=1; shift ;;
    --dry-run)   dry_run=1; shift ;;
    --list)      list_gpus; exit 0 ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)           die "Option inconnue : $1" "Unknown option: $1" ;;
  esac
done

if [ "$remove" = 1 ]; then
  [ "$dry_run" = 1 ] && { say "(--dry-run : rien n'a été modifié)" "(--dry-run: nothing was changed)"; exit 0; }
  need_root
  systemctl disable --now gpu-clock-cap.service 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  say "Service retiré, le verrou est levé." "Service removed, the clock lock is released."
  exit 0
fi

[ -n "$bus" ] || die "Il manque --bus (voir --list)." "Missing --bus (see --list)."
[ -n "$max" ] || die "Il manque --max (fréquence maximale en MHz)." "Missing --max (maximum clock in MHz)."
bus=$(normalize_bus "$bus") || die "Adresse PCI invalide : $bus" "Invalid PCI address: $bus"
case "$max" in '' | *[!0-9]*) die "--max doit être un nombre de MHz." "--max must be a number of MHz." ;; esac
[ "$max" -ge 300 ] && [ "$max" -le 3000 ] || die "--max hors de 300-3000 MHz." "--max outside 300-3000 MHz."
list_gpus | grep -q "^$bus " || die "Aucune carte NVIDIA à l'adresse $bus (voir --list)." "No NVIDIA card at $bus (see --list)."

smi=$(command -v nvidia-smi) || die "nvidia-smi introuvable." "nvidia-smi not found."

# 210 MHz is the idle floor of the card: the lock only caps the top, the card still idles normally.
content="[Unit]
Description=Cap the maximum clock of the NVIDIA card at $bus to $max MHz
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$smi -i $bus -lgc 210,$max
ExecStop=$smi -i $bus -rgc

[Install]
WantedBy=multi-user.target
"

say "Unité à écrire : $UNIT" "Unit to write: $UNIT"
printf '%s' "$content" | sed 's/^/  /'
if [ "$dry_run" = 1 ]; then
  say "(--dry-run : rien n'a été modifié)" "(--dry-run: nothing was changed)"
  exit 0
fi

need_root
printf '%s' "$content" > "$UNIT"
systemctl daemon-reload
systemctl enable --now gpu-clock-cap.service
say "Fait. Le verrou est actif maintenant et sera remis à chaque démarrage. Si tu déplaces la carte dans un autre emplacement, refais cette commande avec la nouvelle adresse." \
    "Done. The lock is active now and will be set again at every boot. If you move the card to another slot, run this again with the new address."
