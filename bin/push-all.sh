#!/bin/bash
# ============================================================
# push-all.sh — push SEVERAL P104 cards to Gen2 in one run, one card at a time
#
# ## Why this script exists
#   push.sh handles exactly one TARGET_BDF per invocation. With three identical
#   mining cards the operator had to run it by hand three times and keep track
#   of which card was in which state. The 2026-11-14 session proved how easy
#   that is to get wrong:
#     · card 04:00.0 got two pushes and ended Gen2 (CAP2=0x0006, LNKSTA=1042);
#     · cards 21:00.0 and 27:00.0 got exactly one push each and ended in the
#       "half-pushed" state: CAP2=0x0002 + TLS=1 + declaration bits written.
#   reports/198 measured that state as unrescuable (6 unbind/bind rounds and 9
#   unlock attempts all failed; hammering also risks TLS=3, and the measured
#   cure is a full reboot). A full reboot did exactly that -- it reset every
#   card to the factory state (measured 2026-11-15 07:11 on this server),
#   which is why this script REFUSES stuck cards and tells the operator to
#   reboot instead of hammering.
#
# ## What it does
#   1. classifies every listed card from its BAR0 fingerprint (read-only peek);
#   2. refuses unsafe states up front (stuck, dirty TLS=3, unknown, unreadable);
#   3. pushes only factory-clean cards, ONE AT A TIME, via push.sh --force
#      (one fresh gen2kr load per card, exactly like a hand-run push.sh);
#   4. after each push, watches the registers for up to ~2 minutes -- late
#      latches are finished by the resident guard (its debounce + retrain gates);
#   5. re-arms "latched-but-Gen1" cards (a previous push latched CAP2=0x0006 but
#      the link never rose): fresh gen2kr + one probe, then watch;
#   6. prints a per-card summary and leaves gen2kr resident -- the guard keeps
#      maintaining Gen2 under load, and its CAP2==0x0006 gate covers every P104.
#
# ## What it never does
#   · never rmmod/reload nvidia (the workload holds the cards; that module is
#     patched on disk and only a reboot installs it);
#   · never push a stuck or dirty card (the measured verdict is "reboot first");
#   · never start a second card's push while the first is still training (the
#     module serializes queued pushes; this script waits per card anyway).
#
# ## Usage
#   sudo -E bash bin/push-all.sh <BDF> [<BDF> ...]
#   sudo -E bash bin/push-all.sh --dry-run <BDF> ...   # classify + plan only, no writes
#   sudo -E bash bin/push-all.sh --yes <BDF> ...       # skip the confirm prompt
#
#   Example (this server):
#   sudo -E bash bin/push-all.sh 0000:04:00.0 0000:21:00.0 0000:27:00.0
#
# ## Per-card decision table (BAR0 fingerprint -> action)
#   CAP2=0x0006 TLS=2 CUR=2            DONE     (skip; nothing to do)
#   CAP2=0x0002 TLS=0|1 DECLSET=0      FACTORY  (push --force, then watch)
#   CAP2=0x0006 TLS=2 CUR=1            LATCHED  (re-arm: fresh gen2kr + one
#                                                 probe, then watch)
#   CAP2=0x0002 DECLSET=1 TLS=0|1      STUCK    (refuse -> reboot first)
#   TLS=3 (any CAP2)                   DIRTY    (refuse -> cold boot only)
#   anything else / unreadable BAR0    UNKNOWN  (refuse -> investigate)
#
# ## Why DECLSET uses bits 11+15 (mask 0x8800) of 0x8841C
#   The push writes bits 11 and 15 of PRIV_MISC_1; stock has neither set.
#   Measured on this server: stock 0xc0b46500 (& 0x8800 == 0), after a push
#   0xc0b4ad00 (& 0x8800 == 0x8800). (_common.sh's is_stuck() uses the wider
#   0xA800 mask, calibrated on the original machine whose stock value is
#   0xc0b40500; THIS machine's stock already has bit 13 set, so 0xA800 would
#   flag a clean card as stuck here.)
#
# ## Why this script does NOT source _common.sh
#   _common.sh pulls in bdf.sh, which on a multi-card machine hard-exits when
#   TARGET_BDF is unset, and its _BDF_SH_LOADED guard would pin DEV_BDF to the
#   first card for the rest of the loop. The only shared helper this script
#   needs is a read-only register read, duplicated below with the same
#   discipline as _common.sh (PROT_READ mmap; /dev/mem opened O_RDWR|O_SYNC).
# ============================================================
set -u

