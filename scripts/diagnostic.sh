#!/usr/bin/env bash
# diagnostic.sh — READ-ONLY report: does one of your NVIDIA GPUs show the "bogus power reading" signature?
# Rapport en LECTURE SEULE : une de tes cartes NVIDIA présente-t-elle la signature de la « fausse lecture de puissance » ?
#
# Usage : ./diagnostic.sh              (run it once while the PC is idle, and once while a load runs: tools/gpuload 60)
# It changes nothing and prints no serial number or UUID, so the output can be pasted into an issue.
set -u
. "$(dirname "$0")/lib.sh"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi introuvable : le pilote NVIDIA est-il installé ?" "nvidia-smi not found: is the NVIDIA driver installed?"

t "=== Système" "=== System"
echo "os:      $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}")"
echo "kernel:  $(uname -r)"
echo "driver:  $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
lic=$(modinfo -F license nvidia 2>/dev/null | head -1)
case "$lic" in
  *MIT*|*GPL*) echo "module:  $(t "modules noyau OUVERTS ($lic)" "OPEN kernel modules ($lic)")";;
  "")          echo "module:  $(t "module nvidia non trouvé par modinfo" "nvidia module not found by modinfo")";;
  *)           echo "module:  $(t "modules noyau PROPRIÉTAIRES ($lic) — le correctif n'a été testé qu'avec les modules ouverts" "PROPRIETARY kernel modules ($lic) — the fix was only tested with the open modules")";;
esac
reg=$(grep -h Registry /proc/driver/nvidia/params 2>/dev/null | grep -v '""' )
echo "$(t "options de registre actives" "active registry options"): ${reg:-$(t "aucune" "none")}"

t "" ""
t "=== Cartes (une ligne par carte)" "=== GPUs (one line each)"
Q="index,name,pci.bus_id,pci.device_id,vbios_version,pstate,utilization.gpu,clocks.sm,clocks.max.sm,power.draw,power.limit,power.max_limit,fan.speed,temperature.gpu,clocks_event_reasons.active,clocks_event_reasons.sw_power_cap"
nvidia-smi --query-gpu="$Q" --format=csv,noheader,nounits 2>&1 | while IFS= read -r line; do echo "  $line"; done
t "  (colonnes : $Q)" "  (columns: $Q)"

t "" ""
t "=== Verdict par carte" "=== Verdict per GPU"
nvidia-smi --query-gpu=index,name,utilization.gpu,clocks.sm,power.draw,pstate,clocks_event_reasons.sw_power_cap --format=csv,noheader,nounits 2>/dev/null |
while IFS= read -r line; do
  IFS=',' read -r idx name util clk pw pst cap <<<"$line"
  name=${name# }; util=${util# }; clk=${clk# }; pw=${pw# }; pst=${pst# }; cap=${cap# }
  msg=""
  if [[ $pw =~ ^[0-9.]+$ ]]; then
    # idle (<= 5 % usage) but reads a big power draw
    if awk -v p="$pw" -v u="${util:-100}" 'BEGIN{exit !(p>=150 && u<=5)}'; then
      msg="$(t "SUSPECT : lit ${pw} W alors que la carte est inactive (${util} % d'utilisation, état ${pst})." "SUSPICIOUS: reads ${pw} W while the GPU is idle (${util} % usage, state ${pst}).")"
    fi
    # the classic signature: busy, but stuck at a very low clock with "SW Power Cap" active
    if [[ $clk =~ ^[0-9]+$ ]] && [ "${util:-0}" -ge 80 ] 2>/dev/null && [ "$clk" -le 400 ] && [[ $cap == Active* ]]; then
      msg="$msg $(t "SUSPECT : en charge (${util} %) mais bloquée à ${clk} MHz avec « SW Power Cap » actif." "SUSPICIOUS: busy (${util} %) but stuck at ${clk} MHz with 'SW Power Cap' active.")"
    fi
    msg="${msg# }"
    [ -z "$msg" ] && msg="$(t "rien d'anormal dans cet instantané (lit ${pw} W, ${clk} MHz, ${util} % d'utilisation)." "nothing abnormal in this snapshot (reads ${pw} W, ${clk} MHz, ${util} % usage).")"
  else
    msg="$(t "aucune lecture de puissance (power.draw = ${pw}) : normal si le correctif est déjà actif." "no power reading (power.draw = ${pw}): expected if the fix is already active.")"
  fi
  echo "  GPU $idx ($name): $msg"
done

t "" ""
t "Si une carte est SUSPECTE : compare avec un wattmètre de prise. Si la prise montre bien MOINS que ce que nvidia-smi annonce," "If a GPU is SUSPICIOUS: compare with a wall power meter. If the meter shows much LESS than what nvidia-smi claims,"
t "la lecture est fausse et le correctif du README peut s'appliquer. Si la prise confirme la consommation : NE L'APPLIQUE PAS." "the reading is bogus and the fix in the README may apply. If the meter confirms the consumption: DO NOT apply it."
