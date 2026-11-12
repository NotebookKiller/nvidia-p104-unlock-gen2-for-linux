#!/usr/bin/env python3
"""patch_no_gen1.py — stop the driver from downgrading the link back to Gen1 at cuInit

## Conclusion first (measured in reports/199)

perf four breakpoints, one `minictx` run (1 CUDA context):

```
entry     0x127d60  1 time  DX=0x1                      <- mode = 1
or80000   0x127e65  1 time  AX 0x20505800               <- SPEED[19:18] cleared
wr_shared 0x127edd  1 time  R8=0x20585800               <- ★ SPEED=2 really got written
bailret   0x1280c8  1 time
```

=> **SPEED=2 is written by software, not by an endpoint-side writeback**.
   (The "CPU-invisible" conclusion from reports/195/197 is void: that time the
   breakpoints simply did not take effect.)

## Why moving the "range-check boundary" is cleaner than A/B/C

The entry of `_nv017105rm(dev, obj, mode)` is a whitelist check:

```asm
127d66: 8d 42 ff        lea  -0x1(%rdx),%eax     ; eax = mode - 1
127d81: 83 f8 02        cmp  $0x2,%eax
127d84: 0f 87 3e 03 00 00  ja 1280c8             ; (mode-1) > 2 -> bail (i.e. mode not in {1,2,3})
```

Translate it into **`mode - 2` / `cmp $0x1`**:

```asm
127d66: 8d 42 fe        lea  -0x2(%rdx),%eax     ; eax = mode - 2
127d81: 83 f8 01        cmp  $0x1,%eax
127d84: 0f 87 ...       ja   1280c8              ; (mode-2) > 1 -> bail
```

The new bail condition (unsigned):

| mode | mode-2 | > 1? | result |
|---|---|---|---|
| 1 | `0xFFFFFFFF` (underflow) | yes | **bail** ★ the only behavior change |
| 2 | 0 | no | continue (Gen2) |
| 3 | 1 | no | continue (Gen3) |
| >=4 | >=2 | yes | bail (**identical to the original**) |

=> **The only behavioral difference is that mode==1 changes from "execute" to "bail"**;
   every other bit, every other branch, every other mode stays unchanged.

### Why bail is safe
- `1280c8` is the function's **only** return point: `pop %rbx; mov %r12d,%eax; pop x4; add $0x40,%rbp; ret`
- `%r12d` is zeroed at entry by `xor %r12d,%r12d`, and the mode==1 path's write to
  `%r12` (`lea 0x1e08(%r13),%r12`) lives in the code we skip
- => bail returns **0 = CUDA_SUCCESS**, so the driver considers the set successful,
  does not report an error and does not retry

## Comparison with A/B/C

| approach | what it changes | verdict |
|---|---|---|
| A: add `cmp $1,%edx; je ret` at entry | needs a code cave | the function has no slack to fit 5 bytes; CET/IBT would need handling too |
| B: retarget `je .mode1_case` | — | **that instruction does not exist**: mode==1 falls through sequentially, it is not jumped to |
| C: nop out `or $0x80000` | 1 instruction | would fall into `movl $0x1,0xc(%rbp)` (the stored mode); semantics unclear |
| **this approach** | **2 bytes** | boundary shift, whitelist narrowed, zero side effects |

## Usage
  sudo python3 patch_no_gen1.py check
  sudo python3 patch_no_gen1.py apply
  sudo python3 patch_no_gen1.py revert

⚠ After apply the nvidia module must be reloaded (or the machine rebooted) for it to take effect.
"""
import hashlib
import os
import shutil
import subprocess
import sys

ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


