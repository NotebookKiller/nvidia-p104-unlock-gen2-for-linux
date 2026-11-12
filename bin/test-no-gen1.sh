#!/bin/bash
# test-no-gen1.sh — decisive verification: can the patch stop the downgrade
# without the guard?
#
# ## Logic
#   Old approach (gen2kr guard): the driver drops to Gen1 -> the guard notices ->
#   pulls it back after 3.8s. That is "rescue after the fact".
#   New approach (patch): makes `_nv017105rm(mode=1)` bail at entry, so the
#   driver **never downgrades**. That is "no downgrade at all".
#
#   To prove the patch works on its own, the guard **must be removed** first:
#     · with the guard -> the patch's effect cannot be measured (the guard
#       would pull the link back)
#     · without the guard -> if the link stays Gen2, only the patch deserves credit
#
# ## Flow
#   1. rmmod gen2kr + nvidia
#   2. modprobe nvidia (reads the patched .ko)
#   3. insmod gen2kr -> unbind/bind triggers the push to Gen2
#   4. ★ rmmod gen2kr (removes the guard)
#   5. run N rounds of minictx (1 CUDA context per round = 1 cuInit)
#   6. compare LNKSTA before/after each round
#
# ## Verdict (registers only, never nvidia-smi)
#   · LNKSTA[3:0] still == 2 after every round  => ★patch works, no downgrades
#   · drops back to 1                           => patch insufficient, another
#     downgrade path exists
#
# Usage: bash test-no-gen1.sh [rounds]
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
DEV="${DEV_BDF:-0000:01:00.0}"
export DEV_BDF="${DEV}"
N="${1:-3}"

st() {
python3 - <<'PY'
import mmap,os,struct
try:
    p=int(open('/sys/bus/pci/devices/%s/resource' % os.environ.get('DEV_BDF', '0000:01:00.0')).readline().split()[0],16)
    f=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)
    m=mmap.mmap(f,0x1000000,mmap.MAP_SHARED,mmap.PROT_READ,offset=p)
    a=struct.unpack_from('<I',m,0x880A4)[0]
    l=struct.unpack_from('<I',m,0x88088)[0]
    t=struct.unpack_from('<I',m,0x880A8)[0]
    s=struct.unpack_from('<I',m,0x8C040)[0]
    m.close(); os.close(f)
    print(f"CAP2={a:#06x} LNKSTA={(l>>16)&0xF} TLS={t&0xF} SPEED={(s>>18)&3}")
except Exception:
    print("unreadable (the device may be in a bad state)")
PY
}

echo "======== 0. confirm the patch is in place ========"
python3 "$D/tools/patch_no_gen1.py" check 2>&1 | tail -3

echo
echo "======== 1. rmmod gen2kr + nvidia ========"
rmmod gen2kr 2>/dev/null && echo "  gen2kr removed" || echo "  gen2kr not loaded"
for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do rmmod "$m" 2>/dev/null; done
sleep 1
lsmod | grep -E '^nvidia' && echo "  ⚠ leftovers remain" || echo "  fully unloaded"

echo
echo "======== 2. load the patched nvidia ========"
modprobe nvidia && modprobe nvidia_uvm && echo "  OK"
sleep 2
echo "  starting point: $(st)"

echo
echo "======== 3. gen2kr pushes to Gen2 ========"
cd "$D" && insmod build/gen2kr.ko && echo "  insmod OK"
sleep 1
echo "$DEV" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null
sleep 0.8
echo "$DEV" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null
sleep 6

OK2=0
for i in $(seq 1 25); do
  case "$(st)" in *LNKSTA=2*) OK2=1; break;; esac
  sleep 0.4
done
echo "  after push: $(st)"
if [ "$OK2" = "0" ]; then
  echo "  ✗ never reached Gen2; the rest of the test cannot run. See dmesg | grep gen2kr"
  dmesg | grep -i gen2kr | tail -6
  exit 2
fi

echo
echo "======== 4. ★ remove the guard (leave only the patch) ========"
rmmod gen2kr && echo "  gen2kr unloaded —— nothing will pull the link back after a downgrade now"
sleep 1
lsmod | grep -q '^gen2kr' && echo "  ⚠ still present" || echo "  confirmed: no guard left"

echo
echo "  before removing the guard: $(st)"

echo
echo "======== 5. run $N rounds of CUDA contexts, checking the link each round ========"
FAIL=0
for i in $(seq 1 "$N"); do
  "$D/build/minictx" 1 >/dev/null 2>&1
  sleep 0.8
  S=$(st)
  echo "  after round $i: $S"
  case "$S" in
    *LNKSTA=2*) ;;
    *) FAIL=$((FAIL+1));;
  esac
done

echo
echo "======== 6. wait another 10s to rule out a delayed downgrade ========"
sleep 10
S=$(st)
echo "  after 10s: $S"
case "$S" in *LNKSTA=2*) ;; *) FAIL=$((FAIL+1));; esac

echo
echo "======== 7. Xid check ========"
dmesg | grep -i "Xid" | tail -3 || echo "  no Xid"

echo
echo "======== verdict ========"
if [ "$FAIL" = "0" ]; then
  echo "  ★★★ the patch works! The link held Gen2 steadily after the guard was removed."
  echo "      => the downgrade path is fully blocked; gen2kr's 3.8s guard is no longer needed."
  echo "      => gen2kr only does the \"declaration unlock + first probe-time push\"; it can degrade into a one-shot module."
else
  echo "  fell back to Gen1 $FAIL times => the patch is insufficient; another downgrade path remains."
  echo "      => re-check whether mode=1 really bails with trace-mode1.sh (entry hit but no or80000)"
fi
