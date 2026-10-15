#!/usr/bin/env bash
# verify.sh — after the reboot: did the driver receive the option, and does the card now leave 210 MHz under load?
# Après le redémarrage : le pilote a-t-il reçu l'option, et la carte sort-elle de 210 MHz en charge ?
#
# Usage : ./verify.sh --bus 0000:09:00.0 [--seconds 15]
# It runs a short load on that GPU (tools/gpuload, built on the fly with `make` if gcc is available) and samples nvidia-smi during it.
set -u
. "$(dirname "$0")/lib.sh"
BUS=""; SECS=15
while [ $# -gt 0 ]; do
  case "$1" in
    --bus) BUS="${2:-}"; shift 2;;
    --seconds) SECS="${2:-15}"; shift 2;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "Option inconnue : $1" "Unknown option: $1";;
  esac
done
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi introuvable." "nvidia-smi not found."
[ -n "$BUS" ] || die "Précise la carte : --bus 0000:09:00.0 (voir ./apply-fix.sh --list)." "Say which card: --bus 0000:09:00.0 (see ./apply-fix.sh --list)."
BUS=$(normalize_bus "$BUS") || die "Adresse PCI invalide." "Invalid PCI address."
IDX=$(gpu_index_for_bus "$BUS"); [ -n "$IDX" ] || die "Le pilote ne voit pas de carte à l'adresse $BUS." "The driver does not see a GPU at $BUS."

t "1) Option reçue par le pilote ?" "1) Did the driver receive the option?"
REG=$(grep -h RegistryDwordsPerDevice /proc/driver/nvidia/params 2>/dev/null)
echo "   $REG"
if echo "$REG" | grep -qF "pci=$BUS;"; then t "   -> oui, une option est active pour $BUS." "   -> yes, an option is active for $BUS."
else t "   -> NON : aucune option pour $BUS. Le correctif n'est pas pris (initramfs non reconstruit ? mauvaise adresse ?)." "   -> NO: no option for $BUS. The fix is not applied (initramfs not rebuilt? wrong address?)."; fi

t "2) Charge de $SECS s sur la carte $IDX..." "2) $SECS s load on GPU $IDX..."
DIR=$(cd "$(dirname "$0")/../tools" && pwd)
if [ ! -x "$DIR/gpuload" ]; then command -v make >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1 && make -s -C "$DIR" >/dev/null 2>&1; fi
[ -x "$DIR/gpuload" ] || die "tools/gpuload manquant : installe gcc et make puis lance 'make -C tools'." "tools/gpuload missing: install gcc and make, then run 'make -C tools'."
OUT=$(mktemp)
CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$IDX "$DIR/gpuload" "$SECS" > "$OUT" 2>&1 & L=$!
sleep $((SECS / 2))
S=$(nvidia-smi -i "$IDX" --query-gpu=clocks.sm,clocks.mem,pstate,temperature.gpu,power.draw,clocks_event_reasons.sw_power_cap,clocks_event_reasons.active --format=csv,noheader,nounits 2>&1)
wait $L
echo "   nvidia-smi: clocks.sm, clocks.mem, pstate, °C, power.draw, sw_power_cap, reasons = $S"
echo "   $(tail -1 "$OUT")"
TF=$(grep -o '[0-9.]* TFLOPS' "$OUT" | head -1 | cut -d' ' -f1); rm -f "$OUT"
CLK=${S%%,*}
t "3) Verdict" "3) Verdict"
if [[ $CLK =~ ^[0-9]+$ ]] && [ "$CLK" -gt 500 ]; then
  t "   OK : en charge la carte tourne à ${CLK} MHz affichés (${TF:-?} TFLOPS) au lieu de rester à 210 MHz." "   OK: under load the card runs at ${CLK} MHz displayed (${TF:-?} TFLOPS) instead of staying at 210 MHz."
else
  t "   PAS BON : horloge ${CLK} MHz pendant la charge (bloquée bas, ou charge non vue). Vois le README (section « Si ça ne marche pas »)." "   NOT GOOD: clock ${CLK} MHz during the load (stuck low, or the load was not seen). See the README (section 'If it does not work')."
fi
if [ -x "$DIR/sondeclk" ]; then
  t "4) Fréquence RÉELLE des SM (peut être plus basse que celle affichée, voir le README) :" "4) REAL SM clock (may be lower than the displayed one, see the README):"
  CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$IDX "$DIR/sondeclk" 3 2000000 2>&1 | tail -2 | sed 's/^/   /'
fi
