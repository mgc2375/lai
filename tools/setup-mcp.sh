#!/usr/bin/env bash
# setup-mcp.sh — clone, build and register pentest MCP servers for lai.
#
#   TOOLS_DIR=/path ./setup-mcp.sh            install the registered servers there
#   ./setup-mcp.sh --only hexstrike,kali      just those
#   ./setup-mcp.sh --list                     show what's registered
#
# It clones each server into TOOLS_DIR, installs its deps (idempotent: an
# existing checkout is pulled and its env reused), writes mcp-servers.json
# (Claude Desktop format, for `lai mcp import`) pointing at the clone paths,
# and writes start-backends.sh for the servers that need a background service.
#
# Servers that need your own credentials (e.g. BloodHound tokens) are written
# with ${ENV_VAR} placeholders — set those vars before running lai.
set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-$HOME/.local/share/lai/mcp-tools}"
ONLY=""
LIST=0
for a in "$@"; do
  case "$a" in
    --list) LIST=1 ;;
    --only) shift; ONLY="${1:-}" ;;
    --only=*) ONLY="${a#--only=}" ;;
  esac
  shift || true
done

say()  { printf '\033[1m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  warning:\033[0m %s\n' "$*" >&2; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

# registry: id | display name | repo | runtime | backend port (— = none)
# runtime tells setup how to build and how to launch it.
REGISTRY=(
  "hexstrike|hexstrike-ai|0x4m4/hexstrike-ai|py-backend|8888"
  "kali|mcp-kali-server|Wh0am123/MCP-Kali-Server|py-kali|5000"
  "impacket|sec-impacket-mcp|schwarztim/sec-impacket-mcp|node|—"
  "pentester|pentester-mcp|halilkirazkaya/pentester-mcp|py-server|—"
  "bloodhound|sec-bloodhound-mcp|mwnickerson/bloodhound_mcp|uvx|—"
)

if [ "$LIST" = 1 ]; then
  printf '%-12s %-20s %s\n' id name repo
  for e in "${REGISTRY[@]}"; do IFS='|' read -r id name repo _ _ <<< "$e"; printf '%-12s %-20s %s\n' "$id" "$name" "$repo"; done
  exit 0
fi

want() { [ -z "$ONLY" ] && return 0; case ",$ONLY," in *",$1,"*) return 0 ;; esac; return 1; }

