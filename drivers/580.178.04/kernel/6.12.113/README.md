# kernel / 6.12.113

Source of `gen2kr.ko`. **The directory name is "the kernel version this module was compiled and verified on."**

```
Kernel   6.12.113+deb13-amd64   (Debian 13 / trixie)
Driver   580.178.04
GPU      P104-100 (10de:1b87)
gcc      14.2.0 (the same one the kernel was built with)
```

---

## Why directories are named per kernel version

The source uses stable APIs (`kretprobe` / `pci_get_device` / `ioremap`),
so in theory it compiles across kernel versions. But the **build artifact is tightly bound to the kernel**:

- the kernel symbol table, struct offsets, and ABI can all change
- the module must be compiled against the **target machine's kernel headers** (`/lib/modules/$(uname -r)/build`)
- a `.ko` compiled for one kernel cannot be loaded on another (`Invalid module format`)

So "which kernel this was compiled and verified on" must be obvious from the directory name.
When changing kernel versions, create a sibling directory (e.g. `6.13.1`) and **do not rename this one in place** --
the old directory stands as a historical verification record.

---

## Files

| File | Purpose |
|---|---|
| `gen2kr.c` | All the logic: kretprobe + first push + guard (with COMMIT protection) |
| `Makefile` | `obj-m := gen2kr.o`, `KDIR` auto-derived from `$(uname -r)` |
| `gen2kr.service` | systemd unit (**optional, not enabled**; the user explicitly asked for it not to be installed) |

## What it does

It attaches a kretprobe on `nv_pci_probe` and, at the **instant the probe returns**, does three things:

```
① Unlock endpoint declaration
   0x8E110/0x8E11C/0x8E120/0x8E12C  →  XP3G slot
   0x8841C  →  (read | bit11|13|15) & ~(bit12|14)
   0x88610  →  (read & ~bit12) | 1
   0x8C2C0  →  clear bit2 (DIS_G2)
   0x8872C = 6  →  trigger training; LNKCAP2 flips from 0x02 to 0x06 on the spot

② Write SPEED=1 (5.0GT/s)
   SPEED[19:18] of 0x8C040 = 1, ★ never write bit0 (COMMIT)

③ TLS=2 on both ends, Retrain from the root port
```

**Why exactly at the instant the probe returns**: the driver resets those bits inside the
probe; writing earlier gets overwritten, writing later misses the link-training window.
The kretprobe is the only reliable handle on this timing.

## Building

```bash
# From the repo root
bash bin/build.sh

# Or manually (★ do not use sudo; the artifacts would be owned by root)
cd drivers/580.178.04/kernel/6.12.113
make -C /lib/modules/$(uname -r)/build M=$PWD modules
```

`bin/build.sh` finds the directory automatically (preferring a match for the current kernel)
and copies the `.ko` into `build/` afterwards.

## Tunable parameters (inspect after insmod under /sys/module/gen2kr/parameters/)

| Parameter | Default | Meaning |
|---|---|---|
| `guard_period_ms` | 200 | guard period (originally 100ms) |
| `guard_rounds` | 0 | guard rounds, 0 = resident; >0 guards only that many rounds |
| `guard_enabled` | 1 | master switch, 0 = guard does nothing at all |
| `debounce_cnt` | — | how many consecutive downgrades must be seen before acting |
| `retrain_min_ms` | — | minimum interval between retrains |
| `speed_settle_ms` | — | settling wait after writing SPEED |
| `stage_gap_ms` | — | interval between stage0 (write 0x8872C) and stage1 (root-port Retrain) |

> `guard_enabled=0` **cannot stop** the "push SPEED back" path (the guard keeps writing SPEED),
> to fully stop the guard you must `rmmod`. A pitfall we stepped in.

## Judgment discipline (written here so nobody repeats the mistake)

- For Gen2 you may only trust `LNKSTA[3:0] == 2` (BAR0 `0x88088`)
- **Every nvidia-smi PCIe field is driver-cached**, not trustworthy
- `grep 'Speed 5GT/s'` false-matches `2.5GT/s` (stepped in 3 times)
- The bandwidth test must be `512MB × 15`; `128MB × 3` lands inside the recovery window and measures only 0.78

## Related projects (not part of this repo)

Mining cards have another independent problem: frame rate stuck at ~40fps, power draw capped
(the driver writes `method 0x3998 = 0xF0(240)` every batch, ≈218µs of idle spin).

This repo does not ship that patch; if you need it:

- **clear-delay project** (user-space approach): <https://github.com/WJNKAC/nvidia-p106-clear-delay>
- **upstream analysis** (kernel whitelist idea): <https://github.com/dartraiden/NVIDIA-patcher/issues/3>

> Note: the `drivers/<version>/00-whitelist.sh` patch in this repo solves it **at the source** --
> after the patch, the delay commands are never generated at all. So for the frame-rate problem,
> `whitelist` is more thorough than the user-space patch.

---

## ⚠ Before touching anything

Please read `docs/safety-discipline.md` first. In particular:

- **Before `unbind`, confirm no process holds the GPU** (`fuser -v /dev/nvidia*`);
  otherwise the kernel wedges, `kill -9` does nothing, and only a reboot helps (2026-10-29 incident)
- Changing the BAR0 link-control registers **must go through the kernel path**; a user-space `mmap` write bricks the device
