#!/bin/bash
# ============================================================
# 30-verify.sh — verify: whether bandwidth meets the target + whether the patch really took over
#
# Three criteria, all of them required:
#   A. Bandwidth    pinned H2D >= 1.4 GB/s (Gen2 x4 should be ~1.55)
#                   ★ must be 512MB x 15; 128MB x 3 lands inside the recovery
#                     window and only measures 0.78
#   B. Stability    after N rounds of CUDA contexts the link is still 2
#   C. Patch works  with the guard removed the link still holds (guard does zero work)
#
# Usage:
#   sudo bash bin/30-verify.sh            # A + B (default 5 rounds)
#   sudo bash bin/30-verify.sh 20         # A + B (20 rounds)
#   sudo bash bin/30-verify.sh --full     # also do C (temporarily unloads the guard)
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ROUNDS=5                # number of rounds for stage B
FULL=0                  # 1 = also do stage C (drop the guard)
BW_SIZE_MB=512          # bandwidth test: per-run size
BW_ITERS=15             # bandwidth test: iterations (★ small values are not allowed; see header)
BW_THRESHOLD=1.4        # threshold for stage A (GB/s)

# Per-stage results
A_OK=0
B_BAD=0
C_OK=1
BW_H2D=""               # measured pinned H2D (GB/s)
BW_D2H=""               # measured pinned D2H (GB/s)

# ============================================================
# 2. Functions
# ============================================================

# Convert 1/0 into colored text
status_text() {
    if [ "$1" = "1" ]; then echo "$2"; else echo "$3"; fi
}

# Parse args: --full or a plain number of rounds
parse_args() {
    local a
    for a in "$@"; do
        case "${a}" in
            --full)
                FULL=1 ;;
            *[!0-9]*)
                err "unknown option ${a}"
                echo "   usage: sudo bash bin/30-verify.sh [rounds] [--full]"
                exit 2 ;;
            *)
                ROUNDS="${a}" ;;
        esac
    done
}

# A. Bandwidth test
check_bandwidth() {
    local out h2d

    hdr "A. Bandwidth (${BW_SIZE_MB}MB x ${BW_ITERS})"

    if ! is_gen2; then
        warn "currently not Gen2; bandwidth will necessarily be Gen1 level (0.78)"
    fi

    out="$("${BUILD_DIR}/bwtest2" "${BW_SIZE_MB}" "${BW_ITERS}" 2>&1)"
    echo "${out}" | sed 's/^/   /'

    h2d="$(echo "${out}" | grep pinned | grep -o 'H2D med [0-9.]*' | awk '{print $3}')"
    BW_H2D="${h2d}"
    BW_D2H="$(echo "${out}" | grep pinned | grep -o 'D2H med [0-9.]*' | awk '{print $3}')"

    echo
    echo " link after the test: $(read_regs)"

    if [ -n "${h2d}" ] && python3 -c "import sys; sys.exit(0 if ${h2d} >= ${BW_THRESHOLD} else 1)"; then
        ok "pinned H2D = ${h2d} GB/s (meets the Gen2 target)"
        A_OK=1
    else
        err "pinned H2D = ${h2d:-?} GB/s (< ${BW_THRESHOLD}; still Gen1 level)"
        A_OK=0
    fi
}

# B. Stability: create CUDA contexts in a row and see whether the link drops
check_stability() {
    local i speed

    hdr "B. Stability (${ROUNDS} rounds of CUDA contexts)"

    B_BAD=0
    for i in $(seq 1 "${ROUNDS}"); do
        "${BUILD_DIR}/minictx" 1 >/dev/null 2>&1
        sleep 0.8
        speed="$(cur_speed)"
        printf '   round %2d: LNKSTA=%s  %s\n' "${i}" "${speed}" \
            "$([ "${speed}" = "2" ] && echo ok || echo '★dropped')"
        [ "${speed}" = "2" ] || B_BAD=$((B_BAD + 1))
    done

    sleep 3
    echo "   after 3s: $(read_regs)"
    if [ "${B_BAD}" = "0" ]; then
        ok "stayed Gen2 throughout"
    else
        err "${B_BAD} rounds dropped"
    fi
}

# C. Patch independence: drop the guard and re-test to see whether the link still holds
check_patch_independence() {
    local i speed cbad

    hdr "C. Patch independence (temporarily dropping the guard)"
    echo "   rationale: testing with the guard attached cannot measure the patch's effect -- the guard pulls the link back."

    if lsmod | grep -q '^gen2kr'; then
        rmmod gen2kr && echo "   gen2kr unloaded"
    fi
    sleep 1
    echo "   before dropping the guard: $(read_regs)"

    cbad=0
    for i in $(seq 1 3); do
        "${BUILD_DIR}/minictx" 1 >/dev/null 2>&1
        sleep 0.8
        speed="$(cur_speed)"
        printf '     round %d: LNKSTA=%s\n' "${i}" "${speed}"
        [ "${speed}" = "2" ] || cbad=$((cbad + 1))
    done

    sleep 8
    echo "   after another 8s: $(read_regs)"
    is_gen2 || cbad=$((cbad + 1))

    if [ "${cbad}" = "0" ]; then
        ok "patch works independently: without the guard the link still holds Gen2"
        C_OK=1
    else
        err "patch insufficient: ${cbad} drops without the guard"
        C_OK=0
    fi

    echo "   re-loading the guard (safety net):"
    if insmod "${BUILD_DIR}/gen2kr.ko" 2>/dev/null; then
        echo "     gen2kr restored"
    else
        warn "failed to restore gen2kr"
    fi
}

# Summary
show_summary() {
    echo
    echo "======================================================"
    echo " Conclusion"
    echo "======================================================"
    echo "   A bandwidth         : $(status_text "${A_OK}" "${C_G}pass${C_0}" "${C_R}below target${C_0}")  pinned H2D=${BW_H2D:-?} D2H=${BW_D2H:-?}"
    echo "   B stability         : $(status_text "$([ "${B_BAD}" = "0" ] && echo 1 || echo 0)" "${C_G}pass${C_0}" "${C_R}${B_BAD} rounds dropped${C_0}")"
    if [ "${FULL}" = "1" ]; then
        echo "   C patch independence: $(status_text "${C_OK}" "${C_G}pass${C_0}" "${C_R}fail${C_0}")"
    fi
    echo "   link                : $(read_regs)"
    echo
    echo "   Xid check:"
    dmesg | grep -i 'Xid' | tail -3 | sed 's/^/     /' || echo "     none"
    echo "     (note: the r8169 NIC also reports XID; unrelated to the GPU)"
    echo "======================================================"
}

# ============================================================
# 3. main
# ============================================================
main() {
    parse_args "$@"

    need_root
    ensure_build auto || exit 1

    echo "======================================================"
    echo " Verify (${ROUNDS} rounds)"
    echo "======================================================"
    echo " starting point: $(read_regs)"

    check_bandwidth
    check_stability

    [ "${FULL}" = "1" ] && check_patch_independence

    show_summary
}

main "$@"
