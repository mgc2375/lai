#!/usr/bin/env bash
# One-command setup for Parrot OS / Debian:
#
#   ./install.sh                   download the recommended model, build, configure
#   ./install.sh /path/model.gguf  use a model you already have
#   ./install.sh --find            search your drives for a .gguf instead
#   ./install.sh --serve           ...then start the phone page (lai serve)
#   ./install.sh --mcp             ...also clone & set up the pentest MCP servers
#                                  (hexstrike, kali, impacket, pentester, bloodhound)
#   ./install.sh --memguard        ...also run the memory guard (swap + soft RAM cap).
#                                  LAI_PERSIST_SWAP=11G puts the swapfile on the
#                                  persistence partition (reserved once, reused each boot)
#   ./install.sh --tools           ...install the CLI tools the MCP servers call
#                                  (skips what Parrot has; shims the rest on-demand)
#   LAI_DISK=sdc ./install.sh ...   carve lai-data (10G ext4) + lai-swap (11G) out of
#                                  that disk's free space (detected+reused next boot)
#
#   NGROK_AUTHTOKEN=... NGROK_DOMAIN=name.ngrok-free.dev ./install.sh --serve
#                                  use another ngrok account (defaults below;
#                                  NGROK_AUTHTOKEN= NGROK_DOMAIN= skips ngrok)
#
# Re-running skips whatever is already done (download, build, config).
#
# Persistence (live boot): point LAI_PERSIST at a folder on a real drive
# (e.g. your USB persistence partition) and the model, the built engine and
# the config all live there, so after a reboot the same command finds
# everything ready and just starts - no re-download, no rebuild:
#
#   LAI_PERSIST=/run/live/persistence/xxx/lai ./install.sh --serve
#
# MCP servers: install.sh imports an OpenCode or Claude Desktop config when it
# finds one (LAI_MCP overrides the path). Keep that config - and anything the
# servers need (tool clones, their backends) - on the persistent drive too, so
# they survive a reboot; lai re-imports the config on every run.
#
# Overrides: LAI_MODEL_URL (model to download), LAI_MODEL_DIR (where to keep
# it), LAI_DIR (install folder), LAI_MCP (MCP config to import),
# LAI_GPU=cpu|vulkan|cuda|rocm, LLAMA_TAG.
set -euo pipefail

# lai-engine uses llama.cpp's internal chat helpers, which change between
# versions, so it is built against this tested tag.
LLAMA_TAG="${LLAMA_TAG:-b11982}"
# test ngrok account for the phone page (set NGROK_AUTHTOKEN= to skip ngrok)
NGROK_AUTHTOKEN="${NGROK_AUTHTOKEN-3KlWECINqX6TREUEicydo49Fdca_7Y3tYCMbphn5brHqKEsqh}"
NGROK_DOMAIN="${NGROK_DOMAIN-sasquatch-ducking-revered.ngrok-free.dev}"
# fixed access key the serve endpoint requires (the Mac companion sends it as a
# Bearer token). Overrides the random serve.key. Change it for anything real.
export LAI_SERVE_KEY="${LAI_SERVE_KEY-test-key-change_me}"
# small, abliterated, strong at code and tool calls (see README)
LAI_MODEL_URL="${LAI_MODEL_URL:-https://huggingface.co/mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF/resolve/main/Huihui-Qwen3.5-9B-abliterated.Q6_K.gguf}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# mount_persist DEV: mount a persistence partition (e.g. /dev/sdc3) read-write
# and echo its mountpoint. If already mounted, reuses that.
mount_persist() {
  local dev="$1" mp
  [ -b "$dev" ] || { echo ""; return 1; }
  mp="$(findmnt -nro TARGET --source "$dev" 2>/dev/null | head -1)"
  if [ -z "$mp" ]; then
    mp="/mnt/lai-persist"
    ${SUDO:-sudo} mkdir -p "$mp" 2>/dev/null
    ${SUDO:-sudo} mount "$dev" "$mp" 2>/dev/null || { echo ""; return 1; }
  fi
  echo "$mp"
}

# LAI_PERSIST: where the binaries, engine, MCP tools and config live so a live
# boot finds them ready. The model stays in RAM (re-downloaded each boot) unless
# you also set LAI_MODEL_DIR. LAI_PERSIST may be a folder OR a block device
# (e.g. /dev/sdc3), which is mounted first.
if [ -n "${LAI_PERSIST:-}" ]; then
  SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo
  if [ -b "$LAI_PERSIST" ]; then
    _mp="$(mount_persist "$LAI_PERSIST")" || die "couldn't mount $LAI_PERSIST"
    [ -n "$_mp" ] || die "couldn't mount $LAI_PERSIST"
    LAI_PERSIST_MOUNT="$_mp"   # the partition root, for an on-partition swapfile
    LAI_PERSIST="$_mp/lai"
  fi
  mkdir -p "$LAI_PERSIST" || die "can't create $LAI_PERSIST"
  : "${LAI_DIR:=$LAI_PERSIST}"          # binaries, engine, mcp-tools, config -> persistent drive
  : "${LAI_MODEL_DIR:=$HOME/models}"     # model -> RAM (home); set LAI_MODEL_DIR to keep it on disk
fi

file_mb() { echo $(( $(wc -c < "$1") / 1048576 )); }

# find_model prints the chosen .gguf: the only one found, or the user's pick
find_model() {
  local roots=() r list n i choice
  for r in /media /mnt /run/media /run/live/persistence "$HOME"; do
    [ -d "$r" ] && roots+=("$r")
  done
  # skip vision projectors and the non-first parts of split models
  list="$(find "${roots[@]}" -maxdepth 6 -type f -iname '*.gguf' -size +200M 2>/dev/null \
          | grep -viE 'mmproj|-0000[2-9]-of-|-000[1-9][0-9]-of-' | sort -u || true)"
  n=0
  [ -n "$list" ] && n="$(printf '%s\n' "$list" | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then
    die "no .gguf model found under ${roots[*]}. Run: ./install.sh /path/to/model.gguf"
  fi
  if [ "$n" -eq 1 ]; then
    printf '%s\n' "$list"
    return
  fi
  if [ -t 0 ]; then
    echo "found $n models:" >&2
    i=0
    while IFS= read -r r; do
      i=$((i + 1))
      printf '  %d) %s (%s MB)\n' "$i" "$r" "$(file_mb "$r")" >&2
    done <<< "$list"
    printf 'which one? [1-%d] ' "$n" >&2
    read -r choice
    case "$choice" in ''|*[!0-9]*) die "not a number" ;; esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || die "pick 1-$n"
    printf '%s\n' "$list" | sed -n "${choice}p"
  else
    # no terminal to ask: take the biggest
    while IFS= read -r r; do printf '%s %s\n' "$(file_mb "$r")" "$r"; done <<< "$list" \
      | sort -rn | head -1 | cut -d' ' -f2-
  fi
}

