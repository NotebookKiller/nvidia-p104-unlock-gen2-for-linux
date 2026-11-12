# 580.178.04

NVIDIA 580.178.04 / kernel 6.12.113+deb13-amd64 / Debian 13 / P104-100.
**This is the only fully verified version combination.**

---

## Scripts (run in numbered order)

```
00-whitelist.sh    pre-step, optional    lifts the "restricted SKU" check (fixes framerate/power; unrelated to Gen2)
01-gen2-patch.sh   required              patches nvidia.ko so the driver stops dropping the speed back to Gen1
02-gen2-push.sh    required              loads the module and pushes the link to Gen2 (start/stop/status)
```

Every script supports three actions: `check` (read-only) / `apply` or `start` /
`revert` or `stop`.

---

## 1. How to use

> ### ⚠⚠ Pitfall number one: DKMS will overwrite your patch
>
> The `nvidia.ko` produced by patching has two homes, and **they are separate
> files, not symlinks**:
>
> | location | role |
> |---|---|
> | `/usr/src/nvidia-580.178.04/nvidia.ko` | the `make` artifact |
> | `/var/lib/dkms/nvidia/580.178.04/<kver>/x86_64/module/nvidia.ko` | **DKMS's "built" cache** |
> | `/lib/modules/<kver>/updates/dkms/nvidia.ko` | **what modprobe actually reads at boot** |
>
> `dkms install` (and `autoinstall` when a new kernel is installed) takes the
> **built cache** and overwrites the `/lib/modules` copy. If the cache holds an
> old version, **your patch is gone entirely and you are back to 19fps after
> the reboot**.
>
> **So after patching you must sync**:
>
> ```bash
> sudo ./sync-dkms.sh status   # check whether the three places agree
> sudo ./sync-dkms.sh adopt    # pin the currently-live copy into the DKMS cache + /usr/src
> ```
>
> Hit for real on 2026-10-30: patched 00, ran the prompted `make`, rebooted,
> still 19fps — because only `/usr/src` got `make`'d while the DKMS cache was
> still the 10-28 original (md5 `7f6805ed…`, appearing 2 times on the
> P104-100). After running `adopt`, all three places had the same md5 and
> reboots stopped losing it.

### Step 0 (optional): lift the restricted SKU

**Skipping this does not affect Gen2**; it only affects framerate/power. Skip
it if all you want is bandwidth.

```bash
sudo bash 00-whitelist.sh check     # current state (lists the cards in the table)
sudo bash 00-whitelist.sh apply     # apply the patch
```

Afterwards you must **rebuild the kernel module** (the script prints the full
command):

```bash
cd /usr/src/nvidia-580.178.04
sudo make -j$(nproc)                # ★ must run as root; otherwise you get a permission error that is easy to mistake for a compiler problem
```

Then sync DKMS and reload the driver or reboot:

```bash
sudo ./sync-dkms.sh adopt           # ★ skip this and the reboot undoes everything
```

> ★ **Rebuilding makes the 01 gen2 patch vanish** (01 modifies the `.ko`
> directly; a rebuild discards it).
> Correct order: **00 whitelist -> make -> sync-dkms adopt -> 01 gen2 ->
> sync-dkms adopt**.

### Step 1: patch nvidia.ko

```bash
sudo bash 01-gen2-patch.sh check    # current state
sudo bash 01-gen2-patch.sh apply    # apply the 2-byte patch
```

> **About the md5 warning**: if you ran 00 (whitelist) first, this step will
> always report `⚠ md5 mismatch from the pre-write record`. **That is expected
> behavior and does not stop execution** — md5 is only an advisory; the real
> safety net is "unique 32-byte signature location + three-state check".
> See `docs/troubleshooting.md` under "md5 mismatch".

Once applied the new code must be loaded, either way:

```bash
# A) reload the modules (fast; interrupts the graphical session)
sudo rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia
sudo modprobe nvidia && sudo modprobe nvidia_uvm nvidia_modeset nvidia_drm

# B) just reboot — but only after sync-dkms adopt, or the cache will roll it back
```

