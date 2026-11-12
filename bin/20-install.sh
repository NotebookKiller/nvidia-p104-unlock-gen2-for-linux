#!/bin/bash
# ============================================================
# 20-install.sh — apply the patch and get the link running at Gen2
#
# Does two things, in this order (cannot be swapped):
#   1. Patch nvidia.ko with 2 bytes: make _nv017105rm(mode=1) bail at entry
#      => the driver no longer drops the link back to Gen1 on every cuInit
#   2. Load gen2kr so it unlocks the endpoint announcement the instant
#      nv_pci_probe returns and pushes once => the link rises to 5GT/s
#      Afterwards the patch does the "holding"; the gen2kr guard degrades to a
#      safety net (it only acts if the patch is lost)
#
# ★ When to reload nvidia and when not to:
#   · Just applied the patch => **must reload** (the .ko file changed; without a
#     reload the old code is still what runs)
#   · The patch was already in the .ko (e.g. after a reboot) => **no reload
#     needed**, just re-probe the device once
#   The latter case is faster and lighter via bin/push.sh. This script decides
#   automatically.
#
# Usage:
#   sudo bash bin/20-install.sh --dry-run     # print the plan only, change nothing
#   sudo bash bin/20-install.sh               # execute (decides whether to reload)
#   sudo bash bin/20-install.sh --no-patch    # skip the patch, only load gen2kr (old approach)
#   sudo bash bin/20-install.sh --no-kmod     # patch only (for an already-unlocked setup)
#   sudo bash bin/20-install.sh --no-reload   # force no nvidia reload (same as push.sh)
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# Command-line options
DRY=0                   # 1 = print the plan only
DO_PATCH=1              # 0 = skip the patch (--no-patch)
DO_KMOD=1               # 0 = skip gen2kr (--no-kmod)
FORCE_NO_RELOAD=0       # 1 = force no reload (--no-reload)

# Runtime state
PATCH_CHANGED=0         # 1 = the .ko was actually changed this run
DO_RELOAD=0             # 1 = nvidia needs a reload

# Unload order for the nvidia modules (dependency order: drm -> modeset -> uvm -> main module)
NVIDIA_MODULES=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)

# ============================================================
# 2. Functions
# ============================================================

# Run a command; under dry-run only print it
run() {
    if [ "${DRY}" = "1" ]; then
        echo "   ${C_Y}[dry-run]${C_0} $*"
    else
        echo "   $ $*"
        eval "$@"
    fi
}

# Parse command-line arguments
parse_args() {
    local a
    for a in "$@"; do
        case "${a}" in
            --dry-run)   DRY=1 ;;
            --no-patch)  DO_PATCH=0 ;;
            --no-kmod)   DO_KMOD=0 ;;
            --no-reload) FORCE_NO_RELOAD=1 ;;
            *)
                err "unknown option ${a}"
                echo "   available: --dry-run --no-patch --no-kmod --no-reload"
                exit 2
                ;;
        esac
    done
}

# Pre-checks: driver, device, MMIO, probe, whether the device is wedged
precheck() {
    hdr "0. Pre-checks"

    [ -f "${KO}" ] || { err "cannot find ${KO}"; return 1; }
    ok "driver ${KO}"

    lspci -Dn | grep -q '10de:1b87' || { err "no P104-100 found"; return 1; }
    ok "device present on the bus"

    if alive; then
        ok "MMIO responding"
    else
        err "MMIO not responding -- the device may already be ZOMBIE; reboot the whole machine first"
        echo "     verdict tool: python3 bin/linkcap-audit.py"
        return 1
    fi

    ensure_build check || { err "probe not compiled -> bash bin/build.sh"; return 1; }

    # ★ Stuck-state pre-check
    # Do not just look at "CAP2=0x0002 + TLS=1 + Gen1" -- that is the **normal,
    # factory-locked** appearance.
    # A wedged state is characterized by "unlock bits were written but never took
    # effect"; use is_stuck to decide.
    if is_stuck; then
        warn "suspected wedged state (unlock bits set, CAP2 still 0x0002, link still Gen1, observed 3 times in a row)"
        echo "     criteria: 0x8841C=$(printf '0x%08x' "$(_r 0x8841C)") (bits 15/13/11 set)"
        echo "     ${C_Y}this is advisory only; it does not block the flow${C_0}: the push right after may still succeed."
        echo "     Only if CAP2 stays pinned at 0x0002 after the push AND the link stays Gen1 is it a true wedged state"
        echo "     (that case is measurably incurable: unbind/bind x6, retrain x13, TLS rewrite x20 all failed,"
        echo "       the only fix is a full reboot)."
    fi
    return 0
}