ensure_apt() { # ensure_apt pkg...
  local miss=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  [ ${#miss[@]} -eq 0 ] && return 0
  say "installing: ${miss[*]}"
  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${miss[@]}" && $SUDO apt-get clean
}

clone() { # clone repo dest
  if [ -d "$2/.git" ]; then
    git -C "$2" pull -q --ff-only || warn "$2: pull failed, using the existing checkout"
  else
    git clone -q --depth 1 "https://github.com/$1.git" "$2"
  fi
}

py_venv() { # py_venv dir  — venv + requirements, reused if present
  local d="$1"
  [ -x "$d/.venv/bin/python" ] || python3 -m venv "$d/.venv"
  "$d/.venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
  if [ -f "$d/requirements.txt" ]; then
    "$d/.venv/bin/pip" install -q -r "$d/requirements.txt"
  fi
}

mkdir -p "$TOOLS_DIR/logs"
OUT="$TOOLS_DIR/mcp-servers.json"
BACK="$TOOLS_DIR/start-backends.sh"
entries=()                                   # JSON objects, joined at the end
: > "$BACK.tmp"
printf '#!/usr/bin/env bash\n# starts the MCP backends that need a running service; safe to re-run\nset -u\nLOGS="%s/logs"\nup(){ curl -fsS -o /dev/null --max-time 2 "$1" 2>/dev/null; }\n' "$TOOLS_DIR" >> "$BACK.tmp"

add_backend() { # add_backend name healthurl cmd...
  local name="$1" url="$2"; shift 2
  {
    printf 'if up "%s"; then echo "%s backend already up"; else\n' "$url" "$name"
    printf '  echo "starting %s backend"; ( %s ) >"$LOGS/%s.log" 2>&1 &\n' "$name" "$*" "$name"
    printf 'fi\n'
  } >> "$BACK.tmp"
}

for e in "${REGISTRY[@]}"; do
  IFS='|' read -r id name repo runtime port <<< "$e"
  want "$id" || continue
  dir="$TOOLS_DIR/$id"
  say "$name ($repo)"
  case "$runtime" in
    py-backend) # hexstrike: backend server + stdio mcp client
      ensure_apt git python3 python3-venv python3-pip curl
      clone "$repo" "$dir"; py_venv "$dir"
      add_backend "$name" "http://127.0.0.1:$port/health" "cd '$dir' && '$dir/.venv/bin/python' hexstrike_server.py --port $port"
      entries+=("$(printf '"%s": {"command": "%s/.venv/bin/python", "args": ["%s/hexstrike_mcp.py", "--server", "http://127.0.0.1:%s"], "trust": true}' "$name" "$dir" "$dir" "$port")")
      ;;
    py-kali) # kali: command-exec backend + client.py stdio
      ensure_apt git python3 python3-venv python3-pip curl
      clone "$repo" "$dir"; py_venv "$dir"
      add_backend "$name" "http://127.0.0.1:$port/health" "cd '$dir' && '$dir/.venv/bin/python' server.py --port $port"
      entries+=("$(printf '"%s": {"command": "%s/.venv/bin/python", "args": ["%s/client.py", "--server", "http://127.0.0.1:%s"], "trust": true}' "$name" "$dir" "$dir" "$port")")
      ;;
    py-server) # single python stdio server
      ensure_apt git python3 python3-venv python3-pip
      clone "$repo" "$dir"; py_venv "$dir"
      entries+=("$(printf '"%s": {"command": "%s/.venv/bin/python", "args": ["%s/server.py"], "trust": true}' "$name" "$dir" "$dir")")
      ;;
    node) # node stdio server, built with npm
      ensure_apt git nodejs npm
      clone "$repo" "$dir"
      ( cd "$dir" && npm install -s && npm run -s build )
      entries+=("$(printf '"%s": {"command": "node", "args": ["%s/dist/index.js"], "trust": true}' "$name" "$dir")")
      ;;
    uvx) # run straight from git with uv; needs the user's own credentials
      command -v uvx >/dev/null 2>&1 || ensure_apt pipx >/dev/null 2>&1 || true
      command -v uvx >/dev/null 2>&1 || { curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || warn "install uv to use $name"; }
      entries+=("$(printf '"%s": {"command": "uvx", "args": ["--from", "git+https://github.com/%s", "bloodhound-mcp"], "env": {"BLOODHOUND_DOMAIN": "${BLOODHOUND_DOMAIN}", "BLOODHOUND_TOKEN_ID": "${BLOODHOUND_TOKEN_ID}", "BLOODHOUND_TOKEN_KEY": "${BLOODHOUND_TOKEN_KEY}"}, "disabled": true, "trust": true}' "$name" "$repo")")
      warn "$name needs BLOODHOUND_DOMAIN / BLOODHOUND_TOKEN_ID / BLOODHOUND_TOKEN_KEY; it's left disabled until you set them and enable it in the config"
      ;;
  esac
done

# write mcp-servers.json
{
  printf '{\n  "mcpServers": {\n'
  for i in "${!entries[@]}"; do
    printf '    %s' "${entries[$i]}"
    [ "$i" -lt $((${#entries[@]} - 1)) ] && printf ','
    printf '\n'
  done
  printf '  }\n}\n'
} > "$OUT"

mv "$BACK.tmp" "$BACK"; chmod +x "$BACK"
say "wrote $OUT (${#entries[@]} servers)"
say "backends: $BACK"
echo "import into lai with:  lai mcp import \"$OUT\""