> ⚠ **Before reloading/rebooting, confirm nothing is using the GPU**:
> ```bash
> fuser -v /dev/nvidia*
> ```
> If it prints anything, close those programs first (browsers / Electron apps
> are the usual culprits). Otherwise `unbind` wedges the kernel: processes end
> up in D state and `kill -9` does nothing; only a full reboot works.

> **Debian/Ubuntu ship the module compressed as `.ko.zst`**
>
> Distributions (including Ubuntu 24.04) commonly use zstd-compressed kernel
> modules; the file is `nvidia.ko.zst`. The patch scripts **handle this
> automatically**: when the zstd magic is detected they decompress into memory
> to find the signature, then re-compress at the original level (default
> `-19`, override with `ZSTD_LEVEL`) and atomically replace the file.
> The system needs the `zstd` command (`apt install zstd`).
>
> To manually confirm the patch really made it into the compressed blob:
> ```bash
> zstd -dc "$(modinfo -n nvidia)" | md5sum     # compare against the "uncompressed md5" the script prints
> ```

### Step 2: push the link up

The patch only achieves "the driver stops downgrading"; **the link still needs
someone to push it**.

```bash
sudo bash 02-gen2-push.sh status    # check state first
sudo bash 02-gen2-push.sh start     # build (if needed) + load the module + push
```

`start` does, in order: check the patch -> prepare the module -> **confirm the
GPU is idle** -> insmod -> unbind/bind -> wait for Gen2.

> `start` needs root (for insmod / writing sysfs), but **the module must not be
> compiled as root** (on NFS, root_squash prevents root from writing
> `.gen2kr.o.d`). The script automatically drops privileges to `SUDO_USER` for
> the build, so plain `sudo ./02-gen2-push.sh start` is fine.
> To only build, no sudo is needed: `./02-gen2-push.sh build`.

### Step 3: verify

```bash
sudo bash 02-gen2-push.sh status           # CAP2=0x0006 LNKSTA=2
sudo bash ../../bin/30-verify.sh           # bandwidth + stability
```

- success: `LNKSTA=2` (5GT/s), pinned H2D ≈ 1.56 GB/s
- failure: look at `dmesg | grep gen2kr`

---

## 2. Reverting (reverse order)

```bash
sudo bash 02-gen2-push.sh stop      # unload the module first
sudo bash 01-gen2-patch.sh revert   # then restore nvidia.ko
sudo bash 00-whitelist.sh revert    # finally restore the device table (if step 0 was done)
```

After each step, reload the driver or reboot (except for `stop`). The order
must not be reversed — reverting the patch while the module is still loaded
leaves the guard writing SPEED back.

---

## 3. Everything 02 does

| action | description |
|---|---|
| `status` | whether the module is loaded, module parameters, link state (read-only) |
| `start` | build (if needed) + load + push + wait for Gen2 |
| `stop` | unload the module (guard stops; the link drops back to Gen1 on the next `cuInit`) |
| `restart` | `stop` + `start` |
| `build` | only build the module |
| `uninstall` | `stop` + delete build artifacts (sources kept) |

---

## 4. Idle power savings: just turn off autologin

**When this card has nothing to do it stays in P0, the SM at 1607 MHz,
burning 22 W for free.** But as soon as one **Xorg** holds it, within 15
seconds it drops to P8 and ~7.8 W.

**Nothing needs to be installed.** SDDM's default X11 greeter is that Xorg:
sddm launches it itself, it stays resident with `-noreset`, and **it survives
even after you log into the desktop**.

