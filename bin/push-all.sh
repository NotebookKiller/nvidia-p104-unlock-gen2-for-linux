#!/bin/bash
# ============================================================
# push-all.sh — push SEVERAL P104 cards to Gen2 in one run, in TWO passes,
#               one card at a time
#
# ## Why this script exists
#   push.sh handles exactly one TARGET_BDF per invocation. With three identical
#   mining cards the operator had to run it by hand and keep track of which
#   card was in which state -- and the 2026-11-14 version of THIS script got
#   that wrong in an instructive way: it gave every factory card ONE cycle and
#   then, watching the registers for 2 minutes, concluded "half-pushed,
#   incurable, reboot" for the cards that did not finish. The mechanism below
#   shows that conclusion was wrong on this machine: those cards were not
#   stuck, they were ARMED AND NEVER RE-PROBED -- and one more cycle finishes
#   each of them.
#
# ## The mechanism this script is built around (measured 2026-11-15)
#   journalctl of both boots of this server (3/3 cards) pins down what a push
#   actually does:
#     · a push only ARMS the card: it writes the declaration bits of 0x8841C
#       (0xc0b46500 -> 0xc0b4ad00), moves the endpoint TLS to 2, the root-port
#       TLS2 to 2 + Retrain, XVE_OVR=6 and the [fast] hook's SPEED=1 write --
#       but CAP2 (0x880A4) does NOT latch during that cycle;
#     · CAP2 latches ONLY at the card's NEXT probe: nv_pci_probe re-inits the
#       link and re-samples the downstream announcement, and only then does
#       CAP2 flip to 0x0006. At that latch probe the driver trains Gen1
#       first; the [fast] hook + push + the resident guard's staged retrains
#       (stage interval 150ms) then complete Gen2 ~2s later;
#     · the guard cannot help an armed-unlatched card: its gate is
#       CAP2==0x0006, so a card with CAP2=0x0002 + declaration bits set is
#       simply ignored until the next probe.
#   => a factory card needs exactly TWO cycles (arm, then latch); a card that
#      is already armed-unlatched needs ONE. The old verdict "armed-unlatched
#      is incurable, only a reboot cures" is OVERTURNED on this machine: the
#      2026-11-14 leftover cards were armed-unlatched simply because nothing
#      ever re-probed them (reports/198's "incurable" claim was measured on
#      the original machine, whose stuck state behaves differently).
#   The proven cure, measured on this server 2026-11-15 11:26-11:30: two full
#   cycles per card via 20-install.sh -- cycles 1-3 armed cards 04/21/27,
#   cycles 4-6 latched them (the guard fired at the latch probe and finished
#   Gen2 ~2s later); all 3 ended Gen2. This script reproduces exactly that
#   flow with push.sh --force (one fresh gen2kr load + one probe per cycle):
#
#     pass 1: one cycle per card -- FACTORY -> arm cycle,
#             ARMED / LATCHED -> latch cycle, DONE -> skip;
#     pass 2: only the cards still unfinished after pass 1 -> one more cycle
#             each (a factory card that just got armed gets its latch cycle;
#             an armed-unlatched card that ignored its first latch cycle gets
#             a retry; a card whose push never took gets a fresh arm cycle).
#             Max 2 cycles per card, NO third pass: the latch is
#             probe-triggered and deterministic, so a card that ignored both
#             latch cycles is wedged and only a reboot cures it.
#
# ## What it does
#   1. classifies every listed card from its BAR0 fingerprint (read-only peek);
#   2. refuses unsafe states up front (dirty TLS=3, unknown, unreadable);
#   3. runs pass 1, one card at a time, each cycle = push.sh --force
#      (one fresh gen2kr load per card, exactly like a hand-run push.sh);
#   4. after each cycle, watches the registers -- pass-aware: after an arm
#      cycle the expected state IS armed-unlatched, not an error;
#   5. pauses ~45s (the pause also lets the guard finish latched-but-Gen1
#      cards; pass 2 re-classifies and skips anything that reached Gen2),
#      then runs pass 2 for the cards still unfinished;
#   6. prints a per-card summary and leaves gen2kr resident -- the guard keeps
#      maintaining Gen2 under load, and its CAP2==0x0006 gate covers every P104.
#
# ## What it never does
#   · never rmmod/reload nvidia (the workload holds the cards; that module is
#     patched on disk and only a reboot installs it; gen2kr may be rmmod'ed
#     and insmod'ed freely -- every cycle does exactly that);
#   · never push a dirty TLS=3 card (only a cold boot recovers from TLS=3);
#   · never hammer: at most 2 cycles per card, one push per cycle, no
#     repeated-write loops -- the TLS=3-producing failure mode of write
#     hammering stays out of reach;
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
#   The card states left behind by the 2026-11-14 version of this script
#   (armed-unlatched, back then classified "stuck") are FINISHABLE here:
#   they classify ARMED and pass 1's single latch cycle completes them.
#
# ## Per-card decision table (BAR0 fingerprint -> action)
#   CAP2=0x0006 TLS=2 CUR=2           DONE     (skip; nothing to do)
#   CAP2=0x0002 TLS=0|1 DECLSET=0     FACTORY  (arm cycle, then latch cycle)
#   CAP2=0x0006 TLS=2 CUR=1           LATCHED  (latch cycle: fresh gen2kr + one
#                                              probe -- reports/201 measured
#                                              push #2 on an already-latched
#                                              card finishing clean)
#   CAP2=0x0002 DECLSET=1 TLS=0|1|2   ARMED    (latch cycle; a second latch
#                                              cycle follows if still
#                                              unlatched; then NEEDS-REBOOT)
#   TLS=3 (any CAP2)                  DIRTY    (refuse -> cold boot only)
#   anything else / unreadable BAR0   UNKNOWN  (refuse -> investigate)
#
# ## Final verdicts (after both passes)
#   DONE          link at Gen2
#   GUARD-WORKING latched (CAP2=0x0006) but still Gen1; the resident guard
#                 finishes it (re-check with bin/peek-regs.py)
#   NOT-LATCHED   armed-unlatched and never latch-cycled (its cycles were
#                 consumed by arming or the push never took) -> RE-RUN the
#                 SAME command; one cycle will finish it
#   NEEDS-REBOOT  armed-unlatched even after a latch cycle (wedged), or dirty
#                 TLS=3 -> reboot (a fresh boot resets every card to the
#                 factory state), then re-run the SAME command
#   FAILED        registers unchanged after a cycle (the push never took) ->
#                 re-run the SAME command
#   UNKNOWN / REFUSED / STOPPED   investigate / refused up front / aborted
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
MONITOR_SECONDS=120        # how long to watch a card after its cycle
POLL_SECONDS=5
INTERPASS_PAUSE=45         # settle time between pass 1 and pass 2
ARM_CONFIRM=2              # consecutive ARMED reads before trusting the mid-state
FACTORY_CONFIRM=3          # consecutive FACTORY reads before "the push never took"

