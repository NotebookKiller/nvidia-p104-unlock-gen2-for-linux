#!/bin/bash
# _common.sh — shared paths, register reads, and verdicts
# All scripts source this file so the package can be relocated as a whole.
#
# Design constraints (learned from real incidents):
#   · Never use $(( )) on values like 0xffffffffc185a000 (dash says "Illegal number", >2^63)
#   · Always let python do the address math
#   · Reading /dev/mem requires O_RDWR (O_RDONLY + PROT_WRITE raises PermissionError)

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PKG_ROOT/build"
SRC_DIR="$PKG_ROOT/src"
DRIVERS_DIR="$PKG_ROOT/drivers"

KVER="$(uname -r)"
KO="/lib/modules/${KVER}/updates/dkms/nvidia.ko"

# ---------- Locate the kernel module source directory ----------
#
# Kernel module sources are archived two levels deep, by driver version / kernel version:
#   drivers/<driver version>/kernel/<kernel version>/gen2kr.c
#
# Why the kernel version is part of the directory name: the **build artifact**
# is tightly bound to the kernel headers (ABI, symbols, and struct offsets can
# all differ between kernels). The source itself uses the stable API, but
# "where it was built and validated" must be visible at a glance.
#
# Match rules:
#   1. Prefer the directory that exactly matches the current kernel (uname -r
#      with suffixes like +deb13-amd64 stripped off)
#   2. If not found, fall back to the "only one set exists in the repo" case
#   3. If neither exists, KMOD_DIR stays empty and the caller reports the error
KVER_SHORT="${KVER%%+*}"        # 6.12.113+deb13-amd64 -> 6.12.113

find_kmod_dir() {
    local d

    # 1) Exact match on the current kernel
    for d in "${DRIVERS_DIR}"/*/kernel/"${KVER_SHORT}"; do
        [ -d "${d}" ] && { echo "${d}"; return 0; }
    done

    # 2) Fallback: if there is only one set, use it (10-check warns about a possible version mismatch)
    for d in "${DRIVERS_DIR}"/*/kernel/*; do
        [ -d "${d}" ] && { echo "${d}"; return 0; }
    done

    return 1
}

KMOD_DIR="$(find_kmod_dir || true)"
LOG_DIR="$PKG_ROOT/history/logs"

# DEV_BDF / DEV_SHORT / ROOT_BDF are auto-discovered by discover_dev_bdf() below

# BAR0 registers (read-only use)
R_LNKCAP=0x88084
R_LNKCAP2=0x880A4
R_LNKSTA=0x88088
R_LNKCTL2=0x880A8
R_CONFIG=0x8841C
R_LTSSM=0x8872C
R_LINKCFG0=0x8C040
R_CYA=0x8C2C0

# ---------- Colors (automatically off when not a tty) ----------
if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
    C_R=; C_G=; C_Y=; C_B=; C_0=
fi
ok()   { echo "${C_G}✓${C_0} $*"; }
warn() { echo "${C_Y}⚠${C_0} $*"; }
err()  { echo "${C_R}✗${C_0} $*"; }
hdr()  { echo; echo "${C_B}=== $* ===${C_0}"; }

# ---------- Target device auto-discovery (single source: drivers/<version>/utils/bdf.sh) ----------
# ★ Do not write a second copy here — duplicate implementations drift apart.
#   Typical symptom: 10-check says "the P104 is on the bus" but the config
#   reads come back from a different card.
#   TARGET_IDS / TARGET_BDF are handled by bdf.sh.
_bdf_lib=""
if [ -n "${GEN2_BDF_LIB:-}" ] && [ -r "${GEN2_BDF_LIB}" ]; then
    _bdf_lib="${GEN2_BDF_LIB}"
else
    for _f in "${DRIVERS_DIR}"/*/utils/bdf.sh; do
        [ -r "${_f}" ] && { _bdf_lib="${_f}"; break; }
    done
fi

if [ -z "${_bdf_lib}" ]; then
    err "Cannot find drivers/<version>/utils/bdf.sh (repo layout incomplete)"
    echo "    Expected location: ${DRIVERS_DIR}/<version>/utils/bdf.sh"
    exit 3
fi

# shellcheck source=/dev/null
source "${_bdf_lib}"


# ---------- Read-only: read a group of BAR0 registers ----------
# Prints one line: CAP2=0x0006 LNKSTA=2 TLS=2 SPEED=1 MAXSPD=2
read_regs() {
python3 - <<'PY'
import mmap, os, struct, sys
try:
    _dev = os.environ.get('DEV_BDF', '0000:01:00.0')
    p = int(open('/sys/bus/pci/devices/%s/resource' % _dev).readline().split()[0], 16)
    f = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ, offset=p)
    g = lambda o: struct.unpack_from('<I', m, o)[0]
    cap  = g(0x88084); cap2 = g(0x880A4)
    lsta = g(0x88088); ctl2 = g(0x880A8); cfg = g(0x8C040)
    m.close(); os.close(f)
    print(f"CAP2=0x{cap2:04x} LNKSTA={(lsta>>16)&0xF} TLS={ctl2&0xF} "
          f"SPEED={(cfg>>18)&3} MAXSPD={cap&0xF}")
except Exception:
    print("CAP2=? LNKSTA=? TLS=? SPEED=? MAXSPD=?")
PY
}

