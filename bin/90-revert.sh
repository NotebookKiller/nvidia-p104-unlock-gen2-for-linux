#!/bin/bash
# ============================================================
# 90-revert.sh — roll everything back to the original state
#
# Rolls back two things:
#   1. Unload gen2kr (the guard stops)
#   2. Restore nvidia.ko from the backup (removes the 2-byte patch)
# Then reloads the driver.
#
# Usage:
#   sudo bash bin/90-revert.sh --dry-run
#   sudo bash bin/90-revert.sh
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DRY=0                   # 1 = print the plan only

# Unload order for the nvidia modules (dependency order: drm -> modeset -> uvm -> main module)
NVIDIA_MODULES=(nvidia_drm nvidia_modeset nvidia_uvm nvidia)

# ============================================================
# 2. Functions
# ============================================================

# Parse arguments
parse_args() {
    case "${1:-}" in
        --dry-run) DRY=1 ;;
        "")        ;;
        *)
            err "unknown argument $1"
            echo "   usage: sudo bash bin/90-revert.sh [--dry-run]"
            exit 2
            ;;
    esac
}

# Step 1: unload gen2kr
step_unload_kmod() {
    hdr "1. Unloading gen2kr"

    if ! lsmod | grep -q '^gen2kr'; then
        echo "   gen2kr is not loaded"
        return 0
    fi

    if [ "${DRY}" = "1" ]; then
        echo "   ${C_Y}[dry-run]${C_0} rmmod gen2kr"
        return 0
    fi

    if rmmod gen2kr; then
        ok "unloaded"
    else
        warn "rmmod failed (it may still be in use)"
    fi
}

# Step 2: restore nvidia.ko
step_revert_patch() {
    hdr "2. Restoring nvidia.ko"

    if [ "${DRY}" = "1" ]; then
        python3 "${PKG_ROOT}/bin/patch_no_gen1.py" check 2>&1 | sed 's/^/   /'
        echo "   ${C_Y}[dry-run]${C_0} python3 bin/patch_no_gen1.py revert"
        return 0
    fi

    python3 "${PKG_ROOT}/bin/patch_no_gen1.py" revert \
        || warn "restore failed (the patch may have never been applied)"
    echo "   current md5 = $(md5sum "${KO}" | cut -d' ' -f1)"
}

# Step 3: reload the driver
step_reload() {
    local m

    hdr "3. Reloading the driver"

    for m in "${NVIDIA_MODULES[@]}"; do
        lsmod | grep -q "^${m} " || continue
        if [ "${DRY}" = "1" ]; then
            echo "   ${C_Y}[dry-run]${C_0} rmmod ${m}"
        else
            rmmod "${m}" 2>/dev/null || true
        fi
    done
    sleep 1

    if [ "${DRY}" = "1" ]; then
        echo "   ${C_Y}[dry-run]${C_0} modprobe nvidia && modprobe nvidia_uvm"
        return 0
    fi

    if modprobe nvidia && modprobe nvidia_uvm; then
        ok "driver reloaded"
    else
        err "driver reload failed"
        return 1
    fi
    sleep 2
    echo "   $(read_regs)"
}

# Closing message
show_footer() {
    echo
    echo "======================================================"
    if [ "${DRY}" = "0" ]; then
        echo " Rolled back. The link should now be Gen1 ($(cur_speed)) -- that is the factory default behavior."
        echo " To unlock again: sudo bash bin/20-install.sh"
    else
        echo " dry-run finished; nothing was changed"
    fi
    echo "======================================================"
}

# ============================================================
# 3. main
# ============================================================
main() {
    parse_args "$@"

    need_root

    echo "======================================================"
    echo " Rollback"
    [ "${DRY}" = "1" ] && echo " ${C_Y}mode: dry-run${C_0}"
    echo "======================================================"

    step_unload_kmod
    step_revert_patch
    step_reload || exit 1

    show_footer
}

main "$@"
