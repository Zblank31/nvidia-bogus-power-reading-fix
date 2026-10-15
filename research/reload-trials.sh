#!/bin/bash
# Try NVIDIA registry options on one card, one after the other, without rebooting.
#
# This is the bench that found the fix of this repository. For every line of a plan it unloads
# the NVIDIA kernel modules, writes the option to /etc/modprobe.d, loads the driver again,
# checks that the driver really received the option, then measures idle and load: displayed
# clock, real clock (tools/sondeclk), TFLOPS (tools/gpuload), temperature. About 45 s per trial.
# modprobe re-reads /etc/modprobe.d on every load, so no initramfs rebuild and no reboot is needed.
#
# WARNING: this stops your display manager and every program using the GPUs, unloads the
# driver, and starts the desktop again at the end (you log in again). Save your work first.
# Run it detached (systemd-run) or from a text console, never from inside the desktop session.
# If a card does not come back after a reload you have to reboot; it never happened during
# the trials that found the fix. It was written on Ubuntu with GNOME/GDM and nvidia-persistenced:
# read it before running it on something else.
#
# Needs: `make -C ../tools`, root, a plan file (plan.example.txt).
#
#   sudo systemd-run --setenv=I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes --setenv=TARGET_ID=10de:2216 \
#        --unit=gpu-trials --collect /bin/bash "$PWD/reload-trials.sh" "$PWD/plan.example.txt"
#   tail -f /var/lib/gpu-trials/last/journal.log        follow it (the desktop is gone: use another machine or a console)
#   sudo touch /var/lib/gpu-trials/STOP                 stop cleanly after the current trial
#
# Plan format, one trial per line:   name|registry setting|optional commands
#   setting   what goes after "pci=<address>;" in NVreg_RegistryDwordsPerDevice, e.g. RmPmgrPmuOverride=1
#             (several keys: KEY=VALUE;KEY=VALUE). Empty = no option (the reference run).
#   commands  space separated: lgc=min,max and lmc=min,max lock the GPU / memory clock during the load,
#             "idle" only reads the idle power (no load, about 25 s).
# Consecutive lines with the same setting reuse the loaded driver, so they only cost the measurement.
#
# The first trial that reaches a real SM clock of 1000 MHz or more ends the series and its option
# stays active until the next boot. Nothing permanent is written (see restore() at the end).

set -u

# ---- settings (all overridable from the environment) -------------------------------------
STATE_DIR=${STATE_DIR:-/var/lib/gpu-trials}
CONF=${CONF:-/etc/modprobe.d/zz-gpu-trials.conf}
PARAMS=${PARAMS:-/proc/driver/nvidia/params}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLAN=${1:-$HERE/plan.example.txt}
GPULOAD=${GPULOAD:-$HERE/../tools/gpuload}
SONDECLK=${SONDECLK:-$HERE/../tools/sondeclk}
TARGET_ID=${TARGET_ID:-10de:2216}            # vendor:device of the card under test (lspci -nn -d 10de:)
COPY_DIR=${COPY_DIR:-$HERE/runs}             # results are copied here at the end, readable without sudo
LOAD_SECONDS=${LOAD_SECONDS:-12}
OWNER=${OWNER:-$(stat -c %U "$HERE")}        # gets the copy of the results and the desktop notice
SIMULATE=${TRIALS_SIMULATE:-0}               # 1 only in tests/run-sim.sh, where every system command is a stub

export LC_ALL=C CUDA_DEVICE_ORDER=PCI_BUS_ID

# ---- guards ---------------------------------------------------------------------------
if [ "${I_UNDERSTAND_THIS_STOPS_MY_DESKTOP:-no}" != yes ]; then
  echo "This script stops your desktop and unloads the NVIDIA driver: read the header, then rerun with I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes."
  exit 1
