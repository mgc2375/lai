package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

type Agent struct {
	cfg      *Config
	llm      Backend
	tools    *Registry
	mcp      *MCPManager
	useTools bool
	msgs     []Message
	in       *bufio.Reader // terminal input for prompts and approvals; nil if none
	auto     bool
	allowed  map[string]bool
}

func newAgent(cfg *Config, llm Backend, tools *Registry, mcp *MCPManager, useTools bool, in *bufio.Reader) *Agent {
	a := &Agent{cfg: cfg, llm: llm, tools: tools, mcp: mcp, useTools: useTools, in: in, auto: cfg.AutoApprove, allowed: map[string]bool{}}
	a.reset()
	return a
}

func (a *Agent) reset() {
	a.msgs = []Message{{Role: "system", Content: systemPrompt(a.cfg, a.useTools)}}
}

func systemPrompt(cfg *Config, useTools bool) string {
	var b strings.Builder
	b.WriteString("You are lai, an AI assistant running locally on the user's own machine.\n")
	if useTools {
		b.WriteString(`You have direct access to the machine through tools.
- Use the bash tool to run shell commands and inspect or change the system. Commands run non-interactively with no stdin: avoid editors, pagers and prompts (use flags like -y, --no-pager, | cat).
- Use read_file, edit_file and write_file for files. Read a file before you edit it.
- When the user asks you to do something, do it with the tools instead of explaining how, then check that it worked.
- Never invent command output. If a command fails, read the error and fix the cause.
`)
	}
	b.WriteString("- Keep answers short and plain.\n\nEnvironment:\n")
	cwd, _ := os.Getwd()
	osName := runtime.GOOS
	if rel, err := os.ReadFile("/etc/os-release"); err == nil {
		for _, l := range strings.Split(string(rel), "\n") {
			if v, ok := strings.CutPrefix(l, "PRETTY_NAME="); ok {
				osName = strings.Trim(v, `"`)
			}
		}
	}
	kernel, _ := exec.Command("uname", "-srm").Output()
	fmt.Fprintf(&b, "- OS: %s (%s)\n- user: %s\n- cwd: %s\n- shell: %s\n- date: %s\n",
		osName, strings.TrimSpace(string(kernel)), os.Getenv("USER"), cwd, cfg.Shell, time.Now().Format("2006-01-02 15:04 MST"))
	if cfg.SystemPrompt != "" {
		b.WriteString("\n" + cfg.SystemPrompt + "\n")
	}
	if agents, err := os.ReadFile("AGENTS.md"); err == nil {
		b.WriteString("\nProject instructions (AGENTS.md):\n" + truncateMiddle(string(agents), 8000) + "\n")
	}
	return b.String()
}

// Turn runs one user prompt to completion, including any tool rounds.
func (a *Agent) Turn(input string) error {
	a.msgs = append(a.msgs, Message{Role: "user", Content: input})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	setInterrupt(cancel)
	defer setInterrupt(nil)

	var defs []ToolDef
	if a.useTools {
		defs = a.tools.Defs()
	}
	for step := 0; step < a.cfg.MaxSteps; step++ {
		msg, st, err := a.complete(ctx, defs)
		if ctx.Err() != nil {
			fmt.Println(c(yellow, "\n[interrupted]"))
			if msg.Content == "" {
				msg.Content = "[interrupted]"
			}
			msg.ToolCalls = nil
			a.msgs = append(a.msgs, msg)
			return nil
		}
		if err != nil {
			if step == 0 {
				a.msgs = a.msgs[:len(a.msgs)-1] // drop the unanswered prompt so a retry doesn't repeat it
			}
			return err
		}
		a.msgs = append(a.msgs, msg)
		if len(msg.ToolCalls) == 0 {
			if st.Tokens > 0 && isTerminal(os.Stdout) {
				if st.TokPerSec > 0 {
					fmt.Println(c(dim, fmt.Sprintf("[%d tokens, %.1f tok/s]", st.Tokens, st.TokPerSec)))
				} else {
					fmt.Println(c(dim, fmt.Sprintf("[%d tokens]", st.Tokens)))
				}
			}
			return nil
		}
		for _, tc := range msg.ToolCalls {
			out := "[skipped: interrupted by user]"
			if ctx.Err() == nil {
				out = a.runTool(ctx, tc)
			}
			a.msgs = append(a.msgs, Message{Role: "tool", ToolCallID: tc.ID, Name: tc.Function.Name, Content: out})
		}
		if ctx.Err() != nil {
			fmt.Println(c(yellow, "[interrupted]"))
			return nil
		}
	}
	fmt.Println(c(yellow, fmt.Sprintf("[stopped after %d tool rounds; say 'continue' to go on]", a.cfg.MaxSteps)))
	return nil
}

