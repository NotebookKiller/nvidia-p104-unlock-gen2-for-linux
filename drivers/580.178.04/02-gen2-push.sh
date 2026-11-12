#!/bin/bash
# ============================================================
# 02-gen2-push.sh — load the kernel module and push the PCIe
# link to Gen2
#
# Precondition: 01-gen2-patch.sh has been applied and the module
# reloaded / machine rebooted
# (otherwise the push gets dropped back by the driver anyway)
#
# What it does: build the module (if no .ko) -> insmod -> unbind/bind
# to trigger one probe -> gen2kr unlocks the declaration + writes
# SPEED + retrains at the instant nv_pci_probe returns -> the link
# rises to 5.0GT/s
#
# Usage:
#   sudo bash 02-gen2-push.sh status     # module load state + link state
#   sudo bash 02-gen2-push.sh start      # load the module and push
#   sudo bash 02-gen2-push.sh stop       # unload the module (guard stops; the link falls back to Gen1)
#   sudo bash 02-gen2-push.sh restart    # stop + start
#   sudo bash 02-gen2-push.sh build      # only build the module
#   sudo bash 02-gen2-push.sh uninstall  # stop + delete build artifacts (full cleanup)
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/utils/_lib.sh"

ACTION="${1:-}"
WAIT_SECONDS=20         # longest time to wait for the link to reach Gen2

# exit codes
EXIT_PRECHECK=1
EXIT_PUSH_FAIL=2

# ============================================================
# 2. Functions
# ============================================================

usage() {
    cat <<'EOF'
Usage: sudo bash 02-gen2-push.sh <action>

Actions:
  status      show module load state and the link (read-only)
  start       build (if no .ko) -> load the module -> push -> wait for Gen2
  stop        unload the module (the link falls back to Gen1)
  restart     stop + start
  build       only build the kernel module (a normal user is enough, no sudo needed)
  uninstall   stop + delete build artifacts

Notes:
  This script does "pushing the link up". The patch (01) only achieves
  "no more downgrading". When reverting, go in reverse order:
  02 stop -> 01 revert (-> 00 revert if it was applied)
EOF
}

validate() {
    # Extra arguments are always refused (same as 01: don't let a
    # "preview" really execute)
    if [ "$#" -gt 1 ]; then
        err "extra arguments: ${*:2}"
        echo "    This script has no --dry-run-like switches; from the second argument on, everything is an error."
        usage
        exit 2
    fi

    case "${ACTION}" in
        status|start|stop|restart|build|uninstall) ;;
        "")  usage; exit 2 ;;
        *)   err "unknown action: ${ACTION}"; usage; exit 2 ;;
    esac
}

# Precondition check: is the patch present
check_patch_applied() {
    hdr "precondition check (is the 01 patch present)"

    if [ ! -f "${KO}" ]; then
        err "cannot find ${KO}"
        return 1
    fi

    local state
    state="$(python3 "${PATCH_PY}" check "$(spec_gen2_for_check)" "$0" 2>&1 \
             | grep -oE 'state: (not )?patched' | head -1)"

    case "${state}" in
        "state: patched")
            ok "01 patch present" ;;
        "state: not patched")
            err "01 patch absent — pushing would get dropped back by the driver anyway"
            echo "     First run: sudo bash 01-gen2-patch.sh apply"
            echo "     Then reload the module or reboot, and come back to run this script"
            return 1 ;;
        *)
            warn "cannot determine the patch state; continuing, but it may not work" ;;
    esac
    return 0
}

# Minimal spec for _patch.py check (status only, nothing else)
spec_gen2_for_check() {
    cat <<EOF
{
  "name": "gen2",
  "desc": "status check",
  "path": "${KO}",
  "anchor": {"mode": "sig", "sig": "${GEN2_SIG_HEX}"},
  "edits": [
    {"off": $(( GEN2_OFF_LEA )), "old": "${GEN2_ORIG_LEA}", "new": "${GEN2_NEW_LEA}", "what": ""},
    {"off": $(( GEN2_OFF_CMP )), "old": "${GEN2_ORIG_CMP}", "new": "${GEN2_NEW_CMP}", "what": ""}
  ]
}
EOF
}

# ---------- status ----------
do_status() {
    hdr "module state"

    if kmod_loaded; then
        ok "gen2kr loaded"
        local p
        for p in guard_period_ms guard_rounds guard_enabled; do
            printf '     %-16s = %s\n' "$p" \
                "$(cat "/sys/module/gen2kr/parameters/${p}" 2>/dev/null || echo N/A)"
        done
    else
        echo "     gen2kr not loaded"
    fi

    hdr "module artifact"
    if kmod_built; then
        ok "$(kmod_path)  ($(stat -c%s "$(kmod_path)") bytes)"
    else
        warn "not built (start builds it automatically, or run build alone)"
    fi

    hdr "link"
    echo "     $(read_regs)"
    if is_gen2; then
        ok "currently Gen2 (5.0GT/s)"
    else
        echo "     currently Gen$(cur_speed) (not Gen2)"
    fi
}

