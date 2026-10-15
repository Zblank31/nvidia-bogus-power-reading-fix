#!/usr/bin/env bash
# Read-only report: does one of your NVIDIA cards show the "bogus power reading" signature?
#
#   ./diagnostic.sh
#
# Run it twice: once with the PC idle, once while a load runs (tools/gpuload 60 in another terminal),
# because the clock-stuck-at-210-MHz half of the signature only shows up under load.
# It changes nothing and prints no serial number or UUID, so the output can go into an issue as is.
set -u
. "$(dirname "$0")/lib.sh"

command -v nvidia-smi >/dev/null 2>&1 ||
  die "nvidia-smi introuvable : le pilote NVIDIA est-il installé ?" "nvidia-smi not found: is the NVIDIA driver installed?"

say "=== Système" "=== System"
echo "os:      $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}")"
echo "kernel:  $(uname -r)"
echo "driver:  $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"

# The open kernel modules are MIT/GPL licensed, the proprietary ones are not. The workaround
# was only tested with the open modules.
license=$(modinfo -F license nvidia 2>/dev/null | head -1)
case "$license" in
  *MIT* | *GPL*) echo "module:  $(say "modules noyau OUVERTS ($license)" "OPEN kernel modules ($license)")" ;;
  "")            echo "module:  $(say "module nvidia non trouvé par modinfo" "nvidia module not found by modinfo")" ;;
  *)             echo "module:  $(say "modules noyau PROPRIÉTAIRES ($license) : le correctif n'a été testé qu'avec les modules ouverts" \
                                      "PROPRIETARY kernel modules ($license): the fix was only tested with the open modules")" ;;
esac
active_opts=$(grep -h Registry /proc/driver/nvidia/params 2>/dev/null | grep -v '""')
echo "$(say "options de registre actives" "active registry options"): ${active_opts:-$(say "aucune" "none")}"

echo
say "=== Cartes (une ligne par carte)" "=== GPUs (one line each)"
fields="index,name,pci.bus_id,pci.device_id,vbios_version,pstate,utilization.gpu,clocks.sm,clocks.max.sm,power.draw,power.limit,power.max_limit,fan.speed,temperature.gpu,clocks_event_reasons.active,clocks_event_reasons.sw_power_cap"
nvidia-smi --query-gpu="$fields" --format=csv,noheader,nounits 2>&1 | sed 's/^/  /'
say "  (colonnes : $fields)" "  (columns: $fields)"

echo
say "=== Verdict par carte" "=== Verdict per GPU"
nvidia-smi --query-gpu=index,name,utilization.gpu,clocks.sm,power.draw,pstate,clocks_event_reasons.sw_power_cap \
           --format=csv,noheader,nounits 2>/dev/null |
while IFS=',' read -r idx name util clk power pstate cap; do
  # nvidia-smi pads the CSV fields with a leading space
  name=${name# }; util=${util# }; clk=${clk# }; power=${power# }; pstate=${pstate# }; cap=${cap# }
  verdict=""
  if [[ $power =~ ^[0-9.]+$ ]]; then
    # symptom 1: a big power reading while the card does nothing
    if awk -v p="$power" -v u="${util:-100}" 'BEGIN { exit !(p >= 150 && u <= 5) }'; then
      verdict="$(say "SUSPECT : lit ${power} W alors que la carte est inactive (${util} % d'utilisation, état ${pstate})." \
                     "SUSPICIOUS: reads ${power} W while the GPU is idle (${util} % usage, state ${pstate}).")"
    fi
    # symptom 2: busy, but stuck at the minimum clock with the software power cap active
    if [[ $clk =~ ^[0-9]+$ ]] && [[ ${util:-0} =~ ^[0-9]+$ ]] && [ "$util" -ge 80 ] && [ "$clk" -le 400 ] && [[ $cap == Active* ]]; then
      verdict="$verdict $(say "SUSPECT : en charge (${util} %) mais bloquée à ${clk} MHz avec « SW Power Cap » actif." \
                              "SUSPICIOUS: busy (${util} %) but stuck at ${clk} MHz with 'SW Power Cap' active.")"
    fi
    verdict="${verdict# }"
    [ -n "$verdict" ] || verdict="$(say "rien d'anormal dans cet instantané (lit ${power} W, ${clk} MHz, ${util} % d'utilisation)." \
                                        "nothing abnormal in this snapshot (reads ${power} W, ${clk} MHz, ${util} % usage).")"
  else
    verdict="$(say "aucune lecture de puissance (power.draw = ${power}) : normal si le correctif est déjà actif." \
                   "no power reading (power.draw = ${power}): expected if the fix is already active.")"
  fi
  echo "  GPU $idx ($name): $verdict"
done

echo
say "Si une carte est SUSPECTE : compare avec un wattmètre de prise. Si la prise montre bien MOINS que ce que nvidia-smi annonce," \
    "If a GPU is SUSPICIOUS: compare with a wall power meter. If the meter shows much LESS than what nvidia-smi claims,"
say "la lecture est fausse et le correctif du README peut s'appliquer. Si la prise confirme la consommation : NE L'APPLIQUE PAS." \
    "the reading is bogus and the fix in the README may apply. If the meter confirms the consumption: DO NOT apply it."
