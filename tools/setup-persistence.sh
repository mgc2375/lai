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

# --- reuse an existing 'persistence' partition (by filesystem label) ---
EX="$(blkid -L persistence 2>/dev/null || true)"
if [ -n "$EX" ]; then
  say "found an existing 'persistence' partition: $EX — reusing it"
  write_conf "$EX"
  say "reboot and pick the 'persistence' boot entry to activate it"
  echo "LAI_PERSISTENCE_DEV=$EX"
  exit 0
fi

# --- otherwise carve one from free space ---
[ -n "$dev" ] || die "no 'persistence' partition yet, and no disk given. Run: sudo bash tools/setup-persistence.sh <disk with free space, e.g. sdc> [size]"
dev="/dev/${dev#/dev/}"
[ -b "$dev" ] || die "no such disk: $dev"
case "$dev" in *[0-9]) die "give the whole disk (e.g. sdc), not a partition" ;; esac

# guards: never the running-system disk
root_src="$(findmnt -nro SOURCE / 2>/dev/null || true)"
if [ -n "$root_src" ] && [ -b "$root_src" ]; then
  root_disk="/dev/$(lsblk -nro PKNAME "$root_src" 2>/dev/null | head -1)"
  [ "$dev" = "$root_disk" ] && die "$dev holds the running system — refusing"
fi
[ "$(blkid -o value -s PTTYPE "$dev" 2>/dev/null)" = gpt ] || \
  die "$dev is not GPT. Make an ext4 partition labelled 'persistence' with gparted and re-run (or use a GPT disk)."

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

before="$(lsblk -nro NAME "$dev" | sort)"
sgdisk -n "0:0:+${size}" -t 0:8300 -c 0:persistence "$dev" >/dev/null
partprobe "$dev" 2>/dev/null || true; sleep 1
mapfile -t newp < <(comm -13 <(printf '%s\n' "$before") <(lsblk -nro NAME "$dev" | sort))
[ "${#newp[@]}" -ge 1 ] || die "expected a new partition; check 'lsblk $dev'"
PP="/dev/${newp[0]}"
say "formatting $PP ext4 (filesystem label 'persistence')"
mkfs.ext4 -q -L persistence "$PP"
write_conf "$PP"
say "done: persistence partition = $PP"
say "REBOOT and pick the 'persistence' boot entry, then rerun ./install.sh"
echo "LAI_PERSISTENCE_DEV=$PP"
