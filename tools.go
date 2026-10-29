package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Tool struct {
	Name   string
	Desc   string
	Schema string
	Ask    bool // needs user approval unless auto-approve is on
	MCP    bool
	Show   func(args map[string]any) string // one-line summary shown to the user
	Run    func(ctx context.Context, args map[string]any) (string, error)
}

type Registry struct {
	list   []*Tool
	byName map[string]*Tool
}

func newRegistry() *Registry { return &Registry{byName: map[string]*Tool{}} }

func (r *Registry) Add(t *Tool) {
	if _, dup := r.byName[t.Name]; dup {
		return
	}
	r.list = append(r.list, t)
	r.byName[t.Name] = t
}

func (r *Registry) Get(name string) *Tool { return r.byName[name] }

func (r *Registry) RemoveMCP() {
	keep := r.list[:0]
	for _, t := range r.list {
		if t.MCP {
			delete(r.byName, t.Name)
		} else {
			keep = append(keep, t)
		}
	}
	r.list = keep
}

func (r *Registry) Defs() []ToolDef {
	defs := make([]ToolDef, 0, len(r.list))
	for _, t := range r.list {
		defs = append(defs, ToolDef{Type: "function", Function: FunctionDef{Name: t.Name, Description: t.Desc, Parameters: json.RawMessage(t.Schema)}})
	}
	return defs
}

