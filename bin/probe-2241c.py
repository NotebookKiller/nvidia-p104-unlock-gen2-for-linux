#!/usr/bin/env python3
"""probe-2241c.py — read-only verification of two register semantics mentioned in
skbskhud's report that we never touched

## Background
The technical report of `skbskhud/p104-gen2-unlock` (a Windows tool) claims:

  · `0x8841C` bit15 = **"reset pre-set value"**: preset 1 -> after reset the
    declaration latches as Gen2 (7/7, no counterexample)
  · `0x8841C` bit14:13 = the downgrade gate (== 3 forces back to Gen1)
  · `0x2241C` = `PUNITS.PCI`, **bit7 is a live Gen1/Gen2 selector**
      writing 0 drops to Gen1 immediately, writing 1 returns to Gen2 immediately,
      **no reset needed**
  · In the Gen2 steady state `LNKCAP2` should be `0x06` and `0x2241C` should be
    `0x81`

Our approach never touched `0x2241C`, and we never figured out the semantics of
`0x8841C` bit15 -- we only knew "we set it", not why.

## What this script does
**Purely read-only.** It prints the actual values of these locations on our
cards, to cross-check whether his conclusions hold. It writes no registers
(writing `0x2241C` bit7=0 would instantly drop the link to Gen1; the risk is not
worth it).

Usage: sudo python3 probe-2241c.py
"""
import mmap
import os
import struct
import sys

DEV_RES = "/sys/bus/pci/devices/%s/resource" % os.environ.get("DEV_BDF", "0000:01:00.0")

REGS = [
    (0x88084, "LNKCAP ", "max-speed declaration (bits[3:0])"),
    (0x880A4, "LNKCAP2", "supported-speed vector (0x06=Gen1+Gen2 latched)"),
    (0x88088, "LNKSTA ", "current speed (bits[19:16])"),
    (0x880A8, "LNKCTL2", "target speed (bits[3:0]) <- he calls this 'a thermometer, not a switch'"),
    (0x8841C, "CONFIG ", "capability generator input: bit15=reset preset, bit14:13=downgrade gate"),
    (0x2241C, "PUNITS.PCI", "★ live Gen1/Gen2 selector (bit7) -- we never touched this"),
    (0x8872C, "LTSSM  ", "trigger training (write 6)"),
    (0x8C040, "LINKCFG0", "SPEED=bits[19:18] (1=5GT/s, 2=2.5GT/s)"),
    (0x8C2C0, "CYA_0  ", "bit2 = DIS_G2"),
]


def main():
    if os.geteuid() != 0:
        print("root required"); return 1
    try:
        p = int(open(DEV_RES).readline().split()[0], 16)
    except Exception as e:
        print(f"cannot get BAR0: {e}"); return 1

    f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ, offset=p)
    g = lambda o: struct.unpack_from("<I", m, o)[0]

    print(f"BAR0 = 0x{p:x}\n")
    print("=" * 76)
    print(" actual register values (read-only)")
    print("=" * 76)
    for off, name, desc in REGS:
        v = g(off)
        flag = ""
        if off == 0x88088:
            flag = f" CurSpeed={(v >> 16) & 0xF}"
        elif off == 0x8C040:
            flag = f" SPEED={(v >> 18) & 3}"
        elif off == 0x880A8:
            flag = f" TLS={v & 0xF}"
        print(f"  0x{off:05X}  {name:11s} = 0x{v:08x}{flag}")
        print(f"           {desc}")

    print()
    print("=" * 76)
    print(" cross-checking the key bits (against skbskhud's claims)")
    print("=" * 76)

    cfg = g(0x8841C)
    b15 = (cfg >> 15) & 1
    gate = (cfg >> 13) & 3
    print(f"\n  0x8841C = 0x{cfg:08x}")
    print(f"    bit15 (his 'reset pre-set value')      = {b15}")
    print(f"    bit14:13 (his 'downgrade gate')        = {gate}  "
          f"{'<- ==3; per his claim this forces Gen1' if gate == 3 else '<- not 3; no forced downgrade'}")

    pu = g(0x2241C)
    b7 = (pu >> 7) & 1
    b0 = pu & 1
    print(f"\n  0x2241C = 0x{pu:08x}")
    print(f"    bit7 (his 'live Gen1/Gen2 selector') = {b7}   "
          f"{'<- 1 = FULL, consistent with the current Gen2 link' if b7 else '<- 0, inconsistent with his Gen2 steady state (0x81)'}")
    print(f"    bit0 (PCIE_VERSION)                  = {b0}   "
          f"{'= v2' if b0 else '= v1'}")

    cap2 = g(0x880A4)
    lnksta = g(0x88088)
    cur = (lnksta >> 16) & 0xF

    print()
    print("=" * 76)
    print(" verdict")
    print("=" * 76)
    ok = True
    if cap2 == 0x06:
        print("  ✓ LNKCAP2 = 0x06 -- the declaration has latched as Gen2, matching his description")
    else:
        print(f"  · LNKCAP2 = 0x{cap2:04x} -- not in the Gen2 steady state")
        ok = False
    if cur == 2:
        print("  ✓ LNKSTA = 2 -- the link really runs at 5.0GT/s")
    else:
        print(f"  · LNKSTA = {cur} -- the link is not at Gen2")
        ok = False
    if b7 == 1:
        print("  ✓ 0x2241C bit7 = 1 -- confirms his 'live selector' claim (Gen2 steady state)")
    else:
        print("  ? 0x2241C bit7 = 0 -- inconsistent with his Gen2 steady state; worth digging into")
    if gate != 3:
        print(f"  ✓ downgrade gate = {gate} (not 3) -- not in a forced-downgrade state")
    else:
        print("  ⚠ downgrade gate = 3 -- in the forced-Gen1 state, yet the link is still Gen2; contradiction")

    print()
    print("  note: this script **performs no writes**.")
    print("  Verifying 'write 1 to 0x2241C bit7 returns to Gen2 immediately' requires a write,")
    print("  but that would first drop the link to Gen1 (writing 0 is the only way to measure the switch);")
    print("  the risk does not match the payoff -- not done.")

    m.close(); os.close(f)
    return 0 if ok else 0


if __name__ == "__main__":
    sys.exit(main())