# Step 1: apply the 2-byte patch, and record whether the .ko actually changed
step_patch() {
    local before after

    if [ "${DO_PATCH}" != "1" ]; then
        hdr "1. Skipping patch (--no-patch)"
        return 0
    fi

    hdr "1. Applying the 2-byte patch"
    echo "   target: the mode range check at the entry of _nv017105rm"
    echo "     127d66: lea -0x1(%rdx),%eax   ->  lea -0x2(%rdx),%eax"
    echo "     127d81: cmp \$0x2,%eax         ->  cmp \$0x1,%eax"
    echo "   effect: mode==1 (Gen1) bails right at entry; modes 2/3 normal; >=4 equivalent to the original"

    if [ "${DRY}" = "1" ]; then
        python3 "${PKG_ROOT}/bin/patch_no_gen1.py" check 2>&1 | sed 's/^/   /'
        echo "   ${C_Y}[dry-run]${C_0} python3 bin/patch_no_gen1.py apply"
        return 0
    fi

    before="$(md5sum "${KO}" | cut -d' ' -f1)"
    python3 "${PKG_ROOT}/bin/patch_no_gen1.py" apply || { err "patch failed"; return 1; }
    after="$(md5sum "${KO}" | cut -d' ' -f1)"

    if [ "${before}" != "${after}" ]; then
        PATCH_CHANGED=1
        ok "patch was freshly written => a reload of nvidia is required for it to take effect"
    else
        ok "patch was already in place (.ko unchanged) => no reload needed"
    fi
    return 0
}

# Decide whether a reload is needed
decide_reload() {
    DO_RELOAD=0

    if [ "${FORCE_NO_RELOAD}" = "1" ]; then
        DO_RELOAD=0
    elif [ "${PATCH_CHANGED}" = "1" ]; then
        DO_RELOAD=1
    elif [ "${DRY}" = "1" ] && [ "${DO_PATCH}" = "1" ]; then
        # under dry-run we cannot know whether it will change; show it as "may need a reload"
        DO_RELOAD=1
    fi
}

# Step 2: reload nvidia when needed
step_reload() {
    local m

    if [ "${DO_RELOAD}" != "1" ]; then
        hdr "2. Not reloading nvidia (the patch is already in the .ko; no reload needed)"
        if lsmod | grep -q '^nvidia '; then
            ok "nvidia stays loaded"
            return 0
        fi
        err "nvidia is not loaded -- run modprobe nvidia first"
        return 1
    fi

    hdr "2. Reloading the nvidia driver (to make the freshly written patch take effect)"

    if lsmod | grep -q '^gen2kr'; then
        run "rmmod gen2kr"
    fi

    for m in "${NVIDIA_MODULES[@]}"; do
        if lsmod | grep -q "^${m} "; then
            run "rmmod ${m} 2>/dev/null || true"
        fi
    done
    sleep 1

    if [ "${DRY}" = "0" ] && lsmod | grep -qE '^nvidia'; then
        err "nvidia could not be unloaded; check who holds it:"
        echo "     fuser -v /dev/nvidia* 2>/dev/null"
        echo "     (Xorg / nvitop / any CUDA process will hold it)"
        return 1
    fi
    [ "${DRY}" = "0" ] && ok "fully unloaded"

    run "modprobe nvidia"
    run "modprobe nvidia_uvm"
    [ "${DRY}" = "0" ] && sleep 2
    return 0
}

