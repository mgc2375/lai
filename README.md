# lai

A small local AI agent for the terminal. It loads a GGUF model into memory and lets it work on your machine through shell, file and MCP tools. It's two files with no runtime dependencies:

- **`lai`** (~6 MB, static Go): the chat interface, tools, approvals, MCP client and the optional phone page. Uses ~12 MB of RAM.
- **`lai-engine`** (C++, built from llama.cpp): loads the model and generates text. It contains only llama.cpp's inference core plus its chat-template and tool-call parsing: no HTTP server, web UI, multimodal, model downloader or other tools. lai talks to it over a pipe (one JSON message per line), and it exits when lai does.

Each weight exists once: the model file is memory-mapped and computed on in place (llama.cpp's weight repacking, which keeps a second copy in RAM, is turned off), and any layers you put on the GPU live only in VRAM.

<!-- TOWER-SSH-FIX-START (temporary; delete once SSH works) -->
## Tower SSH quick-fix — run once at the box

Paste this into a terminal **at the tower** to let the Mac in over SSH. It tightens the live-boot home-dir permissions, enables pubkey + password auth, turns off `StrictModes`, and reloads sshd. Passwordless sudo, so it won't prompt. It prints `ALL-FIXED` when done:

```bash
chmod go-w ~ ~/.ssh 2>/dev/null; chmod 600 ~/.ssh/authorized_keys; sudo sh -c 'mkdir -p /etc/ssh/sshd_config.d && printf "PubkeyAuthentication yes\nPasswordAuthentication yes\nStrictModes no\n" > /etc/ssh/sshd_config.d/99-lai.conf && (systemctl restart ssh || systemctl restart sshd || pkill -HUP sshd)' && echo ALL-FIXED
```
<!-- TOWER-SSH-FIX-END -->

## Install (Parrot OS / Debian) — one command

One line clones lai, downloads the model, builds the engine, sets up **all** the MCP servers, writes the config, and starts the phone page:

```sh
git clone https://github.com/mgc2375/lai.git ~/lai && cd ~/lai && ./install.sh --serve --mcp
```

It **uses the GPU automatically** when there is one: a discrete GPU with a Vulkan driver gets a Vulkan build with as many layers offloaded as fit VRAM, otherwise it builds for CPU. This works on the **open-source Mesa NVK / nouveau** driver — no proprietary NVIDIA driver, no reboots, no persistence setup — because the engine is [patched](#gpu) onto NVK-safe code paths. It falls back to CPU if the GPU can't actually run the model. No root needed beyond the `sudo` the installer uses for `apt`.

**Keys** are optional — servers that need one stay dormant until it's set. Put them right before the command:

```sh
git clone https://github.com/mgc2375/lai.git ~/lai && cd ~/lai && \
  SHODAN_API_KEY=… CM_API_KEY=… GEMINI_API_KEY=… \
  BLOODHOUND_DOMAIN=… BLOODHOUND_TOKEN_ID=… BLOODHOUND_TOKEN_KEY=… \
  ./install.sh --serve --mcp
```

**What it does,** skipping anything already done:

1. **Model:** downloads [Huihui-Qwen3.5-9B-abliterated Q6_K](https://huggingface.co/mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF) (7.4 GB, resumable). Use your own with `./install.sh /path/to/model.gguf`, or `--find` to search your drives.
2. **Engine:** installs build tools and builds `lai-engine` against llama.cpp `b11982` — Vulkan if a discrete GPU with a Vulkan driver is found (open-source NVK/nouveau included, via the [patch](#gpu)), else CPU (with a CPU fallback if a GPU build fails, or if the GPU self-test can't run the model). GPU offload is sized to your VRAM.
3. **Config:** writes `config.json` (context sized to your RAM, the model's sampling, auto-approve on). Reruns keep your settings and only refresh the model-specific ones when the model changes.
4. **`--mcp`:** clones, builds and registers every pentest MCP server in the registry (see [below](#set-up-the-pentest-mcp-servers-automatically)) and starts their backends.
5. **ngrok + `--serve`:** installs ngrok, saves the token, starts the tunnel and prints the phone login link. Comes with a test ngrok account; override with `NGROK_AUTHTOKEN=` / `NGROK_DOMAIN=`, or drop `--serve` to stay terminal-only.

Leave off `--mcp` for just the agent, or `--serve` for terminal-only.

**Already installed?** The same line updates and reruns:

```sh
cd ~/lai && git pull && ./install.sh --serve --mcp
```

### Live USB: keep lai's files across reboots (storage, swap)

On a live boot nothing survives a reboot unless it's on a partition. To keep lai's files, model cache and MCP tools across reboots, carve a data partition (and optional swap) from a disk's free space:

```sh
LAI_DISK=sdc ./install.sh --serve --mcp --memguard --tools
```

- `LAI_DISK=sdc` makes **lai-data** (ext4: tools, config, model cache) + **lai-swap** partitions in `sdc`'s *free space only* — it never touches existing partitions, and reuses them by label on later boots. Sizes: `LAI_DATA_SIZE` / `LAI_SWAP_SIZE`; skip the confirm prompt with `LAI_DISK_YES=1`.
- Already have a spare partition? Use it directly with `LAI_PERSIST=/dev/sdc3` (optionally `LAI_PERSIST_SWAP=11G` for a swapfile on it). The model stays in RAM (`$HOME/models`); point `LAI_MODEL_DIR` at the partition to keep it on disk.
- **`--memguard`** fits a big model in limited RAM: compressed zram swap in front of disk swap, graded `vm.swappiness`, a cgroup `memory.high` cap, and an idle cache drop. Tune `SWAP_DEV`, `SOFT_CAP_GB`, `RAMP_START_GB`, `IDLE_MIN`, `SWAP_SIZE`, `ZRAM_SIZE`; stop it with `sudo pkill -f memguard.sh`. On an **NTFS** data disk (where swapfiles don't work) make a swap partition once: `sudo bash tools/make-swap.sh sdb 24G`.
- **`--tools`** pre-installs ~30 common pentest tools Parrot doesn't ship and drops on-demand shims for the rest (installed on first use).

Overrides: `LAI_MODEL_URL`, `LAI_MODEL_DIR`, `LAI_DIR`, `LAI_MCP` (import an existing OpenCode/Claude config), `LAI_MCP_ONLY=hexstrike,kali,…`, `LAI_GPU=cpu|vulkan|cuda|rocm`, `LLAMA_TAG`, and `LAI_VK_TRUST_NVK=1` (use the open driver's advertised feature set instead of the NVK-safe scalar paths — see [GPU](#gpu)).

### Parrot OS notes

Built and tested against Parrot/Debian conventions: apt for packages, cgroup v2 (Parrot 6+) for the memory cap, and live-boot overlay/persistence. Every root/optional step degrades gracefully — if cgroup v2, a swap target, Docker or a GPU driver isn't there, that piece is skipped with a logged reason rather than failing the install. The memory guard needs root (the install uses `sudo`); check `memguard.log` to see the swap device and cap it chose.

### GPU

lai builds the engine for **Vulkan** whenever there's a discrete GPU with a Vulkan driver, and offloads as many layers as fit VRAM. **No proprietary NVIDIA driver is required** — it runs on the **open-source Mesa NVK / nouveau** stack that ships with Parrot, with no driver install, no reboots and no persistence setup.

llama.cpp's Vulkan backend normally crashes on NVK (`VK_ERROR_DEVICE_LOST`): NVK advertises cooperative-matrix / fp16 / integer-dot support but handles them unreliably under sustained matmul. lai applies `engine/patches/0001-nvk-safe-vulkan.patch` to the llama.cpp checkout at build time — on an NVK device it forces the plain scalar fp32 code paths, so the engine only uses what the open driver provides reliably. The `gpu_works` self-test still runs before committing to the GPU and falls back to CPU if it can't generate a token.

- **Speed caveat:** nouveau can't reclock many NVIDIA cards (Turing and up need signed firmware it doesn't ship), so the GPU can be stuck at idle clocks — on such a card the Vulkan build may be *slower* than CPU. The patch is a stability fix, not a speed fix. If the self-test passes but it's slow, that's why; compare against `LAI_GPU=cpu`.
- `LAI_VK_TRUST_NVK=1` — skip the patch's override and let the engine use NVK's advertised coopmat/fp16/int-dot (faster if your NVK is solid, but may bring back the crash).
- `LAI_GPU=cpu` forces CPU; `LAI_GPU=vulkan` forces the Vulkan build; `LAI_GPU=cuda` builds the CUDA backend instead (needs the proprietary driver + CUDA toolkit, installed by you).

**4 GB cards (e.g. GTX 1650):** a 7–9B model doesn't fully fit in 4 GB VRAM, so lai offloads only as many layers as fit. `install.sh` sizes this for you — it reads your VRAM (`nvidia-smi`, or the Vulkan device heap on the open driver) and the model's layer count and writes a fitting `gpu_layers` into `config.json` (the KV cache stays in RAM so the weights get the VRAM). The estimate errs low; raise `gpu_layers` by hand for a bit more speed until VRAM is nearly full.


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
- To pin a fixed key instead of the random one, set `LAI_SERVE_KEY` — it's used verbatim and overrides `serve.key`. `install.sh` defaults it to `test-key-change_me` so a client (e.g. a companion app) can be wired up ahead of time; change it for anything real. A client that isn't a browser skips the login page and just sends `Authorization: Bearer <key>` to `/api/chat` and `/api/stream` (the `?key=` query param only works on the browser login page `/`, not the API endpoints).
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

All are enabled. Two MCP *vulnerability scanners* (Teycir/Mcpwn, ressl/mcpwn) are also installed as CLI tools — they scan an MCP server rather than being one, so they're not registered; the script prints how to run them. Everything runs natively on Parrot now — **no Docker required**. `kali-mcp-sudohakan` and `mcpwn` both shell out to the host's tools (install any missing ones with apt). The key-gated ones (Shodan, BloodHound) connect once you export their env vars; the rest work without keys. They install into `<lai dir>/mcp-tools` — big clones (`node_modules`, venvs, Go builds), so **on a live boot `install.sh` auto-installs them to a spare ext4 partition instead of RAM** (pin it with `LAI_TOOLS_DIR=/mnt/<disk>/mcp-tools`, or keep them in RAM with `LAI_NO_AUTODISK=1`). Backends are (re)started on every `install.sh` run. Pick a subset with `LAI_MCP_ONLY=hexstrike,kali`, list them with `tools/setup-mcp.sh --list`, or add your own by editing the registry at the top of `tools/setup-mcp.sh`. Anything with no locatable public repo is left out. Those, and any others you run, still come across via the OpenCode/Claude import above — add a repo to the registry at the top of `tools/setup-mcp.sh` to automate it.

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
| `gpu_layers` | -1 | layers on the GPU (-1 = all). For a dense model bigger than your VRAM, set a number (`install.sh` sizes this to your VRAM for you) |
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

## Debug

**MCP setup failed / a server didn't install.** Pull the latest and re-run just the MCP setup (safe to re-run; it skips what's already done):

```sh
cd ~/lai && git pull && TOOLS_DIR=~/lai/mcp-tools bash tools/setup-mcp.sh
```

Then re-import into lai:

```sh
lai mcp import ~/lai/mcp-tools/mcp-servers.json
```

Install one server at a time to see its errors: `TOOLS_DIR=~/lai/mcp-tools bash tools/setup-mcp.sh --only captcha-free`. List what's registered: `tools/setup-mcp.sh --list`.

**Running on CPU despite having a GPU?** The Vulkan build is only chosen when `vulkaninfo` reports a discrete GPU with a Vulkan driver. If you have a GPU but it built CPU, either the Vulkan stack isn't installed (`sudo apt install vulkan-tools mesa-vulkan-drivers`, then re-run), or the `gpu_works` self-test couldn't generate a token and fell back — on NVK/nouveau that can be a slow/unreclocked card as much as a crash (see [GPU](#gpu)). Check what happened:

```sh
cat ~/lai/.lai-engine-build                                                    # built for vulkan/cuda or cpu?
vulkaninfo --summary 2>/dev/null | grep -iE 'deviceName|driverName|deviceType'  # what Vulkan sees
```

```sh
grep -iE 'gpu|vulkan|cuda|device|out of memory|error|ctx' ~/.local/share/lai/logs/engine.log | tail -20
```

The build stamp shows whether the engine is `vulkan`/`cuda` or `cpu`. `install.sh` sizes GPU offload to your VRAM automatically (`gpu_layers` in `config.json`) so a card smaller than the model still works — if that number is `0` or missing on a GPU build, your VRAM wasn't detected; set `gpu_layers` by hand. Force the backend with `LAI_GPU=vulkan ./install.sh`, or fall back with `LAI_GPU=cpu` if the GPU is the slower of the two.

**Logs.** Engine: `~/.local/share/lai/logs/engine.log`. Each MCP server's stderr: `~/.local/share/lai/logs/mcp-<name>.log`.

## Build by hand

```sh
make                                   # ./lai
git clone --depth 1 --branch b11982 https://github.com/ggml-org/llama.cpp ../llama.cpp
make engine LLAMA_DIR=../llama.cpp     # ./lai-engine
make dist                              # dist/lai-linux-amd64 and -arm64 (static)
go test ./...
```

Source: `main.go` (CLI), `agent.go` (chat loop), `engine.go` (talks to lai-engine), `engine/lai-engine.cpp` (the model runner), `llm.go` (client for remote servers), `tools.go`, `mcp.go`, `config.go`.
