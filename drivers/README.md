# Patches organized by driver version

> ⚠ Patches are strongly bound to the driver version. Switching versions
> requires re-locating everything yourself, following the method below.

Each subdirectory corresponds to **one NVIDIA driver version** and contains all
the patches verified on that version. The layout follows the
[vGPU-Unlock-patcher](https://github.com/VGPU-Community-Drivers/vGPU-Unlock-patcher)
convention of `patches/blob-<version>.diff`: **offsets and bytes are bound to
the version and cannot be reused across versions**.

## Why directories are per version

Patches modify **specific bytes of closed-source binaries**. When the driver
version changes:

- function locations move (the `.text` offsets inside `nvidia.ko` change)
- even code structure can move (the criterion offsets inside
  `libnvidia-glcore.so` change)
- the md5 is completely different

So every version must be **re-located and re-verified**; numbers from another
version cannot be reused. Pinning "version -> offsets -> verification data"
inside one directory is the only way that avoids mix-ups.

## Directory conventions

```
drivers/<driver-version>/
├── README.md      overview of this version: patches, offset tables, verification data, risks
├── offsets.sh     machine-readable offsets (can be sourced, or just read)
├── 00-whitelist.sh   pre-step (optional): lift the restricted SKU
├── 01-gen2-patch.sh  required: patch nvidia.ko (no more downgrades)
├── 02-gen2-push.sh   required: load the module + push the link
├── _lib.sh           shared bash helpers
├── _patch.py         generic binary patcher (driven by a JSON spec)
└── kernel/
    └── <kernel-version>/    ← ★ kernel modules get one more layer, by [kernel version]
        ├── README.md      description of the module on this kernel
        ├── gen2kr.c       kretprobe + push + guard
        ├── Makefile
        └── gen2kr.service
```

### Why kernel modules are nested by kernel version

Patch offsets are bound to the **driver version**; the kernel module build
artifact is bound to the **kernel version**. They are two different things:

| | bound to | why |
|---|---|---|
| `offsets.sh` / `_patch.py` / `0x-*.sh` | driver version | they modify byte offsets of the driver binary |
| `kernel/<kernel-version>/` | kernel version | the `.ko` must be compiled against the target machine's kernel headers; a different kernel cannot load it |

So there are two levels: `drivers/<driver>/kernel/<kernel>/`.
When the kernel version changes, **create a new sibling directory** instead of
renaming in place — the old directory is the historical verification record.

`bin/build.sh` automatically looks up the directory matching the current
kernel (`find_kmod_dir` in `_common.sh`); with no exact match it falls back to
"the only set in the repo" and warns that the versions may not match.

### Division of labor between 00/01 and 02

| script | what it handles | mechanism |
|---|---|---|
| `00-whitelist.sh` | frame cap / power cap (optional) | byte patch |
| `01-gen2-patch.sh` | stop the driver downgrading | byte patch |
| `02-gen2-push.sh` | push the link up | load the kernel module |

00/01 are **byte-level patches** and work standalone (no need to clone the
whole repo; only `_lib.sh` / `_patch.py` / `offsets.sh` are needed).
02 loads the module built from `kernel/<kernel-version>/`.

All three scripts run directly inside the version directory; no need to go
back to the repo root:

```bash
cd drivers/580.178.04
sudo bash 01-gen2-patch.sh apply
# after the reload/reboot
sudo bash 02-gen2-push.sh start
```

## Versions present

| version | patches | status | kernel |
|---|---|---|---|
| [580.178.04](580.178.04/README.md) | Gen2 unlock (2 bytes)<br>per-batch delay (1 byte)<br>kernel whitelist (10 bytes) | ✅ all measured live | 6.12.113 |

> Only one version exists so far. To add a new one later: copy `580.178.04/`
> as the template, then **re-locate and re-measure every single offset**; do
> not copy the numbers.

## This directory provides two patches

This project focuses on the **PCIe Gen2 unlock**. Only patches directly
related to it live here:

| patch | solves | symptom | file modified | change size |
|---|---|---|---|---|
| **Gen2** | PCIe link speed | `0.78 GB/s` (Gen1 x4) | `nvidia.ko` | 2 bytes |
| **whitelist** | the driver's "restricted SKU" check | framerate stuck ~40fps, power cannot climb | `nv-kernel.o_binary` | 10 bytes |

The two are independent: usable alone, or stacked.

### About "per-batch delay" (gr3d delay) — referenced only; not implemented here

P1XX / CMP mining cards carry one **independent** performance limiter: the
driver writes to the pushbuffer every batch with
`method 0x3998 = 0xF0 (240)`, giving 240 × 0.91µs ≈ 218µs of idle spin, which
pins the framerate at ~40fps and keeps power usage down. This problem has
**nothing to do with PCIe bandwidth**; it is a separate topic.

**This repo does not ship an implementation.** If you need it, see:

- the same author's clear-delay project: <https://github.com/WJNKAC/nvidia-p106-clear-delay>
- upstream analysis (the kernel-whitelist idea): <https://github.com/dartraiden/NVIDIA-patcher/issues/3>

> ★ Every `drivers/<version>/README.md` repeats these two links —
> because someone reading a single version may not browse this far.

Its relationship with this directory's `whitelist` patch:

| config | frame time | fps | delay commands generated? |
|---|---|---|---|
| no patches | 52.202 ms | 18.98 | 40+ |
| **whitelist only** | **3.668 ms** | 243.78 | **0** |
| user-space jump only (not provided by this project) | 3.434 ms | 259.79 | 0 |
| both | 3.667 ms | 246.64 | 0 |

=> **the `whitelist` patch alone is enough**: the commands are **never
generated at all** (not "generated but skipped"); the other patch adds no
benefit on top of it.

That is also why this directory keeps `whitelist`: like `gen2`, it patches the
**identity/policy layer of the driver or kernel module**, located with the same
method, so they belong together. The "user-space glcore jump" is a different
layer and a different topic; only the conclusion is referenced here, no
implementation.

## Gen2's extra requirement

Gen2's 2-byte patch only achieves "the driver no longer drops the speed back
to Gen1"; **the link itself still needs someone to push it up** (unlock the
endpoint declaration + write SPEED + retrain).

The push is done by `580.178.04/kernel/6.12.113/gen2kr.c` (at the instant
`nv_pci_probe` returns); see `580.178.04/README.md` for the full flow.
`01-gen2-patch.sh` only handles that 2-byte patch.
