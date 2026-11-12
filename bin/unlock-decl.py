#!/usr/bin/env python3
"""unlock-decl.py — does only "unlock the declaration + trigger training", to
verify the link can self-heal after the patch

## Why this is needed (reports/195)

`_nv017281rm` writes `0x8C040.SPEED` as "the current link speed" on every
cuCtxCreate:
  · before the patch: sp==1 -> writes SPEED=2 (0x80000) -> 2.5GT/s -> **pinned at Gen1**
  · after the patch:  sp==1 -> writes SPEED=1 (0x40000) -> **requests 5.0GT/s**

The patch is confirmed to work in practice (R8 went 0x20085800 -> 0x20045800).
But the link is still Gen1, because **the declaration `LINK_CAP2` is still
0x0002 (Gen1 only)**, so the hardware refuses to negotiate 5GT/s.

So: unlock the declaration, then trigger one LTSSM training, and the link
**should climb to 5GT/s by itself** — because the target speed SPEED=1 was
already written by the (patched) driver.

This does two fewer things than safe-gen2.py, and is therefore safer:
  · **does not write 0x8C040.SPEED** (it is already 1; no need for us to write
    it; avoids the "write SPEED while training is incomplete" path that killed
    devices every time)
  · **skips the forced ⑤->⑥ retrain** (unless necessary, and only from the
    root port)

## Safety constraints (carried over from reports/186's settled rules)
  ① Unlock the declaration: write the four XP3G registers + `0x8841C`
     **read-then-OR** (never write an absolute value) + `0x88610`
  ② `0x8872C = 6` triggers training, then **wait at least 5s / poll until
     LCAP2 becomes 0x06**
  ③ Retrain only from the **root port**; **never touch the endpoint**
  ④ Read back after every high-risk write; only 20 consecutive 0xffffffff
     readings count as dead

Usage:
  sudo python3 unlock-decl.py --dry-run
  sudo python3 unlock-decl.py
  sudo python3 unlock-decl.py --retrain      # if it still has not risen after training, one more root-port retrain
"""
import mmap
import os
import struct
import subprocess
import sys
import time

DEV = os.environ.get("DEV_BDF", "0000:01:00.0")
ROOT = "00:01.0"
GRACE = 20

R_LNKCAP2 = 0x880A4
R_LNKSTA = 0x88088
R_CONFIG = 0x8841C
R_VSECDEV = 0x8860C
R_VSEC = 0x88610
R_LTSSM = 0x8872C
R_SPEED = 0x8C040
R_CYA = 0x8C2C0

XP3G = ((0x8E110, 0x00000001, "XP3G_OVR0"),
        (0x8E11C, 0x00000004, "XP3G_OVR3"),
        (0x8E120, 0x00000000, "XP3G_VAL0"),
        (0x8E12C, 0x00200000, "XP3G_VAL3"))


def sh(c, t=60):
    return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=t)


def bar0_addr():
    try:
        with open(f"/sys/bus/pci/devices/{DEV}/resource") as f:
            return int(f.readline().split()[0], 16)
    except Exception:
        return None


def pci(sel, reg):
    r = sh(f"setpci -s {sel} {reg}")
    s = r.stdout.strip()
    try:
        return int(s, 16)
    except Exception:
        return None


class Bar:
    def __init__(self, phys):
        # ★ O_RDWR is mandatory: opening O_RDONLY and then requesting
        # PROT_WRITE raises PermissionError
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.pg = 0
        self.m = mmap.mmap(self.fd, 0x1000000, mmap.MAP_SHARED,
                           mmap.PROT_READ | mmap.PROT_WRITE, offset=phys)

    def rd(self, o):
        return struct.unpack_from("<I", self.m, o - self.pg)[0]

    def wr(self, o, v):
        struct.pack_into("<I", self.m, o - self.pg, v & 0xFFFFFFFF)

    def alive(self):
        """★ only 20 consecutive 0xffffffff readings count as dead (a single
        one is a retrain transient)"""
        bad = 0
        for _ in range(GRACE):
            if self.rd(R_LNKCAP2) == 0xFFFFFFFF:
                bad += 1
            else:
                return True
            time.sleep(0.05)
        return False

    def close(self):
        try:
            self.m.close(); os.close(self.fd)
        except Exception:
            pass


def show(tag, bar):
    sp = bar.rd(R_SPEED)
    ls = bar.rd(R_LNKSTA)
    print(f"[{tag}]")
    print(f"  LCAP2 (declaration) = {bar.rd(R_LNKCAP2):#06x}"
          f"   {'✓ unlocked' if bar.rd(R_LNKCAP2) == 0x06 else '(not unlocked; Gen1 only among them)'}")
    print(f"  0x8C040    = {sp:#010x}   SPEED={(sp >> 18) & 3}"
          f"  (1=5GT/s  2=2.5GT/s)")
    print(f"  0x88088    = {ls:#010x}   LNKSTA[3:0]={(ls >> 16) & 0xF}"
          f"   {'Gen2' if ((ls >> 16) & 0xF) == 2 else 'Gen1' if ((ls >> 16) & 0xF) == 1 else '?'}")


