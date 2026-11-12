#!/bin/bash
# measure-recovery.sh — measure the time from "link drops to Gen1" to "guard pulls it back to Gen2"
#
# Background (reports/195 §4.5)
#   Measured: the guard's recovery takes ~20s, while `push_fn` succeeds in one
#   shot (104ms). Comparing the two timings statically, the difference lies in
#   the interval between `0x8872C=6 -> root port retrain`:
#       push_fn : msleep(50)                    -> success
#       guard_fn: limited by retrain_min_ms=2000 -> all 4 rounds fail
#   => suspicion: that interval must not be long (the effect of 0x8872C=6 decays).
#
# This script quantifies it: starting from detecting Gen1, how many seconds
# until LNKSTA returns to 2.
#
# Usage: bash measure-recovery.sh [timeout seconds]
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
DEV="${DEV_BDF:-0000:01:00.0}"
export DEV_BDF="${DEV}"
BW="$D/build/bwtest2"
TIMEOUT="${1:-60}"

lnk() {
python3 - <<'PY'
import mmap,os,struct
p=int(open('/sys/bus/pci/devices/%s/resource' % os.environ.get('DEV_BDF', '0000:01:00.0')).readline().split()[0],16)
f=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)
m=mmap.mmap(f,0x1000000,mmap.MAP_SHARED,mmap.PROT_READ,offset=p)
l=struct.unpack_from('<I',m,0x88088)[0]
v=struct.unpack_from('<I',m,0x8C040)[0]
print((l>>16)&0xF, f"{(v>>18)&3}")
PY
}

echo "=== 0. wait for the link to reach Gen2 first ==="
for i in $(seq 1 "$TIMEOUT"); do
  read -r SP SPEED <<<"$(lnk)"
  if [ "$SP" = "2" ]; then echo "  ready (${i}s, SPEED=$SPEED)"; break; fi
  sleep 1
done
if [ "$SP" != "2" ]; then echo "✗ Gen2 never arrived; aborting"; exit 2; fi

echo
echo "=== 1. trigger one downgrade (run 1 round of bwtest2; it creates a new context) ==="
T0=$(date +%s.%N)
"$BW" 64 1 >/dev/null 2>&1

echo "=== 2. start polling immediately; record the moment it returns to Gen2 ==="
GOT=0
for i in $(seq 1 $((TIMEOUT * 5))); do
  read -r SP SPEED <<<"$(lnk)"
  NOW=$(date +%s.%N)
  E=$(python3 -c "print(f'{$NOW-$T0:.2f}')")
  if [ "$SP" = "2" ]; then
    echo "  ★ ${E}s back to Gen2 (SPEED=$SPEED)"
    GOT=1
    break
  fi
  # one line every 2 seconds to avoid flooding the screen
  if [ $((i % 10)) -eq 0 ]; then echo "  ${E}s  sp=$SP SPEED=$SPEED"; fi
  sleep 0.2
done
[ "$GOT" = "0" ] && echo "  ✗ did not recover within ${TIMEOUT}s"

echo
echo "=== 3. guard log (this run) ==="
dmesg | grep -i gen2kr | tail -12
