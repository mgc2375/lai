#!/usr/bin/env bash
# setup-persistence.sh [DEVICE] [SIZE]
#   e.g. setup-persistence.sh sdc 6G
#
# Sets up live-boot ROOT persistence so the whole root filesystem — the NVIDIA
# driver, apt packages, /home — survives reboots on a live USB. It creates a
# dedicated partition (ext4, filesystem label 'persistence') in the UNALLOCATED
# free space of DEVICE and writes '/ union' to it. This is SEPARATE from any
# lai-data / swap / LAI_PERSIST partition — it never touches, resizes or deletes
# an existing partition, and reuses an existing 'persistence' partition if found.
#
# Live-boot finds this partition by its 'persistence' label on ANY disk, so it
# can live in the free space of whichever disk has room.
#
# After it runs: reboot and pick the entry that says "persistence" in the boot
# menu (that's what activates it).
#
# Prints on the last line, for a caller:
#   LAI_PERSISTENCE_DEV=/dev/sdcN
set -euo pipefail
say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash tools/setup-persistence.sh $*"
dev="${1:-}"; size="${2:-6G}"
command -v sgdisk >/dev/null 2>&1 || { apt-get install -y -qq gdisk >/dev/null 2>&1 || die "need sgdisk (apt install gdisk)"; }

# write_conf PART: ensure PART's root has '/ union' (full root persistence)
write_conf() {
  local p="$1" mp conf
  mp="$(mktemp -d)"
  mount "$p" "$mp" || die "couldn't mount $p"
  conf="$mp/persistence.conf"
  if [ -f "$conf" ] && grep -qE '^[[:space:]]*/[[:space:]]+union([[:space:]]|$)' "$conf"; then
    say "$p already has '/ union'"
  else
    [ -f "$conf" ] && cp -a "$conf" "$conf.bak.$(date +%Y%m%d%H%M%S)"
    printf '/ union\n' > "$conf"; sync
    say "wrote '/ union' to $p"
  fi
  umount "$mp" 2>/dev/null || true; rmdir "$mp" 2>/dev/null || true
}

# use_existing_partition PART: turn an existing ext* partition (e.g. your 21 GB
# /dev/sdc3) INTO the root-persistence volume — no carving, no GPT needed. It
# relabels the filesystem to 'persistence' (so live-boot finds it) and writes
# '/ union'. Non-destructive: the label change and the one config file don't
# touch your data. Refuses the running root and the live-boot medium (the ISO).
use_existing_partition() {
  local p="$1" fstype cur_label root_src m ms
  [ -b "$p" ] || die "no such partition: $p"
  root_src="$(findmnt -nro SOURCE / 2>/dev/null || true)"
  [ -n "$root_src" ] && [ "$p" = "$root_src" ] && die "$p is the running root filesystem — refusing"
  for m in /run/live/medium /lib/live/mount/medium; do
    ms="$(findmnt -nro SOURCE "$m" 2>/dev/null | head -1)"
    [ -n "$ms" ] && [ "$ms" = "$p" ] && die "$p is the live-boot medium (the ISO) — refusing to touch it"
  done
  fstype="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
  case "$fstype" in
    ext2|ext3|ext4) ;;
    "") die "$p has no filesystem. Format it first: sudo mkfs.ext4 -L persistence $p" ;;
    *) die "$p is $fstype, not ext4 — live-boot root persistence needs a Linux filesystem. Refusing to touch $p (make a separate ext4 partition instead)." ;;
  esac
  say "using existing partition $p ($fstype) as the root-persistence volume — your data on it is kept"
  cur_label="$(blkid -o value -s LABEL "$p" 2>/dev/null || true)"
  if [ "$cur_label" != persistence ]; then
    if findmnt -nro TARGET --source "$p" >/dev/null 2>&1; then
      umount "$p" 2>/dev/null || die "$p is mounted and busy; unmount it and re-run:  sudo umount $p"
    fi
    command -v e2label >/dev/null 2>&1 || { apt-get install -y -qq e2fsprogs >/dev/null 2>&1 || true; }
    e2label "$p" persistence || die "couldn't set the 'persistence' label on $p"
    say "relabelled $p -> 'persistence' (was '${cur_label:-none}')"
  fi
  write_conf "$p"
  say "done: persistence volume = $p"
  say "REBOOT and pick the 'persistence' boot entry, then rerun ./install.sh"
  echo "LAI_PERSISTENCE_DEV=$p"
  exit 0
}

# --- reuse an existing 'persistence' partition (by filesystem label) ---
EX="$(blkid -L persistence 2>/dev/null || true)"
if [ -n "$EX" ]; then
  say "found an existing 'persistence' partition: $EX — reusing it"
  write_conf "$EX"
  say "reboot and pick the 'persistence' boot entry to activate it"
  echo "LAI_PERSISTENCE_DEV=$EX"
  exit 0
fi

# --- a specific partition was given (e.g. sdc3): use it directly, don't carve ---
[ -n "$dev" ] || die "no 'persistence' partition yet, and nothing given. Run: sudo bash tools/setup-persistence.sh <an existing ext4 partition, e.g. sdc3, OR a disk with free space, e.g. sdc> [size]"
dev="/dev/${dev#/dev/}"
[ -b "$dev" ] || die "no such device: $dev"
if [ "$(lsblk -nro TYPE "$dev" 2>/dev/null | head -1)" = part ]; then
  use_existing_partition "$dev"