# pick_gpu prints cpu or vulkan. Only a discrete GPU with a working Vulkan
# driver counts: an integrated GPU shares system RAM, so offloading to it
# would hold the weights twice.
pick_gpu() {
  if ! command -v lspci >/dev/null 2>&1 || ! lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qiE 'nvidia|amd|ati|radeon'; then
    echo cpu
    return
  fi
  if ! command -v vulkaninfo >/dev/null 2>&1; then
    $SUDO apt-get install -y -qq vulkan-tools >/dev/null 2>&1 || true
  fi
  local vk
  vk="$(vulkaninfo --summary 2>/dev/null || true)"
  if printf '%s' "$vk" | grep -q 'PHYSICAL_DEVICE_TYPE_DISCRETE_GPU'; then
    # nouveau's Vulkan driver (NVK) loses the device under heavy compute
    if printf '%s' "$vk" | grep -qiE 'driverName *= *NVK|MESA_NVK|nouveau'; then
      warn "your NVIDIA GPU is on the open-source nouveau/NVK driver, which crashes on this workload; building for CPU (install nvidia-driver to use the GPU)"
      echo cpu
      return
    fi
    echo vulkan
  else
    warn "found a GPU but no working Vulkan driver for it (NVIDIA: install nvidia-driver); building for CPU"
    echo cpu
  fi
}

# gpu_vram_mb: total VRAM (MB) of the first NVIDIA GPU, or empty if unknown
gpu_vram_mb() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9'
}

# gguf_block_count FILE: transformer-layer count from the GGUF header, or empty
gguf_block_count() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" <<'PY' 2>/dev/null || true
import struct, sys
try:
    f = open(sys.argv[1], "rb")
    if f.read(4) != b"GGUF":
        sys.exit(0)
    f.read(4)                                   # version
    f.read(8)                                   # tensor count
    n_kv = struct.unpack("<Q", f.read(8))[0]
    def rd(fmt): return struct.unpack(fmt, f.read(struct.calcsize(fmt)))[0]
    def rstr(): return f.read(rd("<Q"))
    SZ = {0:1, 1:1, 2:2, 3:2, 4:4, 5:4, 6:4, 7:1, 10:8, 11:8, 12:8}
    def skip(t):
        if t in SZ: f.read(SZ[t])
        elif t == 8: rstr()
        elif t == 9:
            et = rd("<I"); n = rd("<Q")
            for _ in range(n): skip(et)
        else: raise ValueError(t)
    for _ in range(n_kv):
        key = rstr().decode("utf-8", "replace")
        t = rd("<I")
        if key.endswith(".block_count"):
            fmt = {0:"<B", 1:"<b", 2:"<H", 3:"<h", 4:"<I", 5:"<i", 10:"<Q", 11:"<q"}.get(t)
            if fmt: print(int(rd(fmt)))
            break
        skip(t)
except Exception:
    pass
PY
}

# fit_gpu_layers MODEL VRAM_MB: how many layers to offload so the weights fit
# VRAM (the KV cache stays in RAM). Conservative — errs low. Empty if unknown.
fit_gpu_layers() {
  local model="$1" vram="${2:-}" layers model_mb reserve budget per n
  case "$vram" in ''|*[!0-9]*) return 0 ;; esac
  [ "$vram" -gt 0 ] || return 0
  model_mb="$(file_mb "$model")"
  reserve=1024                                  # compute buffer + headroom (KV is in RAM)
  budget=$(( vram - reserve )); [ "$budget" -lt 0 ] && budget=0
  layers="$(gguf_block_count "$model")"
  if [ -n "$layers" ] && [ "$layers" -gt 0 ] 2>/dev/null; then
    per=$(( (model_mb + layers - 1) / layers )); [ "$per" -lt 1 ] && per=1
    n=$(( budget / per )); [ "$n" -gt "$layers" ] && n="$layers"
  else
    n=$(( budget * 40 / (model_mb + 1) ))       # no layer count: assume ~40, err low
  fi
  [ "$n" -lt 0 ] && n=0
  echo "$n"
}

# nvidia_active: the proprietary NVIDIA driver is loaded and the GPU responds
# (nvidia-smi only works on the proprietary driver, not nouveau/NVK)
nvidia_active() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; }

