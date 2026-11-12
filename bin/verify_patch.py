#!/usr/bin/env python3
"""verify_patch.py — verify the patch bytes and disassembly on a copy, without
touching the live .ko

This machine's /tmp is only 10M (tmpfs) and cannot hold the 157MB nvidia.ko,
so this runs on the union side (/tmp has 12G).

Usage: python3 verify_patch.py
"""
import hashlib
import os
import shutil
import subprocess
import sys

KO = "/lib/modules/%s/updates/dkms/nvidia.ko" % os.uname().release
TMP = "/tmp/patched-test.ko"

SIG = bytes.fromhex(
    "8d42ff" "4156" "4155" "4989fd" "4154" "4531e4" "53" "4883ed40"
    "48897510" "89550c" "83f802" "0f87")
OFF_LEA, OFF_CMP = 2, 0x1D


def main():
    print(f"source {KO}")
    print(f"   size {os.path.getsize(KO):,}")
    shutil.copy2(KO, TMP)
    d = bytearray(open(TMP, "rb").read())

    hits, i = [], 0
    while True:
        i = d.find(SIG, i)
        if i < 0:
            break
        hits.append(i)
        i += 1
    print(f"signature hits {len(hits)}: {[hex(h) for h in hits]}")
    if len(hits) != 1:
        print("✗ signature not unique; aborting"); return 2

    b = hits[0]
    print(f"base = {b:#x}   (offset within .text {b - 0x40:#x})")
    print(f"before: {d[b:b+32].hex(' ')}")

    # verify the bytes to patch really hold the expected values
    if d[b + OFF_LEA] != 0xFF or d[b + OFF_CMP] != 0x02:
        print(f"✗ unexpected bytes at the patch site lea={d[b+OFF_LEA]:#04x} cmp={d[b+OFF_CMP]:#04x}")
        return 2

    d[b + OFF_LEA] = 0xFE     # lea -0x1 -> lea -0x2
    d[b + OFF_CMP] = 0x01     # cmp $0x2 -> cmp $0x1
    open(TMP, "wb").write(d)
    print(f"after: {bytes(d[b:b+32]).hex(' ')}")

    print("\n--- disassembly: before the patch (source file) ---")
    r = subprocess.run(
        f"objdump -d --start-address={b-0x40:#x} --stop-address={b-0x40+0x28:#x} {KO}",
        shell=True, capture_output=True, text=True)
    for ln in r.stdout.splitlines():
        if ":" in ln and any(x in ln for x in ("lea", "cmp", "ja", "push", "mov", "xor", "sub")):
            print("  " + ln.strip())

    print("\n--- disassembly: after the patch (copy) ---")
    r = subprocess.run(
        f"objdump -d --start-address={b-0x40:#x} --stop-address={b-0x40+0x28:#x} {TMP}",
        shell=True, capture_output=True, text=True)
    for ln in r.stdout.splitlines():
        if ":" in ln and any(x in ln for x in ("lea", "cmp", "ja", "push", "mov", "xor", "sub")):
            print("  " + ln.strip())

    print("\n--- logic check ---")
    print("  mode=1: eax = 1-2 = 0xFFFFFFFF; unsigned > 1 -> bail ✓")
    print("  mode=2: eax = 0; is 0 > 1? no -> continue (Gen2) ✓")
    print("  mode=3: eax = 1; is 1 > 1? no -> continue (Gen3) ✓")
    print("  mode>=4: eax >= 2 > 1 -> bail (same as the original logic; the original bailed for mode>3 too) ✓")

    md5 = hashlib.md5(open(TMP, "rb").read()).hexdigest()
    print(f"\ncopy md5 {md5}   kept at {TMP}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
