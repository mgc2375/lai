#!/usr/bin/env bash
# persist-root.sh — turn on FULL root persistence on a Debian/Parrot live USB.
#
# A live boot only keeps what the persistence partition's persistence.conf names.
# The NVIDIA driver (and apt packages, and /home) live under /, so without a
# '/ union' line they're wiped every reboot and the GPU drops back to nouveau.
# This adds '/ union' so everything under / survives.
#
#   sudo bash tools/persist-root.sh            # auto-detect the 'persistence' partition
#   sudo bash tools/persist-root.sh sdb3       # or name the partition
#
# After it runs: reboot, pick the *persistence* entry in the boot menu, then
# rerun ./install.sh — the driver install will now stick.
set -euo pipefail
say()  { printf '\033[1m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m  error:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash tools/persist-root.sh [device]"

# 1. locate the persistence partition
dev="${1:-}"
if [ -n "$dev" ]; then
  case "$dev" in /dev/*) : ;; *) dev="/dev/$dev" ;; esac
  [ -b "$dev" ] || die "$dev is not a block device (see: lsblk -f)"
else
  dev="$(blkid -L persistence 2>/dev/null || true)"
  [ -n "$dev" ] || die "no partition labelled 'persistence' found. Pass it explicitly: sudo bash tools/persist-root.sh sdXN  (find it with: lsblk -f)"
  say "found the persistence partition by label: $dev"
fi

# safety: never the running root device
root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
[ -n "$root_src" ] && [ "$dev" = "$root_src" ] && die "$dev is your running root filesystem, not the persistence partition — aborting"

# 2. mount it read-write
mnt="$(mktemp -d)"
mount "$dev" "$mnt" 2>/dev/null || die "couldn't mount $dev"
cleanup() { umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
conf="$mnt/persistence.conf"

if [ -f "$conf" ] && grep -qE '^[[:space:]]*/[[:space:]]+union([[:space:]]|$)' "$conf"; then
  say "full root persistence is already on: $conf already has '/ union'. Nothing to change."
  say "make sure you boot the *persistence* entry in the boot menu."
  exit 0
fi

echo
say "persistence partition: $dev"
if [ -f "$conf" ]; then
  echo "  current persistence.conf:"; sed 's/^/      /' "$conf"
else
  echo "  no persistence.conf yet on this partition."
fi
cat <<'EXPLAIN'

  This writes a single line — '/ union' — which persists EVERYTHING under / (the
  GPU driver, apt packages, /home, config). It replaces the file's current
  contents (backed up first); '/ union' is a superset of narrower lines like
  '/home union'. Your lai data partition (LAI_PERSIST) is separate and untouched.

EXPLAIN
printf "  Enable full root persistence on %s now? [y/N] " "$dev"
read -r ans </dev/tty || ans=n
case "$ans" in y|Y|yes|YES) ;; *) die "cancelled — nothing written" ;; esac

# 3. back up and write
if [ -f "$conf" ]; then
  bak="$conf.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$conf" "$bak" && say "backed up old conf to $(basename "$bak")"
fi
printf '/ union\n' > "$conf"
sync
say "wrote '/ union' to the persistence partition"

cat <<'DONE'

  ->  Done. Finish with:
        1) sudo reboot
        2) in the boot menu choose the entry that says "persistence"
        3) cd ~/lai && ./install.sh --serve --mcp
      From now on the NVIDIA driver (and everything else) survives reboots, so
      the GPU install sticks and finishes on its own.

  Note: with full root persistence the stick fills up as you install things —
  make sure the persistence partition has room (a few GB spare at least).
DONE