fi

# --- otherwise it's a whole disk: carve one from its free space (needs GPT) ---

# guards: never the running-system disk
root_src="$(findmnt -nro SOURCE / 2>/dev/null || true)"
if [ -n "$root_src" ] && [ -b "$root_src" ]; then
  root_disk="/dev/$(lsblk -nro PKNAME "$root_src" 2>/dev/null | head -1)"
  [ "$dev" = "$root_disk" ] && die "$dev holds the running system — refusing"
fi
[ "$(blkid -o value -s PTTYPE "$dev" 2>/dev/null)" = gpt ] || \
  die "$dev is MBR, not GPT, so I can't safely carve a new partition from it. Point me at an EXISTING ext4 partition on it instead (I'll relabel it 'persistence' and add '/ union', non-destructively) — e.g.:  sudo bash tools/setup-persistence.sh ${dev#/dev/}3  (pick your spare data partition with: lsblk -f $dev)."

say "current layout of $dev:"; lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev" >&2; echo >&2
free_gib="$(parted -s "$dev" unit GiB print free 2>/dev/null | awk '/Free Space/{gsub(/GiB/,"",$3); if($3+0>m)m=$3+0} END{print int(m)}')"
need_gib="${size%G}"
[ "${free_gib:-0}" -ge "$need_gib" ] || \
  die "need ${need_gib}G of unallocated free space on $dev, found ~${free_gib:-0}G. Free some (gparted) or pass a smaller size: setup-persistence.sh $1 4G"

say "I will create ONE new partition in the FREE space of $dev:"
say "  persistence  ${size}  ext4  (full root persistence: driver, apt, /home)"
say "No existing partition (your lai-data / swap / sdc3) is touched. This writes the partition table."
if [ "${LAI_DISK_YES:-}" != 1 ]; then
  printf 'proceed? type exactly "yes": ' >&2
  read -r ans; [ "$ans" = yes ] || die "aborted"
fi

# record what's already there — NONE of it gets touched (e.g. sdc1/sdc2 = the
# live-boot ISO, sdc3 = your data partition)
say "existing partitions on $dev (these are NOT touched):"
lsblk -nro NAME,SIZE,FSTYPE,LABEL "$dev" | sed 's/^/      /' >&2
before_names="$(lsblk -nro NAME "$dev" | sort)"
before_tbl="$(sfdisk -d "$dev" 2>/dev/null | grep -E '^/dev/' || true)"

# back up the whole partition table first, so it can be restored if anything is off
gpt_backup="$PWD/lai-parttable-$(basename "$dev")-$(date +%Y%m%d%H%M%S).bin"
if sgdisk --backup="$gpt_backup" "$dev" >/dev/null 2>&1; then
  say "backed up $dev's partition table -> $gpt_backup"
  say "  (restore with: sudo sgdisk --load-backup='$gpt_backup' $dev)"
fi

# create ONE partition in free space only: auto number (0 = next free, so it
# becomes the highest-numbered partition), auto start (0 = first free sector).
# sgdisk writes only a new GPT entry + the new partition's own area; it never
# resizes, moves or rewrites an existing partition.
sgdisk -n "0:0:+${size}" -t 0:8300 -c 0:persistence "$dev" >/dev/null
partprobe "$dev" 2>/dev/null || true; sleep 1

# SAFETY: every partition that existed before must be byte-for-byte unchanged
after_tbl="$(sfdisk -d "$dev" 2>/dev/null | grep -E '^/dev/' || true)"
if [ -n "$before_tbl" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    printf '%s\n' "$after_tbl" | grep -qxF "$l" || {
      warn "SAFETY CHECK FAILED — an existing partition changed:"
      printf '      %s\n' "$l" >&2
      warn "restoring the original table: sudo sgdisk --load-backup='$gpt_backup' $dev"
      [ -f "$gpt_backup" ] && sgdisk --load-backup="$gpt_backup" "$dev" >/dev/null 2>&1 && partprobe "$dev" 2>/dev/null || true
      die "aborted before formatting anything; your partitions are untouched"
    }
  done <<< "$before_tbl"
  say "verified: every pre-existing partition (sdc1/sdc2/… and your data partition) is unchanged"
fi

mapfile -t newp < <(comm -13 <(printf '%s\n' "$before_names") <(lsblk -nro NAME "$dev" | sort))
[ "${#newp[@]}" -eq 1 ] || die "expected exactly ONE new partition, found ${#newp[@]}; check 'lsblk $dev' (nothing formatted)"
PP="/dev/${newp[0]}"
say "new partition created in free space: $PP — formatting ext4 (label 'persistence')"
mkfs.ext4 -q -L persistence "$PP"
write_conf "$PP"
say "done: persistence partition = $PP"
say "REBOOT and pick the 'persistence' boot entry, then rerun ./install.sh"
echo "LAI_PERSISTENCE_DEV=$PP"
