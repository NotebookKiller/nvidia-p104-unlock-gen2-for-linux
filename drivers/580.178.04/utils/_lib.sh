#!/bin/bash
# ============================================================
# _lib.sh — the common part of the scripts under drivers/<version>/
#
# Sourced by 00-whitelist.sh / 01-gen2-patch.sh / 02-gen2-push.sh.
# Only holds the "generic" things: paths, colors, permissions, register
# reads, the GPU-busy check, module building.
# Business specifics (which bytes to change, how to push the link)
# live in the individual scripts.
#
# Design constraints (pitfalls already hit):
#   · do not use $(( )) for numbers >2^63 (dash reports "Illegal number")
#     -> hand it to python
#   · reading /dev/mem must use O_RDWR (O_RDONLY + PROT_WRITE gives
#     PermissionError)
# ============================================================

# ============================================================
# 1. Paths
# ============================================================
# _lib.sh now lives in drivers/<version>/utils/
UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # drivers/<version>/utils
VER_DIR="$(cd "${UTILS_DIR}/.." && pwd)"                    # drivers/<version>
PKG_ROOT="$(cd "${VER_DIR}/../.." && pwd)"                  # repo root
OFFSETS_FILE="${VER_DIR}/offsets.sh"
PATCH_PY="${UTILS_DIR}/_patch.py"

KVER="$(uname -r)"
KVER_SHORT="${KVER%%+*}"                                    # 6.12.113+deb13 -> 6.12.113
KERNEL_SRC_DIR="${VER_DIR}/kernel/${KVER_SHORT}"            # module sources directory

KO="/lib/modules/${KVER}/updates/dkms/nvidia.ko"

# ★ Target device BDF auto-discovery (single source: utils/bdf.sh)
#   Do not hardcode 01:00.0 here — on a multi-card machine it would
#   operate the wrong card.
#   Overridable with TARGET_BDF / TARGET_IDS.
# shellcheck source=./bdf.sh
source "${UTILS_DIR}/bdf.sh"

# Driver sources directory (input of the whitelist patch)
NVKERNEL_DIR="/usr/src/nvidia-580.178.04"

# ============================================================
# 2. Output
# ============================================================
if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
    C_R=; C_G=; C_Y=; C_B=; C_0=
fi
ok()   { echo "${C_G}✓${C_0} $*"; }
warn() { echo "${C_Y}⚠${C_0} $*"; }
err()  { echo "${C_R}✗${C_0} $*"; }
hdr()  { echo; echo "${C_B}── $* ──${C_0}"; }

# Big section title
section() {
    echo
    echo "======================================================"
    echo " $*"
    echo "======================================================"
}

need_root() {
    [ "$(id -u)" = "0" ] || { err "root required: sudo bash $0 $*"; exit 1; }
}

# Load the offset definitions (offsets.sh only defines variables, does nothing)
load_offsets() {
    if [ ! -f "${OFFSETS_FILE}" ]; then
        err "cannot find ${OFFSETS_FILE}"
        exit 1
    fi
    # shellcheck source=offsets.sh
    source "${OFFSETS_FILE}"
}

# ============================================================
# 3. Register reads (read-only, used to judge state)
# ============================================================
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

# One-line summary: CAP2=0x0006 LNKSTA=2 ...
read_regs() {
python3 - <<'PY'
import mmap, os, struct
try:
    _dev = os.environ.get('DEV_BDF', '0000:01:00.0')
    p = int(open('/sys/bus/pci/devices/%s/resource' % _dev).readline().split()[0], 16)
    f = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ, offset=p)
    g = lambda o: struct.unpack_from('<I', m, o)[0]
    cap = g(0x88084); cap2 = g(0x880A4)
    lsta = g(0x88088); ctl2 = g(0x880A8); cfg = g(0x8C040)
    m.close(); os.close(f)
    print(f"CAP2=0x{cap2:04x} LNKSTA={(lsta>>16)&0xF} TLS={ctl2&0xF} "
          f"SPEED={(cfg>>18)&3} MAXSPD={cap&0xF}")
except Exception:
    print("CAP2=? LNKSTA=? TLS=? SPEED=? MAXSPD=?")
PY
}

# Current link speed (the only trustworthy criterion: LNKSTA[3:0])
cur_speed() {
    local s
    s="$(_r 0x88088)"
    python3 -c "print((${s:-0}>>16)&0xF)" 2>/dev/null || echo 0
}

# Whether the link is already Gen2
is_gen2() { [ "$(cur_speed)" = "2" ]; }

# Wait for the link to reach Gen2; the argument is the maximum number of seconds
wait_gen2() {
    local n="${1:-20}" i
    for i in $(seq 1 $((n * 5))); do
        is_gen2 && return 0
        sleep 0.2
    done
    return 1
}

# ============================================================
# 4. Safety checks
# ============================================================

# Is the GPU idle
#
# ★ 2026-10-29 incident: when the GPU was held by a browser, writing
#   unbind did not fail and did not return — it wedged inside
#   device_release_driver_internal, processes fell into D/R state,
#   kill -9 did nothing, and only a full reboot recovered. So this is a
#   hard block.
check_gpu_idle() {
    local holders
    holders="$(fuser /dev/nvidia* 2>/dev/null | tr -s ' ')"
    [ -z "${holders}" ] && return 0

    err "processes are using the GPU; unbind would wedge the kernel (only a reboot recovers)"
    echo "     holders:"
    fuser -v /dev/nvidia* 2>&1 | sed 's/^/       /'
    echo
    echo "     Close those programs first (browsers / Electron apps are the most common), then retry."
    echo "     ⚠ Observed: unbind stalls in device_lock without moving, processes fall into D state, kill -9 does nothing."
    return 1
}

# ============================================================
# 5. Kernel module
# ============================================================