# ============================================================
# 1. Variables
# ============================================================
PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PKG_ROOT/build"
SYS_PCI="/sys/bus/pci/devices"
NVIDIA_DRV_SYS="/sys/bus/pci/drivers/nvidia"
MONITOR_SECONDS=120        # how long to watch a card after its push/re-arm
POLL_SECONDS=5

DRY_RUN=0
YES=0
BDFS=()
PLAN_CLASSES=()
PLAN_FPS=()
RESULTS=()
DETAILS=()
VERDICT=""                 # per-card outcome, set by run_card
DETAIL=""                   # human one-liner, set by run_card

# Colors (same convention as _common.sh: off when not a tty)
if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
    C_R=; C_G=; C_Y=; C_B=; C_0=
fi
ok()   { echo "${C_G}✓${C_0} $*"; }
warn() { echo "${C_Y}⚠${C_0} $*"; }
err()  { echo "${C_R}✗${C_0} $*"; }
hdr()  { echo; echo "${C_B}=== $* ===${C_0}"; }

trap 'err "interrupted -- if gen2kr was resident it stays resident (harmless: its guard only services cards with CAP2 latched)"; exit 130' INT TERM

# ============================================================
# 2. Register reads + classification
# ============================================================

# ---------- read one card's BAR0 fingerprint (read-only; never writes) ----------
# Prints: CAP2=<dec> TLS=<dec> CUR=<dec> DECLSET=<0|1> CFGSPD=<dec> MAXSPD=<dec>
# "?" fields mean the BAR0 read failed (card offline, or a training transient;
# 0xffffffff is exactly how an unread BAR0 shows up during a retrain).
read_fp() {
python3 - "$1" <<'PY'
import mmap, os, struct, sys
dev = sys.argv[1]
try:
    p = int(open('/sys/bus/pci/devices/%s/resource' % dev).readline().split()[0], 16)
    f = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, 0x1000000, mmap.MAP_SHARED, mmap.PROT_READ, offset=p)
    g = lambda o: struct.unpack_from('<I', m, o)[0]
    cap  = g(0x88084); cap2 = g(0x880A4); lsta = g(0x88088)
    ctl2 = g(0x880A8); cfg  = g(0x8841C); lc0  = g(0x8C040)
    m.close(); os.close(f)
    if 0xffffffff in (cap, cap2, lsta, ctl2, cfg, lc0):
        print("? ? ? ? ? ?")
    else:
        declset = 1 if (cfg & 0x8800) else 0   # bits 11|15 = the push's declaration
        print("%d %d %d %d %d %d" % (cap2, ctl2 & 0xF, (lsta >> 16) & 0xF,
                                     declset, (lc0 >> 18) & 3, cap & 0xF))
except Exception:
    print("? ? ? ? ? ?")
PY
}

# ---------- classify a fingerprint line (sets CLS + the CLS_* fields) ----------
classify() {
    local fp="$1"
    set -- ${fp}
    CLS_CAP2="${1:-?}"; CLS_TLS="${2:-?}"; CLS_CUR="${3:-?}"
    CLS_DECLSET="${4:-?}"; CLS_CFGSPD="${5:-?}"; CLS_MAXSPD="${6:-?}"
    if [ "${CLS_CAP2}" = "?" ]; then
        CLS="UNREADABLE"; return 0
    fi
    # TLS=3 first: dirty regardless of anything else, only a cold boot recovers
    if [ "${CLS_TLS}" = "3" ]; then
        CLS="DIRTY"; return 0
    fi
    if [ "${CLS_CAP2}" = "6" ]; then
        if [ "${CLS_TLS}" = "2" ] && [ "${CLS_CUR}" = "2" ]; then CLS="DONE"
        elif [ "${CLS_TLS}" = "2" ] && [ "${CLS_CUR}" = "1" ]; then CLS="LATCHED"
        else CLS="UNKNOWN"; fi   # e.g. latched vector with TLS=1: not a known state
        return 0
    fi
    if [ "${CLS_CAP2}" = "2" ]; then
        # The declaration was written but never latched = the reports/198 stuck
        # state (TLS clamped back to 0/1, link Gen1). Measured cure: full reboot.
        if [ "${CLS_DECLSET}" = "1" ]; then CLS="STUCK"
        elif [ "${CLS_TLS}" -le 1 ]; then CLS="FACTORY"
        else CLS="UNKNOWN"; fi
        return 0
    fi
    CLS="UNKNOWN"
}

