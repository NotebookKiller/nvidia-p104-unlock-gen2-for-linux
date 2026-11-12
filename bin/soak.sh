#!/bin/bash
# soak.sh — long-run stability verification (30 minutes by default)
#
# Purpose (reports/197 §8 backlog)
#   The guard has been verified for a single recovery in 3.84s and bandwidth
#   1.56/1.71. But "does performance degrade after dozens of downgrade-recover
#   cycles" was never measured. This script loops over:
#       create a CUDA context (triggers a downgrade) -> wait for recovery ->
#       record the duration -> measure bandwidth periodically
#   and checks on every round:
#       · whether LNKSTA really returned to Gen2
#       · whether the device still answers (only 20 consecutive 0xffffffff
#         readings count as dead)
#       · whether new Xids appeared
#       · whether the recovery time grows over rounds (a degradation trend)
#
# ★ Uses read-only MMIO + gen2kr's own actions only; **no user-space MMIO
#   writes at all**
#   (reports/197: a user-space write to 0x8C040 killed 2/2 devices while the
#   link was dynamic)
#
# Usage: bash soak.sh [minutes] [per-round gap seconds]
# Log: /tmp/log-soak-<time>.log (reason explained in the comment below)
set -u
MIN="${1:-30}"
GAP="${2:-3}"
D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# ★ The log goes to /tmp by default: this script runs as root (it reads
#   /dev/mem), and if the repo sits on NFS (root_squash), root cannot write
#   into the repo directory. Copy the log back into logs/ when done.
LOGF="/tmp/log-soak-$(date +%Y%m%d-%H%M%S).log"

lnk() {
python3 - <<'PY'
import mmap,os,struct
try:
    p=int(open('/sys/bus/pci/devices/%s/resource' % os.environ.get('DEV_BDF', '0000:01:00.0')).readline().split()[0],16)
    f=os.open('/dev/mem',os.O_RDWR|os.O_SYNC)
    m=mmap.mmap(f,0x1000000,mmap.MAP_SHARED,mmap.PROT_READ,offset=p)
    v=struct.unpack_from('<I',m,0x8C040)[0]
    l=struct.unpack_from('<I',m,0x88088)[0]
    c=struct.unpack_from('<I',m,0x880A4)[0]
    m.close(); os.close(f)
    print((l>>16)&0xF, (v>>18)&3, f"{c:04x}")
except Exception:
    print("15 3 dead")
PY
}

# only 20 consecutive 0xffffffff readings count as dead (retrain transients are normal)
alive() {
  local bad=0
  for i in $(seq 1 20); do
    read -r SP _ _ <<<"$(lnk)"
    if [ "$SP" = "15" ]; then bad=$((bad+1)); else return 0; fi
    sleep 0.05
  done
  return 1
}

log() { echo "$*" | tee -a "$LOGF"; }

log "================ soak start $(date '+%F %T') ================"
log "duration ${MIN} minutes, per-round gap ${GAP}s"
log "kernel: $(uname -r)   gen2kr parameters:"
for p in stage_gap_ms debounce_cnt retrain_min_ms speed_settle_ms guard_period_ms allow_busy_retrain; do
  log "  $p = $(cat /sys/module/gen2kr/parameters/$p 2>/dev/null || echo N/A)"
done
log ""
printf '%-5s %-9s %-8s %-7s %-6s %-6s %s\n' round time recover link SPEED LCAP2 Xid | tee -a "$LOGF"

XID0=$(dmesg | grep -c "Xid" || true)
log "starting Xid count: $XID0"
log ""

END=$(( $(date +%s) + MIN * 60 ))
N=0
FAIL=0
MAXT=0
SUMT=0

while [ "$(date +%s)" -lt "$END" ]; do
  N=$((N + 1))

  # the starting point must be Gen2, otherwise wait first
  ready=0
  for i in $(seq 1 40); do
    read -r SP _ _ <<<"$(lnk)"
    [ "$SP" = "2" ] && { ready=1; break; }
    sleep 0.25
  done
  if [ "$ready" = "0" ]; then
    log "$(printf '%-5s %-9s %-8s %-7s' "$N" "$(date +%H:%M:%S)" "-" "not Gen2 at start")"
    FAIL=$((FAIL + 1))
    if ! alive; then log "  ★★ device lost; aborting the soak"; break; fi
    sleep "$GAP"; continue
  fi

  # trigger a downgrade and time it
  T0=$(date +%s.%N)
  "$D/build/minictx" 1 >/dev/null 2>&1
  GOT=""
  for i in $(seq 1 250); do    # up to 50s
    read -r SP SD CP <<<"$(lnk)"
    if [ "$SP" = "2" ]; then
      GOT=$(python3 -c "print(f'{$(date +%s.%N)-$T0:.2f}')")
      break
    fi
    if [ "$SP" = "15" ]; then
      if ! alive; then
        log "  ★★ round $N: device lost (20 consecutive ffffffff); aborting"
        GOT="DEAD"; break
      fi
    fi
    sleep 0.2
  done

  XID=$(dmesg | grep -c "Xid" || true)
  XIDN=$((XID - XID0))

  if [ "$GOT" = "DEAD" ]; then break; fi
  if [ -z "$GOT" ]; then
    log "$(printf '%-5s %-9s %-8s %-7s %-6s %-6s %s' "$N" "$(date +%H:%M:%S)" ">50s" "$SP" "$SD" "$CP" "$XIDN")"
    FAIL=$((FAIL + 1))
  else
    log "$(printf '%-5s %-9s %-8s %-7s %-6s %-6s %s' "$N" "$(date +%H:%M:%S)" "${GOT}s" "$SP" "$SD" "$CP" "$XIDN")"
    SUMT=$(python3 -c "print($SUMT + $GOT)")
    MAXT=$(python3 -c "print(max($MAXT, $GOT))")
  fi

  # measure bandwidth every 10 rounds (256MB: less likely to land inside the recovery window than 128)
  if [ $((N % 10)) -eq 0 ]; then
    for i in $(seq 1 40); do
      read -r SP _ _ <<<"$(lnk)"
      [ "$SP" = "2" ] && break
      sleep 0.25
    done
    BW=$("$D/build/bwtest2" 256 8 2>&1 | grep -E "pinned" | head -1)
    log "      [round $N bandwidth] $BW"
  fi

  sleep "$GAP"
done

log ""
log "================ summary ================"
OK=$((N - FAIL))
log "total rounds $N   succeeded $OK   failed $FAIL"
if [ "$OK" -gt 0 ]; then
  log "average recovery $(python3 -c "print(f'{$SUMT/$OK:.2f}')")s   slowest ${MAXT}s"
fi
XIDF=$(dmesg | grep -c "Xid" || true)
log "Xid: start $XID0 -> end $XIDF (new: $((XIDF - XID0)))"
read -r SP SD CP <<<"$(lnk)"
log "final: LNKSTA[3:0]=$SP  SPEED=$SD  LCAP2=$CP"
log "ended at $(date '+%F %T')"
log "log: $LOGF"
