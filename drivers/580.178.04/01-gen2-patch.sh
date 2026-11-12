#!/bin/bash
# ============================================================
# 01-gen2-patch.sh — patch nvidia.ko: stop the driver dropping
# the PCIe speed back to Gen1
#
# What it changes: the mode whitelist at the entry of
# _nv017105rm (the driver's set_link_speed(mode)) is narrowed
# from {1,2,3} to {2,3}, so mode==1 falls into the pre-existing
# bail branch.
# 2 bytes change: the lea imm8 (ff->fe) and the cmp imm8 (02->01).
#
# ⚠ This step is only half the job: after the patch the driver
#   stops downgrading, but **the link has not risen yet**.
#   Raising it is what 02-gen2-push.sh does.
#
# ⚠ The nvidia module must be reloaded (or the machine rebooted)
#   after patching for it to take effect (the script prints the commands).
#
# Usage:
#   sudo bash 01-gen2-patch.sh check     # read-only, show current state
#   sudo bash 01-gen2-patch.sh apply     # patch
#   sudo bash 01-gen2-patch.sh revert    # restore
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/utils/_lib.sh"

ACTION="${1:-}"

# ============================================================
# 2. Functions
# ============================================================

usage() {
    cat <<'EOF'
Usage: sudo bash 01-gen2-patch.sh <action>

Actions:
  check     read-only, show whether the patch is applied
  apply     patch (backs up .orig_nogen1 automatically)
  revert    restore

Notes:
  Changes 2 bytes of nvidia.ko so the driver stops dropping the link
  back to Gen1. Afterwards the module must be reloaded / the machine
  rebooted, then run 02-gen2-push.sh to push the link up.
EOF
}

validate() {
    # Extra arguments are always refused: avoids a "preview" like
    # `revert --dry-run` really executing
    if [ "$#" -gt 1 ]; then
        err "extra arguments: ${*:2}"
        echo "    This script has no --dry-run-like switches; from the second argument on, everything is an error."
        usage
        exit 2
    fi

    case "${ACTION}" in
        check|apply|revert) ;;
        "")  usage; exit 2 ;;
        *)   err "unknown action: ${ACTION}"; usage; exit 2 ;;
    esac
}

# Build the JSON spec _patch.py needs
#
# Locate with the 32-byte signature (unique across the whole file),
# no dependence on absolute offsets:
#   8d42ff 4156 4155 4989fd 4154 4531e4 53 4883ed40 48897510 89550c 83f802 0f87
# Two positions inside the signature change: index 0x02 (ff->fe),
# index 0x1D (02->01)
build_spec() {
    cat <<EOF
{
  "name": "gen2",
  "desc": "stop the driver dropping the PCIe speed back to Gen1",
  "path": "${KO}",
  "anchor": {"mode": "sig", "sig": "${GEN2_SIG_HEX}"},
  "edits": [
    {"off": $(( GEN2_OFF_LEA )), "old": "${GEN2_ORIG_LEA}", "new": "${GEN2_NEW_LEA}",
     "what": "lea -0x1(%rdx),%eax -> lea -0x2(%rdx),%eax  (ff -> fe)"},
    {"off": $(( GEN2_OFF_CMP )), "old": "${GEN2_ORIG_CMP}", "new": "${GEN2_NEW_CMP}",
     "what": "cmp \$0x2,%eax -> cmp \$0x1,%eax          (02 -> 01)"}
  ],
  "md5_before": "${GEN2_MD5_BEFORE}",
  "md5_after": "${GEN2_MD5_AFTER}",
  "after_note": "the nvidia module must be reloaded (or the machine rebooted) for the patch to take effect; the link still needs 02-gen2-push.sh to push it up"
}
EOF
}

# Call the generic patcher
run_patch() {
    hdr "nvidia.ko ($(basename "${KO}"))"
    echo "   target symbol: the mode range check at the entry of _nv017105rm"
    echo "   effect: mode==1 (Gen1) bails right at the entry; modes 2/3 unchanged; >=4 equivalent to the original"
    echo
    python3 "${PATCH_PY}" "${ACTION}" "$(build_spec)" "$0"
    return $?
}

# After apply/revert, print what to do next
print_next_steps() {
    [ "${ACTION}" = "check" ] && return 0

    echo
    section "Next steps (required, or the patch does nothing)"
    echo "   What changed is the on-disk nvidia.ko; the kernel still runs the old"
    echo "   code. Pick one of two ways:"
    echo
    echo "     A) reload the modules (fast; interrupts the graphical session)"
    echo "        sudo rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia"
    echo "        sudo modprobe nvidia nvidia_uvm"
    echo "     B) just reboot (recommended, cleanest)"
    echo
    echo "   ⚠ Before reloading, confirm nothing is using the GPU: fuser -v /dev/nvidia*"
    echo "      If it prints anything, close those programs first (browsers are the"
    echo "      most common culprit), otherwise the kernel may wedge."
    echo
    echo "   After the reload/reboot the link is **still not** Gen2 — the patch only"
    echo "   achieves \"no more downgrading\"."
    echo "   Then run: sudo bash 02-gen2-push.sh start"
}

# ============================================================
# 3. main
# ============================================================
main() {
    validate "$@"

    section "01 · patch nvidia.ko (no more downgrades)"

    load_offsets

    if [ "${ACTION}" != "check" ]; then
        need_root "${ACTION}"
        echo "   change size: 2 bytes"
    fi

    if [ ! -f "${KO}" ]; then
        err "cannot find ${KO}"
        echo "    If the driver is installed elsewhere, adjust KO in _lib.sh"
        exit 1
    fi

    echo "   driver version: ${DRIVER_VERSION} (the only version this directory was verified on)"

    run_patch || exit $?

    print_next_steps
}

main "$@"