| state | P-state | SM | power |
|---|---|---|---|
| no Xorg | P0 | 1607 MHz | 22.3 ~ 22.6 W |
| with Xorg (sddm's `:0`) | **P8** | 139 MHz | **7.4 ~ 8.0 W** |
| Xorg exits | P0 | 1607 MHz | 22.4 W |

Saves about **14.6 W (-65%)**, reversible.

### The only thing to do: disable SDDM autologin

In `/etc/sddm.conf.d/*.conf`, empty out `[Autologin]`:

```ini
[Autologin]
Relabel=false
Session=
User=
```

Then reboot (or `systemctl restart sddm`). At boot, sddm goes through the full
"launch display server -> launch greeter" flow, and that Xorg stays around.

### Why there is no Xorg under autologin

Autologin skips both steps entirely — measured log comparison (same machine):

```
# autologin (Session=plasma, User=union)
sddm-helper: pam_unix(sddm-autologin:session): session opened for user union
sddm:        Session ".../plasma.desktop" selected ... --autologin
grep -c "Display server starting"  ->  0      <- no Xorg started at all

# with autologin disabled
sddm: Display server starting...
sddm: Display server started.
sddm: Greeter starting...
sddm-helper: Starting X11 session: "" "/usr/bin/sddm-greeter-qt6 ..."   <- X11
grep -c "Display server starting"  ->  1
```

After logging into the Wayland desktop the greeter exits, but sddm's **Xorg
process does not exit** (`ps` shows its parent as `/usr/bin/sddm`, with
`-noreset` in the args), so the card keeps sitting in P8.

### ⚠ It conflicts with the Gen2 push

This Xorg **holds `/dev/nvidia*` the whole time**:

```
/dev/nvidia0:        root  1095 F...m Xorg
/dev/nvidiactl:      root  1095 F.... Xorg
/dev/nvidia-modeset: root  1095 F.... Xorg
```

And `02-gen2-push.sh start` relies on `unbind`/`bind` to trigger probe —
**when the GPU is in use, `unbind` hangs inside
`device_release_driver_internal`**, processes go into D state and `kill -9`
does nothing; only a reboot helps (happened once; see iron rule 9b in
`docs/safety-discipline.md`). So the script's `check_gpu_idle()` blocks it
outright, and that is correct.

You can only pick one path, or sequence them:

| goal | how |
|---|---|
| **power saving** (P8, 7.5 W) | turn off autologin so sddm's Xorg stays resident. Link sits at Gen1 |
| **Gen2** (1.56 GB/s) | first `systemctl stop sddm` to stop Xorg -> push Gen2 -> then `start sddm` |

Ordering matters: **push Gen2 first, start Xorg afterwards** gives you both —
with the patch in place `cuInit` no longer downgrades, and the link keeps Gen2
after Xorg starts. The reverse (Xorg holds it first) cannot be pushed.

---

### ⚠ `Xwayland` does not count

`Xwayland` inside a Wayland session is no substitute for Xorg — measured: with
Xwayland present the card **still** sat in P0 burning 22 W. The criterion is
simple:

```bash
pgrep -x Xorg        # output = a real Xorg; only seeing Xwayland does not count
```

Only machines without sddm (pure console / another DM) need to start one:

```bash
Xorg :8 -config /etc/bumblebee/xorg.conf.nvidia   # if bumblebee is installed
```

(An earlier revision of this repo shipped `xorg/xorg-p104.sh` for this; it was
removed after discovering that the "disable autologin" trick above is enough
and cleaner — see `git show 5972b68`.)

> By the way: making **programs** render on the P104 is a separate matter —
> PRIME offload,
> `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <program>`,
> unrelated to power savings.

---

## 5. Speedup: framerate and power

Besides the PCIe restriction, P1XX / CMP mining cards have **another
independent problem**: framerate stuck at ~40fps and power that cannot climb.
That is caused by the driver writing to the pushbuffer every batch with
`method 0x3998 = 0xF0 (240)` (≈218µs of idle spin per batch).

**This directory does not provide that patch** (it modifies
`libnvidia-glcore.so`, a user-space GL library, a separate topic). If you need
it, see:

- **the clear-delay project** (user-space approach): <https://github.com/WJNKAC/nvidia-p106-clear-delay>
- **upstream analysis** (the kernel-whitelist idea, the origin of `00-whitelist.sh`):
  <https://github.com/dartraiden/NVIDIA-patcher/issues/3>

> ★ **But note**: `00-whitelist.sh` can **solve it at the root** —
> after applying, the delay command is **never generated at all** (not
> "generated but skipped"); frame time 52.202 -> 3.668 ms, fps 18.98 -> 243.78.
> So if you want both fixes, doing step 0 is enough; the user-space patch is
> not needed.

---

## 6. Files in this directory

```
00-whitelist.sh      pre-step (optional): modifies nv-kernel.o_binary
01-gen2-patch.sh     required: modifies nvidia.ko
02-gen2-push.sh      required: loads the module + pushes the link
sync-dkms.sh         ★ syncs the patch into DKMS after patching, so a reboot cannot undo it
offsets.sh           this version's offsets and original bytes (plain variables, sourceable)
kernel/6.12.113/     kernel module sources (one directory per kernel version)
README.md            this file
utils/               ★ shared scripts (used by several scripts, kept here)
  bdf.sh             automatic discovery of the target GPU's PCIe BDF (single source of truth)
  _lib.sh            common parts (paths, colors, register reads, GPU-usage check, module build)
  _patch.py          generic binary patcher (JSON-spec driven, called by 00/01)
```

> Things in `utils/` are **sourced by the scripts above**; do not run them
> directly as commands (`bdf.sh` is the exception — it runs standalone and
> only prints the discovered BDF).
> All scripts locate utils with `$(dirname "${BASH_SOURCE[0]}")/utils/...`, so
> **the whole repo can be moved anywhere**.

### Why the module is nested by kernel version

Patch offsets are bound to the **driver version**; the module build artifact is
bound to the **kernel version**. They are two different things:

| | bound to | why |
|---|---|---|
| `offsets.sh` / `_patch.py` | driver version | they modify byte offsets of the driver binary |
| `kernel/<kernel-version>/` | kernel version | the `.ko` must be compiled against the target machine's kernel headers; a different kernel cannot load it |

When the kernel version changes, **create a new sibling directory** instead of
renaming in place — the old directory is the historical verification record.

---

## 6a. Multi-card machines: you must name the target card

The scripts **find the card automatically by device id** (`10de:1b87` =
P104-100); no need to hardcode a slot. But if your machine has **multiple**
cards of the same type (say two P104s), automatic discovery refuses to run and
you must specify explicitly:

```bash
# explicit BDF (check the slots with lspci -Dn | grep 10de)
TARGET_BDF=0000:02:00.0 sudo -E bash 02-gen2-push.sh start

# or search for a different device id (the P106-100 is 1c07)
TARGET_IDS=1c07 sudo -E bash 02-gen2-push.sh start

# discovery only; nothing is touched
bash utils/bdf.sh
```

Available environment variables:

| variable | default | role |
|---|---|---|
| `TARGET_IDS` | `1b87` | target device id; space-separated list allowed (`"1b87 1c07"`) |
| `TARGET_BDF` | empty | explicit BDF, skips auto-discovery |

> ⚠ **Why a hardcoded `01:00.0` will not work**
>
> Early versions hardcoded `01:00.0`. On a multi-card machine where your P104
> sits at `02:00.0` and `01:00.0` is a different card (e.g. a P100 already at
> full speed Gen3), the script would **read and write the P100**: it would read
> `CAP2=0x0006 / TLS=2` yet always see `LNKSTA=1041` (the P100 is at full speed
> by design), looking like a "lock-up" when in fact **the wrong device was
> chosen**. Worse, `10-check.sh` takes a different path for the device check,
> producing contradictions like "section 2 says the P104 is on the bus, but
> section 3 shows the P100's `cfg=1f6f10de`".
>
> Now the BDF is computed once in `utils/bdf.sh` and shared by all scripts, so
> the two-path mismatch can no longer happen.

---

## 7. The mechanics (read if you want depth)

### 01: nvidia.ko, 2 bytes

The mode whitelist at the entry of `_nv017105rm` (the driver's
`set_link_speed(mode)`) is narrowed from `{1,2,3}` to `{2,3}`, so `mode==1`
falls into the pre-existing bail branch.

```asm
_nv017105rm:
  8d 42 ff              lea    -0x1(%rdx),%eax     ; eax = mode - 1
  ...
  83 f8 02              cmp    $0x2,%eax
  0f 87 xx xx xx xx     ja     <bail>
```

becomes:

```asm
  8d 42 fe              lea    -0x2(%rdx),%eax     ; eax = mode - 2   (ff -> fe)
  ...
  83 f8 01              cmp    $0x1,%eax                               (02 -> 01)
```

`(mode-2) > 1` under unsigned comparison:

| mode | eax | result |
|---|---|---|
| 1 | `0xFFFFFFFF` (underflow) | bail ★ the only behavior change |
| 2 | 0 | continue (same as original) |
| 3 | 1 | continue (same as original) |
| >=4 | >=2 | bail (same as original) |

bail jumps to the function's only return, returning `%r12d` (zeroed at entry
by `xor %r12d,%r12d`)
=> **returns 0 = `CUDA_SUCCESS`**; the driver considers it a success and
reports no error.