# root_persistent: do changes to / (where the GPU driver installs) survive a
# reboot? True when installed to disk, or a live boot whose ROOT overlay's write
# layer sits on a persistence volume (full '/ union' persistence) — NOT just any
# persistence (a data-partition persistence doesn't keep the driver). Guards
# against a futile driver-install + reboot that reverts to nouveau every time.
root_persistent() {
  if ! grep -qw 'boot=live' /proc/cmdline 2>/dev/null && [ ! -d /run/live ]; then
    return 0                                   # not a live session -> installed to disk
  fi
  local line upper src
  line="$(awk '$2=="/"{print; exit}' /proc/mounts 2>/dev/null)"
  case "$line" in *overlay*) ;; *) return 1 ;; esac
  upper="$(printf '%s\n' "$line" | tr ',' '\n' | sed -n 's/^upperdir=//p' | head -1)"
  [ -n "$upper" ] || return 1
  case "$upper" in /run/live/persistence/*) return 0 ;; esac
  command -v findmnt >/dev/null 2>&1 || return 1
  src="$(findmnt -no SOURCE -T "$upper" 2>/dev/null || true)"
  case "$src" in /dev/*) return 0 ;; *) return 1 ;; esac      # on a disk, not tmpfs/RAM
}

# live_persistence_present: a live boot has persistence enabled (even if it only
# covers data, not root) — used to pick the right fix message.
live_persistence_present() {
  grep -qw persistence /proc/cmdline 2>/dev/null && return 0
  [ -d /run/live/persistence ] && command -v findmnt >/dev/null 2>&1 \
    && findmnt -rn /run/live/persistence >/dev/null 2>&1
}

# live_boot_disk: the whole-disk kernel name (e.g. sdc) the live system booted
# from — the USB stick that holds the ISO and (usually) the leftover free space.
# Found via the live medium mount; empty if it can't be worked out. Used to carve
# the persistence partition automatically, so the bare one-command install needs
# no LAI_DISK. (setup-persistence.sh only ever touches that disk's FREE space and
# verifies every existing partition is untouched, so sdc1/sdc2 stay safe.)
live_boot_disk() {
  command -v lsblk >/dev/null 2>&1 || return 0
  command -v findmnt >/dev/null 2>&1 || return 0
  local src="" mp disk=""
  # NOTE: every pipeline/command-sub here ends in '|| true' and the function
  # always 'return 0' — under the script's set -euo pipefail a bare non-zero here
  # would abort install.sh silently (no output) from the caller's "$(...)".
  for mp in /run/live/medium /lib/live/mount/medium /run/live/findfs; do
    src="$(findmnt -nro SOURCE "$mp" 2>/dev/null | head -1 || true)"
    [ -n "$src" ] && break
  done
  # last resort: the disk holding any mount under /run/live
  [ -n "$src" ] || src="$(findmnt -nro SOURCE /run/live/* 2>/dev/null | grep -m1 '^/dev/' || true)"
  case "$src" in /dev/*) ;; *) return 0 ;; esac
  disk="$(lsblk -nro PKNAME "$src" 2>/dev/null | head -1 || true)"
  [ -n "$disk" ] || disk="$(basename "$src" 2>/dev/null | sed -E 's/p?[0-9]+$//' || true)"
  if [ -n "$disk" ] && [ -b "/dev/$disk" ]; then echo "$disk"; fi
  return 0
}

# existing_persist_partition DISK: the biggest existing ext2/3/4 partition on
# DISK that isn't the running root or the live medium (the ISO) — i.e. a spare
# data partition like /dev/sdc3 we can turn into the persistence volume without
# carving anything. Needs ~4 GB+. Empty if there's no suitable one.
existing_persist_partition() {
  local disk="$1" root_src="" medium="" best="" bestsz=0 name sz typ fstype dev
  [ -n "$disk" ] || return 0
  command -v lsblk >/dev/null 2>&1 || return 0
  # (same set -e discipline as live_boot_disk: guard every pipe, always return 0)
  root_src="$(findmnt -nro SOURCE / 2>/dev/null || true)"
  medium="$(findmnt -nro SOURCE /run/live/medium 2>/dev/null | head -1 || true)"
  # list partitions with byte sizes; read fstype straight off each device with
  # blkid (probes the superblock — reliable even when lsblk's column is blank)
  while read -r name sz typ; do
    [ "${typ:-}" = part ] || continue
    dev="/dev/$name"
    [ "$dev" = "$root_src" ] && continue
    [ "$dev" = "$medium" ] && continue
    case "${sz:-}" in ''|*[!0-9]*) continue ;; esac
    [ "$sz" -ge $((4 * 1024 * 1024 * 1024)) ] || continue       # >= 4 GB
    fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    case "$fstype" in ext2|ext3|ext4) ;; *) continue ;; esac
    if [ "$sz" -gt "$bestsz" ]; then best="$dev"; bestsz="$sz"; fi
  done < <(lsblk -bnro NAME,SIZE,TYPE "/dev/${disk#/dev/}" 2>/dev/null || true)
  [ -n "$best" ] && echo "$best"
  return 0
}

# seed_persist_resume DEV ARGS...: pre-seed an auto-continue onto the just-made
# persistence partition DEV, so after the user picks the "persistence" boot entry
# the install CONTINUES by itself (desktop auto-login) — no re-clone, no re-typing.
# The persistence partition's filesystem root IS the '/ union' overlay's write
# layer, so a file written at <part>/home/<user>/x appears at /home/<user>/x once
# persistence is active. We copy this repo there (it's in RAM otherwise, gone on
# reboot) and drop an autostart entry that reruns ./install.sh. The driver-reboot
# that follows is then handled by the normal arm_autoresume (/home persists by
# then). Best-effort: returns 1 if it can't seed (caller falls back to "rerun").
#   LAI_NO_AUTORESUME=1  skip (user reruns the command after the reboot instead)
seed_persist_resume() {
  local dev="$1"; shift
  [ "${LAI_NO_AUTORESUME:-}" = 1 ] && return 1
  [ -b "$dev" ] || return 1
  local ru rh ruid rgid mp base dest ad resume home_rel v
  ru="${SUDO_USER:-$(id -un)}"
  rh="$(getent passwd "$ru" 2>/dev/null | cut -d: -f6)"; [ -n "$rh" ] || rh="/home/$ru"
  ruid="$(id -u "$ru" 2>/dev/null || echo 1000)"
  rgid="$(id -g "$ru" 2>/dev/null || echo 1000)"
  base="$(basename "$HERE")"
  home_rel="${rh#/}"                                  # e.g. home/live
  mp="$(mktemp -d)"
  $SUDO mount "$dev" "$mp" 2>/dev/null || { rmdir "$mp" 2>/dev/null || true; return 1; }

  dest="$mp/$home_rel/$base"                          # the repo, persisted
  ad="$mp/$home_rel/.config/autostart"
  resume="$mp/$home_rel/.lai-persist-resume.sh"
  $SUDO mkdir -p "$dest" "$ad" 2>/dev/null
  # copy the whole repo onto the partition so it's there after the reboot
  if ! $SUDO cp -a "$HERE/." "$dest/" 2>/dev/null; then
    $SUDO umount "$mp" 2>/dev/null || true; rmdir "$mp" 2>/dev/null || true; return 1
  fi

  # resume script: paths below are the REAL runtime paths (/home/<user>/…), not $mp
  {
    echo '#!/usr/bin/env bash'
    echo '# auto-generated: continues the lai install after the persistence reboot'
    echo 'set -u'
    for v in LAI_PERSIST LAI_PERSIST_SWAP LAI_DISK LAI_DISK_YES LAI_DATA_SIZE LAI_SWAP_SIZE \
             LAI_MODEL_DIR LAI_MODEL_URL LAI_DIR LAI_MCP LAI_MCP_ONLY LAI_GPU SWAP_DEV \
             SOFT_CAP_GB RAMP_START_GB IDLE_MIN SWAP_SIZE ZRAM_SIZE ZRAM NGROK_AUTHTOKEN \
             NGROK_DOMAIN SHODAN_API_KEY VIRUSTOTAL_API_KEY CM_API_KEY GEMINI_API_KEY \
             BLOODHOUND_DOMAIN BLOODHOUND_TOKEN_ID BLOODHOUND_TOKEN_KEY; do
      [ -n "${!v:-}" ] && printf 'export %s=%q\n' "$v" "${!v}"
    done
    printf 'rm -f %q\n' "$rh/.config/autostart/lai-persist-resume.desktop"  # run once
    printf 'cd %q || exit 0\n' "$rh/$base"
    printf 'command -v notify-send >/dev/null 2>&1 && notify-send lai "Persistence active — continuing install (GPU driver next)…" || true\n'
    printf './install.sh'
    for v in "$@"; do printf ' %q' "$v"; done
    printf ' >> %q 2>&1\n' "$rh/$base/.lai-resume.log"
    printf 'rm -f %q\n' "$rh/.lai-persist-resume.sh"                        # self-delete
  } | $SUDO tee "$resume" >/dev/null 2>&1 || { $SUDO umount "$mp" 2>/dev/null || true; rmdir "$mp" 2>/dev/null || true; return 1; }
  $SUDO chmod 700 "$resume" 2>/dev/null || true

  $SUDO tee "$ad/lai-persist-resume.desktop" >/dev/null 2>&1 <<EOF || { $SUDO umount "$mp" 2>/dev/null || true; rmdir "$mp" 2>/dev/null || true; return 1; }
[Desktop Entry]
Type=Application
Name=Finish lai install (after persistence)
Exec=$rh/.lai-persist-resume.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

  $SUDO chown -R "$ruid:$rgid" "$mp/$home_rel" 2>/dev/null || true
  $SUDO sync
  $SUDO umount "$mp" 2>/dev/null || true
  rmdir "$mp" 2>/dev/null || true
  return 0
}

# ensure_root_persistence: run BEFORE the driver gate. On a live boot where /
# doesn't persist, set up full root persistence so the GPU driver (and apt, and
# /home) survive reboots — reusing a 'persistence'-labelled partition if present,
# else carving a DEDICATED one from the free space of $LAI_DISK via
# tools/setup-persistence.sh. It then stops and asks for a reboot into the
# persistence entry, since nothing should install onto a non-persistent /.
# Never touches the LAI_PERSIST data partition. Skip with LAI_SKIP_ROOT_PERSIST=1.
ensure_root_persistence() {
  [ "${LAI_SKIP_ROOT_PERSIST:-}" = 1 ] && return 0
  grep -qw 'boot=live' /proc/cmdline 2>/dev/null || return 0       # installed to disk: nothing to do
  root_persistent && return 0                                       # / already persists

  # target is what we hand to setup-persistence.sh: an existing ext4 PARTITION
  # (e.g. /dev/sdc3 — relabelled + '/ union', non-destructive) when there is one,
  # else a whole DISK to carve from. The user can force either via LAI_DISK /
  # LAI_PERSIST_DISK (a disk) or by pointing those at a partition.
  local target="${LAI_DISK:-${LAI_PERSIST_DISK:-}}" have_pp out dev auto=0 bootdisk
  have_pp="$(blkid -L persistence 2>/dev/null || true)"
  if [ -z "$have_pp" ] && [ -z "$target" ]; then
    bootdisk="$(live_boot_disk || true)"
    if [ -z "$bootdisk" ]; then
      warn "to run on the GPU, lai needs the driver to survive reboots, which needs root persistence — but I couldn't work out which disk this live USB is. Point me at a spare ext4 partition and I'll use it:  LAI_PERSIST_DISK=/dev/sdXN ./install.sh --serve --mcp  (list them with: lsblk -f). Running on CPU for now."
      LAI_GPU=cpu
      return 0
    fi
    auto=1
    # prefer an existing spare partition on the USB (e.g. your 21 GB sdc3) over
    # carving — works on MBR sticks too, and it's what you asked for.
    target="$(existing_persist_partition "$bootdisk" || true)"
    if [ -n "$target" ]; then
      say "no 'persistence' partition yet — using the existing $target on the live USB as the root-persistence volume (relabelled 'persistence' + '/ union'; your data on it is kept)"
    else
      target="/dev/${bootdisk#/dev/}"
      say "no 'persistence' partition yet and no spare ext4 partition found — carving one from the free space of $target"
    fi
  fi

  local where="reusing the existing persistence partition"
  [ -n "$target" ] && where="$target"
  say "setting up full root persistence so the GPU driver survives reboots ($where)"
  # auto => no confirm (you asked for one hands-off command); an explicitly-given
  # target still prompts (whole-disk carve only) unless LAI_DISK_YES=1.
  if ! out="$($SUDO env LAI_DISK_YES="${LAI_DISK_YES:-$auto}" bash "$HERE/tools/setup-persistence.sh" ${target:+"$target"} "${LAI_PERSIST_ROOT_SIZE:-6G}")"; then
    warn "couldn't set up root persistence (see above). Running on CPU; set it up by hand: sudo bash tools/setup-persistence.sh ${target:-sdXN}"
    LAI_GPU=cpu
    return 0
  fi
  dev="$(printf '%s\n' "$out" | sed -n 's/^LAI_PERSISTENCE_DEV=//p' | tail -1)"

  local seeded=0 rh_log
  rh_log="~/$(basename "$HERE")/.lai-resume.log"
  if [ -n "$dev" ] && seed_persist_resume "$dev" "$@"; then
    seeded=1
  fi

  if [ "$seeded" = 1 ]; then
    cat >&2 <<EOF

  ->  Root persistence is set up on $dev, and the install is primed to CONTINUE on
      its own after the reboot. The only thing left to do:

        1) sudo reboot
        2) at the boot menu, pick the entry that says "persistence"

      That's it — nothing to type. It auto-logs in and finishes (installs the GPU
      driver, reboots once more — pick "persistence" again — then builds and starts
      lai). Progress log: $rh_log
EOF
  else
    cat >&2 <<EOF

  ->  Root persistence is set up${dev:+ on $dev}. It activates on the NEXT boot of the
      "persistence" entry. Finish with:

        1) sudo reboot
        2) in the boot menu choose the entry that says "persistence"
        3) cd $HERE && ./install.sh $*

      From there the driver installs and STAYS, and the rest runs on its own.
EOF
  fi
  exit 0
}

# ensure_gpu_driver: run BEFORE downloading anything. If the box has an NVIDIA
# GPU on the open-source nouveau driver (which crashes this workload), install
# the proprietary driver and reboot — so the model download and build happen on
# the right driver, not twice. Returns (continuing on CPU, no reboot) when there
# is no NVIDIA GPU, CPU was requested, or a live boot can't keep the driver.
#   LAI_GPU=cpu / LAI_SKIP_GPU_DRIVER=1  skip the whole check
#   LAI_NO_REBOOT=1                      install the driver but don't auto-reboot
#   LAI_NO_AUTORESUME=1                  don't auto-finish after the reboot
#   LAI_FORCE_REBOOT=1                   reboot even on a non-persistent live boot

# arm_autoresume ARGS...: after the driver reboot, finish the install on its own
# via a desktop-autostart entry (Parrot live auto-logs in). The entry reruns the
# same install, then deletes itself. Best-effort: if it can't be set up (no
# writable autostart dir, non-persistent /home), the user just reruns the line.
arm_autoresume() {
  [ "${LAI_NO_AUTORESUME:-}" = 1 ] && return 1
  local ru rh ad resume v
  ru="${SUDO_USER:-$(id -un)}"
  rh="$(getent passwd "$ru" 2>/dev/null | cut -d: -f6)"; [ -n "$rh" ] || rh="$HOME"
  ad="$rh/.config/autostart"
  resume="$HERE/.lai-resume.sh"
  {
    echo '#!/usr/bin/env bash'
    echo '# auto-generated: finishes the lai install after the GPU-driver reboot'
    echo 'set -u'
    for v in LAI_PERSIST LAI_PERSIST_SWAP LAI_DISK LAI_DISK_YES LAI_DATA_SIZE LAI_SWAP_SIZE \
             LAI_MODEL_DIR LAI_MODEL_URL LAI_DIR LAI_MCP LAI_MCP_ONLY LAI_GPU SWAP_DEV \
             SOFT_CAP_GB RAMP_START_GB IDLE_MIN SWAP_SIZE ZRAM_SIZE ZRAM NGROK_AUTHTOKEN \
             NGROK_DOMAIN SHODAN_API_KEY VIRUSTOTAL_API_KEY CM_API_KEY GEMINI_API_KEY \
             BLOODHOUND_DOMAIN BLOODHOUND_TOKEN_ID BLOODHOUND_TOKEN_KEY; do
      [ -n "${!v:-}" ] && printf 'export %s=%q\n' "$v" "${!v}"
    done
    printf 'rm -f %q\n' "$ad/lai-resume.desktop"           # don't run again
    printf 'cd %q || exit 0\n' "$HERE"
    printf 'command -v notify-send >/dev/null 2>&1 && notify-send lai "Finishing install (model + build)…" || true\n'
    printf 'LAI_SKIP_GPU_DRIVER=1 ./install.sh'
    for v in "$@"; do printf ' %q' "$v"; done
    printf ' >> %q 2>&1\n' "$HERE/.lai-resume.log"
    printf 'command -v notify-send >/dev/null 2>&1 && notify-send lai "Install finished." || true\n'
    printf 'rm -f %q\n' "$resume"                           # self-delete (it holds the env/keys)
  } > "$resume" 2>/dev/null || { warn "couldn't write the resume script; after the reboot rerun the install command to finish"; return 1; }
  chmod 700 "$resume" 2>/dev/null || true
  mkdir -p "$ad" 2>/dev/null || true
  cat > "$ad/lai-resume.desktop" 2>/dev/null <<EOF || { warn "couldn't arm auto-resume (no writable autostart dir); after the reboot rerun the install command to finish"; return 1; }
[Desktop Entry]
Type=Application
Name=Finish lai install
Exec=$resume
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  return 0
}

ensure_gpu_driver() {
  [ "${LAI_GPU:-}" = cpu ] && return 0
  [ "${LAI_SKIP_GPU_DRIVER:-}" = 1 ] && return 0
  command -v lspci >/dev/null 2>&1 || return 0
  lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi nvidia || return 0

  local marker="$HERE/.lai-driver-attempted"
  if nvidia_active; then
    say "proprietary NVIDIA driver active"
    rm -f "$marker" 2>/dev/null || true
    return 0
  fi

  warn "your NVIDIA GPU is on the open-source nouveau/NVK driver, which crashes under llama.cpp compute"
  if [ -f "$marker" ]; then
    warn "the driver was installed and the box rebooted once, but it's still on nouveau — this live boot isn't keeping the driver across reboots. Continuing on CPU. Install Parrot to disk (or enable root persistence) to use the GPU; set LAI_SKIP_GPU_DRIVER=1 to silence this."
    LAI_GPU=cpu
    return 0
  fi
  if ! root_persistent && [ "${LAI_FORCE_REBOOT:-}" != 1 ]; then
    if live_persistence_present; then
      warn "your live USB has persistence, but it doesn't cover the ROOT filesystem — so the GPU driver (installed into /) wouldn't survive a reboot. Turn on full root persistence first:  sudo bash tools/persist-root.sh  (then reboot into the persistence boot entry and rerun). Running on CPU for now; LAI_FORCE_REBOOT=1 overrides."
    else
      warn "this looks like a non-persistent live boot, so a driver install wouldn't survive the reboot. Turn on full root persistence:  sudo bash tools/persist-root.sh  (and boot the persistence menu entry). Running on CPU for now; LAI_FORCE_REBOOT=1 overrides."
    fi
    LAI_GPU=cpu
    return 0
  fi

  say "installing the proprietary NVIDIA driver first — before downloading the model, so nothing is wasted across the reboot"
  if ! bash "$HERE/tools/enable-gpu.sh" --from-install; then
    warn "driver install failed; continuing on CPU (see the apt output above). Retry by hand with: sudo bash tools/enable-gpu.sh"
    LAI_GPU=cpu
    return 0
  fi
  : > "$marker" 2>/dev/null || true

  # pre-install the build toolchain now, while we have sudo, so the post-reboot
  # finish needs no password
  say "pre-installing build tools so the finish-after-reboot is hands-off"
  $SUDO apt-get install -y -qq build-essential cmake git libvulkan-dev glslc spirv-headers \
    vulkan-tools python3 python3-venv python3-pip nodejs npm golang-go >/dev/null 2>&1 || true

  local resumed=1
  arm_autoresume "$@" || resumed=0

  if [ "${LAI_NO_REBOOT:-}" = 1 ]; then
    if [ "$resumed" = 1 ]; then
      say "driver installed. It'll finish on its own the next time you reboot and log in — nothing to type."
    else
      say "driver installed. Reboot, then rerun this exact command to finish."
    fi
    exit 0
  fi
  if [ "$resumed" = 1 ]; then
    warn "driver installed — rebooting in 10s. It finishes on its own after the reboot (desktop auto-login); you don't need to run anything. Progress: $HERE/.lai-resume.log. Ctrl-C to cancel."
  else
    warn "driver installed — rebooting in 10s to load it. Rerun this same command after the reboot to finish. Ctrl-C to cancel; LAI_NO_REBOOT=1 skips the auto-reboot."
  fi
  sleep 10
  $SUDO reboot
  exit 0
}

# build_engine WORK [cmake flags...]: configure and compile lai-engine,
# printing the relevant part of the log on failure
build_engine() {
  local work="$1"; shift
  if ! cmake -S "$HERE/engine" -B "$work/build" -DLLAMA_DIR="$work/llama.cpp" -DCMAKE_BUILD_TYPE=Release "$@" >"$work/cmake.log" 2>&1; then
    grep -E -A4 'CMake Error' "$work/cmake.log" | head -20 >&2
    return 1
  fi
  if ! cmake --build "$work/build" --target lai-engine -j"$(nproc)" >"$work/build.log" 2>&1; then
    grep -E 'error' "$work/build.log" | head -20 >&2
    return 1
  fi
}

# install_engine DIR GPU: install build tools, build lai-engine for GPU
# (cpu, vulkan, cuda, rocm) and put it in DIR. Returns 1 if the build fails.
install_engine() {
  local dir="$1" gpu="$2"
  local pkgs=(build-essential cmake git) missing=() p flags=()
  case "$gpu" in
    cpu)    ;;
    vulkan) pkgs+=(libvulkan-dev glslc spirv-headers); flags+=(-DGGML_VULKAN=ON) ;;
    cuda)   pkgs+=(nvidia-cuda-toolkit); flags+=(-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=native) ;;
    rocm)   flags+=(-DGGML_HIP=ON) ;;
    *) die "unknown LAI_GPU=$gpu (cpu, vulkan, cuda, rocm)" ;;
  esac
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -gt 0 ]; then
    say "installing build tools: ${missing[*]}"
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq "${missing[@]}"
    $SUDO apt-get clean  # drop the downloaded .debs (they sit in RAM on a live boot)
  fi
  local work="${TMPDIR:-/tmp}/lai-build"
  rm -rf "$work"
  say "fetching llama.cpp $LLAMA_TAG"
  git clone -q --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$work/llama.cpp"
  say "building lai-engine; this takes a few minutes"
  build_engine "$work" ${flags[@]+"${flags[@]}"} || return 1
  install -m 755 "$work/build/lai-engine" "$dir/lai-engine"
  echo "$LLAMA_TAG $gpu" > "$dir/.lai-engine-build"
  rm -rf "$work"
}

# gpu_works ENGINE MODEL: generate one token on the GPU build. Some drivers
# build fine but lose the device as soon as real work starts.
gpu_works() { # ENGINE MODEL [NGL]
  local out ngl=()
  [ -n "${3:-}" ] && ngl=(-ngl "$3")
  out="$(printf '%s\n' '{"messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
         | timeout 900 "$1" -m "$2" -c 1024 ${ngl[@]+"${ngl[@]}"} --cpu-moe --kv q8_0 --ubatch 256 2>/dev/null || true)"
  case "$out" in
    *'"done"'*) return 0 ;;
    *) return 1 ;;
  esac
}

# fetch_model URL DIR: download (resumable) and print the path; skips a
# file that is already complete
fetch_model() {
  local url="$1" dir="$2" name path
  name="$(basename "${url%%\?*}")"
  path="$dir/$name"
  mkdir -p "$dir"
  if [ -f "$path" ]; then
    say "model already downloaded: $path" >&2
  else
    say "downloading $name (resumes if interrupted)" >&2
    curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$path.part" "$url" >&2 \
      || die "download failed; run install.sh again to resume ($url)"
    mv "$path.part" "$path"
  fi
  printf '%s\n' "$path"
}

# setup_ngrok DIR: install the ngrok agent next to lai and save the token
setup_ngrok() {
  local dir="$1" bin arch="$GOARCH" u
  [ -n "${NGROK_AUTHTOKEN:-}" ] || [ -n "${NGROK_DOMAIN:-}" ] || return 0
  bin="$(command -v ngrok || true)"
  if [ -z "$bin" ]; then
    bin="$dir/ngrok"
    if [ ! -x "$bin" ]; then
      say "installing ngrok"
      for u in "https://bin.ngrok.com/c/bNyj1mQVY4c/ngrok-v3-stable-linux-$arch.tgz" \
               "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-$arch.tgz"; do
        curl -fsSL "$u" | tar xz -C "$dir" ngrok && break
      done
      [ -x "$bin" ] || die "couldn't download ngrok"
    fi
  fi
  if [ -n "${NGROK_AUTHTOKEN:-}" ]; then
    "$bin" config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null || die "ngrok rejected the authtoken"
    say "ngrok authtoken saved"
  fi
}

# merge_config OLD NEW MODEL: keep the user's settings, but when the model
# changed take the new model's sampling and context settings
merge_config() {
  python3 - "$1" "$2" "$3" "${NGROK_DOMAIN:-}" <<'PY'
import json, sys
old_path, new_path, model, domain = sys.argv[1:5]
old, new = json.load(open(old_path)), json.load(open(new_path))
managed = ["model", "kv_limit_mb", "temperature", "top_p", "top_k", "min_p", "repeat_penalty", "thinking"]
changed = old.get("model") != model
if changed:
    for k in managed:
        old.pop(k, None)
        if k in new:
            old[k] = new[k]
# gpu_layers is machine-derived (sized to this box's VRAM): always mirror new
if "gpu_layers" in new:
    old["gpu_layers"] = new["gpu_layers"]
else:
    old.pop("gpu_layers", None)
if domain:
    old["ngrok_domain"] = domain
json.dump(old, open(old_path, "w"), indent=2)
print("updated for the new model" if changed else "kept")
PY
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# write_config FILE MODEL GPU: settings sized to this machine
write_config() {
  local cfg="$1" model="$2" gpu="$3" ngl="${4:-}" ram_mb model_mb kv sampling="" extra="" gpu_line=""
  if [ -n "${NGROK_DOMAIN:-}" ]; then
    extra="
  \"ngrok_domain\": \"$(json_escape "$NGROK_DOMAIN")\","
  fi
  ram_mb="${LAI_RAM_MB:-$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)}"
  model_mb="$(file_mb "$model")"
  # cache budget: what's left after the model and ~6 GB for the system, 1-8 GB
  kv=$(( ram_mb - model_mb - 6144 ))
  [ "$kv" -gt 8192 ] && kv=8192
  [ "$kv" -lt 1024 ] && kv=1024
  case "$(basename "$model" | tr '[:upper:]' '[:lower:]')" in
    # Qwen3.5 thinks by default; these are Qwen's settings for precise coding
    *qwen3.5*|*qwen3_5*) sampling='
  "temperature": 0.6,
  "top_p": 0.95,
  "top_k": 20,
  "min_p": 0,
  "repeat_penalty": 1.0,
  "thinking": true,' ;;
    *qwen3*) sampling='
  "temperature": 0.7,
  "top_p": 0.8,
  "top_k": 20,
  "min_p": 0,
  "repeat_penalty": 1.05,' ;;
  esac
  # partial GPU offload, sized to VRAM; absent for CPU builds (engine default)
  case "$ngl" in ''|*[!0-9]*) ;; *) [ "$gpu" != cpu ] && gpu_line="
  \"gpu_layers\": $ngl," ;; esac
  cat > "$cfg" <<EOF
{
  "model": "$(json_escape "$model")",
  "ctx_size": 0,
  "kv_cache": "q8_0",
  "kv_in_ram": true,
  "kv_limit_mb": $kv,
  "moe_on_cpu": true,$gpu_line$sampling
  "auto_approve": true,$extra
  "mcpServers": {}
}
EOF
  echo "$kv"
}

main() {
  [ "$(uname -s)" = Linux ] || die "this installer is for Linux"
  case "$(uname -m)" in
    x86_64|amd64)  GOARCH=amd64 ;;
    aarch64|arm64) GOARCH=arm64 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
  esac
  SUDO=""
  [ "$(id -u)" -eq 0 ] || SUDO=sudo

  # 0a. Root persistence — on a live USB, make sure / persists (via a dedicated
  #     'persistence' partition carved from LAI_DISK's free space) so the driver
  #     survives reboots. Stops for a reboot into the persistence entry if it had
  #     to set it up. No-op on an installed Parrot or when / already persists.
  ensure_root_persistence "$@"

  # 0b. GPU driver gate — before any download. On an NVIDIA GPU stuck on nouveau,
  #     this installs the proprietary driver and reboots; we only reach the model
  #     download below once the right driver is active (or on CPU if there's no
  #     GPU / it can't be fixed here).
  ensure_gpu_driver "$@"

  # 1. model
  local model="" serve=0 find=0 setup_mcp=0 memguard=0 do_tools=0 a
  for a in "$@"; do
    case "$a" in
      --serve) serve=1 ;;
      --find)  find=1 ;;
      --mcp)   setup_mcp=1 ;;
      --memguard) memguard=1 ;;
      --tools) do_tools=1 ;;
      -*) die "unknown option $a" ;;
      *) model="$a" ;;
    esac
  done
  [ -n "${LAI_SETUP_TOOLS:-}" ] && do_tools=1

  # 0. optional: carve lai-data + lai-swap partitions out of a disk's free space
  #    (LAI_DISK=sdc). Detected and reused on later boots; model stays in RAM.
  if [ -n "${LAI_DISK:-}" ] && [ -f "$HERE/tools/setup-disk.sh" ]; then
    say "setting up partitions on /dev/${LAI_DISK#/dev/} (${LAI_DATA_SIZE:-10G} data + ${LAI_SWAP_SIZE:-11G} swap)"
    local _disk_out
    _disk_out="$($SUDO env LAI_DISK_YES="${LAI_DISK_YES:-}" bash "$HERE/tools/setup-disk.sh" \
                  "$LAI_DISK" "${LAI_DATA_SIZE:-10G}" "${LAI_SWAP_SIZE:-11G}" | tail -2)"
    local _dm _sw
    _dm="$(printf '%s\n' "$_disk_out" | sed -n 's/^LAI_DATA_MOUNT=//p')"
    _sw="$(printf '%s\n' "$_disk_out" | sed -n 's/^LAI_SWAP_DEV=//p')"
    [ -n "$_dm" ] || die "disk setup didn't return a data mount (see output above)"
    : "${LAI_DIR:=$_dm/lai}"
    : "${LAI_MODEL_DIR:=$HOME/models}"     # model in RAM
    SWAP_DEV="${SWAP_DEV:-${LAI_DISK#/dev/}}"   # memguard keeps lai-swap active (zram on top)
    say "data partition mounted at $_dm; swap on $_sw"
  fi
  [ -n "${LAI_SETUP_MCP:-}" ] && setup_mcp=1
  [ -n "${LAI_MEMGUARD:-}" ] && memguard=1

  # full root persistence persists /home onto the (small) persistence partition,
  # so keep the big model off it — default it to RAM unless it's on a data disk
  if grep -qw 'boot=live' /proc/cmdline 2>/dev/null && root_persistent; then
    case "${LAI_MODEL_DIR:-}" in
      ""|"$HOME"|"$HOME"/*|"$HERE"|"$HERE"/*)
        warn "root persistence is on — keeping the model in RAM (/dev/shm/lai-models) so it doesn't fill the persistence partition. Set LAI_MODEL_DIR=<data-partition>/models (e.g. on sdc3) to keep it on disk."
        LAI_MODEL_DIR=/dev/shm/lai-models ;;
    esac
  fi

  local dir_default="$HERE"
  if [ -n "$model" ]; then
    dir_default="$(dirname "$model")/lai"
  elif [ "$find" = 1 ]; then
    say "looking for .gguf models"
    model="$(find_model)"
    dir_default="$(dirname "$model")/lai"
  else
    model="$(fetch_model "$LAI_MODEL_URL" "${LAI_MODEL_DIR:-$HERE/models}")"
  fi
  [ -f "$model" ] || die "model not found: $model"
  model="$(readlink -f "$model")"
  say "model: $model ($(file_mb "$model") MB)"

  # 2. install folder: beside the model if writable, else ~/.local/bin
  local dir="${LAI_DIR:-$dir_default}"
  if ! mkdir -p "$dir" 2>/dev/null || [ ! -w "$dir" ]; then
    warn "can't write next to the model; installing to ~/.local/bin instead (gone after a reboot on a live system)"
    dir="$HOME/.local/bin"
    mkdir -p "$dir"
  fi
  case "$(stat -f -c %T "$dir" 2>/dev/null)" in
    msdos|vfat|exfat|fuseblk|ntfs*)
      warn "$dir is on a FAT/exFAT/NTFS drive, which can't run Linux programs; installing to ~/.local/bin instead"
      dir="$HOME/.local/bin"
      mkdir -p "$dir" ;;
  esac

  # 3. GPU or CPU
  local gpu="${LAI_GPU:-}"
  [ -n "$gpu" ] || gpu="$(pick_gpu)"
  say "building for: $gpu"

  # 4. lai (static Go binary)
  if [ -x "$HERE/dist/lai-linux-$GOARCH" ]; then
    install -m 755 "$HERE/dist/lai-linux-$GOARCH" "$dir/lai"
  elif command -v go >/dev/null 2>&1; then
    (cd "$HERE" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$dir/lai" .)
  else
    die "no prebuilt dist/lai-linux-$GOARCH and Go isn't installed"
  fi

  # 5. lai-engine, skipped when an identical build is already there
  local stamp="$dir/.lai-engine-build" want="$LLAMA_TAG $gpu"
  if [ -x "$dir/lai-engine" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
    say "lai-engine already built ($want)"
  else
    if ! install_engine "$dir" "$gpu"; then
      [ "$gpu" != cpu ] || die "build failed (logs in ${TMPDIR:-/tmp}/lai-build)"
      warn "the $gpu build failed; building for CPU instead"
      gpu=cpu
      install_engine "$dir" cpu || die "CPU build failed too (logs in ${TMPDIR:-/tmp}/lai-build)"
    fi
  fi

  local ngl=""
  if [ "$gpu" != cpu ]; then
    # size the offload to VRAM so a card smaller than the model still works
    # (and so the test below doesn't OOM by loading every layer onto the GPU)
    ngl="$(fit_gpu_layers "$model" "$(gpu_vram_mb)")"
    [ -n "$ngl" ] && say "GPU offload sized to your VRAM: $ngl layers"
    say "testing the $gpu build on your model (loads it once, can take a minute)"
    if gpu_works "$dir/lai-engine" "$model" "$ngl"; then
      say "the GPU works"
    else
      warn "the $gpu build didn't run on your GPU; rebuilding for CPU (see ${TMPDIR:-/tmp}/lai-build and ~/.local/share/lai/logs/engine.log)"
      gpu=cpu; ngl=""
      install_engine "$dir" cpu || die "CPU build failed (logs in ${TMPDIR:-/tmp}/lai-build)"
    fi
  fi

  # 6. config: written once, then only updated when the model changes
  local kv
  if [ -f "$dir/config.json" ] && command -v python3 >/dev/null 2>&1; then
    kv="$(write_config "$dir/config.json.new" "$model" "$gpu" "$ngl")"
    say "config: $(merge_config "$dir/config.json" "$dir/config.json.new" "$model")"
    rm -f "$dir/config.json.new"
  else
    [ -f "$dir/config.json" ] && mv "$dir/config.json" "$dir/config.json.bak"
    kv="$(write_config "$dir/config.json" "$model" "$gpu" "$ngl")"
    say "wrote $dir/config.json (context cache up to ${kv} MB in RAM)"
  fi

  # 6b. with --mcp, clone and register the built-in pentest MCP servers
  local tools_dir="${LAI_TOOLS_DIR:-$dir/mcp-tools}"
  if [ "$setup_mcp" = 1 ]; then
    say "setting up MCP servers in $tools_dir (clones + builds; takes a while)"
    if TOOLS_DIR="$tools_dir" bash "$HERE/tools/setup-mcp.sh" ${LAI_MCP_ONLY:+--only "$LAI_MCP_ONLY"}; then
      "$dir/lai" mcp import "$tools_dir/mcp-servers.json" || warn "couldn't import the generated MCP config"
    else
      warn "MCP setup failed; continuing without it (rerun: TOOLS_DIR=$tools_dir bash tools/setup-mcp.sh)"
    fi
  fi
  # start any MCP backends every run, so they come back after a reboot
  if [ -x "$tools_dir/start-backends.sh" ]; then
    say "starting MCP backends"; bash "$tools_dir/start-backends.sh" || true
  fi

  # 6c. also import an existing OpenCode / Claude Desktop config when present
  local mcpsrc="${LAI_MCP:-}"
  if [ -z "$mcpsrc" ]; then
    for c in "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/config.json" \
             "$HOME/.opencode.json" "$HOME/.config/Claude/claude_desktop_config.json"; do
      [ -f "$c" ] && { mcpsrc="$c"; break; }
    done
  fi
  if [ -n "$mcpsrc" ] && [ -f "$mcpsrc" ]; then
    say "importing MCP servers from $mcpsrc"
    "$dir/lai" mcp import "$mcpsrc" || warn "couldn't import MCP servers from $mcpsrc"
  fi

  # 6d. with --tools, install the CLI tools the MCP servers call (skip what
  #     Parrot already has + GUI wrappers; shim the rest for on-demand install)
  local shim_dir=""
  if [ "$do_tools" = 1 ] && [ -f "$HERE/tools/setup-tools.sh" ]; then
    say "checking the tools the MCP servers need (installing missing core ones)"
    local _tout
    _tout="$($SUDO -E env TOOLS_DIR="$tools_dir" bash "$HERE/tools/setup-tools.sh" | tail -2 || true)"
    shim_dir="$(printf '%s\n' "$_tout" | sed -n 's/^SHIM_DIR=//p')"
    if [ -n "$shim_dir" ]; then
      # put the shim dir at the END of PATH for this session and future shells,
      # so a real tool wins and only missing ones trigger an on-demand install
      case ":$PATH:" in *":$shim_dir:"*) ;; *) export PATH="$PATH:$shim_dir" ;; esac
      local prof="$HOME/.bashrc"
      grep -qF "$shim_dir" "$prof" 2>/dev/null || echo "export PATH=\"\$PATH:$shim_dir\"" >> "$prof"
      say "on-demand tool shims: $shim_dir (added to PATH)"
    fi
  fi

  # 7. ngrok, when a token or domain was given
  setup_ngrok "$dir"

  # 8. check both binaries start
  "$dir/lai" version >/dev/null || die "$dir/lai doesn't run"
  # with no arguments it prints usage and exits 2, so look at the output, not the status
  local engine_out
  engine_out="$("$dir/lai-engine" 2>&1 || true)"
  case "$engine_out" in
    *usage*) ;;
    *) die "$dir/lai-engine doesn't start: $(printf '%s\n' "$engine_out" | head -3)" ;;
  esac

  # put lai on PATH for this session too
  if [ "$dir" != "$HOME/.local/bin" ]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$dir/lai" "$HOME/.local/bin/lai"
    [ -x "$dir/ngrok" ] && ln -sf "$dir/ngrok" "$HOME/.local/bin/ngrok"
  fi

  # memory guard: swap + soft RAM cap, running in the background
  if [ "$memguard" = 1 ]; then
    if [ -f "$HERE/tools/memguard.sh" ]; then
      local mg_dir="" mg_size="${SWAP_SIZE:-24G}"
      # LAI_PERSIST_SWAP=<size> puts the swapfile ON the persistence partition
      # (reserved first-install, reused every boot after)
      if [ -n "${LAI_PERSIST_SWAP:-}" ] && [ -n "${LAI_PERSIST_MOUNT:-}" ]; then
        mg_dir="$LAI_PERSIST_MOUNT"; mg_size="$LAI_PERSIST_SWAP"
        say "starting the memory guard (${mg_size} swapfile on the persistence partition, soft cap ${SOFT_CAP_GB:-29}G)"
      else
        say "starting the memory guard (swap on a data disk, soft cap ${SOFT_CAP_GB:-29}G)"
      fi
      $SUDO env SWAP_DEV="${SWAP_DEV:-}" SWAP_DIR="$mg_dir" SWAP_SIZE="$mg_size" \
        ZRAM="${ZRAM:-1}" ZRAM_SIZE="${ZRAM_SIZE:-}" ZRAM_ALGO="${ZRAM_ALGO:-lz4}" \
        SOFT_CAP_GB="${SOFT_CAP_GB:-29}" RAMP_START_GB="${RAMP_START_GB:-22}" IDLE_MIN="${IDLE_MIN:-8}" \
        setsid bash "$HERE/tools/memguard.sh" >"$dir/memguard.log" 2>&1 < /dev/null &
      echo "  memguard log: $dir/memguard.log  (stop it with: sudo pkill -f memguard.sh)"
    else
      warn "tools/memguard.sh missing; skipping the memory guard"
    fi
  fi

  echo
  say "done. Start it with:"
  echo "    $dir/lai"
  case ":$PATH:" in *":$HOME/.local/bin:"*) echo "  (or just: lai)" ;; esac
  echo "  phone page: $dir/lai serve"
  if [ "$serve" = 1 ]; then
    echo
    exec "$dir/lai" serve
  fi
}

# sourcing the file (for tests) defines the functions without running setup
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
