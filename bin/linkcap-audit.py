#!/usr/bin/env python3
"""linkcap-audit.py — read-only audit: how much "declared link capability" do the
endpoint/root port actually advertise?

## Why this matters (reports/198)

`nvidia-smi -q` shows:
    Max            : 2
    Current        : 1
    Device Max     : 1     <- the driver believes the endpoint maxes out at Gen1
    Host Max       : 3

And inside the driver, `_nv017279rm` ANDs the 5 capability sources together and
hands the result to `_nv017812rm` to set `obj[0x954]` (the Gen2 cap). If that bit
is 0, then `_nv017105rm` / `_nv017102rm` (the driver's `set_link_speed(mode)`)
**bail outright** when mode >= 2.

=> If `Device Max = 1` comes from "the endpoint declares LnkCap is still
   2.5GT/s", that is the **architectural root cause** of the whole Gen2 quest:
   hardware declares Gen1 -> driver capability bit = 0 -> never asks for Gen2 ->
   RM initializes internally as Gen1.

The **overdriven** marker on `Speed 5GT/s (overdriven)` in `lspci` is exactly the
evidence: actual speed > declared speed. It shows we changed the "declared
mirror", but **the LnkCap in config space did not change**.

This script is strictly read-only; it performs no writes. Output:
  1. LnkCap / LnkCap2 / LnkSta / LnkCtl2 in config space (endpoint + root port)
  2. The corresponding mirror registers in BAR0
  3. A field-by-field decode that spells out the difference between "declared"
     and "actual"

Usage: sudo python3 linkcap-audit.py
"""
import mmap
import os
import struct
import subprocess
import sys

DEV = os.environ.get("DEV_BDF", "0000:01:00.0")[-8:]
ROOT = os.environ.get("ROOT_BDF", "0000:00:01.0")[-7:]

# Offsets inside the PCIe capability
CAP_LNKCAP = 0x0C
CAP_LNKSTA = 0x12
CAP_LNKCTL2 = 0x30
CAP_LNKCAP2 = 0x2C

SPEED_NAME = {1: "2.5GT/s (Gen1)", 2: "5.0GT/s (Gen2)", 3: "8.0GT/s (Gen3)",
              4: "16GT/s (Gen4)", 5: "32GT/s (Gen5)"}

# BAR0 mirrors
R_LNKCAP = 0x88084
R_LNKCAP2 = 0x880A4
R_LNKSTA = 0x88088
R_LNKCTL2 = 0x880A8
R_CONFIG = 0x8841C


def setpci(sel, reg):
    r = subprocess.run(f"setpci -s {sel} {reg}", shell=True,
                       capture_output=True, text=True)
    try:
        return int(r.stdout.strip(), 16)
    except Exception:
        return None


def decode_lnkcap2(v):
    """LnkCap2 low 32 bits: byte0 = Supported Link Speeds Vector"""
    if v is None:
        return "unreadable"
    vec = v & 0xFF
    out = []
    for gen, bit in ((1, 1), (2, 2), (3, 3), (4, 4), (5, 5)):
        if vec & (1 << bit):
            out.append(f"Gen{gen}")
    return f"vector=0x{vec:02x} -> " + ("/".join(out) if out else "none")