# Human one-liners for the current fingerprint / class
fp_text() { echo "CAP2=${CLS_CAP2} TLS=${CLS_TLS} CUR=${CLS_CUR} DECLSET=${CLS_DECLSET} CFGSPD=${CLS_CFGSPD} MAXSPD=${CLS_MAXSPD}"; }
cls_text() {
    case "$1" in
        DONE)       echo "Gen2 (CAP2=0x0006 TLS=2 CUR=2)" ;;
        FACTORY)    echo "factory-clean (CAP2=0x0002 TLS=${CLS_TLS} decl-bits clear)" ;;
        LATCHED)    echo "latched-but-Gen1 (CAP2=0x0006 TLS=2 CUR=1)" ;;
        STUCK)      echo "stuck/half-pushed (CAP2=0x0002 TLS=${CLS_TLS} decl-bits SET)" ;;
        DIRTY)      echo "dirty TLS=3 (cold boot required)" ;;
        UNREADABLE) echo "BAR0 unreadable (offline or training transient)" ;;
        *)          echo "unknown fingerprint" ;;
    esac
}

# ============================================================
# 3. Gates
# ============================================================

# ---------- holders gate (the 2026-10-29 wedge makes this a hard block) ----------
check_idle() {
    local holders
    holders="$(fuser /dev/nvidia* 2>/dev/null | tr -s ' \n' ' ')"
    [ -z "${holders}" ] && return 0
    err "a process is using the GPU; unbind would wedge the kernel (reboot only)"
    echo "     holders:"
    fuser -v /dev/nvidia* 2>&1 | sed 's/^/       /'
    echo "     close these programs first (python/maya/browser/Electron are the usual culprits),"
    echo "     then re-run this script in the idle window."
    return 1
}

# ---------- startup gates (all read-only; exits 1 on failure) ----------
gate_environment() {
    local patch_state vmagic

    [ "$(id -u)" = "0" ] || { err "root required (sudo -E bash bin/push-all.sh ...)"; exit 1; }

    if ! lsmod | grep -q '^nvidia '; then
        err "nvidia is not loaded -- boot normally first (this script never reloads it)"
        exit 1
    fi
    ok "nvidia is loaded (this script will never touch the module)"

    patch_state="$(python3 "${PKG_ROOT}/bin/patch_no_gen1.py" check 2>/dev/null \
                   | grep -oE '\[not patched\]|\[patched\]')"
    case "${patch_state}" in
        "[patched]")
            ok "no-Gen1 patch is in place" ;;
        "[not patched]")
            err "patch is missing -- a push would just get downgraded by the driver again"
            echo "     run first: sudo bash bin/20-install.sh (it applies + reloads the module)"
            exit 1 ;;
        *)
            warn "cannot determine the patch state; continuing, but pushes may not stick" ;;
    esac

    if [ ! -f "${BUILD_DIR}/gen2kr.ko" ]; then
        err "build/gen2kr.ko is missing -> bash bin/build.sh"
        exit 1
    fi
    # ★ multi-GPU marker: the PLURAL "links" in the module description.
    #   2026-11-14 failure mode: the OLD single-GPU build was loaded, so only
    #   the first probed card ever got a push ("worked only for one card").
    if ! modinfo -d "${BUILD_DIR}/gen2kr.ko" 2>/dev/null | grep -q 'PCIe links'; then
        err "build/gen2kr.ko is the OLD single-GPU build (it pushes only one card)"
        echo "     rebuild: TARGET_BDF=0000:04:00.0 bash bin/build.sh"
        exit 1
    fi
    ok "gen2kr build = multi-GPU (modinfo -d mentions 'PCIe links')"

    vmagic="$(modinfo -F vermagic "${BUILD_DIR}/gen2kr.ko" 2>/dev/null | head -1)"
    case "${vmagic}" in
        "$(uname -r)"*)
            ok "gen2kr vermagic matches the running kernel (${vmagic%% *})" ;;
        "")
            err "cannot read gen2kr vermagic"; exit 1 ;;
        *)
            err "gen2kr was built for another kernel (${vmagic%% *}) -> rebuild: TARGET_BDF=<one card> bash bin/build.sh"
            exit 1 ;;
    esac

    if [ ! -x "${BUILD_DIR}/minictx" ] || [ ! -x "${BUILD_DIR}/bwtest2" ]; then
        err "probes missing in build/ (minictx / bwtest2) -> bash bin/build.sh"
        echo "     (push.sh refuses to run without them)"
        exit 1
    fi
}