**How to locate it** (no offsets to memorize) — a 32-byte signature, unique in
the whole file:

```
8d42ff 4156 4155 4989fd 4154 4531e4 53 4883ed40 48897510 89550c 83f802 0f87
```

Two positions inside the signature change: index `0x02` `ff`->`fe`, index
`0x1D` `02`->`01`.

> File offset = offset within `.text` + `0x40`. For this version `_nv017105rm`
> is at `0x127d60` inside `.text`, corresponding to file offset `0x127da6`.

md5: `7f6805ed…` -> `514de9d4…`

### 00: nv-kernel.o_binary, 10 bytes

It contains a "restricted device table" with entries shaped like `0x0007XXXX`
(low 16 bits = device ID). For this version the table sits at **file offset
`0x5CFDFCC`**, 5 consecutive dwords, **all 5 restricted mining cards**:

| offset | original | device | |
|---|---|---|---|
| `+0x00` | `0x00071B07` | P102-100 | |
| `+0x04` | `0x00071B87` | **P104-100** | ★ this project's card |
| `+0x08` | `0x00071BC7` | P104-101 | |
| `+0x0C` | `0x00071C07` | P106-100 | |
| `+0x10` | `0x00071C09` | P106-090 | |

> After patching, all 5 become `0x0007FFFF`; **the current file alone cannot
> tell which card each entry was**. `00-whitelist.sh check` reads the original
> IDs from the `.orig` backup and lists them one by one
> (see `docs/troubleshooting.md` under "which devices the table holds").