# Which kernel the module directory corresponds to (used for hints)
kmod_kernel_version() {
    basename "${KERNEL_SRC_DIR}" 2>/dev/null || echo "?"
}

# Whether the module is loaded
kmod_loaded() { lsmod | grep -q '^gen2kr'; }

# Build the module. When successful the .ko is at ${KERNEL_SRC_DIR}/gen2kr.ko
# Which user should build a kernel module
#
# ★ Pitfall already hit (2026-10-29): the script as a whole needs root
#   (insmod / writing sysfs), but **the build must not run as root** —
#   if the repo sits on NFS (root_squash), root cannot write
#   .gen2kr.o.d, and the build fails with "permission denied".
#
# So: if not root, just use the current user; if root, drop privileges
# to SUDO_USER. If SUDO_USER is unavailable (e.g. logged in via `su -`),
# return empty and let the caller report the error.
build_user() {
    if [ "$(id -u)" != "0" ]; then
        id -un
        return 0
    fi
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        echo "${SUDO_USER}"
        return 0
    fi
    echo ""
}

# Run a command as the given user (root drops privileges; if not root
# in the first place, just run it)
run_as() {
    local user="$1"; shift
    if [ "${user}" = "$(id -un)" ]; then
        "$@"
    else
        sudo -u "${user}" "$@"
    fi
}

build_kmod() {
    hdr "build the kernel module"

    if [ ! -d "${KERNEL_SRC_DIR}" ]; then
        err "cannot find the module sources directory: ${KERNEL_SRC_DIR}"
        echo "    expected: kernel/<kernel version>/gen2kr.c"
        echo "    existing in the repo:"
        ls -1 "${VER_DIR}/kernel/" 2>/dev/null | sed 's/^/      /'
        return 1
    fi
    echo "   sources directory: kernel/$(basename "${KERNEL_SRC_DIR}")"

    local dir_kver
    dir_kver="$(kmod_kernel_version)"
    if [ "${dir_kver}" != "${KVER_SHORT}" ]; then
        warn "the kernel verified in that directory is ${dir_kver}; the current one is ${KVER_SHORT}"
        echo "     The sources use stable APIs and usually compile, but the artifact is unverified on that kernel"
    fi

    if [ ! -d "/lib/modules/${KVER}/build" ]; then
        err "kernel headers missing: /lib/modules/${KVER}/build"
        echo "    install with: sudo apt install linux-headers-${KVER}"
        return 1
    fi

    # ★ Build user: must not be root (NFS root_squash cannot write .gen2kr.o.d)
    local cuser
    cuser="$(build_user)"
    if [ -z "${cuser}" ]; then
        err "currently root but SUDO_USER is unavailable; do not know which user to build as"
        echo "    two options:"
        echo "      A) run as a normal user: bash 02-gen2-push.sh build"
        echo "      B) re-run via sudo: sudo bash 02-gen2-push.sh start"
        return 1
    fi
    if [ "${cuser}" != "$(id -un)" ]; then
        echo "   build identity: ${cuser} (currently root; dropping privileges to build — building as root cannot write the artifact)"
    fi

    # ① First clean the old artifacts under the current identity
    #    (if root built before, the artifacts are root-owned and only root can remove them)
    rm -f "${KERNEL_SRC_DIR}"/gen2kr.o \
          "${KERNEL_SRC_DIR}"/gen2kr.ko \
          "${KERNEL_SRC_DIR}"/gen2kr.mod \
          "${KERNEL_SRC_DIR}"/gen2kr.mod.c \
          "${KERNEL_SRC_DIR}"/gen2kr.mod.o \
          "${KERNEL_SRC_DIR}"/.gen2kr.o.d \
          "${KERNEL_SRC_DIR}"/.gen2kr.mod.o.d \
          "${KERNEL_SRC_DIR}"/.module-common.o \
          "${KERNEL_SRC_DIR}"/Module.symvers \
          "${KERNEL_SRC_DIR}"/modules.order 2>/dev/null || true

    # ② The directory itself must be writable by cuser
    if [ "${cuser}" != "$(id -un)" ]; then
        chown "${cuser}" "${KERNEL_SRC_DIR}" 2>/dev/null || true
    fi
    if ! run_as "${cuser}" test -w "${KERNEL_SRC_DIR}"; then
        err "user ${cuser} has no write permission on ${KERNEL_SRC_DIR}"
        echo "    fix the ownership: sudo chown -R ${cuser}:${cuser} ${VER_DIR}"
        return 1
    fi

    # ③ Build with dropped privileges
    local log
    log="$(mktemp)"
    if run_as "${cuser}" make -C "/lib/modules/${KVER}/build" \
               M="${KERNEL_SRC_DIR}" modules >"${log}" 2>&1; then
        ok "build succeeded  ($(stat -c%s "${KERNEL_SRC_DIR}/gen2kr.ko" 2>/dev/null || echo ?) bytes)"
        rm -f "${log}"
        return 0
    fi

    err "build failed; the last 20 lines:"
    tail -20 "${log}" | sed 's/^/     /'
    rm -f "${log}"
    echo
    echo "   common causes:"
    echo "     1. kernel headers version mismatch — must build on the machine actually running this card"
    echo "     2. the compiler differs from the one the kernel was built with (clang kernel + gcc module builds report"
    echo "        unrecognized command-line option '-mstack-alignment')"
    echo "     3. wrong directory ownership — the build user must be able to write the directory"
    echo "        sudo chown -R ${cuser}:${cuser} ${VER_DIR}"
    return 1
}

# The module .ko path
kmod_path() { echo "${KERNEL_SRC_DIR}/gen2kr.ko"; }

# Whether the module is built
kmod_built() { [ -f "$(kmod_path)" ]; }