def main():
    if os.geteuid() != 0:
        print("root required"); return 1
    dry = "--dry-run" in sys.argv
    do_retrain = "--retrain" in sys.argv

    phys = bar0_addr()
    if not phys:
        print("cannot get BAR0"); return 1
    print(f"BAR0 = {phys:#x}   mode={'dry-run' if dry else 'live'}\n")

    bar = Bar(phys)
    if not bar.alive():
        print("MMIO not responding — run pci-state.sh first"); bar.close(); return 1

    show("⓪ starting point", bar)
    if dry:
        print("\n--dry-run: observe only, no changes."); bar.close(); return 0

    # ---- ① unlock the declaration ----
    print("\n=== ① unlock the declaration (never kills the card) ===")
    for off, val, nm in XP3G:
        bar.wr(off, val)
        print(f"  {nm:10s}= {val:#010x}  {'✓' if bar.rd(off) == val else '✗'}")

    c = bar.rd(R_CONFIG)
    newc = (c | (1 << 11) | (1 << 13) | (1 << 15)) & ~((1 << 12) | (1 << 14))
    bar.wr(R_CONFIG, newc)
    print(f"  0x8841C    {c:#010x} -> {bar.rd(R_CONFIG):#010x}  (read-then-OR, set 15/13/11 clear 12/14)")

    g = bar.rd(R_VSEC)
    bar.wr(R_VSEC, (g & ~(1 << 12)) | 1)
    print(f"  0x88610    {g:#010x} -> {bar.rd(R_VSEC):#010x}")

    v = bar.rd(R_VSECDEV)
    bar.wr(R_VSECDEV, v | 1)
    print(f"  0x8860C    {v:#010x} -> {bar.rd(R_VSECDEV):#010x}")

    cya = bar.rd(R_CYA)
    if (cya >> 2) & 1:
        bar.wr(R_CYA, cya & ~(1 << 2)); print(f"  0x8C2C0    DIS_G2 cleared")
    else:
        print(f"  0x8C2C0    = {cya:#010x}  DIS_G2 was already 0")

    if not bar.alive():
        print("!! MMIO stopped responding after ①; stopping immediately"); bar.close(); return 2

    # ---- ② trigger training ----
    print("\n=== ② write 0x8872C = 6 (fires the LTSSM training; the write itself is safe) ===")
    bar.wr(R_LTSSM, 6)
    print(f"  0x8872C    = {bar.rd(R_LTSSM):#x}")

    # ---- ③ wait for training to finish ----
    print("\n=== ③ wait for the declaration to latch (LCAP2 -> 0x06), at least 5s ===")
    t0 = time.time()
    latched = False
    while time.time() - t0 < 25:
        if not bar.alive():
            print("!! MMIO stopped responding during ③"); bar.close(); return 2
        v2 = bar.rd(R_LNKCAP2)
        if v2 == 0x06:
            latched = True
            print(f"  LCAP2 = 0x06 after {time.time()-t0:.1f}s  ✓ latched")
            break
        time.sleep(0.5)
    if not latched:
        print(f"  ✗ did not latch within 25s; LCAP2 = {bar.rd(R_LNKCAP2):#06x}")

    show("③ after training", bar)

    # ---- ④ check whether SPEED was already set by the driver ----
    print("\n=== ④ check 0x8C040.SPEED (after the patch the driver should have written 1) ===")
    sp = bar.rd(R_SPEED)
    speed = (sp >> 18) & 3
    if speed == 1:
        print(f"  SPEED = 1 (5.0GT/s)  ✓ patch is in effect; target speed correct")
    else:
        print(f"  SPEED = {speed}  ⚠ not 1 —— the patch may not be in effect, or the driver has not written it yet")

    # ---- ⑤ optional: root-port retrain ----
    if do_retrain:
        print("\n=== ⑤ retrain from the [root port] (never touch the endpoint), up to 6 rounds ===")
        for i in range(1, 7):
            if not bar.alive():
                print(f"!! MMIO stopped responding before round {i}"); bar.close(); return 2
            cur = pci(ROOT, "CAP_EXP+0x10.w")
            if cur is None:
                print("  cannot read the root port's LNKCTL"); break
            sh(f"setpci -s {ROOT} CAP_EXP+0x10.w={((cur | (1 << 5)) & 0xFFFF):04x}")
            time.sleep(1.5)
            ls = bar.rd(R_LNKSTA)
            sp2 = (ls >> 16) & 0xF
            print(f"  after round {i} LNKSTA[3:0] = {sp2}  {'★Gen2' if sp2 == 2 else ''}")
            if sp2 == 2:
                break

    show("final", bar)

    print("\n=== physical link (lspci's official verdict) ===")
    r = sh(f"lspci -vv -s {DEV} 2>/dev/null | grep -o 'LnkSta:.*' | head -1")
    print("  " + (r.stdout.strip() or "(unreadable)"))

    bar.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
