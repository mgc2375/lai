#!/usr/bin/env bash
# memguard.sh — aggressive memory manager for running lai on a 32 GB live box.
#
# While it runs it:
#   * adds swap on a data disk (SWAP_DEV, e.g. sdb) — a swap partition if one exists, else a swapfile on a Linux fs there,
#   * caps lai's process tree at a soft RAM limit (cgroup v2 memory.high) so the
#     kernel pushes it to swap before the system runs out,
#   * ramps vm.swappiness up as RAM fills (gentle under ~22 GB, maximal near the
#     cap) and makes the kernel reclaim earlier,
#   * drops clean page cache after the machine has been idle a while.
#
# Root only. Started by install.sh with --memguard, or by hand:
#   sudo LAI_PID=<pid of lai> tools/memguard.sh
#
# Tunables (env): SOFT_CAP_GB=29 RAMP_START_GB=22 IDLE_MIN=8 SWAP_SIZE=24G
#   SWAP_DEV=sdb  SWAP_DIR=<a writable dir on that disk>  INTERVAL=10
set -u

SOFT_CAP_GB="${SOFT_CAP_GB:-29}"
RAMP_START_GB="${RAMP_START_GB:-22}"
IDLE_MIN="${IDLE_MIN:-8}"
SWAP_SIZE="${SWAP_SIZE:-24G}"
SWAP_DEV="${SWAP_DEV:-}"
INTERVAL="${INTERVAL:-10}"
LAI_PID="${LAI_PID:-0}"

log() { printf '[memguard] %s\n' "$*"; }
die() { printf '[memguard] error: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "must run as root (sudo)"

SWAPFILE=""
CGROUP="/sys/fs/cgroup/lai.memguard"
ORIG_SWAPPINESS="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)"
ORIG_WATERMARK="$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null || echo 10)"

cleanup() {
  log "stopping; restoring settings"
  # turn our swapfile off but KEEP it, so the next run reuses it instead of rebuilding
  [ -n "$SWAPFILE" ] && swapoff "$SWAPFILE" 2>/dev/null || true
  echo "$ORIG_SWAPPINESS" > /proc/sys/vm/swappiness 2>/dev/null || true
  echo "$ORIG_WATERMARK" > /proc/sys/vm/watermark_scale_factor 2>/dev/null || true
  [ -d "$CGROUP" ] && rmdir "$CGROUP" 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM EXIT

# ---- swap on a disk (swapfile, or an existing swap partition) ----
setup_swap() {
  # SWAP_DIR given (e.g. the persistence partition): put the swapfile right there
  if [ -n "${SWAP_DIR:-}" ]; then
    local f="$SWAP_DIR/lai.swap"
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$f"; then
      log "swapfile already active: $f"; return
    fi
    if [ -f "$f" ]; then                      # created on a previous boot: just turn it on
      swapon "$f" 2>/dev/null && { log "reusing swapfile $f"; return; }
    fi
    local fst; fst="$(findmnt -nro FSTYPE --target "$SWAP_DIR" 2>/dev/null)"
    case "$fst" in
      ext4|ext3|xfs) make_swapfile "$f" ;;
      *) log "$SWAP_DIR is $fst — can't host a swapfile; use a swap partition" ;;
    esac
    return
  fi
  if [ -n "$(swapon --show=NAME --noheadings 2>/dev/null | grep -i "$SWAP_DEV" || true)" ]; then
    log "existing swap on $SWAP_DEV, leaving it"
    return
  fi
  # if a swap partition already exists on this device (e.g. from make-swap.sh), use it
  local swp
  for swp in /dev/${SWAP_DEV}[0-9]*; do
    [ -b "$swp" ] || continue
    if [ "$(blkid -o value -s TYPE "$swp" 2>/dev/null)" = swap ]; then
      swapon "$swp" 2>/dev/null && { log "swap on existing partition $swp"; return; }
    fi
  done
  local dir="" fstype=""
  if [ -z "$dir" ]; then
    # a mounted writable filesystem on $SWAP_DEV?
    while read -r src tgt fst; do
      case "$src" in *"$SWAP_DEV"*) if [ -w "$tgt" ]; then dir="$tgt"; fstype="$fst"; break; fi ;; esac
    done < <(findmnt -rno SOURCE,TARGET,FSTYPE 2>/dev/null)
    # not mounted? mount a Linux partition on $SWAP_DEV
    if [ -z "$dir" ]; then
      for part in /dev/${SWAP_DEV}[0-9]*; do
        [ -b "$part" ] || continue
        case "$(blkid -o value -s TYPE "$part" 2>/dev/null)" in
          ext4|ext3|xfs)
            mkdir -p /mnt/lai-swap && mount "$part" /mnt/lai-swap 2>/dev/null \
              && { dir=/mnt/lai-swap; fstype="$(blkid -o value -s TYPE "$part")"; break; } ;;
        esac
      done
    fi
  else
    fstype="$(findmnt -nro FSTYPE --target "$dir" 2>/dev/null)"
  fi
  [ -n "$dir" ] || { log "no writable Linux filesystem on /dev/$SWAP_DEV. If it's NTFS or has free space, run once:  sudo bash tools/make-swap.sh $SWAP_DEV ${SWAP_SIZE}. Running without a swapfile for now."; return; }
  case "$fstype" in
    ext4|ext3|xfs) ;;                      # swapfile works
    ntfs|ntfs3|fuseblk|vfat|exfat|"")      # swapfiles don't work here
      log "$SWAP_DEV is $fstype — a swapfile won't work on it. Make a swap partition once:  sudo bash tools/make-swap.sh $SWAP_DEV ${SWAP_SIZE}"; return ;;
    btrfs)
      log "btrfs needs a special swapfile setup; make a swap partition instead:  sudo bash tools/make-swap.sh $SWAP_DEV ${SWAP_SIZE}"; return ;;
  esac
  make_swapfile "$dir/lai.swap"
}