DRY_RUN=0
YES=0
BDFS=()
PLAN_CLASSES=()
PLAN_FPS=()
RESULTS=()
DETAILS=()
FINALS=()
FINAL_DETAILS=()
LATCH_TRIED=()             # per card: 1 once a latch cycle has run
VERDICT=""                 # per-cycle outcome, set by await_result
DETAIL=""                  # human one-liner, set by await_result
CUR_ACT=""                 # what run_card did: arm|latch|skip|refuse

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
        # The declaration was written but CAP2 never latched = armed-unlatched.
        # NOT stuck: the latch happens at the card's NEXT probe, so one more
        # cycle finishes this card (measured 2026-11-15, 3/3 cards). The old
        # 2026-11-14 "incurable" verdict was an artifact of never re-probing.
        if [ "${CLS_DECLSET}" = "1" ]; then CLS="ARMED"
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
        ARMED)      echo "armed-unlatched (CAP2=0x0002 TLS=${CLS_TLS} decl-bits SET; latches at the NEXT probe)" ;;
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

# ---------- watch one card after its cycle ----------
# await_result <kind> <bdf>          kind = "arm" | "latch"
#
# Kind-aware; sets VERDICT/DETAIL. The verdict is the contract:
#   DONE          the link reached Gen2
#   GUARD-WORKING latched (CAP2=0x0006) but still Gen1 at the end of the watch;
#                 the resident guard retrains until the link rises
#   NOT-LATCHED   armed-unlatched (CAP2=0x0002 + declaration bits set). After
#                 an arm cycle this is the EXPECTED mid-state (the latch
#                 happens at the card's NEXT probe -- the next pass supplies
#                 it); after a latch cycle it means the latch was skipped or
#                 wedged (the caller retries once, then reports NEEDS-REBOOT)
#   NEEDS-REBOOT  the link went dirty (TLS=3) during the watch
#   UNKNOWN       fingerprint changed unexpectedly during the watch
#   FAILED        registers unchanged (the push never took) or unreadable
#                 throughout the watch
await_result() {
    local kind="$1" bdf="$2" fp t arm_seen=0 factory_seen=0

    AWAIT_DEADLINE=$(( $(date +%s) + MONITOR_SECONDS ))
    local mrc=99 last="?"
    while :; do
        fp="$(read_fp "${bdf}")"
        classify "${fp}"
        last="${CLS}"
        if [ "${CLS_CAP2}" = "6" ] && [ "${CLS_TLS}" = "2" ]; then
            # Latched: the resident guard owns this card from here on.
            # CUR=2 = Gen2 (done); CUR=1 = still training; CUR=0 = the LNKSTA
            # mirror reads 0 for ~100ms during the guard's retrain -- same
            # "keep watching".
            if [ "${CLS_CUR}" = "2" ]; then mrc=0; break; fi
            last="LATCHED"
        else
            case "${CLS}" in
                ARMED)
                    # armed-unlatched: the latch happens at the NEXT probe,
                    # never during this cycle's own retrain
                    if [ "${kind}" = "arm" ]; then
                        arm_seen=$((arm_seen + 1))
                        [ "${arm_seen}" -ge "${ARM_CONFIRM}" ] && { mrc=5; break; }
                    else
                        mrc=5; break   # latch cycle: break early; caller retries/finalizes
                    fi ;;
                DIRTY) mrc=2; break ;;
                FACTORY)
                    # declaration bits gone again = the push never took
                    factory_seen=$((factory_seen + 1))
                    [ "${factory_seen}" -ge "${FACTORY_CONFIRM}" ] && { mrc=4; break; }
                    ;;
                UNREADABLE) ;;               # a retrain transient; keep watching
                *)     mrc=3; break ;;       # genuinely unknown fingerprint
            esac
        fi
        t="$(date +%s)"
        [ "${t}" -ge "${AWAIT_DEADLINE}" ] && break
        sleep "${POLL_SECONDS}"
    done

    if [ "${mrc}" = "99" ]; then         # timed out without a decisive read
        if [ "${last}" = "LATCHED" ]; then mrc=1
        elif [ "${arm_seen}" -gt 0 ]; then mrc=5
        else                               mrc=4
        fi
    fi

    case "${mrc}" in
        0) VERDICT="DONE";          DETAIL="link reached Gen2" ;;
        1) VERDICT="GUARD-WORKING"; DETAIL="latched (CAP2=0x0006) but still Gen1 after ${MONITOR_SECONDS}s; the resident guard keeps training" ;;
        2) VERDICT="NEEDS-REBOOT";  DETAIL="link went dirty (TLS=3) during the watch" ;;
        3) VERDICT="UNKNOWN";       DETAIL="fingerprint changed unexpectedly during the watch" ;;
        4) VERDICT="FAILED";        DETAIL="registers unchanged after the cycle (the push never took), or unreadable throughout the watch" ;;
        *) VERDICT="NOT-LATCHED";   DETAIL="armed-unlatched (CAP2=0x0002 + decl-bits set): CAP2 latches at the NEXT probe, not during this cycle" ;;
    esac
}
AWAIT_DEADLINE=0    # set inside await_result