def main():
    if os.geteuid() != 0:
        print("root required"); return 1

    print("=" * 68)
    print("1. config space -- the 'declaration' the kernel and driver really read")
    print("=" * 68)
    for sel, nm in ((DEV, "endpoint 01:00.0"), (ROOT, "root port 00:01.0")):
        lc = setpci(sel, f"CAP_EXP+{CAP_LNKCAP:#04x}.l")
        ls = setpci(sel, f"CAP_EXP+{CAP_LNKSTA:#04x}.w")
        l2 = setpci(sel, f"CAP_EXP+{CAP_LNKCTL2:#04x}.w")
        c2 = setpci(sel, f"CAP_EXP+{CAP_LNKCAP2:#04x}.l")
        print(f"\n[{nm}]")
        if lc is not None:
            msp = lc & 0xF
            print(f"  LnkCap  = 0x{lc:08x}   MaxSpeed={msp} "
                  f"({SPEED_NAME.get(msp, '?')})  Width=x{(lc >> 4) & 0x3F}")
        else:
            print("  LnkCap  unreadable")
        if ls is not None:
            csp = ls & 0xF
            print(f"  LnkSta  = 0x{ls:04x}       CurSpeed={csp} "
                  f"({SPEED_NAME.get(csp, '?')})  Width=x{(ls >> 4) & 0x3F}")
        else:
            print("  LnkSta  unreadable")
        print(f"  LnkCtl2 = 0x{l2:04x}       TLS={l2 & 0xF} "
              f"({SPEED_NAME.get(l2 & 0xF, '?')})" if l2 is not None
              else "  LnkCtl2 unreadable")
        print(f"  LnkCap2 = 0x{c2:08x}   {decode_lnkcap2(c2)}" if c2 is not None
              else "  LnkCap2 unreadable")

    print()
    print("=" * 68)
    print("2. BAR0 mirrors -- the 'other copy' we keep changing")
    print("=" * 68)
    try:
        p = int(open(f"/sys/bus/pci/devices/0000:{DEV}/resource")
                .readline().split()[0], 16)
    except Exception:
        print("cannot get BAR0"); return 2
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ, offset=p)
    vals = {}
    for off, nm in ((R_LNKCAP, "LNKCAP "), (R_LNKCAP2, "LNKCAP2"),
                    (R_LNKSTA, "LNKSTA "), (R_LNKCTL2, "LNKCTL2"),
                    (R_CONFIG, "0x8841C")):
        v = struct.unpack_from("<I", m, off)[0]
        vals[off] = v
        print(f"  0x{off:05x} {nm} = 0x{v:08x}")
    m.close(); os.close(fd)

    print()
    print("=" * 68)
    print("3. Diagnosis")
    print("=" * 68)
    ep_cap = setpci(DEV, f"CAP_EXP+{CAP_LNKCAP:#04x}.l")
    ep_sta = setpci(DEV, f"CAP_EXP+{CAP_LNKSTA:#04x}.w")
    ep_cap2 = setpci(DEV, f"CAP_EXP+{CAP_LNKCAP2:#04x}.l")
    mirror_cap2 = vals.get(R_LNKCAP2, 0)

    if ep_cap is not None:
        msp = ep_cap & 0xF
        print(f"  endpoint LnkCap.MaxSpeed = {msp} ({SPEED_NAME.get(msp, '?')})")
        print(f"     -> nvidia-smi's 'Device Max' is derived from this")
    if ep_sta is not None:
        csp = ep_sta & 0xF
        if ep_cap is not None and csp > (ep_cap & 0xF):
            print(f"  ★ LnkSta.CurSpeed({csp}) > LnkCap.MaxSpeed({ep_cap & 0xF})")
            print(f"    that is why lspci prints '(overdriven)':")
            print(f"    the link actually runs faster than declared => the declaration is still Gen1; only the link was pushed up")
    print(f"  endpoint LnkCap2 (config) = 0x{ep_cap2 if ep_cap2 is not None else 0:08x}"
          f"   BAR0 mirror 0x880A4 = 0x{mirror_cap2:08x}")
    if ep_cap2 is not None and (ep_cap2 & 0xFF) != 0x06 and (mirror_cap2 & 0xFF) == 0x06:
        print("  ★★ the two disagree!")
        print("     we only changed the BAR0 mirror (0x880A4 = 0x06, declaring 5GT support),")
        print("     but the config-space LnkCap2 still lacks the 5GT bit => what the driver reads is still Gen1.")
        print("     => this explains Device Max=1, and why RM internally always initializes as Gen1.")

    print()
    print("  next steps (if ★★ appeared above):")
    print("    1. check whether the config-space LnkCap2 is writable (very likely RO, wired by hardware)")
    print("    2. if RO, then 'making the driver believe Gen2 is available' can only be done by")
    print("       changing the capability bit in memory (the _nv017812rm sets obj+0x954 path),")
    print("       not by changing the declaration")
    print("    3. still rely on gen2kr's probe-timing approach -- it bypasses the declaration and")
    print("       makes the link run 5GT directly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
