#!/usr/bin/env bash
# setup-tools.sh — make sure the CLI tools the MCP servers call are available.
#
# Parrot ships most of them already; this installs the common ones that are
# missing (CORE), caches the .deb files on the data dir for fast/offline
# reboots, and leaves a shim for every other tool so it installs ON DEMAND the
# first time the model actually calls it. GUI-only wrappers are skipped (the
# servers only need the CLI the wrapper drives).
#
#   TOOLS_DIR=/mnt/lai-data/mcp-tools sudo -E bash tools/setup-tools.sh
#   add the printed shim dir to PATH so on-demand install works for lai.
set -u
SHIM_DIR="${LAI_TOOLS_SHIM:-${TOOLS_DIR:-$HOME/.local/share/lai/mcp-tools}/tools-bin}"
DEB_CACHE="${LAI_DEB_CACHE:-$(dirname "$SHIM_DIR")/deb-cache}"
say() { printf '\033[1m  ->\033[0m %s\n' "$*"; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

# tool -> apt package (only where they differ from the tool name)
pkg_of() {
  case "$1" in
    cme) echo crackmapexec ;;
    searchsploit) echo exploitdb ;;
    msfconsole|msfvenom) echo metasploit-framework ;;
    impacket-) echo impacket-scripts ;;
    *) echo "$1" ;;
  esac
}

# CORE: installed up front (the tools the servers lean on most)
CORE="nmap masscan rustscan nikto sqlmap gobuster dirb feroxbuster ffuf wfuzz \
nuclei subfinder amass httpx katana gau waybackurls wafw00f whatweb wpscan \
hydra john hashcat crackmapexec enum4linux smbclient smbmap responder \
evil-winrm searchsploit theharvester dnsenum dnsrecon exiftool binwalk \
metasploit-framework dalfox arjun paramspider tcpdump tshark aircrack-ng"

# ON-DEMAND: shimmed, installed when first called (adds to CORE's coverage)
ONDEMAND="commix fierce gospider grpcurl netdiscover bettercap ettercap \
hashid socat recon-ng semgrep steghide foremost binwalk sslscan \
dnsx naabu nikto xsser dirsearch sublist3r assetfinder"

have()   { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$SHIM_DIR" "$DEB_CACHE"

# install the missing CORE tools, caching the debs
missing=()
for t in $CORE; do
  have "$t" || missing+=("$(pkg_of "$t")")
done
# de-dup
mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
if [ "${#missing[@]}" -gt 0 ] && [ -n "${missing[0]}" ]; then
  say "installing ${#missing[@]} core tools (caching .debs in $DEB_CACHE): ${missing[*]}"
  $SUDO apt-get update -qq || true
  # download first into the cache, then install from there (so reboots can reuse)
  $SUDO apt-get install -y -qq -o Dir::Cache::archives="$DEB_CACHE" "${missing[@]}" \
    || say "some core tools failed to install (not in the repos?); they'll shim on demand"
else
  say "all core tools already present (Parrot ships most of them)"
fi

# on-demand shims: a tiny script per tool that installs then re-execs the real one.
# The shim dir goes at the END of PATH, so a real tool is always used first and
# the shim only fires for a genuinely-missing tool.
make_shim() {
  local tool="$1" pkg; pkg="$(pkg_of "$1")"
  cat > "$SHIM_DIR/$tool" <<SHIM
#!/bin/sh
# lai on-demand installer for '$tool'
if ! command -v dpkg >/dev/null 2>&1 || ! dpkg -s "$pkg" >/dev/null 2>&1; then
  echo "lai: installing $pkg for '$tool'..." >&2
  ${SUDO:+sudo }apt-get install -y -qq -o Dir::Cache::archives="$DEB_CACHE" "$pkg" >&2 \
    || { echo "lai: couldn't install $pkg" >&2; exit 127; }
fi
real="\$(PATH="\$(echo "\$PATH" | tr ':' '\n' | grep -vx "$SHIM_DIR" | paste -sd:)" command -v "$tool")"
[ -n "\$real" ] || { echo "lai: $tool still not found after installing $pkg" >&2; exit 127; }
exec "\$real" "\$@"
SHIM
  chmod +x "$SHIM_DIR/$tool"
}

n=0
for t in $ONDEMAND; do have "$t" || { make_shim "$t"; n=$((n+1)); }; done
# also shim any CORE tool that failed to install, so it retries on demand
for t in $CORE; do have "$t" || [ -e "$SHIM_DIR/$t" ] || { make_shim "${t%-framework}"; n=$((n+1)); }; done
say "wrote $n on-demand shims in $SHIM_DIR"
echo "SHIM_DIR=$SHIM_DIR"
echo "add to PATH so lai/MCP servers can auto-install on demand:  export PATH=\"\$PATH:$SHIM_DIR\""