The low 16 bits become `0xFFFF` (a sentinel, effectively erasing the card from
the table):

```
07 1B 07 00  ->  FF FF 07 00    87 1B 07 00  ->  FF FF 07 00
c7 1B 07 00  ->  FF FF 07 00    07 1C 07 00  ->  FF FF 07 00
09 1C 07 00  ->  FF FF 07 00
```

md5 (`nv-kernel.o_binary`): `caa613d3…` -> `f3480248…`

**On Linux there is only one copy** — `libnvidia-glcore.so` does not contain
this table (0 hits for the P1XX ID strings). Only Windows needs the
replacement repeated across 6+ files (each UMD carries its own copy).

### 02: what the module does

It attaches a kretprobe to `nv_pci_probe` and, at the **instant probe
returns**:

```
① unlock the endpoint declaration
   0x8E110/0x8E11C/0x8E120/0x8E12C  ->  XP3G slots
   0x8841C  ->  (value | bit11|13|15) & ~(bit12|14)
   0x88610  ->  (value & ~bit12) | 1
   0x8C2C0  ->  clear bit2 (DIS_G2)
   0x8872C = 6  ->  trigger training; LNKCAP2 flips from 0x02 to 0x06 on the spot

② write SPEED=1 (5.0GT/s)  0x8C040's SPEED[19:18] = 1, ★ never write bit0 (COMMIT)

③ TLS=2 on both ends; retrain from the root port
```

**Why at the instant probe returns**: the driver resets these bits inside
probe; writing earlier gets overwritten, writing later misses the link
training window. A kretprobe is the only reliable hook for this timing.

---

## 8. Risks

| risk | description |
|---|---|
| modifying a closed-source binary | may violate NVIDIA's license terms |
| version-bound | switching driver versions requires re-locating; **do not reuse these numbers** |
| whitelist alters device identity | broader blast radius than `gen2`; may affect unverified code paths |
| driver upgrades overwrite | both patches are lost and must be reapplied |

**Read `../../docs/safety-discipline.md` before doing anything.**
