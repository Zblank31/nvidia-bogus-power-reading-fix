#!/usr/bin/env bash
# Tests for reload-trials.sh against fake system commands: nothing here touches the real
# driver, the desktop or /etc. Every command the script relies on (systemctl, modprobe, rmmod,
# lsmod, nvidia-smi, gpuload, sondeclk, ...) is replaced by a small stub in a temporary
# directory, and the "driver" is a few files that remember what was loaded.
#
#   ./run-sim.sh          prints one line per check, exits non-zero if something fails
#
# The fake driver behaves according to the option it is loaded with:
#   RmPmgrPmuOverride=1     the real fix: clock goes up, no power reading
#   RmPerfLimitsOverride=2  the trap: power cap lifted but stuck in P8 at 420 MHz
#   FAIL_ONCE               the card is missing after this load, and comes back after the recovery
#   DEAD                    the card never comes back
#   NOT_RECEIVED            the driver silently ignores the option
#   anything else           no effect (210 MHz, power cap active)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../reload-trials.sh

SANDBOX=$(mktemp -d)           # holds the stubs; removed on exit
CASE=$SANDBOX/case             # state of the fake machine; rebuilt for every scenario
export SANDBOX CASE
trap 'rm -rf "${SANDBOX:?}"' EXIT
STUBS=$SANDBOX/bin
mkdir -p "$STUBS"

stub() { cat > "$STUBS/$1"; chmod +x "$STUBS/$1"; }

stub sleep <<'EOF'
#!/bin/bash
exec /bin/sleep 0.01
EOF
stub systemctl <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CASE/commands.log"
[ "$1" = is-active ] && { [ "$2" = gdm3.service ] && echo active || echo inactive; }
exit 0
EOF
stub lspci <<'EOF'
#!/bin/bash
echo "0000:09:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA102 [10de:2216] (rev a1)"
EOF
stub fuser <<'EOF'
#!/bin/bash
exit 1
EOF
stub lsmod <<'EOF'
#!/bin/bash
echo "Module                  Size  Used by"
cat "$CASE/modules" 2>/dev/null
EOF
stub rmmod <<'EOF'
#!/bin/bash
echo "rmmod $*" >> "$CASE/commands.log"
for m in "$@"; do grep -v "^$m " "$CASE/modules" > "$CASE/modules.new"; mv "$CASE/modules.new" "$CASE/modules"; done
EOF
stub modprobe <<'EOF'
#!/bin/bash
echo "modprobe $*" >> "$CASE/commands.log"
grep -q "^$1 " "$CASE/modules" 2>/dev/null || echo "$1 1000 0" >> "$CASE/modules"
if [ "$1" = nvidia ]; then
  cp "$CONF" "$CASE/loaded_conf" 2>/dev/null || : > "$CASE/loaded_conf"
  grep -q DEAD "$CASE/loaded_conf" && touch "$CASE/dead"
  if grep -q FAIL_ONCE "$CASE/loaded_conf" || [ -e "$CASE/dead" ]; then echo 0 > "$CASE/card1"; else echo 1 > "$CASE/card1"; fi
  if grep -q NOT_RECEIVED "$CASE/loaded_conf"; then
    echo 'RegistryDwordsPerDevice: ""' > "$PARAMS"
  else
    line=$(grep -o 'NVreg_RegistryDwordsPerDevice="[^"]*"' "$CASE/loaded_conf" | head -1 | sed 's/NVreg_//; s/="/: "/')
    echo "${line:-RegistryDwordsPerDevice: \"\"}" > "$PARAMS"
  fi
fi
exit 0
EOF
stub nvidia-smi <<'EOF'
#!/bin/bash
echo "nvidia-smi $*" >> "$CASE/commands.log"
grep -q '^nvidia ' "$CASE/modules" 2>/dev/null || { echo "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver."; exit 9; }
conf=$(cat "$CASE/loaded_conf" 2>/dev/null)
if [[ $conf == *RmPmgrPmuOverride=1* ]]; then clk=1995; mem=9251; ps=P2; cap="Not Active"; rs=0x0000000000000400; pw="[N/A]"
elif [[ $conf == *RmPerfLimitsOverride=2* ]]; then
  clk=420; [ -e "$CASE/locked" ] && clk=700
  mem=405; ps=P8; cap="Not Active"; rs=0x0; pw=407.00