# make_swapfile PATH — create, format and activate a SWAP_SIZE swapfile; sets SWAPFILE
make_swapfile() {
  SWAPFILE="$1"
  log "creating $SWAP_SIZE swapfile at $SWAPFILE"
  if ! fallocate -l "$SWAP_SIZE" "$SWAPFILE" 2>/dev/null; then
    local mb; mb=$(numfmt --from=iec "$SWAP_SIZE" 2>/dev/null); mb=$(( ${mb:-0} / 1048576 ))
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="${mb:-24576}" status=none || { log "couldn't allocate swapfile"; SWAPFILE=""; return; }
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null 2>&1 || { log "mkswap failed"; rm -f "$SWAPFILE"; SWAPFILE=""; return; }
  swapon "$SWAPFILE" 2>/dev/null || { log "swapon failed (filesystem may not support swapfiles; use a swap partition)"; rm -f "$SWAPFILE"; SWAPFILE=""; return; }
  log "swap active on $SWAPFILE"
}

# ---- soft cap on lai's process tree (cgroup v2 memory.high) ----
setup_cgroup() {
  [ -w /sys/fs/cgroup/cgroup.controllers ] || { log "no cgroup v2; skipping the soft cap (swappiness still applies)"; return; }
  grep -qw memory /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null \
    || echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
  mkdir -p "$CGROUP" 2>/dev/null || { log "couldn't create cgroup"; return; }
  echo $(( SOFT_CAP_GB * 1024 * 1024 * 1024 )) > "$CGROUP/memory.high" 2>/dev/null || true
  echo "max" > "$CGROUP/memory.swap.max" 2>/dev/null || true
  log "capping lai's tree at ${SOFT_CAP_GB}G (cgroup memory.high)"
}