func argStr(a map[string]any, k string) string {
	switch v := a[k].(type) {
	case string:
		return v
	case nil:
		return ""
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

func argInt(a map[string]any, k string, def int) int {
	switch v := a[k].(type) {
	case float64:
		return int(v)
	case string:
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func argBool(a map[string]any, k string) bool {
	switch v := a[k].(type) {
	case bool:
		return v
	case string:
		return v == "true"
	}
	return false
}

func expandPath(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		h, _ := os.UserHomeDir()
		return filepath.Join(h, p[1:])
	}
	return p
}

// truncateMiddle keeps the head and tail of long output, which is where
// errors and results usually are.
func truncateMiddle(s string, max int) string {
	if max <= 0 || len(s) <= max {
		return s
	}
	head := max * 2 / 3
	tail := max - head
	return s[:head] + fmt.Sprintf("\n\n[... %d chars truncated ...]\n\n", len(s)-max) + s[len(s)-tail:]
}

func builtinTools(cfg *Config) []*Tool {
	return []*Tool{
		{
			Name: "bash",
			Desc: "Run a shell command on the user's machine and return its combined stdout/stderr and exit code. Commands are non-interactive (no stdin).",
			Schema: `{"type":"object","properties":{
				"command":{"type":"string","description":"The command to run with bash -c"},
				"timeout":{"type":"integer","description":"Timeout in seconds (default ` + strconv.Itoa(cfg.CommandTimeout) + `)"},
				"workdir":{"type":"string","description":"Directory to run in (default: current directory)"}},
				"required":["command"]}`,
			Ask: true,
			Show: func(a map[string]any) string {
				s := argStr(a, "command")
				if wd := argStr(a, "workdir"); wd != "" {
					s += "  (in " + wd + ")"
				}
				return s
			},
			Run: func(ctx context.Context, a map[string]any) (string, error) {
				cmd := argStr(a, "command")
				if strings.TrimSpace(cmd) == "" {
					return "", errors.New("command is empty")
				}
				t := time.Duration(argInt(a, "timeout", cfg.CommandTimeout)) * time.Second
				return runShell(ctx, cfg.Shell, cmd, expandPath(argStr(a, "workdir")), t), nil
			},
		},
		{
			Name: "read_file",
			Desc: "Read a text file. Returns lines prefixed with line numbers.",
			Schema: `{"type":"object","properties":{
				"path":{"type":"string"},
				"offset":{"type":"integer","description":"First line to read, 1-based (default 1)"},
				"limit":{"type":"integer","description":"Max lines to read (default 2000)"}},
				"required":["path"]}`,
			Show: func(a map[string]any) string { return argStr(a, "path") },
			Run: func(ctx context.Context, a map[string]any) (string, error) {
				return readFile(expandPath(argStr(a, "path")), argInt(a, "offset", 1), argInt(a, "limit", 2000))
			},
		},
		{
			Name: "write_file",
			Desc: "Create or overwrite a file with the given content. Creates parent directories.",
			Schema: `{"type":"object","properties":{
				"path":{"type":"string"},
				"content":{"type":"string"}},
				"required":["path","content"]}`,
			Ask: true,
			Show: func(a map[string]any) string {
				c := argStr(a, "content")
				return fmt.Sprintf("%s (%d lines)\n%s", argStr(a, "path"), strings.Count(c, "\n")+1, preview(c, "+ ", 12))
			},
			Run: func(ctx context.Context, a map[string]any) (string, error) {
				p := expandPath(argStr(a, "path"))
				mode := os.FileMode(0o644)
				if fi, err := os.Stat(p); err == nil {
					mode = fi.Mode().Perm()
				}
				if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
					return "", err
				}
				c := argStr(a, "content")
				if err := os.WriteFile(p, []byte(c), mode); err != nil {
					return "", err
				}
				return fmt.Sprintf("wrote %d bytes to %s", len(c), p), nil
			},
		},
		{
			Name: "edit_file",
			Desc: "Replace an exact string in a file. old_string must match exactly (including whitespace) and be unique unless replace_all is true. Read the file first.",
			Schema: `{"type":"object","properties":{
				"path":{"type":"string"},
				"old_string":{"type":"string"},
				"new_string":{"type":"string"},
				"replace_all":{"type":"boolean"}},
				"required":["path","old_string","new_string"]}`,
			Ask: true,
			Show: func(a map[string]any) string {
				return argStr(a, "path") + "\n" + preview(argStr(a, "old_string"), "- ", 10) + "\n" + preview(argStr(a, "new_string"), "+ ", 10)
			},
			Run: func(ctx context.Context, a map[string]any) (string, error) {
				p := expandPath(argStr(a, "path"))
				b, err := os.ReadFile(p)
				if err != nil {
					return "", err
				}
				old, nw := argStr(a, "old_string"), argStr(a, "new_string")
				if old == "" {
					return "", errors.New("old_string is empty")
				}
				n := strings.Count(string(b), old)
				switch {
				case n == 0:
					return "", errors.New("old_string not found in file")
				case n > 1 && !argBool(a, "replace_all"):
					return "", fmt.Errorf("old_string occurs %d times; add more context or set replace_all", n)
				}
				s := strings.Replace(string(b), old, nw, -1)
				fi, _ := os.Stat(p)
				if err := os.WriteFile(p, []byte(s), fi.Mode().Perm()); err != nil {
					return "", err
				}
				return fmt.Sprintf("replaced %d occurrence(s) in %s", n, p), nil
			},
		},
	}
}

func preview(s, prefix string, maxLines int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	var b strings.Builder
	for i, l := range lines {
		if i == maxLines {
			fmt.Fprintf(&b, "%s... (%d more lines)", prefix, len(lines)-maxLines)
			break
		}
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(prefix + l)
	}
	return b.String()
}

// capBuffer keeps at most max bytes, dropping the middle once full.
type capBuffer struct {
	head, tail []byte
	max        int
	dropped    int
}

func (c *capBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if room := c.max/2 - len(c.head); room > 0 {
		k := min(room, len(p))
		c.head = append(c.head, p[:k]...)
		p = p[k:]
	}
	c.tail = append(c.tail, p...)
	if over := len(c.tail) - c.max/2; over > 0 {
		c.dropped += over
		c.tail = append(c.tail[:0], c.tail[over:]...)
	}
	return n, nil
}

func (c *capBuffer) String() string {
	if c.dropped == 0 {
		return string(c.head) + string(c.tail)
	}
	return string(c.head) + fmt.Sprintf("\n[... %d bytes dropped ...]\n", c.dropped) + string(c.tail)
}

func runShell(ctx context.Context, shell, command, dir string, timeout time.Duration) string {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.Command(shell, "-c", command)
	cmd.Dir = dir
	buf := &capBuffer{max: 1 << 20}
	cmd.Stdout, cmd.Stderr = buf, buf
	// Own process group: terminal Ctrl-C reaches lai, which then kills the whole group.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Start(); err != nil {
		return "error: " + err.Error()
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var err error
	killed := false
	select {
	case err = <-done:
	case <-ctx.Done():
		killed = true
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		err = <-done
	}
	out := strings.TrimRight(buf.String(), "\n")
	code := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		code = ee.ExitCode()
	} else if err != nil && !killed {
		out += "\nerror: " + err.Error()
	}
	switch {
	case killed && ctx.Err() == context.DeadlineExceeded:
		out += fmt.Sprintf("\n[timed out after %s]", timeout)
	case killed:
		out += "\n[interrupted by user]"
	}
	if out == "" {
		out = "(no output)"
	}
	return fmt.Sprintf("%s\n[exit code %d]", out, code)
}

func readFile(path string, offset, limit int) (string, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if fi.IsDir() {
		return "", fmt.Errorf("%s is a directory; use bash ls", path)
	}
	if fi.Size() > 20<<20 {
		return "", fmt.Errorf("file is %d bytes; use bash (head, sed -n, grep) for large files", fi.Size())
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if bytes.IndexByte(b[:min(len(b), 8192)], 0) >= 0 {
		return "", errors.New("binary file")
	}
	lines := strings.Split(string(b), "\n")
	if offset < 1 {
		offset = 1
	}
	if limit <= 0 {
		limit = 2000
	}
	var out strings.Builder
	end := min(len(lines), offset-1+limit)
	for i := offset - 1; i < end; i++ {
		fmt.Fprintf(&out, "%6d\t%s\n", i+1, lines[i])
	}
	if end < len(lines) {
		fmt.Fprintf(&out, "[%d more lines; use offset=%d]\n", len(lines)-end, end+1)
	}
	if out.Len() == 0 {
		return "(empty file)", nil
	}
	return out.String(), nil
}