func (a *Agent) complete(ctx context.Context, defs []ToolDef) (Message, Stats, error) {
	for attempt := 0; ; attempt++ {
		p := &printer{}
		msg, st, err := a.llm.Chat(ctx, a.msgs, defs, p.emit)
		p.end()
		if err != nil && isContextError(err) && attempt < 5 && a.compact() {
			fmt.Println(c(yellow, "[context full: dropped oldest messages]"))
			continue
		}
		return msg, st, err
	}
}

// compact frees context by dropping the oldest exchange, or, with only one
// exchange left, by shortening the biggest tool outputs.
func (a *Agent) compact() bool {
	for i := 2; i < len(a.msgs); i++ {
		if a.msgs[i].Role == "user" {
			a.msgs = append(a.msgs[:1], a.msgs[i:]...)
			return true
		}
	}
	changed := false
	for i := range a.msgs {
		if a.msgs[i].Role == "tool" && len(a.msgs[i].Content) > 2000 {
			a.msgs[i].Content = truncateMiddle(a.msgs[i].Content, 2000)
			changed = true
		}
	}
	return changed
}

func (a *Agent) runTool(ctx context.Context, tc ToolCall) string {
	t := a.tools.Get(tc.Function.Name)
	if t == nil {
		fmt.Println(c(red, "● unknown tool "+tc.Function.Name))
		return fmt.Sprintf("error: unknown tool %q", tc.Function.Name)
	}
	args := map[string]any{}
	if s := strings.TrimSpace(tc.Function.Arguments); s != "" && s != "null" {
		if err := json.Unmarshal([]byte(s), &args); err != nil {
			fmt.Println(c(red, "● "+t.Name+": bad arguments"))
			return "error: arguments are not valid JSON: " + err.Error()
		}
	}
	fmt.Println(c(cyan, "● "+t.Name) + " " + t.Show(args))
	if t.Ask && !a.auto && !a.allowed[t.Name] {
		ok, note := a.confirm(t.Name)
		if !ok {
			msg := "The user denied this tool call."
			if note != "" {
				msg += " They said: " + note
			}
			return msg
		}
	}
	out, err := t.Run(ctx, args)
	if err != nil {
		out = strings.TrimSpace("error: " + err.Error() + "\n" + out)
	}
	fmt.Println(c(dim, preview(out, "  ", 8)))
	return truncateMiddle(out, a.cfg.MaxOutput)
}

func (a *Agent) confirm(tool string) (bool, string) {
	if a.in == nil {
		fmt.Println(c(red, "  denied: no terminal to ask for approval (use -y to allow tools)"))
		return false, ""
	}
	fmt.Print(c(yellow, "  allow? [y]es  [n]o  [a]lways "+tool+"  (or type feedback): "))
	line, err := a.in.ReadString('\n')
	if err != nil && line == "" {
		fmt.Println(c(red, "denied"))
		return false, ""
	}
	ans := strings.TrimSpace(line)
	switch strings.ToLower(ans) {
	case "y", "yes", "":
		return true, ""
	case "a", "always":
		a.allowed[tool] = true
		return true, ""
	case "n", "no":
		return false, ""
	}
	return false, ans
}

// printer streams model output, showing reasoning dimmed.
type printer struct {
	thinking bool
	wrote    bool
	lastNL   bool
}

func (p *printer) emit(kind int, s string) {
	if kind == outThink && !p.thinking {
		p.thinking = true
		fmt.Print(colorOn(dim))
	} else if kind == outText && p.thinking {
		p.thinking = false
		fmt.Print(colorOff() + "\n")
	}
	if kind == outText && !p.wrote {
		s = strings.TrimLeft(s, "\n")
	}
	if s == "" {
		return
	}
	fmt.Print(s)
	p.wrote = true
	p.lastNL = strings.HasSuffix(s, "\n")
}

func (p *printer) end() {
	if p.thinking {
		fmt.Print(colorOff())
	}
	if p.wrote && !p.lastNL {
		fmt.Println()
	}
}