# ---------- run one push.sh cycle on one card ----------
# do_cycle <bdf> <kind>          kind = "arm" | "latch" (only affects the watch)
#
# One cycle = exactly the proven 20-install.sh per-card flow:
#   rmmod gen2kr + insmod gen2kr + one nv_pci_probe (unbind/bind) + wait,
#   which is what push.sh --force does; the kretprobe fires at the probe and
#   gen2kr pushes the card there.
do_cycle() {
    local bdf="$1" kind="$2" rc

    if [ "${kind}" = "arm" ]; then
        hdr "Arming ${bdf} (cycle 1 of 2 for a factory card: push.sh --force)"
    else
        hdr "Latch cycle for ${bdf} (push.sh --force; CAP2 latches at THIS probe)"
    fi

    # ★ --force is REQUIRED but never blind: push.sh's own pre-check refuses
    #   this server's fresh-boot state (on the ORIGINAL machine "clean" means
    #   CAP2=0x0002 + TLS=1, but the patched driver never writes the Gen1
    #   declaration at boot, so here the factory state boots with TLS=0) and
    #   refuses armed/latched cards as "dirty". The classifier verified the
    #   full fingerprint immediately before this call, so --force only skips a
    #   check this script already made itself.
    #   (push.sh's rc=2 advice -- "CAP2 stays pinned => reboot, do not keep
    #   retrying" -- is generic; the pass structure of THIS script replaces
    #   it: an arm cycle is SUPPOSED to leave the link at Gen1.)
    TARGET_BDF="${bdf}" bash "${PKG_ROOT}/bin/push.sh" --force
    rc=$?
    case "${rc}" in
        0) ;;   # push.sh's own wait saw Gen2 -- verified again below anyway
        1) VERDICT="STOPPED"; DETAIL="push.sh refused at its pre-check; nothing was written"; return 0 ;;
        2) ;;   # the link stayed Gen1: EXPECTED for an arm cycle, and possible
                # for a latch cycle whose guard retrains outlast push.sh's 20s
                # wait -- await_result decides
        *) VERDICT="STOPPED"; DETAIL="push.sh exited ${rc}"; return 0 ;;
    esac

    await_result "${kind}" "${bdf}"
}

