#!/usr/bin/env bash
# make-swap.sh DEVICE [SIZE] — create a swap partition in the UNALLOCATED free
# space of a data disk (e.g. sdb), for memguard to use.
#
#   sudo bash tools/make-swap.sh sdb 24G
#
# Safety: it only creates ONE new partition in free space and NEVER touches,
# resizes or deletes any existing partition. It refuses the disk that holds the
# running system or any mounted partition, shows you the layout, and asks for a
# typed "yes" before writing. A swap partition on a real disk persists across
# reboots, so you run this once.
#
# Works on GPT disks (via sgdisk). For an MBR/msdos disk it prints manual steps.
set -euo pipefail

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash tools/make-swap.sh $*"
[ $# -ge 1 ] || die "usage: make-swap.sh DEVICE [SIZE]  e.g. make-swap.sh sdb 24G"

dev="/dev/${1#/dev/}"
size="${2:-24G}"
[ -b "$dev" ] || die "no such disk: $dev"
case "$dev" in *[0-9]) die "give the whole disk (e.g. sdb), not a partition ($dev)";; esac

command -v sgdisk >/dev/null 2>&1 || { say "installing gdisk (for sgdisk)"; apt-get install -y -qq gdisk || die "need sgdisk: apt install gdisk"; }

# refuse the system disk and any disk with a mounted partition
root_src="$(findmnt -nro SOURCE / 2>/dev/null)"
root_disk="/dev/$(lsblk -nro PKNAME "$root_src" 2>/dev/null | head -1)"
[ "$dev" = "$root_disk" ] && die "$dev holds the running system — refusing"
mounted="$(lsblk -nro MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' || true)"
if [ -n "$mounted" ]; then
  die "$dev has mounted partitions ($(echo "$mounted" | tr '\n' ' ')); unmount them first, or this disk is in use"
fi

echo
say "current layout of $dev:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev"
echo
say "free space on $dev:"
parted -s "$dev" unit GiB print free 2>/dev/null | sed -n '/Free Space/p;/Number/,$p' || true
echo

label="$(blkid -o value -s PTTYPE "$dev" 2>/dev/null || true)"
if [ "$label" != "gpt" ]; then
  echo "This disk is '${label:-unknown}', not GPT. To stay safe this script only"
  echo "auto-creates partitions on GPT disks. For an MBR disk, create a Linux-swap"
  echo "partition in free space with cfdisk/gparted yourself, then: mkswap <part> && swapon <part>."
  echo "memguard will pick up any existing swap partition on $dev automatically."
  exit 1
fi

say "I will create ONE new ${size} partition in the FREE space of $dev (type: Linux swap)."
say "No existing partition will be touched. This writes to the partition table."
printf 'proceed? type exactly "yes": '
read -r ans
[ "$ans" = "yes" ] || { echo "aborted."; exit 1; }

before="$(lsblk -nro NAME "$dev" | sort)"
# -n 0:0:+SIZE => new partition, auto number, start at largest free block, given size
sgdisk -n "0:0:+${size}" -t 0:8200 -c 0:lai-swap "$dev" >/dev/null
partprobe "$dev" 2>/dev/null || true
sleep 1
after="$(lsblk -nro NAME "$dev" | sort)"
newpart="$(comm -13 <(echo "$before") <(echo "$after") | head -1)"
[ -n "$newpart" ] || die "couldn't tell which partition was created; check 'lsblk $dev'"
newpart="/dev/$newpart"

say "formatting $newpart as swap"
mkswap "$newpart" >/dev/null
swapon "$newpart"
say "done — swap active on $newpart ($(swapon --show=NAME,SIZE --noheadings | grep "$newpart"))"
echo "memguard will reactivate it automatically each run (SWAP_DEV=${dev#/dev/})."
