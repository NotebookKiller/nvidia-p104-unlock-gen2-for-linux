#!/bin/bash
# ============================================================
# sync-dkms.sh — sync the patched nvidia.ko into DKMS so a reboot
# cannot overwrite it
#
# [Why this exists]
#   At boot, modprobe reads /lib/modules/<kver>/updates/dkms/nvidia.ko.
#   DKMS keeps a separate "built" copy at
#       /var/lib/dkms/nvidia/<version>/<kver>/x86_64/module/nvidia.ko
#   These are **two independent files**, not a symlink.
#
#   `dkms install` (and autoinstall when a new kernel is installed)
#   **copies** the built copy into /lib/modules — if the built copy is
#   still the original, your patch gets overwritten.
#
#   ★ So: after make produces the nvidia.ko under /usr/src, both
#     locations must be synced.
#
# [A pitfall actually hit]
#   2026-10-30: applied the 00 whitelist, ran make as instructed, but
#   after the reboot it was still 19fps. The cause: only /usr/src had
#   been rebuilt; the DKMS built cache was still the 10-28 original
#   (md5 7f6805ed…, P104-100 appearing 2 times) and overwrote it at boot.
#
# Usage:
#   sudo ./sync-dkms.sh status   show the three locations (read-only)
#   sudo ./sync-dkms.sh apply    sync from /usr/src to both DKMS locations
#   sudo ./sync-dkms.sh restore  recover /usr/src from DKMS built (rollback)
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
KVER="$(uname -r)"
SRC="/usr/src/nvidia-580.178.04/nvidia.ko"
DKMS_BUILT="/var/lib/dkms/nvidia/580.178.04/${KVER}/x86_64/module/nvidia.ko"
INSTALLED="/lib/modules/${KVER}/updates/dkms/nvidia.ko"

ACTION="${1:-status}"

# P104-100 = 0x1b87; appearing in the "restricted SKU table" means the
# whitelist patch is absent.
# Appearing in the "PCI device ID table" is normal (that one is used for
# device identification and must be kept).
# Criterion: <=1 occurrence = whitelist applied; >=2 occurrences = not applied

if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
    C_R=; C_G=; C_Y=; C_B=; C_0=
fi
ok()   { echo "${C_G}✓${C_0} $*"; }
warn() { echo "${C_Y}⚠${C_0} $*"; }
err()  { echo "${C_R}✗${C_0} $*"; }
hdr()  { echo; echo "${C_B}── $* ──${C_0}"; }

# ============================================================
# 2. Functions
# ============================================================

usage() {
    cat <<EOF
Usage: sudo ./sync-dkms.sh <action>

Actions:
  status    show the md5 / patch state of the three .ko files (read-only, default)
  adopt     ★ pin the copy at the [currently loaded location] into the
              DKMS cache + /usr/src
              -- scenario: things run fine right now (patches present),
                 but a reboot might overwrite them
  apply     push from /usr/src to the two DKMS locations
              -- scenario: just ran make on a fresh .ko and want it to be
                 the canonical artifact
  restore   recover /usr/src from the DKMS built cache (rollback reference)

Notes:
  Boot loads $INSTALLED
  DKMS caches     $DKMS_BUILT
  The two are independent; dkms install overwrites the former with the
  cache => after patching you must sync.

  ⚠ adopt and apply point in opposite directions:
     the /usr/src nvidia.ko is what make produced and **does not contain
     the 01 gen2 patch** (01 patches the .ko directly; a rebuild loses it).
     So after a fresh make do not apply directly — either re-run the 01
     patch against the /usr/src copy, or use adopt to copy the currently
     loaded (working) one back.
EOF
}

need_root() {
    [ "$(id -u)" = "0" ] || { err "root required: sudo $0 $*"; exit 1; }
}

# Show the state of the three locations
show_status() {
    hdr "state of the three nvidia.ko copies"
    python3 - "${SRC}" "${DKMS_BUILT}" "${INSTALLED}" <<'PY'
import sys, os, time, hashlib

pat = bytes([0x87, 0x1b, 0x07, 0x00])          # P104-100
labels = ["/usr/src (build artifact)", "DKMS built (cache)", "loaded copy (what modprobe reads)"]

for label, p in zip(labels, sys.argv[1:4]):
    if not os.path.exists(p):
        print(f"   {label:<26} does not exist")
        continue
    d = open(p, "rb").read()
    n = d.count(pat)
    st = time.strftime("%m-%d %H:%M", time.localtime(os.stat(p).st_mtime))
    wl = "applied" if n <= 1 else "not applied"
    flag = "  ★" if label.startswith("loaded copy") else ""
    print(f"   {label:<26} {st}  md5={hashlib.md5(d).hexdigest()[:10]}  "
          f"whitelist={wl} (P104 x{n}){flag}")

print()
print("   criterion: P104-100 appearing <=1 time = whitelist applied (the remaining")
print("              one occurrence is the PCI device ID table, which must be kept)")
print("              appearing 2 times = not applied (still present in the restricted SKU table)")
PY
}

