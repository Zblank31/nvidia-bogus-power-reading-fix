#!/usr/bin/env bash
# After the reboot: did the driver receive the option, and does the card now leave 210 MHz under load?
#
#   ./verify.sh --bus 0000:09:00.0 [--seconds 15]
#
# It runs a short load on that card (tools/gpuload, built with make if needed) and samples
# nvidia-smi halfway through. The verdict only looks at the displayed clock; the real clock
# (step 4) can be lower, see the README.
set -u
. "$(dirname "$0")/lib.sh"

bus=""; seconds=15
while [ $# -gt 0 ]; do
  case "$1" in
    --bus)       bus="${2:-}"; shift 2 ;;
    --seconds)   seconds="${2:-15}"; shift 2 ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)           die "Option inconnue : $1" "Unknown option: $1" ;;
  esac
done

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi introuvable." "nvidia-smi not found."
[ -n "$bus" ] || die "Précise la carte : --bus 0000:09:00.0 (voir ./apply-fix.sh --list)." "Say which card: --bus 0000:09:00.0 (see ./apply-fix.sh --list)."
bus=$(normalize_bus "$bus") || die "Adresse PCI invalide." "Invalid PCI address."
idx=$(gpu_index_for_bus "$bus")
[ -n "$idx" ] || die "Le pilote ne voit pas de carte à l'adresse $bus." "The driver does not see a card at $bus."

# 1. is the option really loaded in the module? (a modprobe.d line that never made it into the
#    initramfs looks exactly like "the fix doesn't work")
say "1) Option reçue par le pilote ?" "1) Did the driver receive the option?"
registry=$(grep -h RegistryDwordsPerDevice /proc/driver/nvidia/params 2>/dev/null)
echo "   $registry"
if echo "$registry" | grep -qF "pci=$bus;"; then
  say "   -> oui, une option est active pour $bus." "   -> yes, an option is active for $bus."
else
  say "   -> NON : aucune option pour $bus. Le correctif n'est pas pris (initramfs non reconstruit ? mauvaise adresse ?)." \
      "   -> NO: no option for $bus. The fix is not applied (initramfs not rebuilt? wrong address?)."
fi

# 2. a short load
say "2) Charge de $seconds s sur la carte $idx..." "2) $seconds s load on card $idx..."
tools=$(cd "$(dirname "$0")/../tools" && pwd)
if [ ! -x "$tools/gpuload" ] && command -v make >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then
  make -s -C "$tools" >/dev/null 2>&1
fi
[ -x "$tools/gpuload" ] || die "tools/gpuload manquant : installe gcc et make puis lance 'make -C tools'." \
                               "tools/gpuload missing: install gcc and make, then run 'make -C tools'."

out=$(mktemp)
CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$idx "$tools/gpuload" "$seconds" > "$out" 2>&1 &
load_pid=$!
sleep $((seconds / 2))
sample=$(nvidia-smi -i "$idx" --query-gpu=clocks.sm,clocks.mem,pstate,temperature.gpu,power.draw,clocks_event_reasons.sw_power_cap,clocks_event_reasons.active \
                    --format=csv,noheader,nounits 2>&1)
wait "$load_pid"
echo "   nvidia-smi: clocks.sm, clocks.mem, pstate, °C, power.draw, sw_power_cap, reasons = $sample"
echo "   $(tail -1 "$out")"
tflops=$(grep -o '[0-9.]* TFLOPS' "$out" | head -1 | cut -d' ' -f1)
rm -f "$out"

# 3. verdict: the failure mode is a clock pinned near 210 MHz while the card is busy
clock=${sample%%,*}
say "3) Verdict" "3) Verdict"
if [[ $clock =~ ^[0-9]+$ ]] && [ "$clock" -gt 500 ]; then
  say "   OK : en charge la carte tourne à ${clock} MHz affichés (${tflops:-?} TFLOPS) au lieu de rester à 210 MHz." \
      "   OK: under load the card runs at ${clock} MHz displayed (${tflops:-?} TFLOPS) instead of staying at 210 MHz."
else
  say "   PAS BON : horloge ${clock} MHz pendant la charge (bloquée bas, ou charge non vue). Vois le README (section « Si ça ne marche pas »)." \
      "   NOT GOOD: clock ${clock} MHz during the load (stuck low, or the load was not seen). See the README (section 'If it does not work')."
fi

# 4. the clock the SMs really run at (nvidia-smi only shows the requested one)
if [ -x "$tools/sondeclk" ]; then
  say "4) Fréquence RÉELLE des SM (peut être plus basse que celle affichée, voir le README) :" \
      "4) REAL SM clock (may be lower than the displayed one, see the README):"
  CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$idx "$tools/sondeclk" 3 2000000 2>&1 | tail -2 | sed 's/^/   /'
fi
