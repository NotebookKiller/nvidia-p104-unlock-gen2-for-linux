#!/bin/bash
# test-patch-alone.sh — verify that with "the patch only, no push" the link
# cannot reach Gen2
#
# ## Conclusion (reports/200 §1, already measured with a full-machine reboot)
#   With the patch in place and gen2kr not loaded:
#     LNKSTA=1, LCAP2=0x0002, TLS=1, 0x8841C=0xc0b40500, bandwidth 0.78
#   => **the patch can only "hold" Gen2; it cannot "establish" Gen2.**
#
# ## ★ How to reset to "declaration not unlocked"
#   **`unbind/bind` will NOT do it!** Measured: the declaration unlock survives
#   across unbind/bind (reports/200 §3: CAP2 was 0x0006 before and after
#   unbind/bind, and the link stayed Gen2 both times).
#
#   Only two things can reset it:
#     · `rmmod nvidia && modprobe nvidia` (fast, but repeated reloads risk a
#       driver-side lock-up)
#     · a full machine reboot (cleanest)
#
#   This script defaults to the **module reload** (fast) path but warns first.
#   To skip the reset and only observe the current state, use `--no-reset`.
#
# Usage:
#   bash test-patch-alone.sh              # reset via module reload, then try with the patch alone
#   bash test-patch-alone.sh --no-reset   # observe the current state only, no reset
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
DEV="${DEV_BDF:-0000:01:00.0}"
export DEV_BDF="${DEV}"
RESET=1
[ "${1:-}" = "--no-reset" ] && RESET=0

st() {
python3 - <<'PY'
import mmap,os,struct
try:
    p=int(open('/sys/bus/pci/devices/%s/resource' % os.environ.get('DEV_BDF', '0000:01:00.0')).readline().split()[0],16)
    f=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)
    m=mmap.mmap(f,0x1000000,mmap.MAP_SHARED,mmap.PROT_READ,offset=p)
    g=lambda o: struct.unpack_from('<I',m,o)[0]
    cap=g(0x88084); cap2=g(0x880A4); ls=g(0x88088); ctl2=g(0x880A8)
    cfg=g(0x8C040); priv=g(0x8841C)
    m.close(); os.close(f)
    print(f"CAP2=0x{cap2:04x} LNKSTA={(ls>>16)&0xF} TLS={ctl2&0xF} "
          f"SPEED={(cfg>>18)&3} MAXSPD={cap&0xF} 0x8841C=0x{priv:08x}")
except Exception:
    print("unreadable")
PY
}

echo "======== 0. starting point ========"
echo "  $(st)"
echo -n "  gen2kr: "; lsmod | grep -q '^gen2kr' && echo "loaded" || echo "not loaded"
echo -n "  patch : "; python3 "$D/bin/patch_no_gen1.py" check 2>/dev/null | grep -oE '\[not patched\]|\[patched\]'

echo
echo "======== 1. remove gen2kr (make sure no pusher remains) ========"
if lsmod | grep -q '^gen2kr'; then
    rmmod gen2kr && echo "  removed"
fi
sleep 1
lsmod | grep -q '^gen2kr' && echo "  ⚠ still present" || echo "  confirmed: no gen2kr left"

if [ "$RESET" = "1" ]; then
    echo
    echo "======== 2. reload the nvidia modules to reset the declaration back to Gen1 ========"
    echo "  ★ unbind/bind cannot be used —— it does not reset the declaration (reports/200 §3)"
    echo "  ★ repeated reloads risk a driver-side lock-up; if it fails, reboot the whole machine"
    for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
        rmmod "$m" 2>/dev/null || true
    done
    sleep 1
    if lsmod | grep -qE '^nvidia'; then
        echo "  ✗ nvidia did not fully unload (check fuser -v /dev/nvidia*); aborting"
        exit 1
    fi
    modprobe nvidia && modprobe nvidia_uvm && echo "  reloaded"
    sleep 3
    echo "  after reset: $(st)"
else
    echo
    echo "======== 2. skipping the reset (--no-reset) ========"
fi

echo
echo "======== 3. watch for 10 seconds (only the patch; nobody pushes) ========"
for i in 1 2 3 4 5; do
    sleep 2
    echo "   $((i*2))s: $(st)"
done

echo
echo "======== 4. verdict ========"
S="$(st)"
case "$S" in
  *LNKSTA=2*)
    if [ "$RESET" = "0" ]; then
      echo "  the link is Gen2 —— but very likely leftover from the earlier push"
      echo "  (the declaration unlock survives unbind/bind, see reports/200 §3)."
      echo "  To really test \"the patch alone\", rerun without --no-reset, or reboot the machine first."
    else
      echo "  ★ still reached Gen2 after the reset —— inconsistent with reports/200; re-verify"
    fi
    ;;
  *)
    echo "  ✓ as expected: the link is still Gen1"
    echo "    => the patch can only [hold] Gen2; it cannot [establish] Gen2."
    echo "    => installing the patched driver alone is not enough; gen2kr must make that one push."
    ;;
esac
echo "  current: $S"

echo
echo "======== 5. restore (reload gen2kr and push) ========"
if ! lsmod | grep -q '^gen2kr'; then
    insmod "$D/build/gen2kr.ko" 2>/dev/null && echo "  gen2kr loaded"
fi
sleep 1
echo "$DEV" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null
sleep 1
echo "$DEV" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null
for i in $(seq 1 30); do
    case "$(st)" in *LNKSTA=2*) break;; esac
    sleep 0.5
done
echo "  after restore: $(st)"
case "$(st)" in
  *LNKSTA=2*) echo "  ✓ Gen2 restored" ;;
  *) echo "  ⚠ not restored. If this fails repeatedly, follow reports/198: reboot the whole machine and stop retrying" ;;
esac
