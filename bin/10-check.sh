#!/bin/bash
# ============================================================
# 10-check.sh — environment self-check (★ strictly read-only, changes nothing)
#
# Run this before touching anything to confirm:
#   the device is present, the driver version is right, the patcher can
#   locate its target, the probes run, and what the register state is
#
# Usage:
#   sudo bash bin/10-check.sh
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# gen2kr tunable parameters (shown when present)
GEN2KR_PARAMS=(guard_period_ms debounce_cnt retrain_min_ms speed_settle_ms stage_gap_ms)

# ============================================================
# 2. Functions
# ============================================================

# System information
check_system() {
    hdr "1. System"
    echo "  Kernel       : ${KVER}"
    echo "  Distribution : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "  Current user : $(id -un) (uid $(id -u))"
}

# nvidia driver file and load state
check_driver() {
    hdr "2. nvidia driver"

    if [ -f "${KO}" ]; then
        ok "${KO}"
        echo "     md5 = $(md5sum "${KO}" | cut -d' ' -f1)"
        echo "     size = $(stat -c%s "${KO}")"
    else
        err "Cannot find ${KO}"
        echo "     Expected path: /lib/modules/${KVER}/updates/dkms/nvidia.ko"
        echo "     If the driver lives elsewhere, adjust KO in bin/_common.sh"
    fi

    if [ -r /proc/driver/nvidia/version ]; then
        echo "     $(head -1 /proc/driver/nvidia/version)"
    fi

    if lsmod | grep -qE '^nvidia'; then
        lsmod | grep -E '^nvidia' | sed 's/^/     loaded: /'
    else
        echo "     nvidia not loaded"
    fi
}

# Device present on the bus, current link state
check_device() {
    hdr "3. Device"

    if lspci -Dn 2>/dev/null | grep -q '10de:1b87'; then
        ok "P104-100 (10de:1b87) on the bus"
        lspci -vv -s "${DEV_SHORT}" 2>/dev/null | grep -o 'LnkSta:.*' | sed 's/^/     /'
        echo "     cfg = $(setpci -s "${DEV_SHORT}" 0.l 2>&1)"
    else
        err "Cannot find P104-100"
        lspci -Dn | grep -i 10de | sed 's/^/     /' || echo "     (no NVIDIA devices)"
    fi
}

# Read-only check of the key registers (the only trustworthy verdict)
check_registers() {
    hdr "4. Registers (the only trustworthy verdict)"
    echo "     $(read_regs)"
    echo "     ↑ LNKSTA=2 means Gen2; CAP2=0x0006 means the declaration is unlocked"

    if alive; then
        ok "MMIO responding normally"
    else
        err "MMIO read 0xffffffff 20 times in a row — the device may be a ZOMBIE"
    fi
}

# Can the patch tool uniquely locate its target on this .ko version
check_patch_locator() {
    hdr "5. Patch tool target location"
    [ -f "${KO}" ] || return 0
    python3 "${PKG_ROOT}/bin/patch_no_gen1.py" check 2>&1 | sed 's/^/     /'
}

# Are the probes built
check_probes() {
    hdr "6. Probes"

    if ensure_build check >/dev/null 2>&1; then
        ok "probes in build/ are ready"
    else
        warn "probes missing in build/ -> run bin/build.sh first"
    fi

    if [ -f "${BUILD_DIR}/gen2kr.ko" ]; then
        ok "build/gen2kr.ko is ready"
    else
        warn "build/gen2kr.ko missing -> run bin/build.sh first"
    fi

    if [ -n "${KMOD_DIR}" ]; then
        ok "module source directory ${KMOD_DIR#${PKG_ROOT}/}"
    else
        warn "cannot find the kernel module source directory (drivers/*/kernel/*/)"
    fi
}

# gen2kr current load state and parameters
check_gen2kr_state() {
    local p

    hdr "7. Current gen2kr state"

    if ! lsmod | grep -q '^gen2kr'; then
        echo "     gen2kr not loaded"
        return 0
    fi

    warn "gen2kr loaded (guard is running)"
    for p in "${GEN2KR_PARAMS[@]}"; do
        printf '     %-16s = %s\n' "$p" \
            "$(cat "/sys/module/gen2kr/parameters/${p}" 2>/dev/null || echo N/A)"
    done
}

# Known interference sources
check_interference() {
    hdr "8. Interference check"

    if pgrep -x nvitop >/dev/null 2>&1; then
        err "nvitop detected — it once killed a device through Xid 79, and holding /dev/nvidia* makes rmmod return EBUSY"
    else
        ok "no nvitop"
    fi

    if pgrep -x Xorg >/dev/null 2>&1; then
        warn "Xorg is running (holds /dev/nvidia*, rmmod may return EBUSY)"
    fi
}

# Summarize the current link state
show_summary() {
    local speed

    speed="$(cur_speed)"

    echo
    echo "======================================================"
    if [ "${speed}" = "2" ]; then
        echo " Current state: ${C_G}link is already Gen2${C_0}"
    else
        echo " Current state: link Gen$([ "${speed}" = "1" ] && echo 1 || echo '?'), unlock needed"
    fi
    echo " Next step  : sudo bash bin/20-install.sh --dry-run   to preview the plan first"
    echo "======================================================"
}

# ============================================================
# 3. main
# ============================================================
main() {
    echo "======================================================"
    echo " NVIDIA P104-100 PCIe Gen2 unlock — environment self-check"
    echo "======================================================"

    check_system
    check_driver
    check_device
    check_registers
    check_patch_locator
    check_probes
    check_gen2kr_state
    check_interference
    show_summary
}

main "$@"
