#!/usr/bin/env bash
# charge_longue.sh — supervised sustained load on one GPU, with a temperature cut-off.
# Charge soutenue et surveillée sur une carte, avec coupure en température.
#
# Usage : ./charge_longue.sh [gpu index=0] [seconds=60] [cut-off °C=75]
# Every 3 s it prints: temperature °C, GPU MHz, memory MHz, P-state, fan %, power W, clock-event reasons (as nvidia-smi reports them).
# Needs ./gpuload (run `make` first). If the temperature reaches the cut-off the load is stopped.
IDX=${1:-0}; DUREE=${2:-60}; MAXT=${3:-75}
DIR=$(cd "$(dirname "$0")" && pwd)
[ -x "$DIR/gpuload" ] || { echo "gpuload missing: run 'make' in $DIR"; exit 1; }
export CUDA_DEVICE_ORDER=PCI_BUS_ID LC_ALL=C
OUT=$(mktemp)
echo "load of $DUREE s on GPU $IDX (cut-off at $MAXT °C); columns: °C, GPU MHz, memory MHz, P-state, fan %, W read, clock-event reasons"
CUDA_VISIBLE_DEVICES=$IDX timeout -k 3 $((DUREE + 30)) "$DIR/gpuload" "$DUREE" > "$OUT" 2>&1 & L=$!
n=0
while kill -0 $L 2>/dev/null; do
  sleep 1; n=$((n + 1))
  l=$(nvidia-smi -i "$IDX" --query-gpu=temperature.gpu,clocks.sm,clocks.mem,pstate,fan.speed,power.draw,clocks_event_reasons.active --format=csv,noheader,nounits 2>&1)
  T=${l%%,*}
  [ $((n % 3)) = 0 ] && echo "t=${n}s  $l"
  if [[ $T =~ ^[0-9]+$ ]] && [ "$T" -ge "$MAXT" ]; then echo "!! CUT-OFF: ${T} °C"; kill $L 2>/dev/null; break; fi
done
wait $L 2>/dev/null
echo "--- end: $(grep -o '[0-9.]* TFLOPS' "$OUT" | head -1)"; rm -f "$OUT"
sleep 5; echo "5 s later: $(nvidia-smi -i "$IDX" --query-gpu=temperature.gpu,clocks.sm,pstate,fan.speed --format=csv,noheader,nounits 2>&1)"
