#!/usr/bin/env bash
# Sustained load on one card with a temperature log and an automatic cut-off.
#
#   ./charge_longue.sh [gpu index=0] [seconds=60] [cut-off in degrees C=75]
#
# Every 3 s it prints: temperature, GPU clock, memory clock, P-state, fan %, power draw, clock event
# reasons (all as nvidia-smi reports them; some read N/A when the fix is active).
# If the temperature reaches the cut-off the load is killed. Needs ./gpuload (run `make` first).
gpu=${1:-0}; seconds=${2:-60}; max_temp=${3:-75}
here=$(cd "$(dirname "$0")" && pwd)
[ -x "$here/gpuload" ] || { echo "gpuload missing: run 'make' in $here"; exit 1; }

export CUDA_DEVICE_ORDER=PCI_BUS_ID LC_ALL=C     # LC_ALL=C so the TFLOPS line below is easy to grep
out=$(mktemp)
echo "load of $seconds s on GPU $gpu (cut-off at $max_temp C); columns: C, GPU MHz, memory MHz, P-state, fan %, W read, clock event reasons"

# gpuload stops by itself after $seconds; the timeout is only a safety net in case the driver hangs
CUDA_VISIBLE_DEVICES=$gpu timeout -k 3 $((seconds + 30)) "$here/gpuload" "$seconds" > "$out" 2>&1 &
load_pid=$!

n=0
while kill -0 "$load_pid" 2>/dev/null; do
  sleep 1
  n=$((n + 1))
  line=$(nvidia-smi -i "$gpu" --query-gpu=temperature.gpu,clocks.sm,clocks.mem,pstate,fan.speed,power.draw,clocks_event_reasons.active \
                    --format=csv,noheader,nounits 2>&1)
  temp=${line%%,*}
  [ $((n % 3)) = 0 ] && echo "t=${n}s  $line"
  if [[ $temp =~ ^[0-9]+$ ]] && [ "$temp" -ge "$max_temp" ]; then
    echo "!! CUT-OFF: ${temp} C"
    kill "$load_pid" 2>/dev/null
    break
  fi
done
wait "$load_pid" 2>/dev/null

echo "--- end: $(grep -o '[0-9.]* TFLOPS' "$out" | head -1)"
rm -f "$out"
sleep 5
echo "5 s later: $(nvidia-smi -i "$gpu" --query-gpu=temperature.gpu,clocks.sm,pstate,fan.speed --format=csv,noheader,nounits 2>&1)"