# ---------- classify + act on one card ----------
# run_card <bdf> <planned>       planned = "" suppresses the change warning
#
# The ACTION follows the CURRENT class, not the plan -- that is what makes
# both passes safe: in pass 2 a card armed by pass 1 is ARMED and gets its
# latch cycle; a card whose push never took is still FACTORY and gets a fresh
# arm cycle. Sets CUR_ACT so the caller can record whether this card has had
# a latch cycle.
run_card() {
    local bdf="$1" planned="$2" fp

    VERDICT=""; DETAIL=""; CUR_ACT=""

    if ! check_idle; then
        VERDICT="STOPPED"; DETAIL="a workload is holding /dev/nvidia*"
        return 0
    fi

    # Re-classify right before acting: the plan may be minutes old, and a
    # stale fingerprint could send the cycle to the wrong state.
    fp="$(read_fp "${bdf}")"
    classify "${fp}"
    if [ -n "${planned}" ] && [ "${CLS}" != "${planned}" ]; then
        warn "${bdf}: state changed since the plan (${planned} -> ${CLS}); acting on the current state"
    fi
    case "${CLS}" in
        UNREADABLE|UNKNOWN)
            CUR_ACT="refuse"
            VERDICT="REFUSED"; DETAIL="current fingerprint unreadable/unknown: $(fp_text)"
            return 0 ;;
    esac

    case "${CLS}" in
        DONE)
            CUR_ACT="skip"
            VERDICT="DONE"; DETAIL="already Gen2 (nothing to do)" ;;
        FACTORY)
            CUR_ACT="arm"
            do_cycle "${bdf}" arm ;;
        ARMED|LATCHED)
            CUR_ACT="latch"
            do_cycle "${bdf}" latch ;;
        DIRTY)
            CUR_ACT="refuse"
            VERDICT="NEEDS-REBOOT"
            DETAIL="refused: TLS=3 dirty link state (cold boot required)" ;;
        *)
            CUR_ACT="refuse"
            VERDICT="REFUSED"; DETAIL="unknown fingerprint: $(fp_text)" ;;
    esac
}

