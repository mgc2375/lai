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
# Servers that need your own key/credentials (Shodan, BloodHound) are written
# with ${ENV_VAR} placeholders and enabled; set those vars before running lai
# and they connect. Everything else works without keys.
set -euo pipefail

TOOLS_DIR="${TOOLS_DIR:-$HOME/.local/share/lai/mcp-tools}"
ONLY=""
LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    --only) ONLY="${2:-}"; shift ;;
    --only=*) ONLY="${1#--only=}" ;;
  esac
  shift
done

say()  { printf '\033[1m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  warning:\033[0m %s\n' "$*" >&2; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

# registry: id | display name | repo | runtime | arg
#   arg is the port (py-backend/py-kali), entry file (py-server/node),
#   console script (py-editable) or npm package (npx).
REGISTRY=(
  "hexstrike|hexstrike-ai|0x4m4/hexstrike-ai|py-backend|8888"
  "kali|mcp-kali-server|Wh0am123/MCP-Kali-Server|py-kali|5000"
  "impacket|sec-impacket-mcp|schwarztim/sec-impacket-mcp|node|dist/index.js"
  "pentester|pentester-mcp|halilkirazkaya/pentester-mcp|py-server|server.py"
  "pentestmcp|pentestmcp|dev-lu/PentestMCP|py-server|pentest_mcp.py"
  "adstrike|adstrike|capture0x/AdStrike|py-installer|mcp_server.py"
  "adagent|adagent|capture0x/AdAgent|py-installer|mcp_server.py"
  "cve|mcp-cve-project|mukul975/cve-mcp-server|py-editable|cve-mcp"
  "shodan|mcp-shodan|@burtthecoder/mcp-shodan|npx|@burtthecoder/mcp-shodan"
  "bloodhound|sec-bloodhound-mcp|mwnickerson/bloodhound_mcp|uvx|bloodhound-mcp"
  "mcpwn|mcpwn|https://gitlab.com/parrotsec/project/mcpwn.git|go|cmd/mcpwn"
  "kali-sudohakan|kali-mcp-sudohakan|sudohakan/kali-mcp-server|docker-sse|8000"
)

# scanners: MCP vulnerability scanners — CLI tools you run AGAINST an MCP
# server, not servers themselves, so they're installed but not registered.
SCANNERS=(
  "teycir|Teycir/Mcpwn|git"
  "ressl|ressl/mcpwn|pipx"
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

have_uv() { command -v uvx >/dev/null 2>&1; }
ensure_uv() {
  have_uv && return 0
  say "installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || true
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
}

clone() { # clone repo dest  (repo = owner/name on GitHub, or a full git URL)
  local url="$1"
  case "$1" in *://*) : ;; *) url="https://github.com/$1.git" ;; esac
  if [ -d "$2/.git" ]; then
    git -C "$2" pull -q --ff-only || warn "$2: pull failed, using the existing checkout"
  else
    git clone -q --depth 1 "$url" "$2"
  fi
}

have_docker() { command -v docker >/dev/null 2>&1; }

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
printf '#!/usr/bin/env bash\n# starts the MCP backends that need a running service; safe to re-run\nset -u\nLOGS="%s/logs"\nup(){ curl -fsS -o /dev/null --max-time 2 "$1" 2>/dev/null; }\n' "$TOOLS_DIR" > "$BACK.tmp"

add_backend() { # add_backend name healthurl cmd...
  local name="$1" url="$2"; shift 2
  {
    printf 'if up "%s"; then echo "%s backend already up"; else\n' "$url" "$name"
    printf '  echo "starting %s backend"; ( %s ) >"$LOGS/%s.log" 2>&1 &\n' "$name" "$*" "$name"
    printf 'fi\n'
  } >> "$BACK.tmp"
}

# entry NAME JSON  — add a server entry
entry() { entries+=("$(printf '"%s": %s' "$1" "$2")"); }

for e in "${REGISTRY[@]}"; do
  IFS='|' read -r id name repo runtime arg <<< "$e"
  want "$id" || continue
  dir="$TOOLS_DIR/$id"
  say "$name ($repo)"
  case "$runtime" in
    py-backend) # hexstrike: backend server on :arg + stdio mcp client
      ensure_apt git python3 python3-venv python3-pip curl
      clone "$repo" "$dir"; py_venv "$dir"
      add_backend "$name" "http://127.0.0.1:$arg/health" "cd '$dir' && '$dir/.venv/bin/python' hexstrike_server.py --port $arg"
      entry "$name" "$(printf '{"command": "%s/.venv/bin/python", "args": ["%s/hexstrike_mcp.py", "--server", "http://127.0.0.1:%s"], "trust": true}' "$dir" "$dir" "$arg")"
      ;;
    py-kali) # kali: command-exec backend on :arg + client.py stdio
      ensure_apt git python3 python3-venv python3-pip curl
      clone "$repo" "$dir"; py_venv "$dir"
      add_backend "$name" "http://127.0.0.1:$arg/health" "cd '$dir' && '$dir/.venv/bin/python' server.py --port $arg"
      entry "$name" "$(printf '{"command": "%s/.venv/bin/python", "args": ["%s/client.py", "--server", "http://127.0.0.1:%s"], "trust": true}' "$dir" "$dir" "$arg")"
      ;;
    py-server) # single python stdio server, entrypoint = arg
      ensure_apt git python3 python3-venv python3-pip
      clone "$repo" "$dir"; py_venv "$dir"
      entry "$name" "$(printf '{"command": "%s/.venv/bin/python", "args": ["%s/%s"], "trust": true}' "$dir" "$dir" "$arg")"
      ;;
    py-installer) # repo ships its own install.sh creating venv/; stdio entry = arg
      ensure_apt git python3 python3-venv python3-pip
      clone "$repo" "$dir"
      if [ -f "$dir/install.sh" ]; then
        ( cd "$dir" && bash install.sh </dev/null ) >"$TOOLS_DIR/logs/$id-install.log" 2>&1 \
          || warn "$name: its install.sh failed (log: $TOOLS_DIR/logs/$id-install.log); trying a plain venv"
      fi
      [ -x "$dir/venv/bin/python3" ] || { python3 -m venv "$dir/venv"; [ -f "$dir/requirements.txt" ] && "$dir/venv/bin/pip" install -q -r "$dir/requirements.txt"; }
      entry "$name" "$(printf '{"command": "%s/venv/bin/python3", "args": ["%s/%s"], "trust": true}' "$dir" "$dir" "$arg")"
      ;;
    node) # node stdio server, built with npm; entry = arg
      ensure_apt git nodejs npm
      clone "$repo" "$dir"
      ( cd "$dir" && npm install -s && npm run -s build )
      entry "$name" "$(printf '{"command": "node", "args": ["%s/%s"], "trust": true}' "$dir" "$arg")"
      ;;
    py-editable) # pip install -e . ; stdio via console script = arg
      ensure_apt git python3 python3-venv python3-pip
      clone "$repo" "$dir"
      [ -x "$dir/.venv/bin/python" ] || python3 -m venv "$dir/.venv"
      "$dir/.venv/bin/pip" install -q -e "$dir"
      if [ "$id" = cve ]; then
        entry "$name" "$(printf '{"command": "%s/.venv/bin/%s", "args": [], "env": {"SHODAN_API_KEY": "${SHODAN_API_KEY}", "VIRUSTOTAL_API_KEY": "${VIRUSTOTAL_API_KEY}"}, "trust": true}' "$dir" "$arg")"
      else
        entry "$name" "$(printf '{"command": "%s/.venv/bin/%s", "args": [], "trust": true}' "$dir" "$arg")"
      fi
      ;;
    npx) # published npm package, run with npx; arg = package
      ensure_apt nodejs npm
      if [ "$id" = shodan ]; then
        entry "$name" "$(printf '{"command": "npx", "args": ["-y", "%s"], "env": {"SHODAN_API_KEY": "${SHODAN_API_KEY}"}, "trust": true}' "$arg")"
      else
        entry "$name" "$(printf '{"command": "npx", "args": ["-y", "%s"], "trust": true}' "$arg")"
      fi
      ;;
    uvx) # run straight from git with uv; needs the user's own credentials
      ensure_uv
      entry "$name" "$(printf '{"command": "uvx", "args": ["--from", "git+https://github.com/%s", "%s"], "env": {"BLOODHOUND_DOMAIN": "${BLOODHOUND_DOMAIN}", "BLOODHOUND_TOKEN_ID": "${BLOODHOUND_TOKEN_ID}", "BLOODHOUND_TOKEN_KEY": "${BLOODHOUND_TOKEN_KEY}"}, "trust": true}' "$repo" "$arg")"
      warn "$name needs BLOODHOUND_DOMAIN / BLOODHOUND_TOKEN_ID / BLOODHOUND_TOKEN_KEY set to connect"
      ;;
    go) # Go MCP server (ParrotSec/mcpwn): build the binary, run it in its dir so
        # it finds its mcpwn.yaml; it runs its tools in Docker at runtime
      ensure_apt git golang-go
      clone "$repo" "$dir"
      ( cd "$dir" && go build -o "$dir/${id}" "./$arg" )
      entry "$name" "$(printf '{"command": "%s/%s", "cwd": "%s", "trust": true}' "$dir" "$id" "$dir")"
      have_docker || warn "$name runs its tools in Docker; install docker.io for them to work"
      ;;
    docker-sse) # server shipped as a Docker image, SSE on :arg (sudohakan/kali-mcp-server)
      if ! have_docker; then
        warn "$name needs Docker; install docker.io and rerun. Skipping for now."
        continue
      fi
      ensure_apt git
      clone "$repo" "$dir"
      say "building the $name Docker image (slow the first time)"
      ( cd "$dir" && docker build -q -t "lai-$id" . ) >"$TOOLS_DIR/logs/$id-build.log" 2>&1 \
        || { warn "$name: docker build failed (log: $TOOLS_DIR/logs/$id-build.log)"; continue; }
      add_backend "$name" "http://127.0.0.1:$arg/sse" "docker run --rm -p $arg:$arg --name lai-$id lai-$id"
      entry "$name" "$(printf '{"url": "http://127.0.0.1:%s/sse", "transport": "sse", "trust": true}' "$arg")"
      ;;
  esac
done

# scanners (CLI tools you run AGAINST an MCP server, installed but not registered)
scanners_note=""
for e in "${SCANNERS[@]}"; do
  IFS='|' read -r sid repo method <<< "$e"
  want "$sid" || continue
  case "$method" in
    git)
      ensure_apt git python3 python3-venv python3-pip
      sdir="$TOOLS_DIR/scanners/$sid"
      clone "$repo" "$sdir"; py_venv "$sdir"
      scanners_note+="  $sid (Mcpwn): $sdir/.venv/bin/python $sdir/mcpwn.py --help"$'\n'
      ;;
    pipx)
      ensure_apt python3 python3-pip pipx
      pipx install mcpwn >/dev/null 2>&1 || python3 -m pip install -q --user --break-system-packages mcpwn \
        || warn "couldn't install the ressl mcpwn scanner"
      scanners_note+="  $sid (mcpwn): mcpwn scan --stdio \"python server.py\""$'\n'
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
if [ -n "$scanners_note" ]; then
  echo "MCP vulnerability scanners installed (run them yourself against a server):"
  printf '%s' "$scanners_note"
fi
echo "import into lai with:  lai mcp import \"$OUT\""
