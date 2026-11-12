#!/bin/bash
# ============================================================
# push.sh — lightweight push: no nvidia reload; just re-probe the device once
#
# ## Difference from 20-install.sh
#   20-install.sh does `rmmod nvidia && modprobe nvidia`, and that exists to
#   make the patch take effect (a modified .ko binary must be reloaded in
#   order to be read).
#
#   But once the patch is inside the .ko (it survives a reboot), **no reload
#   is needed anymore** --
#   just let the device walk through `nv_pci_probe` once more so gen2kr's
#   kretprobe fires once.
#
#   This script is exactly that shortest path:
#       insmod gen2kr  ->  unbind  ->  bind   ->  wait for the link to reach Gen2
#
# ## Preconditions
#   · patch applied (patch_no_gen1.py check reports patched)
#   · nvidia loaded (that is the normal post-boot state)
#
# ## Measured (reports/201)
#   ```
#   [fast] direct SPEED=1 write, original 20045800 -> 20045800
#   [push] start cap2=00000006 config=c0b48d00 lnkcfg0=20045800
#   [push] after write cap2=00000006 config=c0b4ad00 lnkcfg0=20045800
#   ★ SUCCESS Gen2 LNKSTA=1042 (attempt 1)
#   ```
#   -> link 5GT/s, pinned H2D 1.561 / D2H 1.708 GB/s
#
# Usage:
#   sudo bash bin/push.sh
#   sudo bash bin/push.sh --no-insmod    # gen2kr already in memory; only unbind/bind
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DO_INSMOD=1             # 1 = rmmod first, then insmod (clears the triggered flag)
FORCE=0                 # 1 = --force, skip the link-state pre-check
WAIT_SECONDS=20         # how long to wait for the link to rise to Gen2

# Exit codes
EXIT_PRECHECK=1         # preconditions not met
EXIT_PUSH_FAIL=2        # push did not succeed

# ============================================================
# 2. Functions
# ============================================================

# Parse command-line arguments
parse_args() {
    case "${1:-}" in
        --no-insmod) DO_INSMOD=0 ;;
        --force)     FORCE=1 ;;
        "")          ;;
        *)
            err "unknown argument $1"
            echo "   usage: sudo bash bin/push.sh [--no-insmod] [--force]"
            exit 2
            ;;
    esac
}

# Preconditions: nvidia loaded + patch in place
check_preconditions() {
    local patch_state

    hdr "0. Preconditions"

    if ! lsmod | grep -q '^nvidia '; then
        err "nvidia is not loaded -- modprobe nvidia first (or use 20-install.sh)"
        return 1
    fi
    ok "nvidia is loaded (we will not touch it)"

    patch_state="$(python3 "${PKG_ROOT}/bin/patch_no_gen1.py" check 2>/dev/null \
                   | grep -oE '\[not patched\]|\[patched\]')"

    case "${patch_state}" in
        "[patched]")
            ok "patch is in place" ;;
        "[not patched]")
            err "patch is missing -- a push would just get downgraded by the driver again"
            echo "     run first: sudo bash bin/20-install.sh   (it applies + reloads)"
            return 1 ;;
        *)
            warn "cannot determine the patch state; continuing, but it may not work" ;;
    esac
    return 0
}

# Link-state pre-check (★ push only from a "clean starting point")
#
# Clean starting point = CAP2 0x0002 + TLS 1 (factory-locked).
# Pushing from a dirty state (e.g. CAP2=0x0006 but TLS=3, or 0x8841C sitting in
# a post-write intermediate state) corrupts the 0x8841C write and produces
# TLS=3, which only a cold boot recovers from.
# If the link is already Gen2, do not push again.
check_link_state() {
    local out cap tls spd
    out="$(read_regs)"
    cap="$(printf '%s' "${out}" | grep -oE 'CAP2=0x[0-9a-f]+' | cut -d= -f2)"
    tls="$(printf '%s' "${out}" | grep -oE 'TLS=[0-9]+'       | cut -d= -f2)"
    spd="$(printf '%s' "${out}" | grep -oE 'SPEED=[0-9]+'     | cut -d= -f2)"

    hdr "0b. Link state"
    echo "   ${out}"

    # Already Gen2 -> nothing to push
    if [ "${cap}" = "0x0006" ] && [ "${tls}" = "2" ] && [ "${spd}" = "1" ]; then
        ok "link is already Gen2; no push needed"
        return 9
    fi

    # Clean starting point
    if [ "${cap}" = "0x0002" ] && [ "${tls}" = "1" ]; then
        ok "clean starting point (CAP2=0x0002 TLS=1)"
        return 0
    fi

    # Everything else is treated as a dirty state
    err "not a clean starting point; refusing to push"
    echo "     expected: CAP2=0x0002 + TLS=1 (factory) or CAP2=0x0006 + TLS=2 + SPEED=1 (already Gen2)"
    echo "     actual:   CAP2=${cap:-?} TLS=${tls:-?} SPEED=${spd:-?}"
    echo "     ${C_R}pushing from a dirty state corrupts 0x8841C and produces TLS=3; only a cold boot recovers.${C_0}"
    echo "     recommended: reboot the whole machine first, then start the push from there."
    if [ "${FORCE}" = "1" ]; then
        warn "--force was given; continuing anyway (at your own risk)"
        return 0
    fi
    echo "     really want to skip the check: pass --force"
    return 1
}