def resolve_ko():
    """Locate the real nvidia.ko, which may be .ko or .ko.zst (common with DKMS/distro packaging).

    Order: TARGET_KO env var -> modinfo -n nvidia -> a few well-known paths.
    """
    kv = os.uname().release
    cands = []
    if os.environ.get("TARGET_KO"):
        cands.append(os.environ["TARGET_KO"])
    try:
        r = subprocess.run(["modinfo", "-n", "nvidia"],
                           capture_output=True, text=True, timeout=20)
        if r.returncode == 0 and r.stdout.strip():
            cands.append(r.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    for base in ("/lib/modules/%s/updates/dkms" % kv,
                 "/lib/modules/%s/updates" % kv,
                 "/lib/modules/%s/kernel/drivers/video" % kv,
                 "/lib/modules/%s/kernel/drivers/video/nvidia" % kv):
        for name in ("nvidia.ko.zst", "nvidia.ko"):
            cands.append(os.path.join(base, name))

    seen = set()
    for c in cands:
        if c in seen:
            continue
        seen.add(c)
        if os.path.isfile(c):
            return c
    return None


KO = resolve_ko()
IS_ZST = False
if KO:
    with open(KO, "rb") as _f:
        IS_ZST = _f.read(4) == ZSTD_MAGIC
BAK = (KO + ".orig_nogen1") if KO else ""


def load_ko(path):
    """Read the **decompressed** ELF bytes. A .zst file is decompressed in memory with `zstd -d` first."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:4] != ZSTD_MAGIC:
        return raw
    try:
        r = subprocess.run(["zstd", "-d", "-c", "--", path], capture_output=True)
    except OSError:
        raise RuntimeError("the zstd command is required to decompress .ko.zst (apt install zstd)")
    if r.returncode != 0:
        raise RuntimeError("zstd decompression failed: %s" % r.stderr.decode("utf-8", "replace")[:200])
    return r.stdout


def store_ko(path, data):
    """Write the **decompressed** ELF bytes back to disk; recompress if the original file is .zst.

    Uses "write temp file + os.replace" for atomicity so a mid-way failure cannot leave a
    half-written .ko behind.
    """
    st = os.stat(path)
    tmp = path + ".new"
    with open(path, "rb") as f:
        was_zst = f.read(4) == ZSTD_MAGIC

    if was_zst:
        level = os.environ.get("ZSTD_LEVEL", "19")
        try:
            r = subprocess.run(
                ["zstd", "-q", "-T0", "-%s" % level, "-f", "-o", tmp, "-"],
                input=data, capture_output=True)
        except OSError:
            raise RuntimeError("the zstd command is required to recompress (apt install zstd)")
        if r.returncode != 0:
            raise RuntimeError("zstd compression failed: %s" % r.stderr.decode("utf-8", "replace")[:200])
    else:
        with open(tmp, "wb") as f:
            f.write(data)

    os.chmod(tmp, st.st_mode)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except PermissionError:
        pass
    os.replace(tmp, path)

# ★ Unique signature: the full 32-byte sequence from the entry's lea to the ja (exactly 1 occurrence in the whole file)
SIG = bytes.fromhex(
    "8d42ff"          # lea  -0x1(%rdx),%eax
    "4156"            # push %r14
    "4155"            # push %r13
    "4989fd"          # mov  %rdi,%r13
    "4154"            # push %r12
    "4531e4"          # xor  %r12d,%r12d
    "53"              # push %rbx
    "4883ed40"        # sub  $0x40,%rbp
    "48897510"        # mov  %rsi,0x10(%rbp)
    "89550c"          # mov  %edx,0xc(%rbp)
    "83f802"          # cmp  $0x2,%eax
    "0f87")           # ja   rel32

# The patched form (used by check / to decide on repeated apply)
SIG_NEW = (SIG[:2] + bytes([0xFE]) +        # lea -0x1 -> lea -0x2
           SIG[3:0x1D] + bytes([0x01]) +    # cmp $0x2 -> cmp $0x1
           SIG[0x1E:])

OFF_LEA = 2      # position of the lea imm8 (byte ff -> fe)
OFF_CMP = 0x1D   # position of the cmp imm8 (byte 02 -> 01)

ORIG_LEA, NEW_LEA = 0xFF, 0xFE
ORIG_CMP, NEW_CMP = 0x02, 0x01


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def find_all(data, pat):
    out, i = [], 0
    while True:
        i = data.find(pat, i)
        if i < 0:
            return out
        out.append(i)
        i += 1


def main():
    act = sys.argv[1] if len(sys.argv) > 1 else "check"
    if os.geteuid() != 0:
        print("root required"); return 1
    if not KO:
        print("cannot find nvidia.ko (and no .ko.zst either)")
        print("  pass TARGET_KO=/path/to/nvidia.ko to specify it explicitly")
        return 1

    print(f"target {KO}")
    print(f"format {'zstd-compressed (.ko.zst)' if IS_ZST else 'raw ELF'}")
    print(f"md5  {md5(KO)}")
    try:
        data = load_ko(KO)
    except RuntimeError as e:
        print(f"!! {e}")
        return 1
    print(f"decompressed size {len(data):,} bytes\n")

    if act == "revert":
        if not os.path.exists(BAK):
            print(f"no backup {BAK}"); return 2
        shutil.copy2(BAK, KO)
        print(f"restored, md5 {md5(KO)}")
        if KO.endswith(".zst"):
            print("  (the backup is also .zst, so it overwrites directly; no recompression needed)")
        return 0

    # ---- Locate ----
    orig_hits = find_all(data, SIG)
    new_hits = find_all(data, SIG_NEW)
    total = len(orig_hits) + len(new_hits)
    print(f"signature hits: original form {len(orig_hits)}, patched form {len(new_hits)}")
    if total != 1:
        print("!! signature is not unique or not found; refusing to proceed")
        for h in orig_hits[:10]:
            print(f"   original @ {h:#x}")
        for h in new_hits[:10]:
            print(f"   patched @ {h:#x}")
        return 2

    already = len(new_hits) == 1
    base = new_hits[0] if already else orig_hits[0]
    print(f"  located at {base:#x}  (offset {base - 0x40:#x} within the .text section)")

    cur_lea, cur_cmp = data[base + OFF_LEA], data[base + OFF_CMP]
    print(f"  lea imm8 @ {base + OFF_LEA:#x} = {cur_lea:#04x}   (orig {ORIG_LEA:#04x} / patched {NEW_LEA:#04x})")
    print(f"  cmp imm8 @ {base + OFF_CMP:#x} = {cur_cmp:#04x}   (orig {ORIG_CMP:#04x} / patched {NEW_CMP:#04x})")

    if act == "check":
        if already:
            print("\n[patched] mode==1 now bails outright; the driver no longer downgrades the link to Gen1")
            print("  ⚠ the nvidia module must be reloaded for this to take effect")
        else:
            print("\n[not patched] currently mode==1 writes SPEED=2 -> the link drops back to 2.5GT/s")
            print("  after patch: mode in {1} -> bail; {2,3} unchanged; >=4 unchanged")
        return 0

    if act == "apply":
        if already:
            print("\nalready patched"); return 0
        if cur_lea != ORIG_LEA or cur_cmp != ORIG_CMP:
            print(f"\n!! unexpected bytes (lea={cur_lea:#04x} cmp={cur_cmp:#04x}); refusing to patch")
            return 2
        if not os.path.exists(BAK):
            shutil.copy2(KO, BAK)
            print(f"\nbacked up -> {BAK}")

        nd = bytearray(data)
        nd[base + OFF_LEA] = NEW_LEA
        nd[base + OFF_CMP] = NEW_CMP
        try:
            store_ko(KO, bytes(nd))
        except RuntimeError as e:
            print(f"\n!! write-back failed: {e}")
            return 2

        print(f"written: {bytes(nd[base:base+len(SIG)]).hex(' ')}")
        print(f"new md5: {md5(KO)}")
        if IS_ZST:
            print(f"  (recompressed with zstd -{os.environ.get('ZSTD_LEVEL', '19')})")
        print("\nnext: rmmod nvidia_uvm nvidia_modeset nvidia_drm nvidia -> modprobe nvidia")
        if IS_ZST:
            print("⚠ DKMS note: the module file is patched but the DKMS cache is still stale,")
            print("   reinstalling the kernel or running dkms install will wipe the patch. Run sync-dkms.sh adopt to persist it.")
        return 0

    print(f"unknown action {act}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
