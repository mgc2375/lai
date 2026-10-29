package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const version = "0.1.0"

const usageText = `lai - lightweight local AI agent for GGUF models

usage:
  lai [flags] [prompt]          chat (one-shot if a prompt is given or stdin is piped)
  lai serve [flags]             web chat for your phone, locked by an access key (see README)
  lai mcp ls                  connect to configured MCP servers and list their tools
  lai mcp add <name> [-e K=V]... [--trust] -- <command> [args...]
  lai mcp add <name> --url <url> [-H "Key: Value"]... [--trust]
  lai mcp rm <name>
  lai config                    show the config file (creates it if missing)

chat flags:
  -m <model>     path to a .gguf file (or a model name with -u)
  -u <url>       use a running OpenAI-compatible server (Ollama, llama-server...)
  -y             run tools without asking
  -c <file>      config file (default ~/.config/lai/config.json)
  --ctx <n>      context size      --ngl <n>   GPU layers
  --no-tools     plain chat        --no-mcp    don't start MCP servers
`

func usage() { fmt.Fprint(os.Stderr, usageText) }

func main() {
	installSignals()
	args := os.Args[1:]
	var err error
	cmd := ""
	if len(args) > 0 {
		cmd = args[0]
	}
	switch cmd {
	case "serve":
		err = cmdServe(args[1:])
	case "mcp":
		err = cmdMCP(args[1:])
	case "config":
		err = cmdConfig()
	case "version", "--version":
		fmt.Println("lai", version)
	case "help", "-h", "--help":
		usage()
	default:
		err = cmdChat(args)
	}
	runCleanups()
	if err != nil {
		fmt.Fprintln(os.Stderr, c(red, "error: ")+err.Error())
		os.Exit(1)
	}
}

// ---- signals and cleanup ----

var (
	mu          sync.Mutex
	cleanups    []func()
	interruptFn func()
	cleanedUp   bool
)

func onCleanup(f func()) {
	mu.Lock()
	cleanups = append(cleanups, f)
	mu.Unlock()
}

func runCleanups() {
	mu.Lock()
	fs := cleanups
	done := cleanedUp
	cleanedUp = true
	mu.Unlock()
	if done {
		return
	}
	for i := len(fs) - 1; i >= 0; i-- {
		fs[i]()
	}
}

// setInterrupt sets what Ctrl-C does; with nil, Ctrl-C quits.
func setInterrupt(f func()) {
	mu.Lock()
	interruptFn = f
	mu.Unlock()
}

func installSignals() {
	ch := make(chan os.Signal, 2)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		for s := range ch {
			mu.Lock()
			f := interruptFn
			mu.Unlock()
			if s == os.Interrupt && f != nil {
				f()
				continue
			}
			fmt.Fprintln(os.Stderr)
			runCleanups()
			os.Exit(130)
		}
	}()
}

// ---- colors ----

const (
	bold   = "1"
	dim    = "2"
	red    = "31"
	green  = "32"
	yellow = "33"
	cyan   = "36"
)

var useColor = isTerminal(os.Stdout) && os.Getenv("NO_COLOR") == ""

func c(code, s string) string {
	if !useColor {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

func colorOn(code string) string {
	if !useColor {
		return ""
	}
	return "\x1b[" + code + "m"
}

func colorOff() string {
	if !useColor {
		return ""
	}
	return "\x1b[0m"
}

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// ---- commands ----

// backend returns a client for the configured server, or loads the GGUF in
// lai-engine when no URL is set. The second value names the model.
func backend(cfg *Config) (Backend, string, error) {
	if cfg.URL != "" {
		llm := newLLM(cfg.URL, cfg.APIKey, cfg.Model, cfg)
		if llm.Model == "" {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			m, err := llm.firstModel(ctx)
			if err != nil {
				return nil, "", err
			}
			llm.Model = m
		}
		return llm, llm.Model, nil
	}
	model, err := resolveModel(cfg.Model)
	if err != nil {
		return nil, "", err
	}
	name := strings.TrimSuffix(baseName(model), ".gguf")
	fmt.Fprint(os.Stderr, c(dim, "loading "+name+"... "))
	setInterrupt(nil)
	e, err := startEngine(cfg, model)
	if err != nil {
		fmt.Fprintln(os.Stderr)
		return nil, "", err
	}
	onCleanup(e.Stop)
	if isTerminal(os.Stderr) {
		fmt.Fprint(os.Stderr, "\r\x1b[K")
	} else {
		fmt.Fprintln(os.Stderr)
	}
	where := "GPU"
	if cfg.KVInRAM {
		where = "RAM"
	}
	return e, fmt.Sprintf("%s · ctx %d (cache %d MB, %s)", name, e.Ctx, e.KVMB, where), nil
}

func baseName(p string) string {
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		return p[i+1:]
	}
	return p
}

func cmdChat(args []string) error {
	fs := flag.NewFlagSet("lai", flag.ExitOnError)
	fs.Usage = usage
	cfgPath := fs.String("c", "", "")
	model := fs.String("m", "", "")
	url := fs.String("u", "", "")
	yes := fs.Bool("y", false, "")
	ctxSize := fs.Int("ctx", 0, "")
	ngl := fs.Int("ngl", -2, "")
	noTools := fs.Bool("no-tools", false, "")
	noMCP := fs.Bool("no-mcp", false, "")
	fs.Parse(args)

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		return err
	}
	if *model != "" {
		cfg.Model = *model
	}
	if *url != "" {
		cfg.URL = *url
		if *model == "" {
			cfg.Model = ""
		}
	}
	if *yes {
		cfg.AutoApprove = true
	}
	if *ctxSize > 0 {
		cfg.CtxSize = *ctxSize
	}
	if *ngl != -2 {
		cfg.GPULayers = *ngl
	}

	prompt := strings.Join(fs.Args(), " ")
	var in *bufio.Reader
	if isTerminal(os.Stdin) {
		in = bufio.NewReader(os.Stdin)
	} else {
		piped, _ := io.ReadAll(os.Stdin)
		if s := strings.TrimSpace(string(piped)); s != "" {
			prompt = strings.TrimSpace(prompt + "\n\n" + s)
		}
		if tty, err := os.Open("/dev/tty"); err == nil {
			in = bufio.NewReader(tty) // approvals still work with piped input
		}
	}
	if prompt == "" && in == nil {
		return errors.New("no prompt and no terminal")
	}

	llm, name, err := backend(cfg)
	if err != nil {
		return err
	}

	tools := newRegistry()
	var mgr *MCPManager
	if !*noTools {
		for _, t := range builtinTools(cfg) {
			tools.Add(t)
		}
		if !*noMCP && len(cfg.MCPServers) > 0 {
			mgr = startMCP(cfg.MCPServers)
			onCleanup(mgr.Close)
			mgr.Register(tools)
		} else if !*noMCP {
			mgr = &MCPManager{}
		}
	}

	a := newAgent(cfg, llm, tools, mgr, !*noTools, in)
	if prompt != "" {
		if mgr != nil {
			for _, s := range mgr.Servers {
				if s.Err != nil {
					fmt.Fprintln(os.Stderr, c(red, fmt.Sprintf("mcp %s: %v", s.Name, s.Err)))
				}
			}
		}
		return a.Turn(prompt)
	}
	return a.REPL(name)
}