# keep lai + all its descendants in the cgroup (MCP servers/browsers spawn over
# time). LAI_PID is auto-discovered when not given, so memguard can start first.
herd_into_cgroup() {
  [ -d "$CGROUP" ] || return 0
  if [ "$LAI_PID" -le 0 ] || ! kill -0 "$LAI_PID" 2>/dev/null; then
    LAI_PID="$(pgrep -x lai 2>/dev/null | head -1)"; LAI_PID="${LAI_PID:-0}"
  fi
  [ "$LAI_PID" -gt 0 ] || return 0
  local pgid pids
  pgid="$(ps -o pgid= -p "$LAI_PID" 2>/dev/null | tr -d ' ')"
  pids="$(pgrep -g "$pgid" 2>/dev/null)"
  for p in $LAI_PID $pids; do
    echo "$p" > "$CGROUP/cgroup.procs" 2>/dev/null || true
  done
}

used_gb()  { awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.1f",(t-a)/1048576}' /proc/meminfo; }
engine_jiffies() { cat /proc/$(pgrep -x lai-engine | head -1)/stat 2>/dev/null | awk '{print $14+$15}'; }

# ---- earlier/harder reclaim knobs ----
setup_sysctls() {
  echo 200 > /proc/sys/vm/watermark_scale_factor 2>/dev/null || true  # kswapd starts reclaiming sooner
  echo 150 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null || true      # reclaim dentry/inode cache more
}

pick_swap_dev() {
  # a whole disk that is NOT the one holding the running system
  local root_src root_disk d
  root_src="$(findmnt -nro SOURCE / 2>/dev/null)"
  root_disk="$(lsblk -nro PKNAME "$root_src" 2>/dev/null | head -1)"
  for d in $(lsblk -dnro NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
    [ "$d" = "$root_disk" ] && continue
    echo "$d"; return
  done
}

main() {
  if [ -n "${SWAP_DIR:-}" ]; then
    log "start: soft cap ${SOFT_CAP_GB}G, ramp from ${RAMP_START_GB}G, idle cache drop after ${IDLE_MIN}m, ${SWAP_SIZE} swapfile in $SWAP_DIR"
  else
    [ -n "$SWAP_DEV" ] || SWAP_DEV="$(pick_swap_dev)"
    [ -n "$SWAP_DEV" ] || log "couldn't pick a swap disk; set SWAP_DEV=sdb or SWAP_DIR=<path>"
    log "start: soft cap ${SOFT_CAP_GB}G, ramp from ${RAMP_START_GB}G, idle cache drop after ${IDLE_MIN}m, swap on /dev/${SWAP_DEV:-none}"
  fi
  setup_swap
  setup_cgroup
  setup_sysctls
  local last_busy_j last_busy_t now_j
  last_busy_j="$(engine_jiffies || echo 0)"; last_busy_t="$(date +%s)"
  while :; do
    herd_into_cgroup
    local u; u="$(used_gb)"
    # graded swappiness: 10 below the ramp, climbing to 100 at the cap
    local sw
    if awk "BEGIN{exit !($u < $RAMP_START_GB)}"; then
      sw=10
    elif awk "BEGIN{exit !($u >= $SOFT_CAP_GB)}"; then
      sw=100
    else
      sw=$(awk "BEGIN{printf \"%d\", 60+40*($u-$RAMP_START_GB)/($SOFT_CAP_GB-$RAMP_START_GB)}")
    fi
    echo "$sw" > /proc/sys/vm/swappiness 2>/dev/null || true
    # over the cap: force reclaim lai's tree to swap, then free clean cache
    if awk "BEGIN{exit !($u >= $SOFT_CAP_GB)}"; then
      [ -w "$CGROUP/memory.reclaim" ] && echo $(( 1024*1024*1024 )) > "$CGROUP/memory.reclaim" 2>/dev/null || true
      sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
      log "over ${SOFT_CAP_GB}G (${u}G) — reclaiming"
    fi
    # idle cache drop: engine CPU unchanged for IDLE_MIN minutes
    now_j="$(engine_jiffies || echo "$last_busy_j")"
    if [ "$now_j" != "$last_busy_j" ]; then
      last_busy_j="$now_j"; last_busy_t="$(date +%s)"
    elif [ $(( $(date +%s) - last_busy_t )) -ge $(( IDLE_MIN * 60 )) ]; then
      sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
      last_busy_t="$(date +%s)"   # once per idle window
    fi
    sleep "$INTERVAL"
  done
}

main
