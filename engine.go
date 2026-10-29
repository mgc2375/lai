package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Backend is anything lai can chat with: the local lai-engine or a remote
// OpenAI-compatible server.
type Backend interface {
	Chat(ctx context.Context, msgs []Message, tools []ToolDef, emit func(kind int, s string)) (Message, Stats, error)
}

// Engine is a lai-engine child process holding one GGUF model in memory.
// It speaks newline-delimited JSON over stdin/stdout (see engine/lai-engine.cpp).
type Engine struct {
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	out      *bufio.Reader
	Log      string
	Ctx      int
	KVMB     int
	sampling map[string]any
	mu       sync.Mutex
	done     chan struct{}
}

type engineEvent struct {
	Ready *bool   `json:"ready"`
	Ctx   int     `json:"ctx"`
	KVMB  int     `json:"kv_mb"`
	Text  *string `json:"text"`
	Think *string `json:"think"`
	Error *string `json:"error"`
	Done  *struct {
		Content   string `json:"content"`
		ToolCalls []struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			Arguments string `json:"arguments"`
		} `json:"tool_calls"`
	} `json:"done"`
	Tokens int     `json:"tokens"`
	TPS    float64 `json:"tps"`
}

func findEngine(cfg *Config) (string, error) {
	if cfg.Engine != "" {
		return expandPath(cfg.Engine), nil
	}
	if d := exeDir(); d != "" {
		if p := filepath.Join(d, "lai-engine"); fileExists(p) {
			return p, nil
		}
	}
	if p, err := exec.LookPath("lai-engine"); err == nil {
		return p, nil
	}
	return "", errors.New("lai-engine not found: run install.sh, put lai-engine next to lai or on PATH, set \"engine\" in the config, or use -u to connect to a running server")
}

func startEngine(cfg *Config, model string) (*Engine, error) {
	bin, err := findEngine(cfg)
	if err != nil {
		return nil, err
	}
	args := []string{"-m", model, "-c", strconv.Itoa(cfg.CtxSize)}
	if cfg.GPULayers >= 0 {
		args = append(args, "-ngl", strconv.Itoa(cfg.GPULayers))
	}
	if cfg.Threads > 0 {
		args = append(args, "-t", strconv.Itoa(cfg.Threads))
	}
	if cfg.KVCache != "" {
		args = append(args, "--kv", cfg.KVCache)
	}
	if cfg.FlashAttn != "" {
		args = append(args, "--fa", cfg.FlashAttn)
	}
	if cfg.UBatch > 0 {
		args = append(args, "--ubatch", strconv.Itoa(cfg.UBatch))
	}
	if cfg.CPUMoE {
		args = append(args, "--cpu-moe")
	}
	if cfg.KVInRAM {
		args = append(args, "--kv-ram")
	}
	if cfg.KVLimitMB > 0 {
		args = append(args, "--kv-limit", strconv.Itoa(cfg.KVLimitMB))
	}

	cmd := exec.Command(bin, args...)
	cmd.SysProcAttr = childAttr()
	logPath := filepath.Join(logsDir(), "engine.log")
	logf, err := os.Create(logPath)
	if err != nil {
		return nil, err
	}
	cmd.Stderr = logf
	// Plain pipes rather than StdoutPipe, so Wait can run while we read.
	inR, inW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	cmd.Stdin, cmd.Stdout = inR, outW
	err = cmd.Start()
	inR.Close()
	outW.Close()
	if err != nil {
		logf.Close()
		return nil, fmt.Errorf("starting %s: %w", bin, err)
	}
	e := &Engine{cmd: cmd, stdin: inW, out: bufio.NewReaderSize(outR, 64*1024), Log: logPath,
		sampling: cfg.sampling(), done: make(chan struct{})}
	go func() {
		cmd.Wait()
		logf.Close()
		close(e.done)
	}()

	ev, err := e.next()
	switch {
	case err != nil:
		e.Stop()
		return nil, fmt.Errorf("lai-engine exited while loading the model:\n%s\n(full log: %s)", tailFile(logPath, 15), logPath)
	case ev.Error != nil:
		e.Stop()
		return nil, fmt.Errorf("%s (log: %s)", *ev.Error, logPath)
	case ev.Ready == nil:
		e.Stop()
		return nil, errors.New("lai-engine sent an unexpected first message")
	}
	e.Ctx, e.KVMB = ev.Ctx, ev.KVMB
	return e, nil
}

func (e *Engine) next() (engineEvent, error) {
	var ev engineEvent
	for {
		line, err := e.out.ReadBytes('\n')
		if len(strings.TrimSpace(string(line))) > 0 {
			if jerr := json.Unmarshal(line, &ev); jerr == nil {
				return ev, nil
			}
		}
		if err != nil {
			<-e.done // pipe closed: wait for the exit so the log is complete
			return ev, err
		}
	}
}

func (e *Engine) Chat(ctx context.Context, msgs []Message, tools []ToolDef, emit func(kind int, s string)) (Message, Stats, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := Message{Role: "assistant"}
	var st Stats

	req := map[string]any{"messages": msgs}
	if len(tools) > 0 {
		req["tools"] = tools
	}
	for k, v := range e.sampling {
		req[k] = v
	}
	b, err := json.Marshal(req)
	if err != nil {
		return out, st, err
	}
	if _, err := e.stdin.Write(append(b, '\n')); err != nil {
		return out, st, fmt.Errorf("lai-engine is not running (log: %s)", e.Log)
	}
	// Ctrl-C: the engine stops generating and still finishes the reply normally.
	stop := context.AfterFunc(ctx, func() { e.cmd.Process.Signal(syscall.SIGINT) })
	defer stop()

	var streamed strings.Builder
	for {
		ev, err := e.next()
		if err != nil {
			out.Content = streamed.String()
			return out, st, fmt.Errorf("lai-engine exited:\n%s\n(log: %s)", tailFile(e.Log, 10), e.Log)
		}
		switch {
		case ev.Text != nil:
			streamed.WriteString(*ev.Text)
			emit(outText, *ev.Text)
		case ev.Think != nil:
			emit(outThink, *ev.Think)
		case ev.Error != nil:
			// same shape as a server error, so context-full detection still works
			return out, st, &apiError{Status: 400, Body: *ev.Error}
		case ev.Done != nil:
			out.Content = ev.Done.Content
			for i, tc := range ev.Done.ToolCalls {
				id := tc.ID
				if id == "" {
					id = fmt.Sprintf("call_%d_%06d", i, rand.Intn(1e6))
				}
				out.ToolCalls = append(out.ToolCalls, ToolCall{ID: id, Type: "function", Function: FunctionCall{Name: tc.Name, Arguments: tc.Arguments}})
			}
			st = Stats{Tokens: ev.Tokens, TokPerSec: ev.TPS}
			return out, st, ctx.Err()
		}
	}
}

func (e *Engine) Stop() {
	e.stdin.Close() // the engine exits when its input ends
	select {
	case <-e.done:
		return
	case <-time.After(3 * time.Second):
	}
	syscall.Kill(-e.cmd.Process.Pid, syscall.SIGKILL)
	<-e.done
}

func tailFile(path string, n int) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// resolveModel checks that the configured model is a GGUF file on disk.
func resolveModel(name string) (string, error) {
	if name == "" {
		return "", errors.New("no model: pass -m /path/to/model.gguf or set \"model\" in " + defaultConfigPath())
	}
	p := expandPath(name)
	if !fileExists(p) {
		return "", fmt.Errorf("model file not found: %s", p)
	}
	return p, nil
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}
