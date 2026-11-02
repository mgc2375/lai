#!/usr/bin/env bash
# build-esp-grub.sh [ESP_DEVICE]        e.g. build-esp-grub.sh /dev/sdc2
#
# Puts a GRUB on the live USB's writable EFI partition so the kernel command
# line can be changed. Without this, nothing else about the proprietary NVIDIA
# driver works on this medium.
#
# WHY THIS IS NEEDED
#   nouveau ships inside the ISO's initramfs (MODULES=most) and binds the GPU
#   before the persistence overlay is mounted -- so /etc/modprobe.d is never
#   read in time and cannot stop it. Only modprobe.blacklist=nouveau on the
#   kernel command line works, and that means editing a bootloader config.
#
#   The ISO's own grub.cfg is on a read-only iso9660 partition, and the stock
#   grubx64.efi locates its prefix by searching for /.disk/info -- a file that
#   exists ONLY on that read-only partition. So a grub.cfg dropped on the
#   writable ESP is simply never read, whichever EFI entry you boot.
#
#   The fix is to replace the EFI binary itself with one whose embedded config
#   finds the ESP by a marker file we control.
#
# AFTER RUNNING THIS, BOOT THE RIGHT EFI ENTRY
#   The firmware offers two entries for the stick. They are NOT equivalent:
#     "UEFI: <vendor> <product>"                -> CDROM(...) El Torito path,
#                                                  reads the read-only ISO,
#                                                  gives the STOCK menu
#     "UEFI: <vendor> <product>, Partition 1"   -> HD(...) partition path,
#                                                  reads the ESP, gives THIS menu
#   Pick the "Partition 1" one. (Or make it permanent with
#   `efibootmgr -o <that-entry-first>,...`.)
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash tools/build-esp-grub.sh [/dev/sdXN]"

KVER="${LAI_KVER:-$(uname -r)}"
WORK=/tmp/lai-esp-grub
MNT=/mnt/lai-esp

# --- locate the ESP: the small vfat partition on the live medium -------------
ESP="${1:-}"
if [ -z "$ESP" ]; then
  medium="$(findmnt -nro SOURCE /run/live/medium 2>/dev/null)"
  [ -n "$medium" ] || die "can't find /run/live/medium; pass the ESP device explicitly"
  disk="/dev/$(lsblk -nro PKNAME "$medium" | head -1)"
  ESP="$(lsblk -nro NAME,FSTYPE,SIZE "$disk" | awk '$2=="vfat"{print "/dev/"$1; exit}')"
  [ -n "$ESP" ] || die "no vfat partition found on $disk; pass the ESP device explicitly"
fi
[ -b "$ESP" ] || die "not a block device: $ESP"
[ "$(blkid -o value -s TYPE "$ESP")" = vfat ] || die "$ESP is not vfat -- refusing"
say "ESP: $ESP ($(lsblk -nro SIZE "$ESP"))"

# --- back it up before touching anything -------------------------------------
BACKUP="${LAI_ESP_BACKUP:-/root/esp-backup-$(date +%Y%m%d%H%M%S).img}"
say "backing up the whole ESP to $BACKUP"
dd if="$ESP" of="$BACKUP" bs=1M status=none || die "backup failed"
say "  $(stat -c %s "$BACKUP") bytes, md5 $(md5sum "$BACKUP" | cut -d' ' -f1)"
say "  keep a copy off the stick -- if the EFI binary is bad, this is the way back"

# --- grub modules ------------------------------------------------------------
# The ISO ships only a partial module set (iso9660, search, configfile and
# fshelp are compiled into its grubx64.efi, not shipped as .mod files), so fetch
# the matching package and extract it WITHOUT installing.
command -v grub-mkimage >/dev/null || die "grub-mkimage missing (install grub-common)"
GRUB_VER="$(grub-mkimage --version | awk '{print $NF}')"
say "grub-mkimage $GRUB_VER -- fetching matching modules"
rm -rf "$WORK"; mkdir -p "$WORK/deb" "$WORK/ext"
MODDIR=/usr/lib/grub/x86_64-efi
if [ ! -d "$MODDIR" ]; then
  ( cd "$WORK/deb" && apt-get download grub-efi-amd64-bin >/dev/null 2>&1 ) \
    || die "couldn't download grub-efi-amd64-bin (need network, or install it)"
  dpkg-deb -x "$WORK"/deb/grub-efi-amd64-bin_*.deb "$WORK/ext"
  MODDIR="$WORK/ext/usr/lib/grub/x86_64-efi"
fi
[ -d "$MODDIR" ] || die "no x86_64-efi module directory"
say "  modules: $MODDIR ($(ls "$MODDIR"/*.mod 2>/dev/null | wc -l) .mod files)"

# --- build the EFI image -----------------------------------------------------
# The embedded config runs before any on-disk config. Searching for our own
# marker is what breaks the dependence on the ISO's /.disk/info.
cat > "$WORK/early.cfg" <<'CFG'
set lai_fallback=$root
search --no-floppy --file --set=root /boot/grub/lai.marker
if [ -e ($root)/boot/grub/grub.cfg ]; then
    set prefix=($root)/boot/grub
