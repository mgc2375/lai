# Proprietary NVIDIA + KDE on a Parrot live USB

Getting both a working desktop **and** GPU acceleration on this medium takes
five separate fixes. Each was diagnosed from logs on a real failure; none of
them are guesses.

Apply with:

```sh
sudo bash tools/build-esp-grub.sh      # bootloader (needs one reboot)
sudo bash tools/setup-live-nvidia.sh   # everything host-side
```

Then **boot the firmware entry ending in `, Partition 1`** — see §5.

---

## Why it is hard at all

nouveau ships *inside the ISO's initramfs* (`MODULES=most`) and binds the GPU
before the persistence overlay is mounted. So `/etc/modprobe.d/blacklist` is
never read in time:

```
19:39:19  nouveau 0000:01:00.0: NVIDIA TU117
19:39:29  ... squashfs loop overlay isofs cdrom ... nouveau ...   <- initramfs module list
19:39:31  NVRM: GPU 0000:01:00.0 is already bound to nouveau.
19:39:31  NVRM: No NVIDIA devices probed.
```

Only `modprobe.blacklist=nouveau` on the **kernel command line** works — which
means editing a bootloader, which is why §1 exists.

## 1. The bootloader (`tools/build-esp-grub.sh`)

The ISO's `grub.cfg` is on a read-only iso9660 partition. Worse, the stock
`grubx64.efi` finds its prefix by searching for `/.disk/info`, which exists
*only* on that read-only partition — so a `grub.cfg` placed on the writable ESP
is never read, whichever EFI entry you boot.

Fix: build a GRUB whose embedded config finds the ESP by our own marker file,
and replace `bootx64.efi` with it. Secure Boot must be off (the script checks).

The ESP is typically ~4 MB with ~2 KB free, so the script reclaims `mmx64.efi`
(MokManager, useless with Secure Boot off) and *replaces* rather than adds.

## 2. No KMS — `nvidia-drm.modeset=0`

With nvidia's KMS on, the DRM fbdev console layer oopses this kernel:

```
BUG: kernel NULL pointer dereference, address: 00000000000000f8
RIP: drm_gem_lock+0x9/0x20 [drm]        RDI: 0000000000000000
  drm_client_buffer_vmap_local    [drm]
  drm_fbdev_ttm_helper_fb_dirty   [drm_ttm_helper]
  drm_fb_helper_damage_work       [drm_kms_helper]
```

Setting `fbdev=1` instead trades it for a different failure in the same layer:
plymouth wedges in `drm_fb_helper_pan_display` (`D` state, unkillable) holding
the display, so Xorg never starts.

`modeset=0` removes the layer. **Xorg does not need KMS**, and Vulkan/CUDA never
touch DRM, so lai is unaffected.

## 3. Plasma on X11, not Wayland

`modeset=0` means no DRM device, and KWin-Wayland requires one:

```
kwin_wayland_wrapper: kwin_wayland_drm: No suitable DRM devices have been found
```

Every Plasma component then aborts in `QGuiApplication` init
(`could not connect to display :0`), lightdm falls back to the greeter, and the
screen cycles between black and the login page.

**The session name comes from AccountsService, not lightdm.conf.** The greeter
reads `/var/lib/AccountsService/users/<user>` and *tells* lightdm what to start:

```
Greeter requests session plasma            <- before
Greeter requests session plasmax11         <- after
Seat seat0: Creating display server of type x
```

Setting `autologin-session=` in `lightdm.conf` alone does nothing.

`tools/fix-gui.sh` is the companion to this: live-config rewrites
`/etc/X11/xorg.conf.d/zz-live-config_xserver-xorg.conf` on *every* boot, forcing
`Driver "nvidia"` whenever the proprietary driver is installed. If nouveau holds
the card that is fatal — Xorg crash-loops (`NRestarts` in the hundreds). The
script installs a unit, ordered before the display manager, that matches the
Xorg driver to whichever kernel driver actually owns the GPU.

```sh
sudo bash tools/fix-gui.sh            # install the unit
sudo bash tools/fix-gui.sh --status   # report
```

## 4. Nuisances that cost real debugging time

- **AER interrupt storm.** A faulty internal wifi card flooded PCIe root port
  `00:1c.5` — 115 million interrupts, one core pinned in `irq/122-aerdrv`,
  starving systemd until sshd could authenticate but not fork a shell. Fixed
  with `pci=noaer` (and blacklisting that card's driver if it is yours).
- **Screen blanking.** DPMS blanks after 10 minutes and is indistinguishable
  from a crash. Set it at the Xorg layer — a lightdm `display-setup-script`
  runs before X auth exists and fails silently.
- **Auto-suspend.** Suspend/resume with the proprietary driver on a live USB is
  a good way to come back with no display.
- **Keep `quiet` off.** Every black-screen failure is unreadable with it on.

## 5. Boot the right EFI entry

The firmware offers two entries for the stick and they are **not** equivalent:

| entry | device path | reads | menu |
|---|---|---|---|
| `UEFI: <vendor> <product>` | `CDROM(...)` | read-only ISO | stock |
| `UEFI: <vendor> <product>, Partition 1` | `HD(...)` | the ESP | **ours** |

Proof, if yours differ:

```sh
md5sum /run/live/medium/EFI/boot/bootx64.efi   # the ISO copy
sudo mount -o ro /dev/sdXN /mnt && md5sum /mnt/EFI/boot/bootx64.efi
```

Make it permanent with `efibootmgr -o <partition-entry>,<rest...>`.

## Verifying

```sh
sudo bash tools/setup-live-nvidia.sh --check
```

A good state looks like:

```
kernel driver   : nvidia
nouveau loaded  : no
cmdline modeset : nvidia-drm.modeset=0
session for live: plasmax11
sleep.target    : masked
```

and:

```sh
nvidia-smi --query-gpu=pstate,clocks.sm,clocks.max.sm --format=csv
vulkaninfo --summary | grep -E 'deviceName|driverID'   # DRIVER_ID_NVIDIA_PROPRIETARY
```

Reclocking is the point of all this: on nouveau the card is pinned at 300 MHz
because reclocking Turing needs signed firmware the open driver does not have.
With the proprietary driver it reaches **P0** — measured here at 1410 MHz core /
6000 MHz memory, against a 2130 MHz / 6001 MHz ceiling.

## If it will not boot

The build script backs the whole ESP up first and prints the path. Restore with:

```sh
sudo dd if=/root/esp-backup-<stamp>.img of=/dev/sdXN bs=1M && sync
```

Keep a copy off the stick. If GRUB drops to a prompt, the stock bootloader is
still present and untouched:

```
set root=(hd0,msdos2)
chainloader /EFI/boot/grubx64.efi
boot
```