# ---------- build ----------
do_build() {
    build_kmod || return 1
    ok "artifact: $(kmod_path)"
}

# ---------- stop ----------
do_stop() {
    hdr "unload the module"

    if ! kmod_loaded; then
        echo "     gen2kr not loaded (nothing to do)"
        return 0
    fi

    if rmmod gen2kr; then
        ok "unloaded"
        echo "     Note: once the guard stops, the driver drops the link back to Gen1 on the next cuInit"
    else
        err "rmmod failed"
        echo "     It may still be held; check: lsmod | grep gen2kr"
        return 1
    fi
}

# ---------- start ----------
do_start() {
    # 1) the patch must be present
    check_patch_applied || return "${EXIT_PRECHECK}"

    # 2) the module must be built
    hdr "prepare the module"
    if kmod_built; then
        ok "already have $(basename "$(kmod_path)")"
    else
        echo "     not built; building now..."
        build_kmod || return "${EXIT_PRECHECK}"
    fi

    # 3) ★ before really touching the hardware, confirm the GPU is idle
    if ! check_gpu_idle; then
        return "${EXIT_PRECHECK}"
    fi

    # 4) load the module (if already loaded, unload first to clear the triggered flag)
    hdr "load the module"
    if kmod_loaded; then
        echo "     already in memory; unloading first to clear the triggered flag"
        rmmod gen2kr 2>/dev/null || true
        sleep 1
    fi
    insmod "$(kmod_path)" || { err "insmod failed"; return "${EXIT_PRECHECK}"; }
    ok "loaded"
    sleep 1

    # 5) trigger one probe
    hdr "trigger the probe (the kretprobe fires here)"
    echo "   starting point: $(read_regs)"

    echo "   unbind ..."
    echo "${DEV_BDF}" > /sys/bus/pci/drivers/nvidia/unbind \
        || { err "unbind failed"; return "${EXIT_PRECHECK}"; }
    sleep 1

    echo "   bind   ..."
    echo "${DEV_BDF}" > /sys/bus/pci/drivers/nvidia/bind \
        || { err "bind failed"; return "${EXIT_PRECHECK}"; }

    # 6) wait for the result
    hdr "waiting for the link to reach Gen2 (up to ${WAIT_SECONDS}s)"
    if wait_gen2 "${WAIT_SECONDS}"; then
        ok "link = Gen2    $(read_regs)"
        echo
        echo "   verify bandwidth: ${PKG_ROOT}/build/bwtest2 512 15 | grep pinned   (should be ~1.56/1.71)"
        return 0
    fi

    warn "did not rise ($(read_regs))"
    echo "   gen2kr log:"
    dmesg | grep -i gen2kr | tail -10 | sed 's/^/     /'
    echo
    echo "   see ${PKG_ROOT}/docs/troubleshooting.md"
    echo "   if CAP2 stays 0x0002 + TLS stays 1 + repeated failures => reboot the whole machine; do not retry"
    return "${EXIT_PUSH_FAIL}"
}

# ---------- uninstall ----------
do_uninstall() {
    do_stop || return 1

    hdr "delete build artifacts"
    rm -f "${KERNEL_SRC_DIR}"/gen2kr.o \
          "${KERNEL_SRC_DIR}"/gen2kr.ko \
          "${KERNEL_SRC_DIR}"/gen2kr.mod \
          "${KERNEL_SRC_DIR}"/gen2kr.mod.c \
          "${KERNEL_SRC_DIR}"/.gen2kr.o.d \
          "${KERNEL_SRC_DIR}"/Module.symvers \
          "${KERNEL_SRC_DIR}"/modules.order 2>/dev/null || true
    ok "cleaned the build artifacts under $(basename "${KERNEL_SRC_DIR}")/"
    echo "     The module sources are kept. The cfg file (if any) can be removed with make clean."
}

# ============================================================
# 3. main
# ============================================================
main() {
    validate "$@"

    case "${ACTION}" in
        status)
            section "02 · link push — status"
            load_offsets
            do_status
            ;;

        build)
            section "02 · build the module only"
            load_offsets
            # ★ root not required — the build should be run as a normal user
            #   if run with sudo, build_kmod drops privileges to SUDO_USER
            do_build || exit 1
            ;;

        stop)
            section "02 · unload the module"
            load_offsets
            need_root stop
            do_stop || exit 1
            ;;

        start)
            section "02 · load the module and push the link"
            load_offsets
            need_root start
            do_start
            exit $?
            ;;

        restart)
            section "02 · restart the push (stop + start)"
            load_offsets
            need_root restart
            do_stop || exit 1
            sleep 1
            do_start
            exit $?
            ;;

        uninstall)
            section "02 · full uninstall (stop + clean artifacts)"
            load_offsets
            need_root uninstall
            do_uninstall || exit 1
            ;;
    esac
}

main "$@"
