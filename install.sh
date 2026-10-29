#!/usr/bin/env bash
# Installs lai and builds lai-engine (a minimal llama.cpp runner) for the
# current user. No root needed. Built for Parrot OS / Debian.
#
#   ./install.sh                     CPU build tuned for this machine
#   LAI_GPU=vulkan ./install.sh      GPU build; vulkan is the light choice for NVIDIA
#                                    (also cuda | rocm)
#   LAI_KEEP_SRC=1 ./install.sh      keep the llama.cpp source and build dir
#
# Building needs:  sudo apt install build-essential cmake git
# Vulkan also needs libvulkan-dev glslc, and a Vulkan driver at runtime
# (NVIDIA's proprietary driver includes one; check with: vulkaninfo --summary).
# CUDA needs nvidia-cuda-toolkit, which is several GB.
set -euo pipefail

# lai-engine uses llama.cpp's internal chat helpers, which change between
# versions, so it is built against this tested tag.
LLAMA_TAG="${LLAMA_TAG:-b11982}"
BIN_DIR="${LAI_BIN_DIR:-$HOME/.local/bin}"
DATA="${LAI_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/lai}"
HERE="$(cd "$(dirname "$0")" && pwd)"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "this installer is for Linux"
case "$(uname -m)" in
  x86_64|amd64)  GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac

# 1. lai (static Go binary)
mkdir -p "$BIN_DIR"
if [ -x "$HERE/dist/lai-linux-$GOARCH" ]; then
  install -m 755 "$HERE/dist/lai-linux-$GOARCH" "$BIN_DIR/lai"
elif command -v go >/dev/null 2>&1; then
  (cd "$HERE" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$BIN_DIR/lai" .)
else
  die "no prebuilt dist/lai-linux-$GOARCH and Go isn't installed"
fi
say "installed $BIN_DIR/lai"

# 2. lai-engine, compiled for this CPU
missing=()
for t in git cmake c++ make; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
[ ${#missing[@]} -eq 0 ] || die "building lai-engine needs: ${missing[*]}
  sudo apt install build-essential cmake git"

flags=()
case "${LAI_GPU:-}" in
  "")     ;;
  vulkan) flags+=(-DGGML_VULKAN=ON) ;;
  cuda)   flags+=(-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=native) ;;  # only this GPU's kernels
  rocm)   flags+=(-DGGML_HIP=ON) ;;
  *) die "unknown LAI_GPU=$LAI_GPU (vulkan, cuda, rocm)" ;;
esac

src="$DATA/src/llama.cpp"
build="$DATA/src/build"
if [ "$(git -C "$src" describe --tags 2>/dev/null || true)" != "$LLAMA_TAG" ]; then
  say "fetching llama.cpp $LLAMA_TAG"
  rm -rf "$src"
  git clone -q --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$src"
fi
say "building lai-engine (${LAI_GPU:-cpu}); this takes a few minutes"
cmake -S "$HERE/engine" -B "$build" -DLLAMA_DIR="$src" -DCMAKE_BUILD_TYPE=Release "${flags[@]}" >/dev/null
cmake --build "$build" --target lai-engine -j"$(nproc)" >/dev/null
install -m 755 "$build/lai-engine" "$BIN_DIR/lai-engine"
if [ "${LAI_KEEP_SRC:-0}" != 1 ]; then
  rm -rf "$DATA/src"
fi
say "installed $BIN_DIR/lai-engine ($(du -h "$BIN_DIR/lai-engine" | cut -f1))"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on PATH. Add it:  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc  (or ~/.zshrc)" ;;
esac
cat <<EOF

next:
  lai -m /path/to/model.gguf
  lai mcp add fs -- npx -y @modelcontextprotocol/server-filesystem ~/

lai and lai-engine are two standalone files: copy them anywhere (e.g. your
USB drive) and run lai from there.
EOF