# ============================================================
# 5. Plan + execution + summary
# ============================================================
plan_action() {   # $1 = class -> human action
    case "$1" in
        DONE)    echo "skip (already Gen2)" ;;
        FACTORY) echo "arm cycle, then latch cycle (2 cycles, one per pass)" ;;
        ARMED)   echo "latch cycle (a retry cycle follows if still unlatched; then reboot)" ;;
        LATCHED) echo "latch cycle (fresh gen2kr + one probe; reports/201 measured this safe)" ;;
        DIRTY)   echo "REFUSED (TLS=3; cold boot only)" ;;
        *)       echo "REFUSED (investigate first)" ;;
    esac
}

summary() {
    local i done_cnt=0 rerun_cnt=0 reboot_cnt=0 guard_cnt=0 f

    hdr "Summary"
    for ((i=0; i<${#BDFS[@]}; i++)); do
        printf '  %-14s %-13s %s\n' "${BDFS[i]}" "${FINALS[i]:-NOT-RUN}" "${FINAL_DETAILS[i]:-}"
        case "${FINALS[i]:-}" in
            DONE)               done_cnt=$((done_cnt + 1)) ;;
            NOT-LATCHED|FAILED) rerun_cnt=$((rerun_cnt + 1)) ;;
            NEEDS-REBOOT)       reboot_cnt=$((reboot_cnt + 1)) ;;
            GUARD-WORKING)      guard_cnt=$((guard_cnt + 1)) ;;
        esac
    done

    if [ "${done_cnt}" -gt 0 ]; then
        ok "${done_cnt} card(s) at Gen2 -- verify bandwidth: build/bwtest2 512 15 | grep pinned   (~1.56 / 1.71 GB/s)"
    fi
    if [ "${guard_cnt}" -gt 0 ]; then
        warn "${guard_cnt} card(s) latched but still training -- the resident guard finishes them;"
        echo "     re-check in a minute:  DEV_BDF=<bdf> python3 bin/peek-regs.py   (CAP2 should be 0x00000006)"
    fi
    if lsmod | grep -q '^gen2kr'; then
        ok "gen2kr stays resident; its guard maintains Gen2 under load (the CAP2==0x0006 gate covers every P104)"
    fi
    if [ "${rerun_cnt}" -gt 0 ]; then
        warn "${rerun_cnt} card(s) still need one more cycle -- re-run the SAME command:"
        echo "     an armed-unlatched card is finished by ONE latch cycle (the latch happens"
        echo "     at the card's next probe); a card whose push never took gets 2 fresh cycles."
    fi
    if [ "${reboot_cnt}" -gt 0 ]; then
        warn "${reboot_cnt} card(s) need a full reboot -- a fresh boot resets every card to the"
        echo "     factory state (measured 2026-11-15 07:11 on this server), so after rebooting"
        echo "     re-run the SAME command -- it will then push every listed card from the clean"
        echo "     starting point, one at a time."
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
            FACTORY|ARMED|LATCHED) n_to_write=$((n_to_write + 1)) ;;
        esac
    done

    if [ "${n_to_write}" = "0" ]; then
        # Nothing pushable: every listed card is DONE, refused, or unreadable.
        local rc=0
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
    echo "  ${n_to_write} card(s) will be written in pass 1; the rest are skipped or refused."
    echo "  A card still unfinished after pass 1 gets ONE more cycle in pass 2 (max 2 per card)."
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

    # ---------- pass 1: one cycle per card ----------
    hdr "Pass 1 -- one cycle per card"
    local stopped=0
    for ((i=0; i<${#BDFS[@]}; i++)); do
        RESULTS[i]="NOT-RUN"; DETAILS[i]=""; LATCH_TRIED[i]=0
        FINALS[i]="NOT-RUN"; FINAL_DETAILS[i]=""
    done
    for ((i=0; i<${#BDFS[@]}; i++)); do
        b="${BDFS[i]}"
        run_card "${b}" "${PLAN_CLASSES[i]}"
        [ "${CUR_ACT}" = "latch" ] && LATCH_TRIED[i]=1
        RESULTS[i]="${VERDICT}"; DETAILS[i]="${DETAIL}"
        printf '  %-14s %s -- %s\n' "${b}" "${VERDICT}" "${DETAIL}"
        case "${VERDICT}" in
            STOPPED)
                err "stopping before the next card (conditions changed under our feet)"
                stopped=1
                break ;;
        esac
    done

    # ---------- pass 2: only the cards still unfinished after pass 1 ----------
    local n2=0
    if [ "${stopped}" = "0" ]; then
        for ((i=0; i<${#BDFS[@]}; i++)); do
            case "${RESULTS[i]}" in
                NOT-LATCHED|FAILED|GUARD-WORKING) n2=$((n2 + 1)) ;;
            esac
        done
    fi

    if [ "${n2}" -gt 0 ] && [ "${stopped}" = "0" ]; then
        echo
        echo "  pass 1 left ${n2} card(s) unfinished; settling ${INTERPASS_PAUSE}s"
        echo "  (the pause also gives the guard time to finish latched-but-Gen1 cards;"
        echo "   pass 2 re-classifies and skips anything that reached Gen2 meanwhile)"
        sleep "${INTERPASS_PAUSE}"

        hdr "Pass 2 -- one more cycle per unfinished card"
        for ((i=0; i<${#BDFS[@]}; i++)); do
            case "${RESULTS[i]}" in
                NOT-LATCHED|FAILED|GUARD-WORKING) ;;
                *) continue ;;
            esac
            b="${BDFS[i]}"
            run_card "${b}" ""
            [ "${CUR_ACT}" = "latch" ] && LATCH_TRIED[i]=1
            RESULTS[i]="${VERDICT}"; DETAILS[i]="${DETAIL}"
            printf '  %-14s %s -- %s\n' "${b}" "${VERDICT}" "${DETAIL}"
            case "${VERDICT}" in
                STOPPED)
                    err "stopping (conditions changed under our feet)"
                    stopped=1
                    break ;;
            esac
        done
    fi

    # ---------- final verdicts ----------
    hdr "Final verdicts"
    for ((i=0; i<${#BDFS[@]}; i++)); do
        case "${RESULTS[i]}" in
            DONE)
                FINALS[i]="DONE"; FINAL_DETAILS[i]="${DETAILS[i]}" ;;
            GUARD-WORKING)
                FINALS[i]="GUARD-WORKING"; FINAL_DETAILS[i]="${DETAILS[i]}" ;;
            NOT-LATCHED)
                if [ "${LATCH_TRIED[i]}" = "1" ]; then
                    FINALS[i]="NEEDS-REBOOT"
                    FINAL_DETAILS[i]="armed-unlatched even after a latch cycle -- wedged; reboot, then re-run"
                else
                    FINALS[i]="NOT-LATCHED"
                    FINAL_DETAILS[i]="armed (declaration written), never latch-cycled -- re-run the SAME command"
                fi ;;
            FAILED)
                FINALS[i]="FAILED"
                FINAL_DETAILS[i]="the push never took (registers unchanged) -- re-run the SAME command" ;;
            NEEDS-REBOOT|UNKNOWN|REFUSED|STOPPED)
                FINALS[i]="${RESULTS[i]}"; FINAL_DETAILS[i]="${DETAILS[i]}" ;;
            *)
                FINALS[i]="NOT-RUN"; FINAL_DETAILS[i]="" ;;
        esac
    done

    summary

    local rc=0 f
    for f in "${FINALS[@]}"; do
        case "${f}" in
            DONE) ;;
            *)    rc=2 ;;
        esac
    done
    [ "${stopped}" = "1" ] && rc=3
    exit "${rc}"
}

main "$@"