do_status() {
    show_status
    echo
    echo "   clock check (confirm after rebooting):"
    echo "     Whether the loaded copy and the DKMS cache match decides whether the"
    echo "     patches survive a reboot."
    if [ -f "${SRC}" ] && [ -f "${DKMS_BUILT}" ]; then
        if cmp -s "${SRC}" "${DKMS_BUILT}"; then
            ok "the two match — reboot is safe"
        else
            warn "the two differ — run apply to sync, otherwise dkms install overwrites"
        fi
    fi
}

do_apply() {
    need_root apply

    if [ ! -f "${SRC}" ]; then
        err "cannot find ${SRC}; run make first"
        exit 1
    fi

    # Guard rail: /usr/src is what make produced and naturally lacks the 01 gen2 patch
    if ! python3 - "${SRC}" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
new_sig = bytes.fromhex("8d42fe415641554989fd41544531e4534883ed404889751089550c83f8010f87")
sys.exit(0 if d.count(new_sig) == 1 else 1)
PY
    then
        warn "no gen2 (01) patch on ${SRC}"
        echo "      It is what make produced; the 01 patch was applied to the .ko itself"
        echo "      and is lost on rebuild. Applying directly would wipe the gen2 patch."
        echo
        echo "      Two correct options:"
        echo "        a) re-run 01-gen2-patch.sh against ${SRC} (retarget it)"
        echo "        b) if the currently loaded copy is already good, use: sudo $0 adopt"
        echo
        read -r -p "      continue with apply anyway? (yes/no) " ans
        [ "${ans}" = "yes" ] || { echo "      cancelled."; exit 1; }
    fi

    hdr "sync into DKMS"
    cp -f "${SRC}" "${DKMS_BUILT}" && ok "built cache  <- ${SRC}"
    cp -f "${SRC}" "${INSTALLED}" && ok "loaded copy  <- ${SRC}"

    echo
    show_status
    echo
    warn "the module currently running is still the old one. To take effect, reload the driver or reboot:"
    echo "     sudo rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia"
    echo "     sudo modprobe nvidia && sudo modprobe nvidia_uvm nvidia_modeset nvidia_drm"
}

# Pin the copy at the currently loaded location into the DKMS cache + /usr/src
# Use case: everything works right now, but the DKMS state could overwrite
# these patches at any time
do_adopt() {
    need_root adopt

    if [ ! -f "${INSTALLED}" ]; then
        err "cannot find the loaded copy ${INSTALLED}"
        exit 1
    fi

    hdr "pin the loaded .ko"
    echo "   source: ${INSTALLED}"

    # First report what the source holds so the user can confirm this is
    # really the desired state
    python3 - "${INSTALLED}" <<'PY'
import sys, hashlib
p = sys.argv[1]
d = open(p, "rb").read()
gen2 = bytes.fromhex("8d42fe415641554989fd41544531e4534883ed404889751089550c83f8010f87")
wl = d.count(bytes([0x87, 0x1b, 0x07, 0x00]))
print(f"   md5={hashlib.md5(d).hexdigest()}")
print(f"   gen2 patch   : {'applied' if d.count(gen2) == 1 else 'not applied'}")
print(f"   whitelist    : {'applied' if wl <= 1 else 'not applied'} (P104 x{wl})")
PY

    # Back up the previous DKMS cache and /usr/src artifact
    ts="$(date +%Y%m%d-%H%M%S)"
    [ -f "${DKMS_BUILT}" ] && cp -a "${DKMS_BUILT}" "${DKMS_BUILT}.bak-${ts}" \
        && ok "backed up the DKMS cache -> $(basename "${DKMS_BUILT}").bak-${ts}"
    [ -f "${SRC}" ] && cp -a "${SRC}" "${SRC}.bak-${ts}" \
        && ok "backed up /usr/src      -> $(basename "${SRC}").bak-${ts}"

    echo
    cp -f "${INSTALLED}" "${DKMS_BUILT}" && ok "DKMS cache <- loaded copy"
    cp -f "${INSTALLED}" "${SRC}"        && ok "/usr/src   <- loaded copy"

    echo
    show_status
    echo
    ok "pinned. Future dkms install / autoinstall on a new kernel can no longer wipe the patches."
    echo "   rollback: copy the .bak-${ts} files above back to their original paths."
}

do_restore() {
    need_root restore

    if [ ! -f "${DKMS_BUILT}" ]; then
        err "cannot find the DKMS cache ${DKMS_BUILT}; cannot recover in reverse"
        exit 1
    fi

    hdr "recover /usr/src from the DKMS cache"
    cp -f "${DKMS_BUILT}" "${SRC}.from-dkms" && ok "wrote ${SRC}.from-dkms"
    echo "   After verifying it is correct, replace by hand:"
    echo "     sudo cp ${SRC}.from-dkms ${SRC}"
}

# ============================================================
# 3. main
# ============================================================
main() {
    case "${ACTION}" in
        status)  do_status ;;
        adopt)   do_adopt ;;
        apply)   do_apply ;;
        restore) do_restore ;;
        -h|--help) usage ;;
        *)       err "unknown action: ${ACTION}"; usage; exit 2 ;;
    esac
}

main "$@"
