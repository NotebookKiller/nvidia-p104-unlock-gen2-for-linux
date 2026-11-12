#!/usr/bin/env python3
"""peek-regs.py — print the key BAR0 registers, read-only (no writes)

Usage: sudo python3 peek-regs.py
"""
import mmap
import os
import struct
import sys

REGS = [
    (0x88084, "LNKCAP mirror (MaxSpeed=bits[3:0])"),
    (0x880A4, "LNKCAP2 mirror (declared vector, 0x06=unlocked)"),
    (0x88088, "LNKSTA mirror (CurSpeed=bits[19:16])"),
    (0x880A8, "LNKCTL2 mirror (TLS=bits[3:0])"),
    (0x8841C, "PRIV_MISC_1 (declaration bit)"),
    (0x8872C, "XVE_OVR (write 6 = trigger training)"),
    (0x8C040, "LINK_CONFIG_0 (SPEED=bits[19:18])"),
    (0x8C2C0, "CYA_0 (bit2 = DIS_G2)"),
]


def main():
    if os.geteuid() != 0:
        print("root required"); return 1
    p = int(open("/sys/bus/pci/devices/%s/resource" % os.environ.get("DEV_BDF", "0000:01:00.0"))
            .readline().split()[0], 16)
    f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ, offset=p)
    print(f"BAR0 = {p:#x}")
    for off, desc in REGS:
        v = struct.unpack_from("<I", m, off)[0]
        extra = ""
        if off == 0x88084:
            extra = f"  MaxSpeed={v & 0xF}"
        elif off == 0x88088:
            extra = f"  CurSpeed={(v >> 16) & 0xF}"
        elif off == 0x8C040:
            extra = f"  SPEED={(v >> 18) & 3}"
        elif off == 0x880A8:
            extra = f"  TLS={v & 0xF}"
        print(f"  0x{off:05x} = 0x{v:08x}   {desc}{extra}")
    m.close(); os.close(f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
