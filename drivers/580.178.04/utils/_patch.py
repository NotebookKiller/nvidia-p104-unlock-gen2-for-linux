#!/usr/bin/env python3
"""_patch.py — a generic binary patcher driven by a JSON spec

Called by 00-whitelist.sh / 01-gen2-patch.sh; not run directly.

Usage (internal):
    python3 _patch.py <action> <spec_json>

spec structure:
    {
      "name": "gen2",
      "desc": "stop the driver dropping the PCIe speed back to Gen1",
      "path": "/lib/modules/<kver>/updates/dkms/nvidia.ko",
      "anchor": {"mode": "sig", "sig": "<hex>"}   or  {"mode": "offset", "off": 0},
      "edits": [
        {"off": 2, "old": "ff", "new": "fe", "what": "lea -1 -> lea -2"}
      ],
      "md5_before": "...",      # optional, informational only
      "md5_after": "...",       # optional
      "after_note": "..."       # optional, printed after apply
    }

Design points:
  · Three-state judgment: each edit is either "all old" / "all new" /
    "unknown". Only "all old" allows apply, only "all new" allows revert —
    mixed states are refused outright.
  · Backup <path>.orig is only created on apply when absent (revert keeps it)
  · md5 is informational only, never blocking (the file may carry other patches)
  · Exit codes: 0 success / 1 failure / 3 state mismatch (operation refused)

Signature anchor (mode=sig):
  If the original signature is not found, the "patched signature" is
  searched once more — this correctly recognizes an "already patched"
  state instead of misreporting a "driver version mismatch".
"""
import hashlib
import json
import os
import shutil
import sys

# ============================================================
# Colors and output
# ============================================================
C_R, C_G, C_Y, C_B, C_0 = (
    "\033[31m", "\033[32m", "\033[33m", "\033[36m", "\033[0m")
if not sys.stdout.isatty():
    C_R = C_G = C_Y = C_B = C_0 = ""


def ok(msg):   print(f"{C_G}✓{C_0} {msg}")
def warn(msg): print(f"{C_Y}⚠{C_0} {msg}")
def err(msg):  print(f"{C_R}✗{C_0} {msg}")


# ============================================================
# Utilities
# ============================================================
def parse_hex(s):
    """accepts 'ff' / '0xff' (always hex); returns bytes"""
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


def find_all(data, pattern):
    """return every position where pattern occurs in data"""
    positions, i = [], data.find(pattern)
    while i != -1:
        positions.append(i)
        i = data.find(pattern, i + 1)
    return positions


def make_patched_sig(sig, edits):
    """apply the edits to the original signature to get the 'patched'
    form, used to recognize the already-patched state"""
    buf = bytearray(sig)
    for e in edits:
        new = parse_hex(e["new"])
        buf[e["off"]:e["off"] + len(new)] = new
    return bytes(buf)


# ============================================================
# Anchor location
# ============================================================
def locate(data, spec):
    """return the anchor base. Bail out if not found or not unique."""
    anchor = spec["anchor"]

    if anchor["mode"] == "offset":
        base = anchor["off"]
        ok(f"using a fixed offset (base 0x{base:x})")
        return base

    sig = bytes.fromhex(anchor["sig"])
    hits = find_all(data, sig)

    if len(hits) == 1:
        base = hits[0]
        ok(f"signature hits once (file offset 0x{base:x})")
        return base

    if len(hits) > 1:
        err(f"signature hits {len(hits)} places (expected 1) — cannot locate safely")
        print("    refusing to continue. Confirm by hand.")
        sys.exit(3)

    # Original signature not found: possibly already patched; retry with the patched signature
    patched = make_patched_sig(sig, spec["edits"])
    hits = find_all(data, patched)
    if len(hits) == 1:
        base = hits[0]
        ok(f"original signature missed, but the patched signature hits once (0x{base:x}) => should already be patched")
        return base

    err("the signature hit nowhere — wrong driver version?")
    print("    Confirm the driver version first, then re-locate the signature (do not force-fit this version's offsets)")
    sys.exit(3)


# ============================================================
# Per-edit state scan
# ============================================================
def scan_states(data, base, edits):
    """return [(state, off, cur, old, new), ...], state ∈ orig/new/unknown"""
    states = []
    for e in edits:
        off = base + e["off"]
        old = parse_hex(e["old"])
        new = parse_hex(e["new"])
        cur = bytes(data[off:off + len(old)])
        if cur == old:
            st = "orig"
        elif cur == new:
            st = "new"
        else:
            st = "unknown"
        states.append((st, off, cur, old, new))
    return states