else clk=210; mem=9251; ps=P2; cap=Active; rs=0x4; pw=420.00; fi
other_card=1; [ "$(cat "$CASE/card1" 2>/dev/null || echo 1)" = 1 ] || other_card=0
case "$*" in
  *" -L"*|"-L") echo "GPU 0: NVIDIA GeForce RTX 3080"; [ $other_card = 1 ] && echo "GPU 1: NVIDIA GeForce RTX 3080"; exit 0 ;;
  *"index,pci.bus_id"*) echo "0, 00000000:08:00.0"; [ $other_card = 1 ] && echo "1, 00000000:09:00.0"; exit 0 ;;
  *" -lgc"*) touch "$CASE/locked"; echo "clocks locked"; exit 0 ;;
  *" -rgc"*) rm -f "$CASE/locked"; exit 0 ;;
  *" -lmc"*|*" -rmc"*) echo ok; exit 0 ;;
  *"temperature.gpu --format"*) echo 61; exit 0 ;;
  *"-q -d"*) echo "Performance State : $ps"; exit 0 ;;
  *"power.draw,fan.speed"*) echo "390.00, 50, $clk, 24, $ps, $rs"; exit 0 ;;
  *"-l 1"*) while true; do echo "100, $pw, $clk, 61, $cap, $ps, $rs, $mem"; /bin/sleep 0.03; done ;;
esac
exit 0
EOF
stub gpuload <<'EOF'
#!/bin/bash
/bin/sleep 0.5
echo "12 launches in 12.0 s (6.93 TFLOPS fma estimated)"
EOF
stub sondeclk <<'EOF'
#!/bin/bash
if grep -q 'RmPmgrPmuOverride=1' "$CASE/loaded_conf" 2>/dev/null; then mhz=1335; else mhz=210; fi
for k in 1 2 3; do echo "launch $k: 0.344 s; real SM clock: mean $mhz MHz (min $mhz, median $mhz, max $mhz); results checksum c1a800a176215af3"; done
EOF
stub dmesg <<'EOF'
#!/bin/bash
echo "[    1.000000] NVRM: loading NVIDIA UNIX Open Kernel Module"
EOF
stub udevadm <<'EOF'
#!/bin/bash
exit 0
EOF
stub nvidia-modprobe <<'EOF'
#!/bin/bash
echo "nvidia-modprobe $*" >> "$CASE/commands.log"
EOF

failures=0

# A clean fake machine: NVIDIA modules loaded, both cards present, empty state directory.
fresh() {
  rm -rf "${CASE:?}"
  mkdir -p "$CASE/state"
  printf 'nvidia_drm 167936 55\nnvidia_uvm 2093056 4\nnvidia_modeset 1613824 16\nnvidia 17190912 513\n' > "$CASE/modules"
  echo 1 > "$CASE/card1"
}

# run <plan text>: run the script on a plan; the journal and results end up in $CASE/state/last
run() {
  printf '%s\n' "$1" > "$CASE/plan.txt"
  PATH="$STUBS:$PATH" I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes TRIALS_SIMULATE=1 STATE_DIR="$CASE/state" CONF="$CASE/zz.conf" \
  PARAMS="$CASE/params" GPULOAD="$STUBS/gpuload" SONDECLK="$STUBS/sondeclk" COPY_DIR="$CASE/copy" TARGET_ID=10de:2216 \
  timeout 120 bash "$SCRIPT" "$CASE/plan.txt" > "$CASE/stdout.txt" 2>&1
  RC=$?
}

# check <description> <command...>
check() {
  local desc=$1; shift
  if "$@" > /dev/null 2>&1; then echo "  ok    $desc"; else echo "  FAIL  $desc"; failures=$((failures + 1)); fi
}
row()    { grep -P "^$1\t" "$CASE/state/last/results.tsv"; }     # the results row of trial $1
journal_has() { grep -q "$1" "$CASE/state/last/journal.log"; }
commands_have() { grep -q "$1" "$CASE/commands.log"; }

echo "1. the fix is found on the second trial and the series stops"
fresh; run $'0_reference|\n1_fix|RmPmgrPmuOverride=1\n2_never|Whatever=1'
check "exit code 0"                                      [ "$RC" = 0 ]
check "the reference is 'no effect'"                     bash -c "$(declare -f row); CASE='$CASE'; row 0 | grep -q 'no effect'"
check "trial 1 is a SUCCESS judged on the real clock"   bash -c "$(declare -f row); CASE='$CASE'; row 1 | grep -q 'SUCCESS: real clock'"
check "trial 2 never ran"                                bash -c "$(declare -f row); CASE='$CASE'; ! row 2"
check "the winning option is kept as .winner"            test -e "$CASE/zz.conf.winner"
check "no *.conf left behind"                            test ! -e "$CASE/zz.conf"
check "the SUCCESS marker is written"                    test -s "$CASE/state/SUCCESS"
check "the desktop was stopped and started again"        bash -c "grep -q 'stop gdm3.service' '$CASE/commands.log' && grep -q 'start gdm3.service' '$CASE/commands.log'"

