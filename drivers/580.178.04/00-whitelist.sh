#!/bin/bash
# ============================================================
# 00-whitelist.sh — [pre-step, optional] lift the driver's
# "restricted SKU" check
#
# This step can be skipped. Doing it or not only affects the
# "framerate / power" problem, not PCIe Gen2.
#
# What it changes: the "restricted device table" inside
# nv-kernel.o_binary, replacing the P1XX device IDs with 0xFFFF
# (sentinel) — effectively erasing the cards from the table.
#
# ⚠ The kernel module must be rebuilt afterwards:
#   cd /usr/src/nvidia-580.178.04 && sudo make
#   then reload the driver or reboot (the script prints the commands).
#
# Usage:
#   sudo bash 00-whitelist.sh check      # read-only, show current state
#   sudo bash 00-whitelist.sh apply      # patch (backs up .orig automatically)
#   sudo bash 00-whitelist.sh revert     # restore
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
Usage: sudo bash 00-whitelist.sh <action>

Actions:
  check     read-only, show whether the patch is applied
  apply     patch (backs up .orig automatically)
  revert    restore

Notes:
  This step is [optional]. It fixes "framerate stuck ~40fps /
  power cannot climb", and has nothing to do with the PCIe Gen2
  unlock. If you only want bandwidth, skip it and go straight to 01.

  ⚠ There is no --dry-run / --force switch. Anything past the first
    argument is rejected, so a "preview" can never be mistaken for
    "just looking" that then actually applies or reverts the patch.
EOF
}