# ============================================================
# Action: check
# ============================================================
def do_check(spec, data, md5_now, states, self_name):
    n_orig = sum(1 for s in states if s[0] == "orig")
    n_new = sum(1 for s in states if s[0] == "new")
    n_unk = sum(1 for s in states if s[0] == "unknown")

    print(f"   md5 = {md5_now}")
    for st, off, cur, old, new in states:
        mark = {"orig": "orig", "new": "new", "unknown": "unknown"}[st]
        print(f"   0x{off:08x}  cur={cur.hex():<6s} {mark}")

    print()
    if n_orig == len(states):
        warn("state: not patched")
        print(f"    patch it: sudo bash {self_name} apply")
    elif n_new == len(states):
        ok("state: patched")
        print(f"    revert:  sudo bash {self_name} revert")
    else:
        err(f"abnormal state: {n_orig} orig / {n_new} changed / {n_unk} unknown")
        print("    The file may have been modified by another tool, or the driver version mismatches. Do not apply blindly.")
        sys.exit(3)
    sys.exit(0)


# ============================================================
# Action: apply / revert
# ============================================================
def do_write(action, spec, data, md5_now, states, path):
    want_from = "orig" if action == "apply" else "new"

    # The state must be "all orig" or "all new"; mixed states are refused
    if not all(s[0] == want_from for s in states):
        err(f"state does not match expectations; refusing {action}")
        for st, off, cur, old, new in states:
            want = ("orig " + old.hex()) if action == "apply" else ("patched " + new.hex())
            print(f"   0x{off:08x}  cur={cur.hex()}  expected={want}")
        sys.exit(3)

    # Backup: only create on apply when .orig is absent
    bak = path + ".orig"
    if action == "apply" and not os.path.exists(bak):
        shutil.copy2(path, bak)
        ok(f"backed up -> {os.path.basename(bak)}")

    # Write back
    for st, off, cur, old, new in states:
        target = new if action == "apply" else old
        data[off:off + len(target)] = target

    with open(path, "wb") as f:
        f.write(data)

    md5_after = hashlib.md5(data).hexdigest()

    print()
    for e, (st, off, cur, old, new) in zip(spec["edits"], states):
        target = new if action == "apply" else old
        print(f"   0x{off:08x}  {cur.hex()} → {target.hex()}   {e['what']}")

    print()
    ok(f"{action} done")
    print(f"   md5: {md5_now} → {md5_after}")

    # md5 verification (informational only, never blocking)
    # On apply: before-write=before, after-write=after; reversed on revert
    if action == "apply":
        checks = [("before-write ", md5_now, spec.get("md5_before")),
                  ("after-write  ", md5_after, spec.get("md5_after"))]
    else:
        checks = [("before-write ", md5_now, spec.get("md5_after")),
                  ("after-write  ", md5_after, spec.get("md5_before"))]

    for label, got, expect in checks:
        if not expect:
            continue
        if got == expect:
            ok(f"md5 {label}matches the record ({expect[:8]}…)")
        else:
            warn(f"md5 {label}differs from the record (recorded {expect[:8]}…, actual {got[:8]}…)")
            # Explain why it can differ — the most common cause is "the 00 whitelist was applied first"
            print("      ⓘ This is not an error and does not affect execution (md5 is informational only, never blocking).")
            print("        Most common cause: this file carries other patches on top / was recompiled.")
            print("        For example, after running 00-whitelist (changing nv-kernel.o_binary -> rebuilding nvidia.ko),")
            print("        nvidia.ko's md5 necessarily no longer matches the \"factory\" record — that is expected.")
            print("        The real safety net is: unique 32-byte signature location + three-state verification (mixed states refused).")

    if action == "apply" and spec.get("after_note"):
        print()
        print(f"   ★ {spec['after_note']}")


# ============================================================
# main
# ============================================================
def main():
    if len(sys.argv) < 4:
        err("internal usage: _patch.py <action> <spec_json> <parent_script>")
        return 1

    action = sys.argv[1]
    spec = json.loads(sys.argv[2])
    self_name = os.path.basename(sys.argv[3])

    path = spec["path"]
    print(f"   file: {path}")

    if not os.path.exists(path):
        err(f"file not found: {path}")
        print("    Check the driver version and install path")
        return 3

    data = bytearray(open(path, "rb").read())
    md5_now = hashlib.md5(data).hexdigest()

    base = locate(data, spec)
    states = scan_states(data, base, spec["edits"])

    if action == "check":
        do_check(spec, data, md5_now, states, self_name)
    elif action in ("apply", "revert"):
        do_write(action, spec, data, md5_now, states, path)
    else:
        err(f"unknown action {action}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