echo "2. the P8 trap, a locked-clock sub-measurement, and a card that comes back after recovery"
fresh; run $'0_reference|\n1_o2|RmPerfLimitsOverride=2\n2_o2_lock|RmPerfLimitsOverride=2|lgc=1000,1000\n3_missing|FAIL_ONCE=1\n4_fix|RmPmgrPmuOverride=1'
check "exit code 0"                                      [ "$RC" = 0 ]
check "the trap is reported as 'power cap lifted'"       bash -c "$(declare -f row); CASE='$CASE'; row 1 | grep -q 'EFFECT: power cap lifted'"
# loads: reference, O2, missing card, its recovery, the fix, and the final clean reload; the locked line reuses O2's load
check "the locked sub-measurement did not reload the driver" bash -c "[ \$(grep -c '^modprobe nvidia\$' '$CASE/commands.log') = 6 ]"
check "the missing card is logged, then recovered"       journal_has 'card recovered'
check "the series went on to the fix"                    bash -c "$(declare -f row); CASE='$CASE'; row 4 | grep -q SUCCESS"
check "the clock lock was released"                      test ! -e "$CASE/locked"

echo "3. a card that never comes back"
fresh; run $'0_reference|\n1_dead|DEAD=1\n2_never|X=1'
check "the series stops with a reboot message"           journal_has 'needs a reboot'
check "the desktop is started again anyway"              commands_have 'start gdm3.service'
check "no option left behind"                            test ! -e "$CASE/zz.conf"
check "the 'finished' marker says why"                   grep -q reboot "$CASE/state/finished"

echo "4. an option the driver did not receive"
fresh; run $'0_reference|\n1_ignored|NOT_RECEIVED=1\n2_never|X=1'
check "marked INVALID"                                   bash -c "$(declare -f row); CASE='$CASE'; row 1 | grep -q INVALID"
check "trial 2 never ran"                                bash -c "$(declare -f row); CASE='$CASE'; ! row 2"

echo "5. nothing works: every trial runs and no option is left"
fresh; run $'0_reference|\n1_a|A=1\n2_b|B=2'
check "'all trials done'"                                journal_has 'all trials done'
check "no option left behind"                            bash -c "test ! -e '$CASE/zz.conf' && test ! -e '$CASE/zz.conf.winner'"
check "header plus three rows"                           bash -c "[ \$(wc -l < '$CASE/state/last/results.tsv') = 4 ]"
check "every row has 17 fields"                          bash -c "[ \$(awk -F'\t' '{print NF}' '$CASE/state/last/results.tsv' | sort -u | wc -l) = 1 ] && [ \$(awk -F'\t' 'NR==1{print NF}' '$CASE/state/last/results.tsv') = 17 ]"

echo "6. idle probe"
fresh; run $'0_reference|\n1_probe|Whatever=1|idle'
check "a probe row without a load"                       bash -c "$(declare -f row); CASE='$CASE'; row 1 | grep -q 'idle probe only'"

echo "7. guards"
fresh
PATH="$STUBS:$PATH" TRIALS_SIMULATE=1 STATE_DIR="$CASE/state" bash "$SCRIPT" "$CASE/plan.txt" > "$CASE/stdout.txt" 2>&1; RC=$?
check "refuses to run without I_UNDERSTAND_THIS_STOPS_MY_DESKTOP" [ "$RC" = 1 ]
fresh; printf '0_reference|\n' > "$CASE/plan.txt"; : > "$CASE/state/.lock"
flock "$CASE/state/.lock" /bin/sleep 5 &          # another "series" holding the lock
holder=$!
/bin/sleep 0.3
PATH="$STUBS:$PATH" I_UNDERSTAND_THIS_STOPS_MY_DESKTOP=yes TRIALS_SIMULATE=1 STATE_DIR="$CASE/state" CONF="$CASE/zz.conf" \
PARAMS="$CASE/params" GPULOAD="$STUBS/gpuload" TARGET_ID=10de:2216 bash "$SCRIPT" "$CASE/plan.txt" > "$CASE/stdout.txt" 2>&1
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "refuses a second run while one holds the lock"    grep -q 'already running' "$CASE/stdout.txt"

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed"; fi
exit "$failures"
