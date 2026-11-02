#!/usr/bin/env bash
# setup-live-nvidia.sh [--check]
#
# Applies every host-side fix needed to run the proprietary NVIDIA driver with a
# working KDE desktop on a Parrot live USB. Idempotent; safe to re-run.
#
# This does NOT handle the kernel command line -- nouveau ships inside the ISO's
# read-only initramfs (MODULES=most) and binds the card before /etc exists, so
# only a kernel parameter can stop it, and that needs a bootloader on the
# writable ESP. See tools/build-esp-grub.sh and docs/live-usb-nvidia.md.
#
# What each fix is for, all diagnosed from logs on a real failure:
#
#   1. nvidia-drm modeset=0 fbdev=0
#      With KMS on, the DRM fbdev console layer oopses this kernel:
#        BUG: kernel NULL pointer dereference, address: 00000000000000f8
#        drm_fb_helper_damage_work -> drm_fbdev_ttm_helper_fb_dirty
#        -> drm_client_buffer_vmap_local -> drm_gem_lock(NULL)
#      With fbdev=1 instead, plymouth wedges in drm_fb_helper_pan_display (D
#      state, unkillable) and holds the display so Xorg can never start. Both
#      failure modes live in that layer; modeset=0 removes it. Xorg does not
#      need KMS, and Vulkan/CUDA never touch DRM, so lai is unaffected.
#
#   2. Plasma on X11, not Wayland
#      KWin-Wayland requires a DRM device: "kwin_wayland_drm: No suitable DRM
#      devices have been found". With modeset=0 there isn't one, so every Plasma
#      component aborts in QGuiApplication init ("could not connect to display").
#      The session name comes from AccountsService, NOT lightdm.conf -- the
#      greeter reads it and then tells lightdm what to start.
#
#   3. No screen blanking
#      A blanked monitor is indistinguishable from a crashed machine from across
#      the room. Set at the Xorg layer; a lightdm display-setup-script runs
#      before X auth exists and silently fails.
#
#   4. No auto-suspend
#      Suspend/resume with the proprietary driver on a live USB is a good way to
#      come back with no display, and the box is meant to stay up for inference.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

USER_NAME="${SUDO_USER:-${LAI_USER:-live}}"

check() {
  printf 'kernel driver   : %s\n' "$(lspci -nnk 2>/dev/null | awk -F': ' '/Kernel driver in use/ && p {print $2; exit} /VGA compatible controller.*NVIDIA/ {p=1}')"
  printf 'nouveau loaded  : %s\n' "$(lsmod | grep -q '^nouveau ' && echo yes || echo no)"
  printf 'cmdline modeset : %s\n' "$(grep -o 'nvidia-drm.modeset=[01]' /proc/cmdline || echo '(not set)')"
  printf 'cmdline blacklist: %s\n' "$(grep -o 'modprobe.blacklist=[^ ]*' /proc/cmdline || echo '(not set)')"
  printf 'session for %-4s: %s\n' "$USER_NAME" "$(grep -s '^XSession=' "/var/lib/AccountsService/users/$USER_NAME" | cut -d= -f2)"
  printf 'wayland session : %s\n' "$(ls /usr/share/wayland-sessions/*.desktop 2>/dev/null | wc -l) enabled"
  printf 'sleep.target    : %s\n' "$(systemctl is-enabled sleep.target 2>&1)"
  printf 'blanking conf   : %s\n' "$([ -f /etc/X11/xorg.conf.d/10-lai-noblank.conf ] && echo present || echo missing)"
}

[ "${1:-}" = "--check" ] && { check; exit 0; }
[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash tools/setup-live-nvidia.sh"

say "1/4  nvidia-drm: KMS and fbdev off"
rm -f /etc/modprobe.d/nvidia-drm-modeset.conf
cat > /etc/modprobe.d/lai-nvidia-drm.conf <<'EOF'
# lai: nvidia's DRM/KMS fbdev layer oopses this kernel
# (drm_fb_helper_damage_work -> drm_gem_lock(NULL)) and deadlocks plymouth when
# fbdev is on. Xorg does not need KMS; Vulkan and CUDA do not use DRM at all.
options nvidia-drm modeset=0 fbdev=0
options nvidia-current-drm modeset=0 fbdev=0
EOF

say "2/4  desktop session: Plasma on X11"
# The greeter reads the session from AccountsService and tells lightdm what to
# run, so setting autologin-session in lightdm.conf alone has no effect.
mkdir -p /var/lib/AccountsService/users
if [ -f "/var/lib/AccountsService/users/$USER_NAME" ]; then
  sed -i -e 's/^XSession=.*/XSession=plasmax11/' -e 's/^Session=.*/Session=plasmax11/' \
    "/var/lib/AccountsService/users/$USER_NAME"
  grep -q '^XSession=' "/var/lib/AccountsService/users/$USER_NAME" || \
    printf 'XSession=plasmax11\n' >> "/var/lib/AccountsService/users/$USER_NAME"
else
  printf '[User]\nSession=plasmax11\nXSession=plasmax11\nSystemAccount=false\n' \
    > "/var/lib/AccountsService/users/$USER_NAME"
fi
# Belt and braces: with no KMS a Wayland session can never start, so take it out
# of the picture entirely rather than leave it selectable.
if [ -f /usr/share/wayland-sessions/plasma.desktop ]; then
  mv /usr/share/wayland-sessions/plasma.desktop \
     /usr/share/wayland-sessions/plasma.desktop.disabled-by-lai
fi
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/99-lai-x11-session.conf <<'EOF'
[Seat:*]
autologin-session=plasmax11
user-session=plasmax11
EOF

say "3/4  screen blanking off"
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-lai-noblank.conf <<'EOF'
# lai: never blank or power down the screen. A blanked monitor looks exactly
# like a dead machine from across the room.
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
EOF

say "4/4  auto-suspend off"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-lai-nosleep.conf <<'EOF'
[Login]
IdleAction=ignore
IdleActionSec=0
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
EOF
systemctl restart systemd-logind >/dev/null 2>&1 || true
u_home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [ -n "$u_home" ] && [ -d "$u_home" ]; then
  mkdir -p "$u_home/.config"
  cat > "$u_home/.config/powermanagementprofilesrc" <<'EOF'
[AC][SuspendSession]
idleTime=0
suspendType=0
EOF
  chown -R "$USER_NAME": "$u_home/.config/powermanagementprofilesrc" 2>/dev/null || true
fi

echo >&2
say "done -- current state:"
check
echo >&2
say "The kernel command line is NOT set by this script. Without"
say "modprobe.blacklist=nouveau the proprietary driver cannot bind at all."
say "See tools/build-esp-grub.sh and docs/live-usb-nvidia.md."
