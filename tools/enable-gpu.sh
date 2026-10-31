#!/usr/bin/env bash
# enable-gpu.sh — install NVIDIA's proprietary driver so lai can use the GPU.
#
# lai falls back to CPU when the GPU is on the open-source nouveau/NVK driver,
# because NVK loses the device under llama.cpp's compute (the session crashes).
# This installs the proprietary driver, which blacklists nouveau. After a
# REBOOT, rerun ./install.sh and lai builds for the GPU automatically
# (pick_gpu then sees the NVIDIA Vulkan driver, not NVK).
#
#   sudo bash tools/enable-gpu.sh          install the driver (then reboot)
#   sudo bash tools/enable-gpu.sh --cuda   also install the CUDA toolkit (big)
#
# Live-boot note: this writes to the root filesystem and builds a kernel
# module, so it only survives a reboot on a PERSISTENT / installed Parrot
# whose persistence covers the root overlay. On a pure-RAM live boot the
# driver is gone next boot — install Parrot to disk (or use full persistence)
# if you want the GPU across reboots.
set -euo pipefail

say()  { printf '\033[1m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m  error:\033[0m %s\n' "$*" >&2; exit 1; }

WITH_CUDA=0
[ "${1:-}" = "--cuda" ] && WITH_CUDA=1

SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo
command -v apt-get >/dev/null 2>&1 || die "this helper is for Debian/Parrot (apt). Install the NVIDIA driver your distro's way, then rerun ./install.sh"

# must actually be an NVIDIA card
if ! { command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi nvidia; }; then
  die "no NVIDIA GPU found with lspci — nothing to do (lai will keep using the CPU)"
fi
say "NVIDIA GPU detected: $(lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -i nvidia | sed 's/^[^:]*: //' | head -1)"

# nvidia-driver lives in Debian's contrib/non-free; make sure they're enabled
if ! $SUDO apt-get install -y -qq --dry-run nvidia-driver >/dev/null 2>&1; then
  say "enabling contrib/non-free apt components for the driver package"
  if command -v add-apt-repository >/dev/null 2>&1; then
    $SUDO add-apt-repository -y contrib non-free non-free-firmware >/dev/null 2>&1 || true
  fi
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    # append the components to any plain 'main'-only deb lines, once
    $SUDO sed -i -E '/non-free/! s/^(deb .* main)$/\1 contrib non-free non-free-firmware/' "$f" 2>/dev/null || true
  done
fi

say "updating apt and installing the proprietary driver (this is a large download)"
$SUDO apt-get update -qq
$SUDO apt-get install -y nvidia-driver firmware-misc-nonfree || \
  die "driver install failed. On Parrot try: sudo apt install nvidia-driver (or check 'apt-cache search nvidia-driver')"

if [ "$WITH_CUDA" = 1 ]; then
  say "installing the CUDA toolkit (for LAI_GPU=cuda builds; large)"
  $SUDO apt-get install -y nvidia-cuda-toolkit || warn "CUDA toolkit install failed; the Vulkan path still works without it"
fi

$SUDO apt-get clean  # drop the .debs (they sit in RAM on a live boot)

cat <<'DONE'

  ->  Driver installed. nouveau is now blacklisted, but it is still loaded
      until you reboot. Finish with:

        sudo reboot

      Then rebuild lai for the GPU (auto-detects the GPU now):

        cd ~/lai && ./install.sh --serve

  ->  On a 4 GB card (e.g. GTX 1650) a 7-9B model does not fully fit in VRAM.
      lai will still use the GPU, but for a dense model larger than your VRAM
      set a partial offload in ~/.config/lai/config.json, e.g.:

        "gpu_layers": 20      (raise until VRAM is ~full; watch `nvidia-smi`)

      Force the backend explicitly if you like: LAI_GPU=vulkan ./install.sh
      (or LAI_GPU=cuda, if you installed the CUDA toolkit with --cuda).
DONE
