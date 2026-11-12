#!/bin/bash
# ============================================================
# utils/bdf.sh -- Automatic discovery of the target GPU's PCIe BDF (**single source of truth**)
#
# Sourced by drivers/<version>/utils/_lib.sh and bin/_common.sh.
#
# Why automatic discovery is mandatory:
#   With a hardcoded 01:00.0, a multi-GPU machine would **read and write the wrong card**.
#   If the same machine also has a P100 already at full-speed Gen3, the script would read
#   CAP2=0x0006 / TLS=2 / LNKSTA stuck at 1041 -- which looks like a "hard lock",
#   but is actually the wrong device; and since 10-check's device check uses a different
#   source, you get self-contradictory output like "section 2 says P104 is on the bus
#   while section 3 shows P100's cfg".
#
# Environment variables:
#   TARGET_IDS   Target device ids, space-separated (default "1b87" = P104-100)
#                Restricted mining cards in the same family: 1b07 P102-100 / 1b87 P104-100 /
#                1bc7 P104-101 / 1c07 P106-100 / 1c09 P106-090
#   TARGET_BDF   Explicitly specify the BDF, skipping auto-discovery (mandatory when
#                several identical cards are present)
#
# Exports: DEV_BDF (0000:01:00.0)  DEV_SHORT (01:00.0)  ROOT_BDF (upstream root port)
#
# Usage:
#   source utils/bdf.sh              # normally done for you by _lib.sh
#   bash utils/bdf.sh                # run standalone: only prints the discovered BDF
# ============================================================

if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    # Sourced: a repeated source returns directly
    [ -n "${_BDF_SH_LOADED:-}" ] && return 0
    _BDF_SH_LOADED=1
fi

_bdf_err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

# Scan /sys/bus/pci/devices, matching target cards by vendor:device
_bdf_scan() {
    local d vid did out=""
    for d in /sys/bus/pci/devices/*; do
        [ -r "${d}/vendor" ] || continue
        vid="$(cat "${d}/vendor" 2>/dev/null)" || continue
        [ "${vid}" = "0x10de" ] || continue
        did="$(cat "${d}/device" 2>/dev/null)"
        case " ${TARGET_IDS} " in
            *" ${did#0x} "*) out="${out} $(basename "${d}")" ;;
        esac
    done
    printf '%s' "${out# }"
}

TARGET_IDS="${TARGET_IDS:-1b87}"

if [ -n "${TARGET_BDF:-}" ]; then
    if [ ! -d "/sys/bus/pci/devices/${TARGET_BDF}" ]; then
        _bdf_err "TARGET_BDF=${TARGET_BDF} does not exist"
        echo "    List all NVIDIA devices: lspci -Dn | grep 10de" >&2
        exit 3
    fi
    DEV_BDF="${TARGET_BDF}"
else
    _bdf_cands="$(_bdf_scan)"
    if [ -z "${_bdf_cands}" ]; then
        _bdf_n=0
    else
        _bdf_n=$(printf '%s\n' ${_bdf_cands} | wc -l)
    fi

    if [ "${_bdf_n}" -eq 0 ]; then
        _bdf_err "No target device found (10de:${TARGET_IDS// /,})"
        echo "    All NVIDIA devices on this machine:" >&2
        lspci -Dn 2>/dev/null | grep -i ' 10de:' | sed 's/^/      /' >&2
        echo "    If the device id differs, use: TARGET_IDS=\"1b87 1c07\" sudo -E bash \$0" >&2
        exit 3
    elif [ "${_bdf_n}" -gt 1 ]; then
        _bdf_err "Found ${_bdf_n} matching devices; cannot auto-select: ${_bdf_cands}"
        echo "    You must specify one explicitly, otherwise the wrong card may be modified (breaking another card's link):" >&2
        echo "        TARGET_BDF=0000:02:00.0 sudo -E bash \$0" >&2
        exit 3
    fi
    DEV_BDF="${_bdf_cands}"
fi

DEV_SHORT="${DEV_BDF#0000:}"
# Upstream root port: resolve the parent device with readlink instead of assuming 00:01.0
ROOT_BDF="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${DEV_BDF}")")")"

export DEV_BDF DEV_SHORT ROOT_BDF TARGET_IDS

# When executed directly, print the result
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "DEV_BDF   = ${DEV_BDF}"
    echo "DEV_SHORT = ${DEV_SHORT}"
    echo "ROOT_BDF  = ${ROOT_BDF}"
fi