# ---------- argument handling ----------
usage() {
    echo "usage: sudo -E bash bin/push-all.sh [--dry-run] [--yes] <BDF> [<BDF> ...]"
    echo "       <BDF> = one or more P104 PCIe addresses, e.g. 0000:04:00.0 0000:21:00.0 0000:27:00.0"
    echo "  P104-100 candidates on this machine:"
    local d
    for d in "${SYS_PCI}"/*; do
        [ -r "${d}/vendor" ] || continue
        [ "$(cat "${d}/vendor" 2>/dev/null)" = "0x10de" ] || continue
        case "$(cat "${d}/device" 2>/dev/null)" in
            0x1b87) echo "         $(basename "${d}")" ;;
        esac
    done
}

parse_args() {
    local a
    for a in "$@"; do
        case "${a}" in
            --dry-run) DRY_RUN=1 ;;
            --yes|-y)  YES=1 ;;
            --help|-h) usage; exit 0 ;;
            -*)        err "unknown flag: ${a}"; usage; exit 2 ;;
            *)         BDFS+=("${a,,}") ;;
        esac
    done
    [ "${#BDFS[@]}" -gt 0 ] || { err "no target cards given"; usage; exit 2; }
}

validate_bdfs() {
    local b dev vid did seen=""
    for b in "${BDFS[@]}"; do
        if ! [[ "${b}" =~ ^[0-9a-f]{4}(:[0-9a-f]{2}){2}\.[0-9a-f]+$ ]]; then
            err "not a PCIe BDF: ${b}"; usage; exit 2
        fi
        dev="${SYS_PCI}/${b}"
        if [ ! -d "${dev}" ]; then
            err "no such PCI device: ${b}"; usage; exit 2
        fi
        vid="$(cat "${dev}/vendor")"; did="$(cat "${dev}/device")"
        if [ "${vid}" != "0x10de" ] || [ "${did}" != "0x1b87" ]; then
            err "${b} is ${vid}:${did} -- this script only drives P104-100 (10de:1b87)"
            exit 2
        fi
        case " ${seen} " in
            *" ${b} "*) err "listed twice: ${b}"; exit 2 ;;
            *)          seen="${seen} ${b}" ;;
        esac
    done
}

# ============================================================
# 4. Per-card actions
# ============================================================

# ---------- watch one card after its push/re-arm ----------
# Sets VERDICT/DETAIL; the verdict is the contract:
#   DONE          the link reached Gen2
#   GUARD-WORKING latched (CAP2=0x0006) but still Gen1; the resident guard
#                 retrains every few seconds until the link rises
#   NEEDS-REBOOT  the hardware did not latch (stuck) or the link went dirty
#   UNKNOWN       fingerprint changed unexpectedly during the wait
#   FAILED        registers unchanged (the push never took) or unreadable
#                 throughout the watch
await_result() {
    local bdf="$1" fp mrc last

    AWAIT_DEADLINE=$(( $(date +%s) + MONITOR_SECONDS ))
    mrc=4
    last="?"
    while :; do
        fp="$(read_fp "${bdf}")"
        classify "${fp}"
        last="${CLS}"
        if [ "${CLS_CAP2}" = "6" ] && [ "${CLS_TLS}" = "2" ]; then
            # The push latched the declaration (CAP2=0x0006, TLS=2): the resident
            # guard owns this card from here on. CUR=2 = Gen2 (done); CUR=1 =
            # latched-but-Gen1 (still training); CUR=0 = the LNKSTA mirror reads
            # 0 for ~100ms during the guard's retrain -- same "keep watching".
            if [ "${CLS_CUR}" = "2" ]; then mrc=0; break; fi
            last="LATCHED"
        else
            case "${CLS}" in
                STUCK|DIRTY)
                    mrc=2; break ;;
                FACTORY)
                    mrc=4; break ;;                       # registers unchanged: the push never took
                UNREADABLE) ;;                            # a retrain transient; keep watching
                *)
                    mrc=3; break ;;                       # genuinely unknown fingerprint
            esac
        fi
        local t
        t="$(date +%s)"
        if [ "${t}" -ge "${AWAIT_DEADLINE}" ]; then
            # Timed out: only a card we saw latched counts as guard-work;
            # everything else is "never took".
            [ "${last}" = "LATCHED" ] && mrc=1
            break
        fi
        sleep "${POLL_SECONDS}"
    done

    case "${mrc}" in
        0) VERDICT="DONE";           DETAIL="link reached Gen2" ;;
        1) VERDICT="GUARD-WORKING";  DETAIL="latched (CAP2=0x0006) but still Gen1; the resident guard keeps training" ;;
        2) VERDICT="NEEDS-REBOOT";   DETAIL="hardware did not latch the declaration (reports/198 stuck state)" ;;
        3) VERDICT="UNKNOWN";        DETAIL="fingerprint changed unexpectedly during the wait" ;;
        *) VERDICT="FAILED";         DETAIL="registers unchanged after the push (or unreadable throughout the watch)" ;;
    esac
}
AWAIT_DEADLINE=0    # set inside await_result

# ---------- push one factory-clean card via push.sh ----------
do_push() {
    local bdf="$1" rc

    hdr "Pushing ${bdf} (push.sh --force; one fresh gen2kr load per card)"

    # ★ push.sh's own pre-check refuses this server's fresh-boot state: on the
    #   ORIGINAL machine "clean" means CAP2=0x0002 + TLS=1, but the patched
    #   driver never writes the Gen1 declaration at boot, so here the factory
    #   state boots with TLS=0. --force is therefore REQUIRED -- but it is
    #   never blind: the classifier above verified the full factory fingerprint
    #   (CAP2=0x0002 + TLS<=1 + decl-bits clear) immediately before this call.
    TARGET_BDF="${bdf}" bash "${PKG_ROOT}/bin/push.sh" --force
    rc=$?
    case "${rc}" in
        0) ;;   # push.sh's own wait saw Gen2 -- verified again below anyway
        1) VERDICT="STOPPED"; DETAIL="push.sh refused at the pre-check; nothing was written"; return 0 ;;
        2) warn "push.sh's 20s wait timed out; watching the registers a bit longer" ;;
        *) VERDICT="STOPPED"; DETAIL="push.sh exited ${rc}"; return 0 ;;
    esac

    await_result "${bdf}"
}

# ---------- re-arm one latched-but-Gen1 card ----------
do_rearm() {
    local bdf="$1"

    hdr "Re-arming ${bdf} (fresh gen2kr + one probe)"

    # Why a probe is mandatory: gen2kr only starts its guard from push_fn --
    # INIT_DELAYED_WORK at insmod never schedules the guard work, so a bare
    # insmod would attach the kretprobe and then just sit there. One probe =
    # one queued push of THIS card, measured safe on an already-latched card
    # (reports/201: push #2 started at cap2=00000006 and finished clean).
    if lsmod | grep -q '^gen2kr'; then
        rmmod gen2kr 2>/dev/null || { err "rmmod gen2kr failed"; VERDICT="STOPPED"; DETAIL="rmmod gen2kr failed"; return 0; }
        echo "   old gen2kr unloaded (the guard rebuilds its per-device state at insmod)"
    fi
    if ! insmod "${BUILD_DIR}/gen2kr.ko"; then
        err "insmod failed"; VERDICT="STOPPED"; DETAIL="insmod failed"; return 0
    fi
    echo "   loaded ${BUILD_DIR}/gen2kr.ko"
    sleep 1

    check_idle || { VERDICT="STOPPED"; DETAIL="a workload started holding /dev/nvidia*"; return 0; }
    echo "   unbind ..."
    if ! echo "${bdf}" > "${NVIDIA_DRV_SYS}/unbind"; then
        err "unbind failed"; VERDICT="STOPPED"; DETAIL="unbind write failed"; return 0
    fi
    sleep 1
    echo "   bind   ..."
    if ! echo "${bdf}" > "${NVIDIA_DRV_SYS}/bind"; then
        err "bind failed"; VERDICT="STOPPED"; DETAIL="bind write failed"; return 0
    fi

    await_result "${bdf}"
}

# ---------- classify + act on one card ----------
run_card() {   # $1 = BDF, $2 = planned class
    local bdf="$1" planned="$2" fp

    VERDICT=""; DETAIL=""

    if ! check_idle; then
        VERDICT="STOPPED"; DETAIL="a workload is holding /dev/nvidia*"
        return 0
    fi

    # Re-classify right before acting: the plan may be minutes old, and a
    # stale fingerprint could send the push to the wrong state.
    fp="$(read_fp "${bdf}")"
    classify "${fp}"
    if [ "${CLS}" != "${planned}" ]; then
        warn "${bdf}: state changed since the plan (${planned} -> ${CLS}); acting on the current state"
        if [ "${CLS}" = "UNREADABLE" ] || [ "${CLS}" = "UNKNOWN" ]; then
            VERDICT="REFUSED"; DETAIL="current fingerprint unreadable/unknown: $(fp_text)"
            return 0
        fi
    fi

    case "${CLS}" in
        DONE)
            VERDICT="DONE"; DETAIL="already Gen2 (nothing to do)" ;;
        FACTORY)
            do_push "${bdf}" ;;
        LATCHED)
            do_rearm "${bdf}" ;;
        STUCK)
            VERDICT="NEEDS-REBOOT"
            DETAIL="refused: half-pushed state (declaration written, CAP2 not latched, TLS=${CLS_TLS})" ;;
        DIRTY)
            VERDICT="NEEDS-REBOOT"; DETAIL="refused: TLS=3 dirty link state (cold boot required)" ;;
        *)
            VERDICT="REFUSED"; DETAIL="unknown fingerprint: $(fp_text)" ;;
    esac
}

# ============================================================
# 5. Plan + execution + summary
# ============================================================
plan_action() {   # $1 = class -> human action
    case "$1" in
        DONE)    echo "skip (already Gen2)" ;;
        FACTORY) echo "push --force, then watch up to ${MONITOR_SECONDS}s" ;;
        LATCHED) echo "re-arm (fresh gen2kr + one probe), then watch up to ${MONITOR_SECONDS}s" ;;
        STUCK)   echo "REFUSED (reports/198: only a full reboot cures)" ;;
        DIRTY)   echo "REFUSED (TLS=3; cold boot only)" ;;
        *)       echo "REFUSED (investigate first)" ;;
    esac
}

summary() {
    local i=0 done_cnt=0 bad_cnt=0 r

    hdr "Summary"
    for b in "${BDFS[@]}"; do
        printf '  %-14s %-13s %s\n' "${b}" "${RESULTS[i]:-not-run}" "${DETAILS[i]:-}"
        i=$((i+1))
    done

    for r in "${RESULTS[@]}"; do
        case "${r}" in
            DONE) done_cnt=$((done_cnt + 1)) ;;
            *)    bad_cnt=$((bad_cnt + 1)) ;;
        esac
    done

    if [ "${done_cnt}" -gt 0 ]; then
        ok "${done_cnt} card(s) at Gen2 -- verify bandwidth: build/bwtest2 512 15 | grep pinned   (~1.56 / 1.71 GB/s)"
    fi
    if lsmod | grep -q '^gen2kr'; then
        ok "gen2kr stays resident; its guard maintains Gen2 under load (the CAP2==0x0006 gate covers every P104)"
    fi
    if [ "${bad_cnt}" -gt 0 ]; then
        warn "${bad_cnt} card(s) did not reach Gen2 -- the measured cure is a full reboot:"
        echo "     a fresh boot resets every card to the factory state (measured 2026-11-15 07:11"
        echo "     on this server), so after rebooting re-run the SAME command -- it will then"
        echo "     push every listed card from the clean starting point, one at a time."
    fi
}

main() {
    parse_args "$@"
    gate_environment
    validate_bdfs

    # ---------- classification pass (read-only; safe under load) ----------
    hdr "Classifying ${#BDFS[@]} card(s) (read-only)"
    local i=0 b fp
    for b in "${BDFS[@]}"; do
        fp="$(read_fp "${b}")"
        classify "${fp}"
        PLAN_CLASSES[i]="${CLS}"
        PLAN_FPS[i]="$(fp_text)"
        printf '  %-14s %s\n         -> %s (%s) -- %s\n' \
            "${b}" "${PLAN_FPS[i]}" "${CLS}" "$(cls_text "${CLS}")" "$(plan_action "${CLS}")"
        i=$((i + 1))
    done

    # ---------- dry-run: plan only, nothing is written ----------
    if [ "${DRY_RUN}" = "1" ]; then
        if check_idle 2>/dev/null; then
            ok "the idle window is open right now"
        else
            warn "the GPUs are busy; the real run would refuse until they are released"
        fi
        hdr "Dry run -- nothing was written"
        exit 0
    fi

    # ---------- plan + confirm ----------
    local n_to_write=0 cls
    for cls in "${PLAN_CLASSES[@]}"; do
        case "${cls}" in
            FACTORY|LATCHED) n_to_write=$((n_to_write + 1)) ;;
        esac
    done

    if [ "${n_to_write}" = "0" ]; then
        # Nothing pushable: every listed card is DONE, refused, or unreadable.
        local rc=0 cls
        for cls in "${PLAN_CLASSES[@]}"; do
            case "${cls}" in
                DONE) ;;
                *) rc=2 ;;
            esac
        done
        if [ "${rc}" = "0" ]; then
            ok "every listed card is already at Gen2 -- nothing to do"
        else
            warn "no card can be pushed right now -- for the refused ones the measured cure is a full reboot:"
            echo "     a fresh boot resets every card to the factory state (measured 2026-11-15 07:11 on this"
            echo "     server), so after rebooting re-run the SAME command -- it will then push every listed"
            echo "     card from the clean starting point, one at a time."
        fi
        exit "${rc}"
    fi

    hdr "Plan"
    i=0
    for b in "${BDFS[@]}"; do
        printf '  %-14s %s -> %s\n' "${b}" "${PLAN_CLASSES[i]}" "$(plan_action "${PLAN_CLASSES[i]}")"
        i=$((i + 1))
    done
    echo "  ${n_to_write} card(s) will be written; the rest are skipped or refused."
    echo "  This must run in an IDLE window: no process may hold /dev/nvidia*"
    echo "  (unbind under load wedges the kernel; only a reboot cures it)."
    if ! check_idle; then
        err "refusing to continue -- the GPUs are busy right now"
        exit 3
    fi

    local ans=""
    printf '%s' "proceed with the writes? [y/N] "
    read -r ans || ans=""
    case "${ans}" in
        y|Y|yes|YES) ;;
        *) echo "aborted by the user"; exit 130 ;;
    esac

    # ---------- execute, one card at a time ----------
    hdr "Executing"
    i=0
    for b in "${BDFS[@]}"; do
        RESULTS[i]="NOT-RUN"; DETAILS[i]=""
        run_card "${b}" "${PLAN_CLASSES[i]}"
        RESULTS[i]="${VERDICT}"; DETAILS[i]="${DETAIL}"
        case "${VERDICT}" in
            STOPPED)
                err "stopping before the next card (conditions changed under our feet)"
                break ;;
        esac
        i=$((i + 1))
    done

    summary
    local rc=0 stop=0 r
    for r in "${RESULTS[@]}"; do
        [ "${r}" = "STOPPED" ] && stop=1
        case "${r}" in
            DONE) ;;
            *) rc=2 ;;
        esac
    done
    [ "${stop}" = "1" ] && rc=3
    exit "${rc}"
}

main "$@"