# LNKSTA[3:0] only (the only trustworthy "current speed" verdict)
cur_speed() {
    local s
    s="$(_r 0x88088)"
    python3 -c "print((${s:-0}>>16)&0xF)" 2>/dev/null || echo 0
}

# CAP2 only (declaration vector; 0x06 = Gen2 support unlocked)
cap2() {
    local v
    v="$(_r 0x880A4)"
    echo "${v:-0}"
}

_r() {
python3 - "$1" <<'PY'
import mmap, os, struct, sys
off = int(sys.argv[1], 16)
try:
    _dev = os.environ.get('DEV_BDF', '0000:01:00.0')
    p = int(open('/sys/bus/pci/devices/%s/resource' % _dev).readline().split()[0], 16)
    f = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ, offset=p)
    print(struct.unpack_from('<I', m, off)[0])
    m.close(); os.close(f)
except Exception:
    print(0)
PY
}

# Liveness: only after 20 consecutive 0xffffffff reads call it dead
# (a single hit is a retrain transient, not a fault)
alive() {
    local bad=0 i v
    for i in $(seq 1 20); do
        v="$(cap2)"
        if [ "$v" = "4294967295" ]; then
            bad=$((bad + 1)); sleep 0.05
        else
            return 0
        fi
    done
    return 1
}

# Gen2 verdict (★ registers only; never nvidia-smi; never grep 'Speed 5GT/s')
is_gen2() { [ "$(cur_speed)" = "2" ]; }

wait_gen2() {
    local n="${1:-25}" i
    for i in $(seq 1 $((n * 5))); do
        is_gen2 && return 0
        sleep 0.2
    done
    return 1
}

need_root() {
    [ "$(id -u)" = "0" ] || { err "root required (sudo bash $0)"; exit 1; }
}

# Detect the "driver-side stuck state"
#
# ★ Do not judge by "CAP2=0x0002 + TLS=1 + Gen1" alone — that is exactly what
#   the stock, un-unlocked state looks like, and a freshly rebooted clean
#   machine shows it too (burned once: a clean reboot produced a false alarm).
#
# The real stuck-state signature: **we wrote the unlock bits but they did not take**
#   · bits 15|13|11 of 0x8841C are set (= the unlock was written)
#   · yet CAP2 is still 0x0002 (= the latch did not succeed)
#   · and the link is still Gen1
#
# Stock 0x8841C = 0xc0b40500 -> (v & 0xA800) == 0
# Unlocked 0x8841C = 0xc0b4ad00 -> (v & 0xA800) == 0xA800
is_stuck() {
    local i cfg cap spd
    # ★ The observation must be stable; a single sample is not enough to declare "stuck".
    #   Right after writing the unlock bits but before the retrain completes,
    #   0x8C040/0x8841C already look "written" while LNKSTA is still 1 —
    #   a single sample then reports a false stuck state, and the following
    #   push usually succeeds anyway.
    #   (Measured: the successful run also printed "stuck detected", yet
    #   section 3 still raised the link to Gen2 normally.)
    #   => Require 3 consecutive hits (0.7s apart, ~1.4s total, beyond the retrain window).
    for i in 1 2 3; do
        cfg="$(_r 0x8841C)"
        cap="$(cap2)"
        spd="$(cur_speed)"
        # Any single observation with "unlock bits not set" or "already at Gen2" => not stuck
        if [ "$(( cfg & 0xA800 ))" = "0" ] || [ "${cap}" != "2" ] || [ "${spd}" != "1" ]; then
            return 1
        fi
        [ "${i}" -lt 3 ] && sleep 0.7
    done
    return 0
}

# Check that the probes are built. By default only check, never compile
# (keeps the "read-only script" promise). Pass "auto" to allow auto-compiling.
ensure_build() {
    local mode="${1:-check}"
    if [ -x "$BUILD_DIR/minictx" ] && [ -x "$BUILD_DIR/bwtest2" ]; then
        return 0
    fi
    if [ "$mode" = "auto" ]; then
        warn "probes missing in build/, compiling..."
        bash "$PKG_ROOT/bin/build.sh" || return 1
        return 0
    fi
    warn "probes missing in build/ (minictx / bwtest2) -> run first: bash $PKG_ROOT/bin/build.sh"
    return 1
}
