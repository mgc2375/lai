# lai

A small local AI agent for the terminal. It loads a GGUF model into memory and lets it work on your machine through shell, file and MCP tools. It's two files with no runtime dependencies:

- **`lai`** (~6 MB, static Go): the chat interface, tools, approvals, MCP client and the optional phone page. Uses ~12 MB of RAM.
- **`lai-engine`** (C++, built from llama.cpp): loads the model and generates text. It contains only llama.cpp's inference core plus its chat-template and tool-call parsing: no HTTP server, web UI, multimodal, model downloader or other tools. lai talks to it over a pipe (one JSON message per line), and it exits when lai does.

Each weight exists once: the model file is memory-mapped and computed on in place (llama.cpp's weight repacking, which keeps a second copy in RAM, is turned off), and any layers you put on the GPU live only in VRAM.

## Install (Parrot OS / Debian) — one command

This clones lai, downloads the model, builds the engine, sets up **all** the MCP servers, configures everything, and starts the phone page:

```sh
git clone https://github.com/mgc2375/lai.git ~/lai && cd ~/lai && ./install.sh --serve --mcp
```

That's it. For keys you have, set them right before `./install.sh` (all optional — the servers that need them just stay dormant until set):

```sh
git clone https://github.com/mgc2375/lai.git ~/lai && cd ~/lai && \
  SHODAN_API_KEY=… CM_API_KEY=… GEMINI_API_KEY=… \
  BLOODHOUND_DOMAIN=… BLOODHOUND_TOKEN_ID=… BLOODHOUND_TOKEN_KEY=… \
  ./install.sh --serve --mcp
```

**On a live USB (persist across reboots):** point `LAI_PERSIST` at your persistence partition so nothing re-downloads or rebuilds next boot (find it with `ls /run/live/persistence/`):

```sh
git clone https://github.com/mgc2375/lai.git ~/lai && cd ~/lai && \
  LAI_PERSIST=/run/live/persistence/<partition>/lai ./install.sh --serve --mcp
```

**Split storage + memory guard (your setup: tools on the SSD partition, model in RAM, aggressive swap):**

```sh
git clone https://github.com/mgc2375/lai.git ~/lai && cd ~/lai && \
  LAI_PERSIST=/dev/sdc3 SWAP_DEV=sdb ./install.sh --serve --mcp --memguard
```

- `LAI_PERSIST=/dev/sdc3` mounts that partition and keeps the binaries, engine, **all MCP tools** and config there, so nothing re-clones or rebuilds next boot. The **model stays in RAM** at `$HOME/models` (re-downloaded each boot). On a standard Parrot live boot `$HOME` is a RAM overlay; if your persistence also covers `/home`, force RAM with `LAI_MODEL_DIR=/dev/shm/lai-models`. To keep the model on disk instead, point `LAI_MODEL_DIR` at the partition.
- `--memguard` runs `tools/memguard.sh` (root) while lai runs: it puts **swap on a data disk** (`SWAP_DEV=sdb` — never your Windows SSD), ramps `vm.swappiness` up as RAM fills (gentle under 22 GB → maximal by 29 GB), caps lai's whole process tree at a 29 GB soft limit via cgroup `memory.high` so the kernel pushes it to swap before the box runs out, makes the kernel reclaim earlier, and drops clean page cache after 8 min idle. Tune with `SOFT_CAP_GB=29 RAMP_START_GB=22 IDLE_MIN=8 SWAP_SIZE=24G`. Stop it with `sudo pkill -f memguard.sh`.

  memguard uses a swapfile when the data disk has a Linux (ext4/xfs) filesystem with free space. If it's **NTFS** (common on a Windows-shared data disk), swapfiles don't work there — make a swap partition **once**, in the disk's free space, with the guarded helper (it never touches your existing partitions and asks before writing):

  ```sh
  sudo bash tools/make-swap.sh sdb 24G
  ```

  A swap partition lives on the physical disk, so it persists across reboots; memguard reactivates it automatically after that.

**Persistence + swap on one partition (your 21 GB `sdc3`: ~10 GB tools, ~11 GB swap):**

```sh
git clone https://github.com/mgc2375/lai.git ~/lai && cd ~/lai && \
  LAI_PERSIST=/dev/sdc3 LAI_PERSIST_SWAP=11G ./install.sh --serve --mcp --memguard
```

- `LAI_PERSIST=/dev/sdc3` mounts the partition; lai's tools/config live in a folder on it (~5 GB, inside your 10 GB), model in RAM.
- `LAI_PERSIST_SWAP=11G` reserves an **11 GB swapfile on the same partition** — no repartitioning (you can't partition a partition; a swapfile is identical in effect and non-destructive). It's created **once on first install** and simply reactivated every boot after; memguard detects the existing swapfile and reuses it. Stopping memguard turns the swap off but keeps the file, so it's instant next time.
- Everything else (graded swappiness to the 29 GB cap, idle cache drop) works as before. Swap on a USB partition is slower than on a hard disk — if you want faster swap, put it on `sdb` instead with `SWAP_DEV=sdb` (and run `tools/make-swap.sh sdb` once if that disk is NTFS).

**Already have `~/lai`?** Update and rerun:

```sh
cd ~/lai && git pull && ./install.sh --serve --mcp
```

What it does, skipping anything already done:

1. **Model:** downloads [Huihui-Qwen3.5-9B-abliterated Q6_K](https://huggingface.co/mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF) (7.4 GB, resumable). Use your own with `./install.sh /path/to/model.gguf`, or `--find` to search your drives.
2. **Engine:** installs build tools (then clears apt's cache) and builds `lai-engine` against llama.cpp `b11982` — Vulkan if a working discrete GPU is found, else CPU, with a CPU fallback if a GPU build crashes.
3. **Config:** writes `config.json` (context sized to your RAM, the model's recommended sampling, auto-approve on). Reruns keep your settings and only refresh the model-specific ones when the model changes.
4. **`--mcp`:** clones, builds and registers every MCP server in the registry (see below) and starts their backends.
5. **ngrok + `--serve`:** installs ngrok, saves the authtoken, starts the tunnel and prints the phone login link. (Comes set up with a test ngrok account; override with `NGROK_AUTHTOKEN=` / `NGROK_DOMAIN=`, or drop `--serve` to stay terminal-only.)

Leave off `--mcp` for just the agent, or `--serve` for terminal-only. Overrides: `LAI_MODEL_URL`, `LAI_MODEL_DIR`, `LAI_DIR`, `LAI_MCP` (import an existing OpenCode/Claude config too), `LAI_PERSIST`, `LAI_MCP_ONLY=hexstrike,kali,…`, `--memguard` (+ `SWAP_DEV`, `SOFT_CAP_GB`, `RAMP_START_GB`, `IDLE_MIN`, `SWAP_SIZE`), `LAI_GPU=cpu|vulkan|cuda|rocm`.

### Parrot OS notes

Built and tested against Parrot/Debian conventions: apt for packages, cgroup v2 (Parrot 6+) for the memory cap, and live-boot overlay/persistence. Every root/optional step degrades gracefully — if cgroup v2, a swap target, Docker or a GPU driver isn't there, that piece is skipped with a logged reason rather than failing the install. The memory guard needs root (the install uses `sudo`); check `memguard.log` to see the swap device and cap it chose.

## Use

```sh
lai -m ~/models/model.gguf            # interactive chat with tools
lai                                   # same, using "model" from the config
lai "why is my disk full?"            # one-shot
dmesg | tail -50 | lai "explain these kernel messages"
lai -m ~/models/model.gguf --ctx 32768
lai -u http://localhost:11434 -m qwen3:4b-instruct-2507-q4_K_M   # use Ollama or another server instead
```

In chat: `/help`, `/clear`, `/tools`, `/mcp`, `/mcp reload`, `/yolo` (toggle auto-approve), `!cmd` runs a command yourself, Ctrl-C stops the current reply or command, Ctrl-D quits. End a line with `\` or wrap text in `"""` for multi-line input.

With `"auto_approve": false`, each tool call waits for you. At the prompt, answer `y`, `n`, `a` (always allow that tool this session), or type a reason to refuse and tell the model why.

Pick a model that can call tools reliably, such as Qwen3 (4B and up, including 30B-A3B), Qwen2.5-Coder 7B+, Llama 3.1/3.2 Instruct or Mistral Small.

### Root commands

The `bash` tool runs commands as you, with no stdin, so `sudo` can't prompt for a password. If you want the model to run root commands, either run `lai` as root (`sudo -E lai`) or allow specific commands in `/etc/sudoers.d/` with `NOPASSWD`.

## Use it from your phone (`lai serve`)

`lai serve` runs the same agent behind a small chat page, so a phone can send messages to your running session and read the replies (tool use included). It listens on `127.0.0.1` only, and every request needs an access key.

```sh
lai serve                                  # http://127.0.0.1:8090, prints a login link
lai serve --ngrok YOUR-DOMAIN.ngrok-free.dev   # also starts the tunnel (or set ngrok_domain in the config)
```

- The first run creates a random access key in `serve.key` next to your `config.json` (mode 600). The printed link (`https://…/?key=…`) logs a browser in with a cookie and then drops the key from the address bar. Treat the link like a password: **anyone holding it can run commands on your machine**. Delete `serve.key` to rotate it.
- One conversation is shared between the terminal session and every device that's logged in. If the phone loses signal or the tab sleeps, it reconnects and catches up from where it was. **Stop** cancels the current reply and **Clear** starts over.
- Tools follow `auto_approve`: with it off, tool calls from the web page are refused, since there's no one at a terminal to approve them.
- Wrong keys are slowed down, and ten in a minute lock logins for a minute.

**ngrok setup:** `install.sh` does it when you pass `NGROK_AUTHTOKEN` and `NGROK_DOMAIN`; by hand it's `ngrok config add-authtoken <your token>` plus `"ngrok_domain"` in the config. Free accounts get one static domain, and a domain can only be online in one place at a time, so stop anything else using it first. ngrok's free plan shows a "Visit Site" warning page the first time a browser opens the link.

## MCP

```sh
lai mcp add fs --trust -- npx -y @modelcontextprotocol/server-filesystem ~/
lai mcp add gh -e GITHUB_PERSONAL_ACCESS_TOKEN='${GITHUB_TOKEN}' -- docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server
lai mcp add remote --url https://example.com/mcp -H "Authorization: Bearer \${TOKEN}"
lai mcp ls      # connects to each server and lists its tools
lai mcp rm fs
```

Already have servers set up in OpenCode or Claude Desktop? Import them instead of re-adding each one:

```sh
lai mcp import ~/.config/opencode/opencode.json   # or a claude_desktop_config.json
```

`install.sh` does this automatically when it finds an OpenCode or Claude Desktop config (override with `LAI_MCP=/path/to/config.json`). The formats differ slightly (OpenCode's single `command` array, `environment`, `enabled`, ms timeouts); lai converts them.

### Set up the pentest MCP servers automatically

`./install.sh --mcp` clones, builds and registers a set of security MCP servers, so they're ready without hand-setup:

| name | repo | notes |
|---|---|---|
| hexstrike-ai | 0x4m4/hexstrike-ai | backend on :8888, started for you |
| mcp-kali-server | Wh0am123/MCP-Kali-Server | command-exec backend on :5000 |
| sec-impacket-mcp | schwarztim/sec-impacket-mcp | node build |
| pentester-mcp | halilkirazkaya/pentester-mcp | ~235 tool wrappers |
| pentestmcp | dev-lu/PentestMCP | Kali tools over MCP |
| adstrike | capture0x/AdStrike | AD red-team framework (runs its own install.sh) |
| adagent | capture0x/AdAgent | AD attack agent, 53 tools |
| mcp-cve-project | mukul975/cve-mcp-server | CVE/threat intel; optional `SHODAN_API_KEY`/`VIRUSTOTAL_API_KEY` |
| mcp-shodan | @burtthecoder/mcp-shodan | needs `SHODAN_API_KEY` |
| sec-bloodhound-mcp | mwnickerson/bloodhound_mcp | needs `BLOODHOUND_DOMAIN`/`TOKEN_ID`/`TOKEN_KEY` |
| mcpwn | gitlab.com/parrotsec/project/mcpwn | Go build; runs its tools natively on Parrot (docker blocks stripped; `LAI_MCPWN_DOCKER=1` keeps Docker) |
| kali-mcp-sudohakan | sudohakan/kali-mcp-server | runs natively on Parrot (stdio, no Docker); ~130 whitelisted tools, apt-install any missing |
| capmonster-mcp | CapMonsterCloud/capmonster-mcp-captcha-solver | CAPTCHA solver; needs `CM_API_KEY` (CapMonster Cloud key) |
| stealth-browser-mcp | vibheksoni/stealth-browser-mcp | nodriver stealth Chrome: navigate/screenshot/click to drive captcha & anti-bot pages; needs Chromium |
| captcha-free | (bundled in this repo) | free local CAPTCHA solvers + a local CLIP vision tool (`vision_match`, `solve_image_grid`, ~66 MB, no key) that gives the text model eyes for image-grid captchas; also OCR (ddddocr), Turnstile (playwright-captcha), reCAPTCHA v2 (PyPasser). Only hCaptcha-via-Gemini needs `GEMINI_API_KEY` |

All are enabled. Two MCP *vulnerability scanners* (Teycir/Mcpwn, ressl/mcpwn) are also installed as CLI tools — they scan an MCP server rather than being one, so they're not registered; the script prints how to run them. Everything runs natively on Parrot now — **no Docker required**. `kali-mcp-sudohakan` and `mcpwn` both shell out to the host's tools (install any missing ones with apt). The key-gated ones (Shodan, BloodHound) connect once you export their env vars; the rest work without keys. They install into `<lai dir>/mcp-tools` (keep that on your persistence partition so they survive a reboot). Backends are (re)started on every `install.sh` run. Pick a subset with `LAI_MCP_ONLY=hexstrike,kali`, list them with `tools/setup-mcp.sh --list`, or add your own by editing the registry at the top of `tools/setup-mcp.sh`. Anything with no locatable public repo is left out. Those, and any others you run, still come across via the OpenCode/Claude import above — add a repo to the registry at the top of `tools/setup-mcp.sh` to automate it.

MCP tools show up to the model as `server__tool`. With `auto_approve` off, they ask first unless the server has `"trust": true`. `${VAR}` in commands, args, env and headers expands from your environment, so secrets can stay out of the config. Server stderr goes to `~/.local/share/lai/logs/mcp-<name>.log`.

## Config

`~/.config/lai/config.json`. Run `lai config` to create and show it, and see `config.example.json` for every option. The settings you're most likely to change:

| key | default | |
|---|---|---|
| `model` | | path to the `.gguf` used when you don't pass `-m` |
| `ctx_size` | 8192 | context window in tokens. `0` = the model's maximum. Capped by `kv_limit_mb` |
| `kv_limit_mb` | 0 | most MB the KV cache may use; the context is shortened to fit (0 = no cap) |
| `kv_in_ram` | false | KV cache in system RAM instead of VRAM: far more room on a small GPU, slower as it fills |
| `kv_cache` | q8_0 | KV-cache precision: `q8_0` is half the size of `f16`, `q4_0` a quarter |
| `flash_attn` | auto | `on`, `off` or `auto` (quantized caches need it, auto turns it on) |
| `ubatch` | 256 | prompt chunk size. The compute buffer grows with it; 512+ speeds up long prompts |
| `moe_on_cpu` | true | MoE models: expert weights stay in RAM, everything else on the GPU (no effect on dense models) |
| `gpu_layers` | -1 | layers on the GPU (-1 = all). For a dense model bigger than your VRAM, set a number |
| `threads` | 0 | CPU threads (0 = one per physical core) |
| `engine` | | path to `lai-engine` if it isn't next to `lai` or on PATH |
| `url` | | use this OpenAI-compatible server instead of `lai-engine` |
| `temperature`, `top_p`, `top_k`, `min_p`, `repeat_penalty` | llama.cpp defaults | sampling; for Qwen3-Coder use 0.7 / 0.8 / 20 / 0 / 1.05, for Qwen3.5 0.6 / 0.95 / 20 / 0 / 1.0 (`install.sh` sets these per model) |
| `thinking` | model default | `false` skips the reasoning step on models that have one (Qwen3.5, GLM): much faster replies on CPU, somewhat less careful |
| `auto_approve` | true | run tools without asking. Set `false` to approve each command and file change (or toggle with `/yolo`) |
| `command_timeout` | 120 | seconds per shell command |
| `system_prompt` | | added to the built-in prompt. An `AGENTS.md` in the current directory is added too |

Environment overrides: `LAI_CONFIG`, `LAI_HOME` (logs dir), `NO_COLOR`. The engine's log is `~/.local/share/lai/logs/engine.log`.

### Memory budget

Measured on a 2.4 GB 4B model at 8k context, CPU-only:

| | weights | working memory |
|---|---|---|
| llama.cpp defaults | 2.4 GB copied (repack) + the mapped file | 1.3 GB compute + 1.15 GB cache |
| lai-engine defaults | the mapped file only | 165 MB compute + 612 MB cache |

The generation speed was the same (about 20 tok/s).

For a 30B-A3B MoE model as a 12 GB file on a 4 GB GPU, with 32k context:

- **RAM:** the expert weights, about 11 GB, mapped from the file.
- **VRAM:** the attention and shared weights (about 1 GB), the q8_0 cache (about 1.6 GB) and the compute buffer.
- **lai:** about 12 MB.

If VRAM runs out, lower `ctx_size` or use `"kv_cache": "q4_0"`.

**For the longest context,** put the cache in RAM and give it a budget. The engine works out the largest context that fits and shows it at startup (e.g. `ctx 120320 (cache 6144 MB, RAM)`):

```json
{ "ctx_size": 0, "kv_in_ram": true, "kv_limit_mb": 6144 }
```

On Qwen3-30B-A3B, about 51 KB per token with q8_0 (27 KB with q4_0): 6 GB gives about 120k tokens, or the model's full 256k with q4_0 at about 7 GB.

On a live boot, keep the `.gguf` on a drive rather than in your RAM home folder. A file in the RAM folder takes its full size in RAM even when lai isn't running. A file on a drive is only paged in as it's used, and the kernel can drop those pages again.

## Build by hand

```sh
make                                   # ./lai
git clone --depth 1 --branch b11982 https://github.com/ggml-org/llama.cpp ../llama.cpp
make engine LLAMA_DIR=../llama.cpp     # ./lai-engine
make dist                              # dist/lai-linux-amd64 and -arm64 (static)
go test ./...
```

Source: `main.go` (CLI), `agent.go` (chat loop), `engine.go` (talks to lai-engine), `engine/lai-engine.cpp` (the model runner), `llm.go` (client for remote servers), `tools.go`, `mcp.go`, `config.go`.