const helpText = `commands:
  /help            this help
  /clear           forget the conversation
  /tools           list available tools
  /mcp             MCP server status
  /mcp reload      reconnect MCP servers after editing the config
  /yolo            toggle auto-approve for tool calls
  /exit            quit (or Ctrl-D)
  !<command>       run a shell command yourself (not sent to the model)
input:
  end a line with \ to continue it; wrap multi-line text in """ ... """
  Ctrl-C stops the current reply or command`

func (a *Agent) REPL(model string) error {
	mcpCount := 0
	if a.mcp != nil {
		for _, s := range a.mcp.Servers {
			if s.Err != nil {
				fmt.Println(c(red, fmt.Sprintf("mcp %s: %v", s.Name, s.Err)))
			} else {
				mcpCount += len(s.Tools)
			}
		}
	}
	mode := "ask"
	if a.auto {
		mode = "auto"
	}
	fmt.Println(c(bold, "lai "+version) + c(dim, fmt.Sprintf(" · %s · %d tools (%d mcp) · approve: %s · /help", model, len(a.tools.list), mcpCount, mode)))
	for {
		fmt.Print(c(green, "\n› "))
		line, err := readInput(a.in)
		if err == io.EOF && strings.TrimSpace(line) == "" {
			fmt.Println()
			return nil
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "!") {
			a.shellEscape(strings.TrimSpace(line[1:]))
			continue
		}
		if strings.HasPrefix(line, "/") {
			if a.command(line) {
				return nil
			}
			continue
		}
		fmt.Println()
		if err := a.Turn(line); err != nil {
			fmt.Println(c(red, "error: "+err.Error()))
		}
	}
}

func readInput(r *bufio.Reader) (string, error) {
	var b strings.Builder
	block := false
	for {
		line, err := r.ReadString('\n')
		trimmed := strings.TrimRight(line, "\r\n")
		switch {
		case strings.TrimSpace(trimmed) == `"""`:
			if block {
				return b.String(), nil
			}
			block = true
		case block:
			b.WriteString(trimmed + "\n")
		case strings.HasSuffix(trimmed, `\`):
			b.WriteString(strings.TrimSuffix(trimmed, `\`) + "\n")
		default:
			b.WriteString(trimmed)
			return b.String(), err
		}
		if err != nil {
			return b.String(), err
		}
		fmt.Print(c(dim, "… "))
	}
}

func (a *Agent) shellEscape(cmdline string) {
	if cmdline == "" {
		return
	}
	cmd := exec.Command(a.cfg.Shell, "-c", cmdline)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	setInterrupt(func() {}) // Ctrl-C goes to the command, not lai
	defer setInterrupt(nil)
	if err := cmd.Run(); err != nil {
		fmt.Println(c(dim, err.Error()))
	}
}

// command handles a slash command; it returns true to quit.
func (a *Agent) command(line string) bool {
	f := strings.Fields(line)
	switch f[0] {
	case "/exit", "/quit", "/q":
		return true
	case "/help", "/?":
		fmt.Println(helpText)
	case "/clear", "/new":
		a.reset()
		fmt.Println(c(dim, "conversation cleared"))
	case "/tools":
		for _, t := range a.tools.list {
			flag := ""
			if t.Ask && !a.auto && !a.allowed[t.Name] {
				flag = c(yellow, " (asks)")
			}
			fmt.Printf("%s%s  %s\n", t.Name, flag, c(dim, truncateMiddle(strings.SplitN(t.Desc, "\n", 2)[0], 90)))
		}
	case "/yolo":
		a.auto = !a.auto
		fmt.Println(c(yellow, fmt.Sprintf("auto-approve: %v", a.auto)))
	case "/mcp":
		if a.mcp == nil {
			fmt.Println("MCP disabled (--no-mcp)")
			break
		}
		if len(f) > 1 && f[1] == "reload" {
			cfg, err := loadConfig(a.cfg.path)
			if err != nil {
				fmt.Println(c(red, err.Error()))
				break
			}
			a.mcp.Close()
			fmt.Println(c(dim, "connecting MCP servers..."))
			*a.mcp = *startMCP(cfg.MCPServers)
			a.mcp.Register(a.tools)
		}
		fmt.Println(a.mcp.Status())
	default:
		fmt.Println("unknown command; /help lists them")
	}
	return false
}