# Check whether any process is holding the GPU
#
# ★ 2026-10-29 incident: when the GPU is held by a browser, writing unbind does not
#   fail and does not return either -- it wedges inside device_release_driver_internal,
#   processes land in D/R state, kill -9 is useless, and only a full reboot helps.
#   That is why this step is a hard block, not a warning.
check_gpu_idle() {
    local holders

    holders="$(fuser /dev/nvidia* 2>/dev/null | tr -s ' ')"
    [ -z "${holders}" ] && return 0

    err "a process is using the GPU; unbind would wedge the kernel (reboot only)"
    echo "     holders:"
    fuser -v /dev/nvidia* 2>&1 | sed 's/^/       /'
    echo
    echo "     close these programs first (browsers / Electron apps are the usual culprits), then retry."
    echo "     ⚠ measured: unbind stops dead in device_lock; processes land in D state and kill -9 does nothing."
    return 1
}

# Step 3: load gen2kr and trigger one probe
step_push() {
    if [ "${DO_KMOD}" != "1" ]; then
        hdr "3. Skipping gen2kr (--no-kmod)"
        return 0
    fi

    hdr "3. Loading gen2kr and triggering one probe"
    echo "   it attaches a kretprobe to nv_pci_probe; the instant the probe returns it:"
    echo "     1. unlocks the endpoint announcement (XP3G + 0x8841C + 0x88610) so LCAP2 -> 0x06"
    echo "     2. writes 0x8C040.SPEED=1 (5.0GT/s)"
    echo "     3. sets TLS=2 on both ends and retrains from the root port"

    # ★ Before actually executing, the GPU must be confirmed idle
    if [ "${DRY}" = "0" ]; then
        check_gpu_idle || return 1
    fi

    # If already in memory, unload it first to clear the triggered flag
    # (otherwise the push will not trigger again)
    if lsmod | grep -q '^gen2kr'; then
        run "rmmod gen2kr 2>/dev/null || true"
        [ "${DRY}" = "0" ] && sleep 1
    fi

    run "insmod ${BUILD_DIR}/gen2kr.ko"
    [ "${DRY}" = "0" ] && sleep 1
    run "echo ${DEV_BDF} > /sys/bus/pci/drivers/nvidia/unbind"
    [ "${DRY}" = "0" ] && sleep 1
    run "echo ${DEV_BDF} > /sys/bus/pci/drivers/nvidia/bind"

    [ "${DRY}" = "1" ] && return 0

    echo "   waiting for the link to rise to Gen2 (up to 20s)..."
    if wait_gen2 20; then
        ok "link = Gen2    $(read_regs)"
        return 0
    fi

    warn "push did not succeed ($(read_regs))"
    echo "     gen2kr log:"
    dmesg | grep -i gen2kr | tail -8 | sed 's/^/       /'
    echo
    echo "     if the guard is auto-retrying, wait another 25s; if it still fails see docs/troubleshooting.md"
    return 0
}

# Step 4: summarize the result
show_result() {
    local regs

    hdr "4. Result"

    if [ "${DRY}" = "1" ]; then
        echo "   ${C_Y}dry-run finished; nothing was changed${C_0}"
        return 0
    fi

    regs="$(read_regs)"
    echo "   ${regs}"

    if is_gen2; then
        ok "link is already at Gen2"
        echo
        echo "   next step: sudo bash bin/30-verify.sh    (verify bandwidth + that the patch really took over)"
        return 0
    fi

    err "link is still at Gen1"
    echo "   possible causes:"
    echo "     1. the device is in a driver-side wedged/stuck state -> reboot the machine and retry"
    echo "     2. the gen2kr push failed -> dmesg | grep gen2kr"
    echo "     3. the announcement was not unlocked -> CAP2 should be 0x0006, currently $(cap2)"
}

# ============================================================
# 3. main
# ============================================================
main() {
    parse_args "$@"

    need_root

    echo "======================================================"
    echo " Installing the PCIe Gen2 unlock"
    [ "${DRY}" = "1" ] && echo " ${C_Y}mode: dry-run (nothing will be changed)${C_0}"
    echo "======================================================"

    precheck   || exit 1
    step_patch || exit 1

    decide_reload
    step_reload || exit 1

    [ "${DRY}" = "0" ] && ok "current: $(read_regs)"

    step_push    || exit 1
    show_result

    echo "======================================================"
}

main "$@"
