# lai

A small local AI agent for the terminal. It loads a GGUF model into memory and lets it work on your machine through shell, file and MCP tools. It's two files with no runtime dependencies:

- **`lai`** (~6 MB, static Go): the chat interface, tools, approvals, MCP client and the optional phone page. Uses ~12 MB of RAM.
- **`lai-engine`** (C++, built from llama.cpp): loads the model and generates text. It contains only llama.cpp's inference core plus its chat-template and tool-call parsing: no HTTP server, web UI, multimodal, model downloader or other tools. lai talks to it over a pipe (one JSON message per line), and it exits when lai does.

Each weight exists once: the model file is memory-mapped and computed on in place (llama.cpp's weight repacking, which keeps a second copy in RAM, is turned off), and any layers you put on the GPU live only in VRAM.

## Install (Parrot OS / Debian)

One command does everything: clone, download the model, build, configure, set up ngrok and start the phone page.

```sh
git clone https://github.com/mgc2375/lai.git ~/lai && cd ~/lai && ./install.sh --serve
```

Already have `~/lai` (e.g. on a persistent install)? Update and rerun instead:

```sh
cd ~/lai && git pull && ./install.sh --serve
```

The installer comes set up with a test ngrok account. Use your own with `NGROK_AUTHTOKEN=<token> NGROK_DOMAIN=<name>.ngrok-free.dev ./install.sh --serve`, or skip ngrok with `NGROK_AUTHTOKEN= NGROK_DOMAIN= ./install.sh` (then run `lai` in the terminal).

What `install.sh` does, skipping anything already done:

1. **Model:** downloads [Huihui-Qwen3.5-9B-abliterated Q6_K](https://huggingface.co/mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF) (7.4 GB, resumable) into `models/`. Use your own with `./install.sh /path/to/model.gguf`, or `--find` to search your drives.
2. **Build tools:** installs any missing ones with apt, then clears apt's download cache.
3. **lai-engine:** builds it against llama.cpp `b11982`. It uses Vulkan if a discrete GPU with a working driver is found, otherwise CPU. A GPU build that crashes on a real token falls back to CPU.
4. **Config:** writes `config.json` (context budget sized to your RAM, the model's recommended sampling, auto-approve on). Later runs keep your settings and only update the model-specific ones when the model changes.
5. **ngrok:** installs the agent and saves your authtoken (only when `NGROK_AUTHTOKEN` / `NGROK_DOMAIN` are set). `lai serve` then starts the tunnel itself.
6. **`--serve`:** starts the phone page and prints its login link.

On a live boot everything lives in RAM: run the same command after each reboot. To keep the model and build between boots, point `LAI_MODEL_DIR` and `LAI_DIR` at a persistent drive.

### Live boot: survive reboots and keep your MCP tools

On a live USB everything is wiped on reboot, so by default each boot re-downloads the model and rebuilds. Point `LAI_PERSIST` at a folder on your persistence partition and the model, the built engine and the config all live there; the next boot finds them ready and just starts:

```sh
LAI_PERSIST=/run/live/persistence/*/lai ./install.sh --serve
```

Your MCP servers (`mcp-kali-server`, `hexstrike-ai`, impacket/BloodHound wrappers, etc.) each run a local command or backend, so they aren't bundled. Set them up once the way you already do in OpenCode, keep that config **and the tool clones/backends on the persistence partition**, and lai re-imports the config on every run — automatically when it's at a standard path, or point to it with `LAI_MCP`:

```sh
LAI_PERSIST=/run/live/persistence/*/lai LAI_MCP=/run/live/persistence/*/opencode.json ./install.sh --serve
```

That way one command brings back the model, the agent, the phone page and all your tools. (CAPTCHA-solving servers like `capmonster-mcp` are the one thing lai won't wire up for you; import carries over whatever is in your own config.)

Overrides: `LAI_MODEL_URL`, `LAI_MODEL_DIR`, `LAI_DIR`, `LAI_MCP`, `LAI_PERSIST`, `LAI_GPU=cpu|vulkan|cuda|rocm`.

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
| sec-bloodhound-mcp | mwnickerson/bloodhound_mcp | left disabled until you set `BLOODHOUND_DOMAIN`/`TOKEN_ID`/`TOKEN_KEY` |

They install into `<lai dir>/mcp-tools` (keep that on your persistence partition so they survive a reboot). Backends are (re)started on every `install.sh` run. Pick a subset with `LAI_MCP_ONLY=hexstrike,kali`, list them with `tools/setup-mcp.sh --list`, or add your own by editing the registry at the top of `tools/setup-mcp.sh`. Servers that aren't in this set — or that need your own credentials — still come across via the OpenCode/Claude import above.

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
