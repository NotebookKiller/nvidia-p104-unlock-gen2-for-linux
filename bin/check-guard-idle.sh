#!/bin/bash
# check-guard-idle.sh — when the patch and the guard coexist, does the guard stay completely idle?
#
# ## Why check this
#   The patch stops the driver from downgrading to Gen1 (reports/199). So the
#   guard (gen2kr's guard_fn) should **never act** while the link stays Gen2.
#   If "[guard] ..." logs still appear, some other downgrade path remains and
#   the patch has not fully taken over.
#
# ## Criteria
#   · count of "gen2kr.*guard" lines in dmesg == 0  => the patch fully took
#     over; the guard is a pure safety net
#   · > 0                                            => the link dropped at
#     some point; investigate
#
# Usage: bash check-guard-idle.sh [rounds]
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
N="${1:-4}"

st() {
python3 - <<'PY'
import mmap,os,struct
try:
    p=int(open('/sys/bus/pci/devices/%s/resource' % os.environ.get('DEV_BDF', '0000:01:00.0')).readline().split()[0],16)
    f=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)
    m=mmap.mmap(f,0x1000000,mmap.MAP_SHARED,mmap.PROT_READ,offset=p)
    a=struct.unpack_from('<I',m,0x880A4)[0]
    l=struct.unpack_from('<I',m,0x88088)[0]
    print(f"CAP2={a:#06x} LNKSTA={(l>>16)&0xF}")
    m.close(); os.close(f)
except Exception:
    print("unreadable")
PY
}

dmesg -C >/dev/null 2>&1
if ! lsmod | grep -q '^gen2kr'; then
  cd "$D/kmod" && insmod gen2kr.ko && echo "  loaded gen2kr (as a safety net)"
else
  echo "  gen2kr already in"
fi
sleep 2

echo "  starting point: $(st)"
echo
echo "  running $N rounds of CUDA contexts (one cuInit per round):"
for i in $(seq 1 "$N"); do
  "$D/build/minictx" 1 >/dev/null 2>&1
  sleep 1
  echo "    after round $i: $(st)"
done

echo
echo "  waiting another 8s to rule out a delayed downgrade..."
sleep 8
echo "    after 8s: $(st)"

echo
G=$(dmesg | grep -c 'gen2kr.*guard' || true)
echo "======== guard log line count: $G ========"
if [ "$G" = "0" ]; then
  echo "  ★ the guard did nothing => the patch fully took over; the guard is just a safety net"
else
  echo "  ⚠ the guard acted $G times, which means the link dropped. Recent lines:"
  dmesg | grep 'gen2kr.*guard' | tail -6
fi

echo
echo "======== all gen2kr logs ========"
dmesg | grep gen2kr | tail -10 || echo "  (none)"