# Make sure gen2kr is in memory with a clean triggered flag
#   gen2kr's init only attaches the kretprobe; it does not push by itself.
#   But if an old instance is already in memory, triggered may already be set
#   -> the push would not fire again, so the default is rmmod first, then insmod.
ensure_gen2kr_loaded() {
    hdr "1. gen2kr (only attaches a kretprobe; it does not push by itself)"

    if lsmod | grep -q '^gen2kr'; then
        echo "   already in memory"
        if [ "${DO_INSMOD}" = "1" ]; then
            rmmod gen2kr 2>/dev/null && echo "   reloaded to clear the triggered flag"
        fi
    fi

    if ! lsmod | grep -q '^gen2kr'; then
        insmod "${BUILD_DIR}/gen2kr.ko" || { err "insmod failed"; return 1; }
        echo "   loaded ${BUILD_DIR}/gen2kr.ko"
    fi

    sleep 1
    return 0
}

# Check whether any process is holding the GPU
#
# ★ 2026-10-29 incident: when the GPU is held by a browser, writing unbind does
#   not fail and does not return either -- it wedges inside
#   device_release_driver_internal, processes land in D/R state, kill -9 is
#   useless, and only a full reboot helps. That is why this step is a hard
#   block, not a warning.
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

# Trigger one nv_pci_probe via unbind/bind so the kretprobe fires
trigger_probe() {
    hdr "2. Triggering one probe (the kretprobe fires here)"

    if [ ! -w /sys/bus/pci/drivers/nvidia/unbind ]; then
        err "cannot write unbind -- root required"
        return 1
    fi

    check_gpu_idle || return 1

    echo "   unbind ..."
    echo "${DEV_BDF}" > /sys/bus/pci/drivers/nvidia/unbind || { err "unbind failed"; return 1; }
    sleep 1

    echo "   bind   ..."
    echo "${DEV_BDF}" > /sys/bus/pci/drivers/nvidia/bind || { err "bind failed"; return 1; }
    return 0
}

# Wait for the link to rise to Gen2; on failure print troubleshooting info
wait_for_gen2() {
    hdr "3. Waiting for the link to rise to Gen2 (up to ${WAIT_SECONDS}s)"

    if wait_gen2 "${WAIT_SECONDS}"; then
        ok "link = Gen2    $(read_regs)"
        return 0
    fi

    warn "did not rise ($(read_regs))"
    echo "   gen2kr log:"
    dmesg | grep -i gen2kr | tail -10 | sed 's/^/     /'
    echo
    echo "   see docs/troubleshooting.md"
    echo "   if CAP2 stays pinned at 0x0002 + TLS stays 1 + failures keep repeating => reboot the whole machine; do not keep retrying"
    return 1
}

# Print the closing message
show_footer() {
    echo
    echo "======================================================"
    echo " Done. The nvidia module was never unloaded/reloaded."
    echo " Verify bandwidth: build/bwtest2 512 15 | grep pinned   (should be ~1.56/1.71)"
    echo "======================================================"
}

# ============================================================
# 3. main
# ============================================================
main() {
    parse_args "$@"

    need_root
    ensure_build check || { err "probe not compiled -> bash bin/build.sh"; exit "${EXIT_PRECHECK}"; }

    echo "======================================================"
    echo " Lightweight push (no nvidia reload)"
    echo "======================================================"
    echo " starting point: $(read_regs)"

    check_preconditions      || exit "${EXIT_PRECHECK}"

    local rc=0
    check_link_state || rc=$?
    case "${rc}" in
        0)  ;;
        9)  show_footer; exit 0 ;;          # already Gen2
        *)  exit "${EXIT_PRECHECK}" ;;
    esac

    ensure_gen2kr_loaded     || exit "${EXIT_PRECHECK}"
    trigger_probe            || exit "${EXIT_PRECHECK}"
    wait_for_gen2            || exit "${EXIT_PUSH_FAIL}"

    show_footer
}

main "$@"