else
    set root=$lai_fallback
    set prefix=($root)/boot/grub
fi
configfile $prefix/grub.cfg
CFG

MODS="part_msdos part_gpt fat iso9660 ext2
search search_fs_file search_fs_uuid search_label
normal configfile linux linux16 boot chain
echo test true loadenv sleep halt reboot minicmd ls cat help
gzio xzio all_video video video_fb efi_gop efi_uga video_bochs video_cirrus
gfxterm gfxmenu font png jpeg terminal play"
use=""; for m in $MODS; do [ -e "$MODDIR/$m.mod" ] && use="$use $m"; done

say "building the EFI image"
grub-mkimage -d "$MODDIR" -O x86_64-efi -o "$WORK/laigrub.efi" \
  -p '/boot/grub' -c "$WORK/early.cfg" $use || die "grub-mkimage failed"
case "$(file -b "$WORK/laigrub.efi")" in
  *"PE32+"*EFI*) say "  $(stat -c %s "$WORK/laigrub.efi") bytes, valid EFI application" ;;
  *) die "built image is not a PE32+ EFI application" ;;
esac

# --- install onto the ESP ----------------------------------------------------
mkdir -p "$MNT"; mountpoint -q "$MNT" || mount "$ESP" "$MNT" || die "mount failed"
# MokManager is only for enrolling Secure Boot keys; with Secure Boot off it is
# dead weight, and this partition is typically ~4 MB with almost nothing spare.
sb="$(od -An -tu1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $5}')"
if [ "${sb:-0}" = 0 ] && [ -f "$MNT/EFI/boot/mmx64.efi" ]; then
  rm -f "$MNT/EFI/boot/mmx64.efi"; say "  removed mmx64.efi (Secure Boot is off)"
elif [ "${sb:-0}" = 1 ]; then
  die "Secure Boot is ENABLED -- an unsigned grub will not load. Disable it first."
fi

printf 'lai: this is the writable ESP; grub.cfg beside this file is authoritative.\n' \
  > "$MNT/boot/grub/lai.marker" 2>/dev/null || { mkdir -p "$MNT/boot/grub"; \
  printf 'lai marker\n' > "$MNT/boot/grub/lai.marker"; }

cat > "$MNT/boot/grub/grub.cfg" <<CFG
# lai boot menu, read from the WRITABLE ESP.
#
# modprobe.blacklist=nouveau  the only place nouveau can be stopped: it ships in
#                             the ISO's read-only initramfs and binds before
#                             /etc/modprobe.d exists.
# nvidia-drm.modeset=0        nvidia's KMS fbdev layer oopses this kernel
#                             (drm_fb_helper_damage_work -> drm_gem_lock(NULL)).
#                             Xorg needs no KMS; Vulkan/CUDA never touch DRM.
#                             NOTE: this also rules out Wayland -- run Plasma on
#                             X11 (see tools/setup-live-nvidia.sh).
# plymouth.enable=0, no splash  plymouth deadlocks on the nvidia framebuffer.
# no "quiet"                  so a failed boot is readable on screen.
set default=0
set timeout=10

search --no-floppy --set=root --file /.disk/info

menuentry "Parrot Persistence + NVIDIA" --class hdd {
    linux /live/vmlinuz-$KVER boot=live hostname=parrot components noautomount persistence modprobe.blacklist=nouveau pci=noaer plymouth.enable=0 nouveau.modeset=0 nvidia-drm.modeset=0
    initrd /live/initrd.img-$KVER
}

menuentry "Parrot Persistence + NVIDIA (text console only)" --class hdd {
    linux /live/vmlinuz-$KVER boot=live hostname=parrot components noautomount persistence modprobe.blacklist=nouveau pci=noaer plymouth.enable=0 nouveau.modeset=0 nvidia-drm.modeset=0 systemd.unit=multi-user.target
    initrd /live/initrd.img-$KVER
}

menuentry "Parrot Persistence (stock, nouveau)" --class hdd {
    set gfxpayload=keep
    linux /live/vmlinuz-$KVER boot=live hostname=parrot quiet splash components noautomount persistence
    initrd /live/initrd.img-$KVER
}

menuentry "Stock Parrot bootloader (chainload original grub)" {
    search --no-floppy --set=esp --file /boot/grub/lai.marker
    chainloader (\$esp)/EFI/boot/grubx64.efi
}
CFG

say "replacing /EFI/boot/bootx64.efi"
cp "$WORK/laigrub.efi" "$MNT/EFI/boot/bootx64.efi" || die "copy failed"
sync
a="$(md5sum "$MNT/EFI/boot/bootx64.efi" | cut -d' ' -f1)"
b="$(md5sum "$WORK/laigrub.efi" | cut -d' ' -f1)"
[ "$a" = "$b" ] || die "write verification failed ($a != $b) -- restore from $BACKUP"
say "  verified byte-for-byte ($a)"

sync; umount "$MNT" || die "umount failed -- do NOT power off yet"
sync
fsck.vfat -n "$ESP" 2>&1 | tail -2 >&2

echo >&2
say "done. Backup: $BACKUP"
say "Boot the firmware entry ending in \", Partition 1\" -- NOT the plain one."