fi
if [ "$SIMULATE" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run me as root (see the header)."
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR" 2>/dev/null
exec 9> "$STATE_DIR/.lock"
flock -n 9 || { echo "A series is already running."; exit 1; }
rm -f "$STATE_DIR/STOP"

RUN_DIR=$STATE_DIR/run_$(date +%Y%m%d_%H%M%S)
mkdir -p "$RUN_DIR" || exit 1
ln -sfn "$RUN_DIR" "$STATE_DIR/last"
RESULTS=$RUN_DIR/results.tsv
LOG=$RUN_DIR/journal.log

# From here on stdout/stderr go to the journal; fd 3 keeps the original stdout for the few
# messages that must reach whoever started the script (systemd-run puts them in the unit's journal).
exec 3>&1
exec >> "$LOG" 2>&1

log() { printf '%s %s\n' "$(date +%T)" "$*"; }
abort_early() {
  log "$1: giving up, nothing was touched"
  echo "$1: giving up, nothing was touched (journal: $LOG)" >&3
  exit 1
}
log "=== series started (simulate=$SIMULATE), plan: $PLAN"

# ---- checks before touching anything --------------------------------------------------
BUS=$(lspci -D -d "$TARGET_ID" | head -1 | cut -d' ' -f1)
BUS_SHORT=${BUS#*:}                          # 09:00.0, the form nvidia-smi prints after its 8-digit domain

count_cards() { timeout 40 nvidia-smi -L 2>/dev/null | grep -c '^GPU '; }

[ -n "$BUS" ] || abort_early "no card $TARGET_ID on the PCI bus"
EXPECTED_CARDS=$(count_cards)                # after every reload we must see as many cards as now
[ "$EXPECTED_CARDS" -ge 1 ] || abort_early "the driver sees no card"
[ -x "$GPULOAD" ] || abort_early "$GPULOAD not found (run make in ../tools)"
[ -s "$PLAN" ] || abort_early "plan $PLAN is empty or missing"

mapfile -t PLAN_LINES < <(grep -vE '^[[:space:]]*(#|$)' "$PLAN")
total=${#PLAN_LINES[@]}

# The first display manager that is running is the one we stop and restart.
DISPLAY_MANAGER=""
for dm in gdm3 gdm sddm lightdm; do
  if [ "$(systemctl is-active "$dm.service" 2>/dev/null)" = active ]; then DISPLAY_MANAGER=$dm; break; fi
done
log "card under test: $BUS, $total trials, $EXPECTED_CARDS card(s) seen, display manager: ${DISPLAY_MANAGER:-none running}"

# ---- helpers ----------------------------------------------------------------------------

# PIDs that hold a GPU or a DRM node open (they would block rmmod). Our own PID is excluded.
pids_using_gpus() {
  fuser /dev/nvidia* /dev/dri/* 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | grep -vx "$$" | sort -un
}

# Wait up to 20 s for the GPUs to be released (the session is dying), then ask the stragglers
# to stop, then kill them. Returns 0 when nothing holds a GPU any more.
free_gpus() {
  local i p
  for i in $(seq 1 20); do
    [ -z "$(pids_using_gpus)" ] && return 0
    sleep 1
  done
  log "   still in use by: $(for p in $(pids_using_gpus); do printf '%s(%s) ' "$p" "$(cat /proc/$p/comm 2>/dev/null)"; done)"
  for p in $(pids_using_gpus); do kill -TERM "$p" 2>/dev/null; done
  sleep 5
  for p in $(pids_using_gpus); do kill -KILL "$p" 2>/dev/null; done
  sleep 2
  [ -z "$(pids_using_gpus)" ]
}

# Detach (0) or reattach (1) the text console that sits on the framebuffer: with nvidia_drm's
# fbdev emulation it can keep the module "in use". Machines without one just skip the loop.
fbcon_bind() {
  local v
  [ "$SIMULATE" = 1 ] && return 0
  for v in /sys/class/vtconsole/vtcon*; do
    [ -e "$v/name" ] && grep -q 'frame buffer' "$v/name" && echo "$1" > "$v/bind" 2>/dev/null
  done
  return 0
}

# Unload the NVIDIA modules, dependents first. Retries because something (a stray nvidia-smi,
# a daemon) can still hold the module for a moment.
unload_driver() {
  local i m
  fbcon_bind 0
  for i in $(seq 1 15); do
    for m in nvidia_drm nvidia_uvm nvidia_modeset nvidia_peermem nvidia; do
      lsmod | grep -q "^$m " && { timeout 90 rmmod "$m" 2>&1 | sed "s/^/   rmmod $m: /"; }
    done
    lsmod | grep -q '^nvidia ' || { log "   driver unloaded"; return 0; }
    sleep 2
  done
  log "!! the driver will not unload: $(lsmod | grep -E '^nvidia' | tr '\n' ' ')"
  return 1
}

# Write the option for the card under test, or remove the file when the setting is empty.
write_conf() {
  if [ -z "$1" ]; then
    rm -f "$CONF"
  else
    printf 'options nvidia NVreg_RegistryDwordsPerDevice="pci=%s;%s;"\n' "$BUS" "$1" > "$CONF"
  fi
}

# Load the driver and bring the cards up. $1 labels the kernel log excerpt of this load.
# nvidia-persistenced matters: without it nothing opens the GPUs, so they are not initialised
# (and the registry options not applied) until the first client shows up.
# Returns 0 if all expected cards are back.
load_driver() {
  local dmesg_before i
  dmesg_before=$(dmesg | wc -l)
  timeout 180 modprobe nvidia 2>&1 | sed 's/^/   modprobe nvidia: /'
  timeout 60 modprobe nvidia_uvm 2>&1 | sed 's/^/   modprobe nvidia_uvm: /'
  nvidia-modprobe -u -c=0 2>&1 | sed 's/^/   nvidia-modprobe: /'     # creates /dev/nvidia-uvm
  timeout 120 systemctl start nvidia-persistenced.service 2>&1 | sed 's/^/   persistenced: /'
  for i in $(seq 1 30); do
    [ "$(count_cards)" -ge "$EXPECTED_CARDS" ] && break
    sleep 2
  done
  dmesg | tail -n +$((dmesg_before + 1)) | grep -iE 'nvrm|nvidia|gsp|aer|pcieport' > "$RUN_DIR/kernel_$1.txt"
  [ "$(count_cards)" -ge "$EXPECTED_CARDS" ]
}

# Sets gpu_index, the nvidia-smi index of the card under test.
find_gpu_index() {
  gpu_index=$(timeout 30 nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null |
              awk -F', ' -v b="$BUS_SHORT" 'index($2, b) { print $1 }' | head -1)
  [ -n "$gpu_index" ]
}

# Did the driver really receive the setting? Sets $received to "-" (empty setting), "yes" or "NO".
# A trial whose option never reached the module proves nothing, so the caller stops on "NO".
check_received() {
  local key=${1%%=*}
  if [ -z "$1" ]; then
    received="-"
  elif grep -F "RegistryDwordsPerDevice" "$PARAMS" | grep -qF "$BUS_SHORT" &&
       grep -F "RegistryDwordsPerDevice" "$PARAMS" | grep -qF "$key"; then
    received=yes
  else
    received=NO
  fi
}

# The card did not come back: reset it over PCI, and if that is not enough remove it from the bus
# and rescan. Both start from a clean driver and no option. Returns 0 if the card is back.
recover_card() {
  log "   recovery: stop, PCI reset of the card, reload without any option"
  systemctl stop nvidia-persistenced.service 2>&1
  free_gpus
  unload_driver || return 1
  write_conf ""
  if [ "$SIMULATE" != 1 ] && [ -e "/sys/bus/pci/devices/$BUS/reset" ]; then
    echo 1 > "/sys/bus/pci/devices/$BUS/reset" 2>&1 && log "   PCI reset done" || log "   PCI reset refused"
    sleep 3
  fi
  load_driver "r$trial" && return 0

  log "   still missing: removing the device from the PCI bus and rescanning"
  systemctl stop nvidia-persistenced.service 2>&1
  free_gpus
  unload_driver || return 1
  if [ "$SIMULATE" != 1 ]; then
    echo 1 > "/sys/bus/pci/devices/$BUS/remove" 2>&1
    sleep 2
    echo 1 > /sys/bus/pci/rescan
    sleep 4
  fi
  load_driver "rr$trial"
}

# One TSV row (17 fields, same order as the header written below).
tsv_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RESULTS"; }
# A row for a trial that could not be measured: trial, name, setting, status.
tsv_failure() { tsv_row "$1" "$2" "$3" "" "" "" "" "" "" "" "" "" "" "" "" "" "$4"; }

# Idle power, fan and clock over 6 s plus a full nvidia-smi snapshot.
# Sets idle_w, idle_fan, idle_clk.
measure_idle() {
  local i
  sleep 3
  : > "$RUN_DIR/idle.tmp"
  for i in 1 2 3 4 5 6; do
    timeout 20 nvidia-smi -i "$gpu_index" --query-gpu=power.draw,fan.speed,clocks.sm,temperature.gpu,pstate,clocks_event_reasons.active \
                          --format=csv,noheader,nounits >> "$RUN_DIR/idle.tmp"
    sleep 1
  done
  timeout 30 nvidia-smi -i "$gpu_index" -q -d PERFORMANCE,CLOCK,POWER > "$RUN_DIR/trial_${trial}_perf_idle.txt" 2>&1
  idle_w=$(awk -F', ' '{ s += $1; n++ } END { if (n) printf "%.0f", s / n }' "$RUN_DIR/idle.tmp")
  idle_fan=$(tail -1 "$RUN_DIR/idle.tmp" | awk -F', ' '{ print $2 }')
  idle_clk=$(tail -1 "$RUN_DIR/idle.tmp" | awk -F', ' '{ print $3 }')
}

# Load the card for LOAD_SECONDS while sampling nvidia-smi once a second. $1 = optional commands (lgc=, lmc=).
# The load is killed if the card reaches 80 C.
# Sets load_w, clk_avg, clk_max, cap_pct (share of samples with the software power cap active),
# max_temp, pstate, reasons, mem_avg, real_mhz (from sondeclk, empty if not built), tflops.
measure_load() {
  local cmd sampler_pid load_pid n temp
  for cmd in $1; do
    case "$cmd" in
      lgc=*) log "   locking the GPU clock: ${cmd#lgc=}";    timeout 30 nvidia-smi -i "$gpu_index" -lgc "${cmd#lgc=}" 2>&1 | sed 's/^/   | /' ;;
      lmc=*) log "   locking the memory clock: ${cmd#lmc=}"; timeout 30 nvidia-smi -i "$gpu_index" -lmc "${cmd#lmc=}" 2>&1 | sed 's/^/   | /' ;;
      *)     log "   unknown command ignored: $cmd" ;;
    esac
  done

  # columns: utilization, power, SM clock, temperature, power cap flag, P-state, reasons, memory clock
  nvidia-smi -i "$gpu_index" --query-gpu=utilization.gpu,power.draw,clocks.sm,temperature.gpu,clocks_event_reasons.sw_power_cap,pstate,clocks_event_reasons.active,clocks.mem \
             --format=csv,noheader,nounits -l 1 > "$RUN_DIR/load.tmp" &
  sampler_pid=$!
  sleep 2
  CUDA_VISIBLE_DEVICES=$gpu_index timeout -k 3 $((LOAD_SECONDS + 40)) "$GPULOAD" "$LOAD_SECONDS" > "$RUN_DIR/gpuload.tmp" 2>&1 &
  load_pid=$!

  n=0
  while kill -0 "$load_pid" 2>/dev/null; do
    sleep 1
    n=$((n + 1))
    [ "$n" = 8 ] && timeout 30 nvidia-smi -i "$gpu_index" -q -d PERFORMANCE,CLOCK,POWER > "$RUN_DIR/trial_${trial}_perf_load.txt" 2>&1
    temp=$(timeout 10 nvidia-smi -i "$gpu_index" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    if [[ $temp =~ ^[0-9]+$ ]] && [ "$temp" -ge 80 ]; then
      log "!! load stopped: $temp C"
      kill "$load_pid" 2>/dev/null
    fi
  done
  wait "$load_pid" 2>/dev/null
  sleep 1
  kill "$sampler_pid" 2>/dev/null
  wait "$sampler_pid" 2>/dev/null
  cp "$RUN_DIR/load.tmp" "$RUN_DIR/trial_${trial}_load.csv"

  # The real SM clock is measured before any clock lock is released, so a locked trial reports the locked clock.
  real_mhz=""
  if [ -x "$SONDECLK" ]; then
    real_mhz=$(CUDA_VISIBLE_DEVICES=$gpu_index timeout 60 "$SONDECLK" 3 2000000 2>/dev/null |
               grep -E 'launch 3|lancement 3' | sed -E 's/.*(mean|moyenne) ([0-9]+) MHz.*/\2/')
  fi
  for cmd in $1; do
    case "$cmd" in
      lgc=*) timeout 30 nvidia-smi -i "$gpu_index" -rgc > /dev/null 2>&1 ;;
      lmc=*) timeout 30 nvidia-smi -i "$gpu_index" -rmc > /dev/null 2>&1 ;;
    esac
  done

  # Averages over the samples where the card was really busy (utilization >= 90 %).
  read -r load_w clk_avg clk_max cap_pct max_temp pstate reasons mem_avg < <(awk -F', ' '
    $1 + 0 >= 90 {
      n++; w += $2; c += $3; m += $8
      if ($3 + 0 > mx) mx = $3 + 0
      if ($5 ~ /^Active/) capped++
      if ($4 + 0 > tm) tm = $4 + 0
      p = $6; r = $7
    }
    END {
      if (n) printf "%.0f %.0f %.0f %.0f %.0f %s %s %.0f", w / n, c / n, mx, 100 * capped / n, tm, p, r, m / n
      else   print "0 0 0 0 0 - - 0"
    }' "$RUN_DIR/load.tmp")
  tflops=$(grep -o '[0-9.]* TFLOPS' "$RUN_DIR/gpuload.tmp" | head -1 | cut -d' ' -f1)
  rm -f "$RUN_DIR"/*.tmp
}

# ---- put everything back (runs on every exit, including errors and SIGTERM) -------------------
touched=0            # becomes 1 once we start stopping things; before that there is nothing to restore
restored=0
won=0; won_name=""; won_setting=""; won_cmds=""
abort_reason=""

restore() {
  [ "$restored" = 1 ] && return 0
  restored=1
  trap - EXIT INT TERM HUP
  if [ "$touched" = 1 ]; then
    log "=== restoring: clean driver reload, persistence daemon and desktop back"
    [ -n "$(jobs -p)" ] && kill $(jobs -p) 2>/dev/null
    systemctl stop nvidia-persistenced.service 2>&1
    free_gpus
    unload_driver || log "!! driver did not unload: trying to bring the desktop back anyway"

    # Reload with no option, or with the winning one so it stays active until the next boot.
    write_conf "$won_setting"
    timeout 180 modprobe nvidia 2>&1 | sed 's/^/   modprobe nvidia: /'
    # The winner is renamed right after the load: modprobe has read it, and a *.conf left in
    # /etc/modprobe.d would be baked into the initramfs by the next update-initramfs.
    [ "$won" = 1 ] && [ -e "$CONF" ] && mv -f "$CONF" "$CONF.winner"
    timeout 60 modprobe nvidia_modeset 2>&1 | sed 's/^/   modprobe nvidia_modeset: /'
    timeout 60 modprobe nvidia_uvm 2>&1 | sed 's/^/   modprobe nvidia_uvm: /'
    timeout 60 modprobe nvidia_drm 2>&1 | sed 's/^/   modprobe nvidia_drm: /'
    nvidia-modprobe -u -c=0 2>&1 | sed 's/^/   nvidia-modprobe: /'
    timeout 120 systemctl start nvidia-persistenced.service 2>&1 | sed 's/^/   persistenced: /'
    udevadm settle --timeout=10 2>&1
    fbcon_bind 1
    log "   cards seen by the driver: $(count_cards) (expected: $EXPECTED_CARDS)"
    if [ -n "$DISPLAY_MANAGER" ]; then
      timeout 120 systemctl start "$DISPLAY_MANAGER.service" 2>&1
      log "   $DISPLAY_MANAGER started again"
    fi
  fi

  log "=== summary"
  [ -s "$RESULTS" ] && column -t -s$'\t' "$RESULTS"
  [ "$won" = 1 ] && log "SUCCESS with '$won_name': $won_setting ${won_cmds:+(+ $won_cmds during the load)} -> active now (until the next boot), copy in $CONF.winner (not in the initramfs)"
  [ -n "$abort_reason" ] && log "SERIES STOPPED: $abort_reason"
  echo "${abort_reason:-done} ($(date '+%F %T'))" > "$STATE_DIR/finished"
  chmod 644 "$STATE_DIR/finished"
  if [ "$SIMULATE" != 1 ]; then
    mkdir -p "$COPY_DIR/$(basename "$RUN_DIR")" &&
      cp -a "$RUN_DIR/." "$COPY_DIR/$(basename "$RUN_DIR")/" &&
      chown -R "$OWNER:$OWNER" "$COPY_DIR" 2>/dev/null
  fi
  log "=== finished"
}
trap restore EXIT
trap 'log "signal received"; exit 143' INT TERM HUP

tsv_row trial name setting received_by_driver idle_W_read fan_pct idle_clock_MHz load_W_read load_clock_avg_MHz load_clock_max_MHz \
        load_mem_clock_avg_MHz real_clock_MHz TFLOPS sw_power_cap_active_pct pstate_under_load clock_event_reasons_hex status

# ---- 1. notice, then stop the desktop -----------------------------------------------------
if [ "$SIMULATE" != 1 ]; then
  minutes=$((total * 45 / 60))
  wall "GPU trials: the desktop closes in 20 seconds (about $minutes minutes, black screens). To cancel: sudo touch $STATE_DIR/STOP" 2>/dev/null
  runuser -u "$OWNER" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$OWNER")/bus" \
    notify-send -u critical -t 20000 "GPU trials" "The desktop closes in 20 seconds (about $minutes minutes, black screens). Save what is open." 2>/dev/null
  log "20 s notice given"
  sleep 20
fi
[ -e "$STATE_DIR/STOP" ] && { abort_reason="cancelled during the notice"; exit 0; }

touched=1
log "stopping the desktop (${DISPLAY_MANAGER:-no display manager running}) and nvidia-persistenced: screens will go black"
[ -n "$DISPLAY_MANAGER" ] && timeout 120 systemctl stop "$DISPLAY_MANAGER.service" 2>&1
systemctl stop nvidia-persistenced.service 2>&1
free_gpus || { abort_reason="processes still hold the GPUs"; exit 1; }

# ---- 2. the trials ----------------------------------------------------------------------------
loaded_setting="@@"      # what the driver is currently loaded with; "@@" means unknown, so the first trial always reloads
for ((trial = 0; trial < total; trial++)); do
  [ -e "$STATE_DIR/STOP" ] && { abort_reason="stop requested (STOP file)"; break; }

  line=${PLAN_LINES[$trial]}
  name=${line%%|*}
  rest=${line#*|}
  setting=${rest%%|*}
  cmds=""
  case "$rest" in *\|*) cmds=${rest#*|} ;; esac
  label="${setting:-(none)}${cmds:+ + $cmds}"
  log ">> trial $trial/$total: $name [$label]"

  # A different setting needs a fresh driver load; the same one only needs the next measurement.
  if [ "$setting" != "$loaded_setting" ]; then
    loaded_setting="@@"
    systemctl stop nvidia-persistenced.service 2>&1
    if ! { free_gpus && unload_driver; }; then
      abort_reason="cannot unload the driver (trial $trial)"
      tsv_failure "$trial" "$name" "$label" "FAILED: driver would not unload"
      break
    fi
    write_conf "$setting"

    if ! load_driver "$trial"; then
      log "!! a card is missing or in error after loading with [${setting:-no option}]: see $RUN_DIR/kernel_$trial.txt"
      tsv_failure "$trial" "$name" "$label" "FAILED: a card did not come back"
      if recover_card; then
        log "   card recovered, going on"
        loaded_setting=""
        continue
      fi
      abort_reason="the card does not come back (trial $trial): the PC needs a reboot"
      break
    fi
    loaded_setting=$setting

    if ! find_gpu_index; then
      abort_reason="nvidia-smi does not list the card (trial $trial)"
      tsv_failure "$trial" "$name" "$label" "FAILED: card not listed"
      break
    fi
    check_received "$setting"
    log "   card under test = index $gpu_index; option received by the driver: $received"
    if [ "$received" = NO ]; then
      abort_reason="option not received by the driver (trial $trial): the series would prove nothing"
      tsv_row "$trial" "$name" "$label" NO "" "" "" "" "" "" "" "" "" "" "" "" "INVALID: option not received by the driver"
      break
    fi
    measure_idle
  fi

  # "idle" probe: only the idle power reading, no load
  case " $cmds " in
    *" idle "*)
      tsv_row "$trial" "$name" "$label" "$received" "$idle_w" "$idle_fan" "$idle_clk" "" "" "" "" "" "" "" "" "" "idle probe only"
      log "   probe: idle ${idle_w} W | fan ${idle_fan} % | clock ${idle_clk} MHz"
      continue ;;
  esac

  measure_load "$cmds"

  # Judge on the real clock when the probe is available: the displayed clock can be well above it.
  judged_clk=${real_mhz:-$clk_avg}
  status="no effect"
  [ "${cap_pct:-100}" -le 20 ] && status="EFFECT: power cap lifted"
  [ "${judged_clk:-0}" -ge 1000 ] && status="SUCCESS: ${real_mhz:+real }clock >= 1000 MHz"
  tsv_row "$trial" "$name" "$label" "$received" "$idle_w" "$idle_fan" "$idle_clk" "$load_w" "$clk_avg" "$clk_max" "$mem_avg" \
          "${real_mhz:-?}" "${tflops:-?}" "$cap_pct" "$pstate" "$reasons" "$status"
  log "   result: idle ${idle_w} W | load ${load_w} W | displayed clock avg ${clk_avg} MHz (max ${clk_max}), real ${real_mhz:-?} MHz, memory ${mem_avg} MHz | max ${max_temp} C | ${tflops:-?} TFLOPS | cap ${cap_pct} % | state ${pstate} reasons ${reasons} | $status"

  if [ "${judged_clk:-0}" -ge 1000 ]; then
    won=1; won_name=$name; won_setting=$setting; won_cmds=$cmds
    echo "$name: $setting ${cmds:+(+ $cmds)}" > "$STATE_DIR/SUCCESS"
    chmod 644 "$STATE_DIR/SUCCESS"
    break
  fi
done

[ -z "$abort_reason" ] && [ "$won" = 0 ] && log "all trials done"
exit 0
