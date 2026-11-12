#!/bin/bash
# trace-mode1.sh — determine which path mode=1 actually takes, and whether it writes SPEED=2
#
# ## Why this must be re-measured (reports/199)
#
# reports/195 once recorded: the two `or $0x80000` sites inside `_nv017105rm`
# (0x127e65 / 0x12803b) were **hit 0 times each** during minictx, from which it
# concluded "SPEED becoming 2 is an endpoint-internal write-back, invisible to
# the CPU".
#
# But this round of perf confirmed: `cuInit` enters `_nv017105rm` with
# **DX=0x1 (mode=1)** every time. Statically, mode=1 **falls through
# sequentially** -> it must pass through 127e65's `or $0x80000`.
# The two conclusions conflict; only a live measurement can settle it.
#
# ## Static path (already checked)
#   entry 127d60
#   127d81 cmp $0x2,%eax ; ja 1280c8      ; (mode-1)>2 -> bail (mode not in {1,2,3})
#   127d8a cmp $0x2,%edx ; je 1280d9      ; mode==2 -> capability gate obj[0x954]
#   127d93 cmpl $0x3,0xc(%rbp) ; je 128169 ; mode==3 -> capability gate obj[0x955]
#   127d9d <- mode==1 falls through sequentially
#   127ded cmpb $0,0x4de5(%r13) ; jne 1281a8   ; only prints a **warning log**, then jmp 127dfb continues
#   127dfb..127e49  loop reading 0x8C040 until (al & 0x1f)==0
#   127e4b mov 0xc(%rbp),%ecx     ; ecx = mode
#   127e4e and $0xfff3ffff,%eax    ; clears SPEED[19:18]
#   127e53 cmp $0x2,%ecx ; je 12819b   -> or $0x40000  (SPEED=1, Gen2)
#   127e5c cmp $0x3,%ecx ; je 12817f   -> keeps eax    (SPEED=0, Gen3)
#   127e65 or  $0x80000,%eax           -> SPEED=2 (Gen1)  ★ mode==1 lands here
#   127e6a movl $0x1,0xc(%rbp)         ; ★★ rewrites the stored mode to 1
#   127e71 mov %eax,0x20(%rbp)         ; value to be written
#   127edd.. writes 0x8c040
#   1280c8 <- the only return path (mov %r12d,%eax; pop x4; add $0x40,%rbp; ret)
#
# ## x86 has only 4 debug registers => at most 4 execution breakpoints
#
# Usage: bash trace-mode1.sh
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
declare -A OFF=(
  [entry]=0x127d60
  [or80000]=0x127e65      # mode==1's SPEED=2
  [wr_shared]=0x127edd    # the write point all modes converge to
  [bailret]=0x1280c8      # the only return
  [warnpath]=0x1281a8     # the warning-log branch taken when obj[0x4de5]!=0
)
BASE=$(cat /sys/module/nvidia/sections/.text)
addr() { python3 -c "print('0x%x' % (int('$BASE',16) + ${OFF[$1]}))"; }

echo "=== probes (.text base $BASE) ==="
for k in entry or80000 wr_shared bailret; do
  printf '  %-10s %s\n' "$k" "$(addr $k)"
done

A_E=$(addr entry); A_O=$(addr or80000); A_W=$(addr wr_shared); A_B=$(addr bailret)
OUT=/tmp/mode1.data
rm -f "$OUT"

echo
echo "=== run 1 round of minictx (creates 1 CUDA context = 1 cuInit) ==="
perf record -e "mem:$A_E:x" -e "mem:$A_O:x" -e "mem:$A_W:x" -e "mem:$A_B:x" \
  -a --intr-regs=ip,dx,si,di,r8,ax -o "$OUT" -- "$D/build/minictx" 1 2>&1 | tail -2

echo
echo "=== hit counts per breakpoint ==="
for k in entry or80000 wr_shared bailret; do
  A=$(addr $k)
  C=$(perf script -i "$OUT" 2>/dev/null | grep -c "mem:$A:x" || true)
  printf '  %-10s %-14s %s hits\n' "$k" "$A" "$C"
done

echo
echo "=== DX (mode) at entry ==="
perf script -i "$OUT" -F iregs 2>/dev/null | grep "IP:$A_E" \
  | grep -oE 'DX:0x[0-9a-f]+' | sort | uniq -c

echo
echo "=== ★ AX at or\\$0x80000 hits (= value just before the OR) ==="
perf script -i "$OUT" -F iregs 2>/dev/null | grep "IP:$A_O" \
  | grep -oE 'AX:0x[0-9a-f]+|R8:0x[0-9a-f]+' | sort | uniq -c | head

echo
echo "=== R8 at the shared write point (= the value actually about to be written to 0x8C040) ==="
perf script -i "$OUT" -F iregs 2>/dev/null | grep "IP:$A_W" \
  | grep -oE 'R8:0x[0-9a-f]+' | sort | uniq -c | head

echo
echo "=== time ordering (who came first) ==="
perf script -i "$OUT" -F time,ip,sym 2>/dev/null | head -20

echo
echo "=== verdict ==="
if [ "$(perf script -i "$OUT" 2>/dev/null | grep -c "mem:$A_O:x" || true)" -gt 0 ]; then
  echo "  ★ mode=1 **did** execute or \$0x80000 => SPEED was software-written to 2"
  echo "    => the patch idea holds: blocking mode==1 stops the downgrade"
  echo "    => it also means reports/195's \"endpoint writes back internally\" conclusion was wrong (those breakpoints did not take effect that time)"
else
  echo "  mode=1 never executed or \$0x80000 => it took another branch; check warnpath/wr_shared"
fi
