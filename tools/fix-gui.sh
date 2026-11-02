#!/usr/bin/env bash
# fix-gui.sh [--install | --now | --uninstall | --status]
#   --install    install the boot-time unit and apply it now   [default]
#   --now        apply once, right now
#   --uninstall  remove the unit and restore live-config's own file
#   --status     report the bound kernel driver and the Xorg driver in use
#
# Keeps the Xorg video driver matched to whatever kernel driver actually owns the
# GPU, so the desktop starts instead of crash-looping on a black screen.
#
# The problem this solves, on this live USB: live-config's 1140-xserver-xorg
# component rewrites /etc/X11/xorg.conf.d/zz-live-config_xserver-xorg.conf on
# EVERY boot with Driver "nvidia", because the proprietary driver is installed.
# When nouveau owns the card the nvidia DDX cannot initialise, Xorg exits,
# lightdm restarts it, and that repeats forever -- NRestarts climbs into the
# hundreds and the screen stays black. Deleting the file by hand does not help:
# live-config writes it again on the next boot.
#
# Scope: this only ever edits the Xorg device section. It does NOT load or unload
# a kernel module and does NOT touch the GPU configuration used for inference.
set -euo pipefail

# lspci/modprobe and friends live in /usr/sbin, which is off a non-login shell's
# PATH; pin it so this behaves the same from systemd and over ssh.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

UNIT=/etc/systemd/system/lai-fix-gui.service
SELF=/usr/local/sbin/lai-fix-gui
XORG=/etc/X11/xorg.conf.d/zz-live-config_xserver-xorg.conf

card_driver() {
  local slot
  slot="$(lspci -nn 2>/dev/null | awk '/VGA compatible controller.*NVIDIA/{print $1; exit}')"
  [ -n "$slot" ] || { echo none; return; }
  lspci -nnk -s "$slot" 2>/dev/null |
    awk -F': ' '/Kernel driver in use/{print $2; f=1} END{if(!f)print "none"}'
}

# Pick the X driver that can actually drive the card as it is bound right now.
# modesetting is the generic KMS path and works with any working DRM driver;
# the proprietary stack is the one case that needs its own DDX.
ddx_for() {
  case "$1" in
    nvidia)  echo nvidia ;;
    nouveau) echo modesetting ;;
    *)       echo "" ;;
  esac
}

ddx_present() { [ -e "/usr/lib/xorg/modules/drivers/${1}_drv.so" ]; }

apply() {
  local drv ddx
  drv="$(card_driver)"
  ddx="$(ddx_for "$drv")"

  if [ -z "$ddx" ]; then
    # Nothing recognisable owns the card. An explicit driver would be a guess,
    # and a wrong guess is the very failure we are fixing -- let Xorg autodetect.
    if [ -f "$XORG" ]; then
      say "no known driver owns the card; removing the forced Xorg driver"
      rm -f "$XORG"
    fi
    return 0
  fi

  ddx_present "$ddx" || die "$ddx DDX is not installed (/usr/lib/xorg/modules/drivers/${ddx}_drv.so)"

  if [ -f "$XORG" ] && grep -q "\"$ddx\"" "$XORG"; then
    say "Xorg already set to \"$ddx\" for the $drv kernel driver"
    return 0
  fi

  say "kernel driver is $drv -- setting Xorg Driver to \"$ddx\""
  mkdir -p "$(dirname "$XORG")"
  cat > "$XORG" <<EOF
# Written by lai fix-gui: matched to the kernel driver bound at boot ($drv).
# live-config's 1140-xserver-xorg component would otherwise force Driver
# "nvidia" here on every boot, which crash-loops Xorg whenever nouveau owns
# the card.
Section "Device"
	Identifier	"Default screen"
	Driver		"$ddx"
	Option		"NoLogo"	"true"
EndSection
EOF
}

status() {
  local drv cfg unit
  drv="$(card_driver)"
  # Read the Driver line itself; grepping for any quoted word also matches
  # "NoLogo" "true" and reports the wrong thing.
  cfg="$(awk '/^[[:space:]]*Driver/{gsub(/"/,"",$2); print $2; exit}' "$XORG" 2>/dev/null || true)"
  # is-enabled prints "not-found" on stdout AND exits non-zero for a missing
  # unit, so a bare `|| echo no` prints both.
  unit="$(systemctl is-enabled lai-fix-gui.service 2>/dev/null || true)"
  case "$unit" in ""|not-found) unit=no ;; esac

  printf 'kernel driver   : %s\n' "$drv"
  printf 'wants Xorg DDX  : %s\n' "$(ddx_for "$drv" | sed 's/^$/(autodetect)/')"
  printf 'Xorg configured : %s\n' "${cfg:-(no file)}"
  printf 'unit installed  : %s\n' "$unit"
  printf 'lightdm         : %s, NRestarts=%s\n' \
    "$(systemctl is-active lightdm 2>/dev/null)" \
    "$(systemctl show lightdm -p NRestarts --value 2>/dev/null)"
  printf 'Xorg pid        : %s\n' "$(pgrep Xorg | tr '\n' ' ' || echo none)"
}

install_unit() {
  install -m 0755 "$0" "$SELF"
  cat > "$UNIT" <<EOF
[Unit]
Description=lai: match the Xorg video driver to the bound GPU kernel driver
Documentation=file://$SELF
# live-config rewrites the Xorg device section early in boot; correct it after
# that and before anything tries to start a display.
After=live-config.service
Before=display-manager.service graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF --now

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable lai-fix-gui.service >/dev/null
  say "installed $UNIT (enabled, runs before the display manager)"
}

uninstall_unit() {
  systemctl disable --now lai-fix-gui.service >/dev/null 2>&1 || true
  rm -f "$UNIT" "$SELF"
  systemctl daemon-reload
  say "removed the unit and $SELF (live-config will rewrite $XORG on the next boot)"
}

restart_dm() {
  # A crash-looping display manager spends most of its time in "activating",
  # where is-active --quiet fails -- guarding on it skips the restart in exactly
  # the case we are here to fix. Only skip when the unit genuinely isn't there.
  systemctl cat lightdm >/dev/null 2>&1 || { say "lightdm is not installed; nothing to restart"; return 0; }
  say "restarting lightdm"
  # The restart counter is what tells us whether X is still crash-looping, so
  # clear it first and let the new value speak for itself.
  systemctl reset-failed lightdm 2>/dev/null || true
  systemctl restart lightdm
}

case "${1:---install}" in
  --status) status; exit 0 ;;
  --now)
    [ "$(id -u)" -eq 0 ] || die "run as root"
    apply; exit 0 ;;
  --uninstall)
    [ "$(id -u)" -eq 0 ] || die "run as root"
    uninstall_unit; exit 0 ;;
  --install)
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo bash tools/fix-gui.sh"
    install_unit
    apply
    restart_dm
    sleep 8
    status
    ;;
  *) die "usage: fix-gui.sh [--install | --now | --uninstall | --status]" ;;
esac
