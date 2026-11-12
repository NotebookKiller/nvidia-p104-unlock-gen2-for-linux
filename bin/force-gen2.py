#!/usr/bin/env python3
"""force-gen2.py — repeatedly try to push the link to Gen2 (register-based
judgment only, never lspci text)

## Why this is needed (reports/198)
After "the driver was reloaded repeatedly", the push fails: the endpoint's
`LnkCtl2.TLS` is pinned back to 1 and the `LnkCap2` declaration also stops at
0x02. At that point the generator (gen2kr) and the driver fight each other and
several retries are needed.

## ★ Judgments must come from registers
`grep 'Speed 5GT/s'` false-matches `Speed 2.5GT/s` (substring) -- that pit has
been stepped on twice already. The only trustworthy signal: `LNKSTA[3:0] == 2`.

Usage (root):
  python3 force-gen2.py [number of attempts]
"""
import mmap
import os
import struct
import subprocess
import sys
import time

DEV = os.environ.get("DEV_BDF", "0000:01:00.0")


def regs():
    p = int(open(f"/sys/bus/pci/devices/{DEV}/resource").readline().split()[0], 16)
    f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ, offset=p)
    a = struct.unpack_from("<I", m, 0x880A4)[0]
    l = struct.unpack_from("<I", m, 0x88088)[0]
    t = struct.unpack_from("<I", m, 0x880A8)[0]
    s = struct.unpack_from("<I", m, 0x8C040)[0]
    m.close(); os.close(f)
    return a, (l >> 16) & 0xF, t & 0xF, (s >> 18) & 3


def main():
    if os.geteuid() != 0:
        print("root required"); return 1
    tries = int(sys.argv[1]) if len(sys.argv) > 1 else 6

    a, sp, tls, sd = regs()
    print(f"starting point: CAP2=0x{a:04x} LNKSTA={sp} TLS={tls} SPEED={sd}")
    if sp == 2:
        print("already Gen2"); return 0

    for i in range(1, tries + 1):
        subprocess.run(f"echo {DEV} > /sys/bus/pci/drivers/nvidia/unbind",
                       shell=True, capture_output=True)
        time.sleep(0.8)
        subprocess.run(f"echo {DEV} > /sys/bus/pci/drivers/nvidia/bind",
                       shell=True, capture_output=True)
        # wait up to 10s
        for _ in range(20):
            time.sleep(0.5)
            a, sp, tls, sd = regs()
            if sp == 2:
                break
        print(f"  attempt {i}: CAP2=0x{a:04x} LNKSTA={sp} TLS={tls} SPEED={sd}")
        if sp == 2:
            print("  ✓ Gen2 reached")
            return 0

    print("  ✗ still not Gen2 after repeated attempts")
    print("    hint: if CAP2 stays 0x0002 and TLS stays 1, the declaration/TLS is being pinned")
    print("          by the driver; a full reboot is needed to get back to a clean state (reports/198 conclusion).")
    return 2


if __name__ == "__main__":
    sys.exit(main())