func cmdConfig() error {
	p := defaultConfigPath()
	if !fileExists(p) {
		if err := writeDefaultConfig(p); err != nil {
			return err
		}
		fmt.Fprintln(os.Stderr, "created", p)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "#", p)
	fmt.Print(string(b))
	return nil
}

func cmdMCP(args []string) error {
	path := defaultConfigPath()
	sub := ""
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "ls", "list", "":
		cfg, err := loadConfig(path)
		if err != nil {
			return err
		}
		if len(cfg.MCPServers) == 0 {
			fmt.Println("no MCP servers in", path)
			return nil
		}
		var off []string
		for n, s := range cfg.MCPServers {
			if s.Disabled {
				off = append(off, n)
			}
		}
		sort.Strings(off)
		m := startMCP(cfg.MCPServers)
		defer m.Close()
		fmt.Println(m.Status())
		for _, n := range off {
			fmt.Println(c(dim, "- "+n+" (disabled)"))
		}
		return nil

	case "rm", "remove":
		if len(args) != 2 {
			return errors.New("usage: lai mcp rm <name>")
		}
		return editRawConfig(path, func(m map[string]any) error {
			servers, _ := m["mcpServers"].(map[string]any)
			if _, ok := servers[args[1]]; !ok {
				return fmt.Errorf("no MCP server named %q", args[1])
			}
			delete(servers, args[1])
			fmt.Println("removed", args[1])
			return nil
		})

	case "add":
		if len(args) < 2 || strings.HasPrefix(args[1], "-") {
			return errors.New("usage: lai mcp add <name> [-e K=V] [--trust] -- <command> [args...]\n       lai mcp add <name> --url <url> [-H \"Key: Value\"] [--trust]")
		}
		name := args[1]
		entry := map[string]any{}
		env := map[string]any{}
		headers := map[string]any{}
		rest := args[2:]
		for i := 0; i < len(rest); i++ {
			a := rest[i]
			next := func() (string, error) {
				if i+1 >= len(rest) {
					return "", fmt.Errorf("%s needs a value", a)
				}
				i++
				return rest[i], nil
			}
			switch a {
			case "--":
				if i+1 >= len(rest) {
					return errors.New("missing command after --")
				}
				entry["command"] = rest[i+1]
				if len(rest) > i+2 {
					entry["args"] = rest[i+2:]
				}
				i = len(rest)
			case "--url":
				v, err := next()
				if err != nil {
					return err
				}
				entry["url"] = v
			case "-e", "--env":
				v, err := next()
				if err != nil {
					return err
				}
				k, val, ok := strings.Cut(v, "=")
				if !ok {
					return fmt.Errorf("-e wants KEY=VALUE, got %q", v)
				}
				env[k] = val
			case "-H", "--header":
				v, err := next()
				if err != nil {
					return err
				}
				k, val, ok := strings.Cut(v, ":")
				if !ok {
					return fmt.Errorf("-H wants \"Key: Value\", got %q", v)
				}
				headers[strings.TrimSpace(k)] = strings.TrimSpace(val)
			case "--trust":
				entry["trust"] = true
			default:
				return fmt.Errorf("unknown option %q (put the server command after --)", a)
			}
		}
		if entry["command"] == nil && entry["url"] == nil {
			return errors.New("give a command after -- or a --url")
		}
		if len(env) > 0 {
			entry["env"] = env
		}
		if len(headers) > 0 {
			entry["headers"] = headers
		}
		if err := editRawConfig(path, func(m map[string]any) error {
			servers, _ := m["mcpServers"].(map[string]any)
			if servers == nil {
				servers = map[string]any{}
				m["mcpServers"] = servers
			}
			servers[name] = entry
			return nil
		}); err != nil {
			return err
		}
		fmt.Printf("added %s to %s\ncheck it with: lai mcp ls\n", name, path)
		return nil
	}
	return fmt.Errorf("unknown mcp command %q (ls, add, rm)", sub)
}