validate() {
    # Extra arguments are always refused: a `revert --dry-run` was once
    # silently ignored and the revert really ran
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
build_spec() {
    local edits="" i off dev
    for i in "${!WHITELIST_DEV_IDS[@]}"; do
        dev="${WHITELIST_DEV_IDS[$i]}"
        off=$(( WHITELIST_OFFSET + i * 4 ))
        # Only the low 16 bits (2 bytes) change; the 0x0007 prefix is kept
        edits+=$(printf '{"off": %d, "old": "%02x%02x", "new": "ffff", "what": "device 0x%04x -> 0xffff (erased)"},' \
                 "${off}" $(( dev & 0xff )) $(( (dev >> 8) & 0xff )) "${dev}")
    done
    edits="${edits%,}"

    cat <<EOF
{
  "name": "whitelist",
  "desc": "erase the P1XX device IDs from the kernel's restricted device table",
  "path": "${NVKERNEL_DIR}/nvidia/nv-kernel.o_binary",
  "anchor": {"mode": "offset", "off": 0},
  "edits": [${edits}],
  "md5_before": "${WHITELIST_MD5_BEFORE}",
  "md5_after": "${WHITELIST_MD5_AFTER}",
  "after_note": "the kernel module must be rebuilt afterwards (see the next step below) or the change never takes effect"
}
EOF
}

# Call the generic patcher
run_patch() {
    hdr "restricted device table ($(basename "${NVKERNEL_DIR}")/nvidia/nv-kernel.o_binary)"
    python3 "${PATCH_PY}" "${ACTION}" "$(build_spec)" "$0"
    return $?
}

# Print which devices the table actually holds
# After patching the current values are all 0x0007ffff, which alone
# cannot tell which card each entry was
# => read the original IDs from the .orig backup to display them
show_table() {
    local bin="${NVKERNEL_DIR}/nvidia/nv-kernel.o_binary"
    local orig="${bin}.orig"

    hdr "which devices the restricted device table holds"

    local ids="" names="" i
    for i in "${!WHITELIST_DEV_IDS[@]}"; do
        ids+="$(printf '%04x' "${WHITELIST_DEV_IDS[$i]}") "
        names+="${WHITELIST_DEV_NAMES[$i]}|"
    done

    python3 - "$bin" "$orig" "$WHITELIST_OFFSET" "$ids" "$names" <<'PY'
import sys, struct, os

binp, origp, off, ids_s, names_s = sys.argv[1], sys.argv[2], int(sys.argv[3], 0), sys.argv[4], sys.argv[5]
ids   = [int(x, 16) for x in ids_s.split()]
names = names_s.rstrip("|").split("|")

def read5(path):
    with open(path, "rb") as f:
        f.seek(off)
        return struct.unpack("<5I", f.read(20))

cur = read5(binp)
orig = read5(origp) if os.path.exists(origp) else None

# This machine's card (BDF decided by utils/bdf.sh, passed in via the environment)
local = None
try:
    _bdf = os.environ.get("DEV_BDF", "0000:01:00.0")
    with open("/sys/bus/pci/devices/%s/vendor" % _bdf) as f:
        v = int(f.read().strip(), 16)
    with open("/sys/bus/pci/devices/%s/device" % _bdf) as f:
        local = int(f.read().strip(), 16)
except Exception:
    pass

for i, c in enumerate(cur):
    o = orig[i] if orig else None
    oid = None
    if o is not None:
        oid = o & 0xFFFF
    else:
        oid = ids[i] if (c & 0xFFFF) == 0xFFFF else (c & 0xFFFF)

    name = names[i] if i < len(names) else "?"
    mark = ""
    if local is not None and oid == local:
        mark = "   ★ this machine's card"

    if oid == 0xFFFF:
        origtxt = "original unknown (no .orig backup)"
    else:
        origtxt = f"orig 0x{oid:04x}"

    print(f"   0x{off + i*4:08x}  current=0x{c:08x}   {origtxt}  {name:<9}{mark}")

print()
if orig is None:
    print("   ⚠ no .orig backup found; original IDs shown only from offsets.sh's known list")
else:
    print(f"   original values come from the backup: {os.path.basename(origp)}")
    print("   after patching the low 16 bits become 0xffff (sentinel), so the current file cannot reveal which card each entry was")
PY
}

# After apply/revert, print what to do next
print_next_steps() {
    [ "${ACTION}" = "check" ] && return 0

    echo
    section "Next steps (required, or the change never takes effect)"
    echo "   What changed is nv-kernel.o_binary (a build input), not the final"
    echo "   module. A rebuild is mandatory:"
    echo
    echo "     cd ${NVKERNEL_DIR}"
    echo "     sudo make -j\$(nproc)"
    echo
    echo "   ★ make must run as root (/usr/src is owned by root), otherwise it"
    echo "     fails with \"cannot create conftest*.c: Permission denied\", which"
    echo "     is easily mistaken for a compiler problem."
    echo
    echo "   ★★ After building you must also sync DKMS — otherwise a reboot"
    echo "      rolls it back (the most common pitfall):"
    echo
    echo "     sudo cp ${NVKERNEL_DIR}/nvidia.ko \\"
    echo "             /var/lib/dkms/nvidia/580.178.04/\$(uname -r)/x86_64/module/nvidia.ko"
    echo "     sudo cp ${NVKERNEL_DIR}/nvidia.ko \\"
    echo "             /lib/modules/\$(uname -r)/updates/dkms/nvidia.ko"
    echo
    echo "   Why: at boot modprobe reads the /lib/modules copy, while DKMS's"
    echo "   \"built\" cache under /var/lib/dkms/... still holds the original it"
    echo "   built on 10-28. dkms install / autoinstall on a new kernel takes that"
    echo "   cache and **overwrites** what you built."
    echo "   make alone without syncing => after the reboot you are back on the"
    echo "   old version (patch wasted)."
    echo
    echo "   Then pick one of two ways to make it live:"
    echo "     A) reload the driver (fast; interrupts the graphical session)"
    echo "        sudo rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia"
    echo "        sudo modprobe nvidia && sudo modprobe nvidia_uvm nvidia_modeset nvidia_drm"
    echo "     B) just reboot (cleanest; a DKMS-synced cache survives the reboot)"
    echo
    echo "   ⚠ Before reloading, confirm nothing is using the GPU: fuser -v /dev/nvidia*"
    echo "      If it prints anything, close those programs first (browsers are the"
    echo "      most common culprit), otherwise the kernel may wedge."
    echo
    echo "   ⚠ Rebuilding regenerates nvidia.ko, **wiping the 01 gen2 patch too**."
    echo "      The order should be: 00 whitelist -> make -> sync DKMS -> 01 gen2 -> sync DKMS."
}

# ============================================================
# 3. main
# ============================================================
main() {
    validate "$@"

    section "00 · lift the restricted SKU check (optional)"

    load_offsets

    if [ "${ACTION}" != "check" ]; then
        need_root "${ACTION}"
        echo "   change size: ${#WHITELIST_DEV_IDS[@]} device IDs -> 0xFFFF"
    fi

    if [ ! -f "${NVKERNEL_DIR}/nvidia/nv-kernel.o_binary" ]; then
        err "cannot find ${NVKERNEL_DIR}/nvidia/nv-kernel.o_binary"
        echo "    This patch only applies when the driver is installed under /usr/src/nvidia-<version>/."
        echo "    If your driver was installed with .run and the source tree was not kept, skip this step (it does not affect Gen2)."
        exit 1
    fi

    run_patch || exit $?

    show_table

    print_next_steps
}

main "$@"
