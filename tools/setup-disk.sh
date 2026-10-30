#!/usr/bin/env bash
# setup-disk.sh DEVICE [DATA_SIZE] [SWAP_SIZE]
#   e.g. setup-disk.sh sdc 10G 11G
#
# Carves a lai data partition (ext4, label lai-data) and a swap partition
# (label lai-swap) out of the UNALLOCATED free space of DEVICE. Detects an
# existing lai-data/lai-swap first and just reuses them, so it's safe to re-run
# every boot. Never touches, resizes or deletes an existing partition.
#
# It prints, on the last two lines, for the caller to use:
#   LAI_DATA_MOUNT=/mnt/lai-data
#   LAI_SWAP_DEV=/dev/sdcN
set -euo pipefail

say() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash tools/setup-disk.sh $*"
[ $# -ge 1 ] || die "usage: setup-disk.sh DEVICE [DATA_SIZE] [SWAP_SIZE]"
dev="/dev/${1#/dev/}"; data_size="${2:-10G}"; swap_size="${3:-11G}"
[ -b "$dev" ] || die "no such disk: $dev"
case "$dev" in *[0-9]) die "give the whole disk (e.g. sdc), not a partition";; esac
command -v sgdisk >/dev/null 2>&1 || { apt-get install -y -qq gdisk >/dev/null 2>&1 || die "need sgdisk (apt install gdisk)"; }

part_by_label() { blkid -L "$1" 2>/dev/null || true; }
DATA_PART="$(part_by_label lai-data)"
SWAP_PART="$(part_by_label lai-swap)"

mount_data() {
  local p="$1" mp=/mnt/lai-data
  mkdir -p "$mp"
  mountpoint -q "$mp" || mount "$p" "$mp" 2>/dev/null || die "couldn't mount $p"
  echo "$mp"
}

# --- already set up on a previous run: just reuse ---
if [ -n "$DATA_PART" ] && [ -n "$SWAP_PART" ]; then
  say "reusing existing lai partitions: data=$DATA_PART swap=$SWAP_PART"
  swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_PART" || swapon -p 10 "$SWAP_PART" 2>/dev/null || true
  echo "LAI_DATA_MOUNT=$(mount_data "$DATA_PART")"
  echo "LAI_SWAP_DEV=$SWAP_PART"
  exit 0
fi

# --- guards before creating anything ---
root_src="$(findmnt -nro SOURCE / 2>/dev/null)"
root_disk="/dev/$(lsblk -nro PKNAME "$root_src" 2>/dev/null | head -1)"
[ "$dev" = "$root_disk" ] && die "$dev holds the running system — refusing"

say "current layout of $dev:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev" >&2
echo >&2
say "free space on $dev:"
parted -s "$dev" unit GiB print free 2>/dev/null | sed -n '/Free Space/p;/Number/,$p' >&2 || true
echo >&2

[ "$(blkid -o value -s PTTYPE "$dev" 2>/dev/null)" = gpt ] || \
  die "$dev is not GPT. To stay safe I only auto-create on GPT disks. Make the partitions with gparted/cfdisk (label them lai-data and lai-swap) and re-run."

# need both partitions' worth of UNALLOCATED free space
free_gib="$(parted -s "$dev" unit GiB print free 2>/dev/null | awk '/Free Space/{gsub(/GiB/,"",$3); if($3+0>m)m=$3+0} END{print int(m)}')"
need_gib=$(( ${data_size%G} + ${swap_size%G} ))
[ "${free_gib:-0}" -ge "$need_gib" ] || \
  die "need ${need_gib}G of unallocated free space on $dev for lai-data+lai-swap, found ~${free_gib:-0}G. Free some space (gparted) or pass smaller sizes."

say "I will create TWO new partitions in the FREE space of $dev:"
say "  lai-data  ${data_size}  ext4  (lai tools/config)"
say "  lai-swap  ${swap_size}  swap"
say "No existing partition is touched. This writes the partition table."
if [ "${LAI_DISK_YES:-}" != 1 ]; then
  printf 'proceed? type exactly "yes": ' >&2
  read -r ans; [ "$ans" = yes ] || die "aborted"
fi

before="$(lsblk -nro NAME "$dev" | sort)"
sgdisk -n "0:0:+${data_size}" -t 0:8300 -c 0:lai-data "$dev" >/dev/null
sgdisk -n "0:0:+${swap_size}" -t 0:8200 -c 0:lai-swap "$dev" >/dev/null
partprobe "$dev" 2>/dev/null || true; sleep 1
mapfile -t newp < <(comm -13 <(echo "$before") <(lsblk -nro NAME "$dev" | sort))
[ "${#newp[@]}" -ge 2 ] || die "expected 2 new partitions; check 'lsblk $dev'"

DATA_PART="$(blkid -L lai-data 2>/dev/null)"; SWAP_PART="$(blkid -L lai-swap 2>/dev/null)"
[ -n "$DATA_PART" ] && [ -n "$SWAP_PART" ] || die "couldn't resolve the new partitions by label"
say "formatting $DATA_PART ext4"
mkfs.ext4 -q -L lai-data "$DATA_PART"
say "formatting $SWAP_PART swap"
mkswap -L lai-swap "$SWAP_PART" >/dev/null
swapon -p 10 "$SWAP_PART"
say "done: data=$DATA_PART swap=$SWAP_PART"
echo "LAI_DATA_MOUNT=$(mount_data "$DATA_PART")"
echo "LAI_SWAP_DEV=$SWAP_PART"
