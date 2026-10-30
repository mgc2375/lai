package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const mcpProtocol = "2025-06-18"

type rpcOut struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      any       `json:"id,omitempty"`
	Method  string    `json:"method,omitempty"`
	Params  any       `json:"params,omitempty"`
	Result  any       `json:"result,omitempty"`
	Error   *rpcError `json:"error,omitempty"`
}

type rpcIn struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string { return fmt.Sprintf("mcp error %d: %s", e.Code, e.Message) }

func parseID(raw json.RawMessage) (int64, bool) {
	var n int64
	if json.Unmarshal(raw, &n) == nil {
		return n, true
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return n, true
		}
	}
	return 0, false
}

type mcpTransport interface {
	Call(ctx context.Context, method string, params any) (json.RawMessage, error)
	Notify(method string, params any) error
	Close()
}

// ---- stdio transport: newline-delimited JSON-RPC over a child process ----

type stdioTransport struct {
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	wmu     sync.Mutex
	pmu     sync.Mutex
	pending map[int64]chan *rpcIn
	nextID  atomic.Int64
	done    chan struct{}
}

func newStdio(name string, sc MCPServerConfig) (*stdioTransport, error) {
	args := make([]string, len(sc.Args))
	for i, a := range sc.Args {
		args[i] = os.ExpandEnv(a)
	}
	cmd := exec.Command(os.ExpandEnv(expandPath(sc.Command)), args...)
	cmd.Env = os.Environ()
	for k, v := range sc.Env {
		cmd.Env = append(cmd.Env, k+"="+os.ExpandEnv(v))
	}
	if sc.Cwd != "" {
		cmd.Dir = expandPath(os.ExpandEnv(sc.Cwd))
	}
	cmd.SysProcAttr = childAttr()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	logf, _ := os.OpenFile(filepath.Join(logsDir(), "mcp-"+name+".log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if logf != nil {
		cmd.Stderr = logf
	}
	if err := cmd.Start(); err != nil {
		if logf != nil {
			logf.Close()
		}
		return nil, err
	}
	t := &stdioTransport{cmd: cmd, stdin: stdin, pending: map[int64]chan *rpcIn{}, done: make(chan struct{})}
	go func() {
		t.readLoop(stdout)
		cmd.Wait()
		if logf != nil {
			logf.Close()
		}
		close(t.done)
	}()
	return t, nil
}

func (t *stdioTransport) send(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	t.wmu.Lock()
	defer t.wmu.Unlock()
	_, err = t.stdin.Write(append(b, '\n'))
	return err
}

func (t *stdioTransport) readLoop(r io.Reader) {
	br := bufio.NewReaderSize(r, 64*1024)
	for {
		line, err := br.ReadBytes('\n')
		if line = bytes.TrimSpace(line); len(line) > 0 {
			t.handle(line)
		}
		if err != nil {
			return
		}
	}
}

func (t *stdioTransport) handle(line []byte) {
	var m rpcIn
	if json.Unmarshal(line, &m) != nil {
		return // servers sometimes print junk to stdout
	}
	if m.Method != "" {
		if len(m.ID) == 0 || string(m.ID) == "null" {
			return // notification
		}
		reply := rpcOut{JSONRPC: "2.0", ID: json.RawMessage(m.ID)}
		if m.Method == "ping" {
			reply.Result = map[string]any{}
		} else {
			reply.Error = &rpcError{Code: -32601, Message: "method not supported: " + m.Method}
		}
		t.send(reply)
		return
	}
	id, ok := parseID(m.ID)
	if !ok {
		return
	}
	t.pmu.Lock()
	ch := t.pending[id]
	delete(t.pending, id)
	t.pmu.Unlock()
	if ch != nil {
		ch <- &m
	}
}

func (t *stdioTransport) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	id := t.nextID.Add(1)
	ch := make(chan *rpcIn, 1)
	t.pmu.Lock()
	t.pending[id] = ch
	t.pmu.Unlock()
	if err := t.send(rpcOut{JSONRPC: "2.0", ID: id, Method: method, Params: params}); err != nil {
		return nil, err
	}
	select {
	case m := <-ch:
		if m.Error != nil {
			return nil, m.Error
		}
		return m.Result, nil
	case <-ctx.Done():
		t.pmu.Lock()
		delete(t.pending, id)
		t.pmu.Unlock()
		t.Notify("notifications/cancelled", map[string]any{"requestId": id})
		return nil, ctx.Err()
	case <-t.done:
		return nil, errors.New("server process exited")
	}
}

func (t *stdioTransport) Notify(method string, params any) error {
	return t.send(rpcOut{JSONRPC: "2.0", Method: method, Params: params})
}

func (t *stdioTransport) Close() {
	t.stdin.Close()
	select {
	case <-t.done:
		return
	case <-time.After(2 * time.Second):
	}
	syscall.Kill(-t.cmd.Process.Pid, syscall.SIGKILL)
	select {
	case <-t.done:
	case <-time.After(time.Second):
	}
}

// ---- Streamable HTTP transport ----

type httpTransport struct {
	url     string
	headers map[string]string
	client  *http.Client
	mu      sync.Mutex
	session string
	proto   string
	nextID  atomic.Int64
}

func newHTTP(sc MCPServerConfig) *httpTransport {
	return &httpTransport{url: os.ExpandEnv(sc.URL), headers: sc.Headers, client: &http.Client{}}
}

func (t *httpTransport) setProto(p string) {
	t.mu.Lock()
	t.proto = p
	t.mu.Unlock()
}

func (t *httpTransport) do(ctx context.Context, method string, payload any) (*http.Response, error) {
	var body io.Reader
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, t.url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	t.mu.Lock()
	if t.session != "" {
		req.Header.Set("Mcp-Session-Id", t.session)
	}
	if t.proto != "" {
		req.Header.Set("MCP-Protocol-Version", t.proto)
	}
	t.mu.Unlock()
	for k, v := range t.headers {
		req.Header.Set(k, os.ExpandEnv(v))
	}
	resp, err := t.client.Do(req)
	if err != nil {
		return nil, err
	}
	if sid := resp.Header.Get("Mcp-Session-Id"); sid != "" {
		t.mu.Lock()
		t.session = sid
		t.mu.Unlock()
	}
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		resp.Body.Close()
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return resp, nil
}

func matchResponse(data []byte, id int64) (json.RawMessage, error, bool) {
	data = bytes.TrimSpace(data)
	var msgs []rpcIn
	if len(data) > 0 && data[0] == '[' {
		json.Unmarshal(data, &msgs)
	} else {
		var m rpcIn
		if json.Unmarshal(data, &m) == nil {
			msgs = append(msgs, m)
		}
	}
	for _, m := range msgs {
		if got, ok := parseID(m.ID); ok && got == id && m.Method == "" {
			if m.Error != nil {
				return nil, m.Error, true
			}
			return m.Result, nil, true
		}
	}
	return nil, nil, false
}

func (t *httpTransport) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	id := t.nextID.Add(1)
	resp, err := t.do(ctx, "POST", rpcOut{JSONRPC: "2.0", ID: id, Method: method, Params: params})
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		r := bufio.NewReader(resp.Body)
		var data bytes.Buffer
		for {
			line, rerr := r.ReadString('\n')
			line = strings.TrimRight(line, "\r\n")
			if d, ok := strings.CutPrefix(line, "data:"); ok {
				data.WriteString(strings.TrimPrefix(d, " "))
				data.WriteByte('\n')
			} else if line == "" || rerr != nil {
				if res, err, ok := matchResponse(data.Bytes(), id); ok {
					return res, err
				}
				data.Reset()
			}
			if rerr != nil {
				return nil, errors.New("event stream ended without a response")
			}
		}
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if res, err, ok := matchResponse(b, id); ok {
		return res, err
	}
	return nil, fmt.Errorf("unexpected response: %.200s", b)
}

func (t *httpTransport) Notify(method string, params any) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	resp, err := t.do(ctx, "POST", rpcOut{JSONRPC: "2.0", Method: method, Params: params})
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

func (t *httpTransport) Close() {
	t.mu.Lock()
	s := t.session
	t.mu.Unlock()
	if s == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if resp, err := t.do(ctx, "DELETE", nil); err == nil {
		resp.Body.Close()
	}
}

// ---- servers and manager ----

type mcpTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

type MCPServer struct {
	Name  string
	Cfg   MCPServerConfig
	Info  string
	Tools []mcpTool
	Err   error
	t     mcpTransport
}

// newTransportFor picks the SSE transport for an explicit transport:"sse" or a
// .../sse endpoint, otherwise Streamable HTTP.
func newTransportFor(sc MCPServerConfig) mcpTransport {
	if sc.Transport == "sse" || strings.HasSuffix(strings.TrimRight(os.ExpandEnv(sc.URL), "/"), "/sse") {
		return newSSE(sc)
	}
	return newHTTP(sc)
}

func connectMCP(ctx context.Context, name string, sc MCPServerConfig) *MCPServer {
	s := &MCPServer{Name: name, Cfg: sc}
	switch {
	case sc.URL != "":
		s.t = newTransportFor(sc)
	case sc.Command != "":
		t, err := newStdio(name, sc)
		if err != nil {
			s.Err = err
			return s
		}
		s.t = t
	default:
		s.Err = errors.New(`needs "command" or "url"`)
		return s
	}
	fail := func(err error) *MCPServer {
		s.Err = err
		s.t.Close()
		s.t = nil
		return s
	}
	res, err := s.t.Call(ctx, "initialize", map[string]any{
		"protocolVersion": mcpProtocol,
		"capabilities":    map[string]any{},
		"clientInfo":      map[string]any{"name": "lai", "version": version},
	})
	if err != nil {
		if sc.Command != "" {
			err = fmt.Errorf("%w (log: %s)", err, filepath.Join(logsDir(), "mcp-"+name+".log"))
		}
		return fail(err)
	}
	var init struct {
		ProtocolVersion string `json:"protocolVersion"`
		ServerInfo      struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"serverInfo"`
	}
	json.Unmarshal(res, &init)
	s.Info = strings.TrimSpace(init.ServerInfo.Name + " " + init.ServerInfo.Version)
	if p, ok := s.t.(interface{ setProto(string) }); ok {
		p.setProto(init.ProtocolVersion)
	}
	if err := s.t.Notify("notifications/initialized", nil); err != nil {
		return fail(err)
	}
	cursor := ""
	for {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		res, err := s.t.Call(ctx, "tools/list", params)
		if err != nil {
			return fail(err)
		}
		var page struct {
			Tools      []mcpTool `json:"tools"`
			NextCursor string    `json:"nextCursor"`
		}
		if err := json.Unmarshal(res, &page); err != nil {
			return fail(err)
		}
		s.Tools = append(s.Tools, page.Tools...)
		if page.NextCursor == "" || page.NextCursor == cursor {
			break
		}
		cursor = page.NextCursor
	}
	return s
}

func (s *MCPServer) CallTool(ctx context.Context, tool string, args map[string]any) (string, error) {
	if s.t == nil {
		return "", errors.New("server not connected")
	}
	if args == nil {
		args = map[string]any{}
	}
	timeout := time.Duration(s.Cfg.Timeout) * time.Second
	if timeout <= 0 {
		timeout = 5 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	res, err := s.t.Call(ctx, "tools/call", map[string]any{"name": tool, "arguments": args})
	if err != nil {
		return "", err
	}
	var r struct {
		Content []struct {
			Type     string `json:"type"`
			Text     string `json:"text"`
			MimeType string `json:"mimeType"`
			URI      string `json:"uri"`
			Resource *struct {
				URI  string `json:"uri"`
				Text string `json:"text"`
			} `json:"resource"`
		} `json:"content"`
		StructuredContent json.RawMessage `json:"structuredContent"`
		IsError           bool            `json:"isError"`
	}
	if err := json.Unmarshal(res, &r); err != nil {
		return string(res), nil
	}
	var parts []string
	for _, c := range r.Content {
		switch {
		case c.Type == "text":
			parts = append(parts, c.Text)
		case c.Resource != nil:
			parts = append(parts, fmt.Sprintf("[resource %s]\n%s", c.Resource.URI, c.Resource.Text))
		case c.Type == "resource_link":
			parts = append(parts, "[resource link] "+c.URI)
		default:
			parts = append(parts, fmt.Sprintf("[%s content, %s, not shown]", c.Type, c.MimeType))
		}
	}
	if len(parts) == 0 && len(r.StructuredContent) > 0 {
		parts = append(parts, string(r.StructuredContent))
	}
	out := strings.Join(parts, "\n")
	if r.IsError {
		return "", errors.New(out)
	}
	return out, nil
}

type MCPManager struct {
	Servers []*MCPServer
}

func startMCP(cfgs map[string]MCPServerConfig) *MCPManager {
	var names []string
	for n, c := range cfgs {
		if !c.Disabled {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	m := &MCPManager{Servers: make([]*MCPServer, len(names))}
	var wg sync.WaitGroup
	for i, n := range names {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			m.Servers[i] = connectMCP(ctx, n, cfgs[n])
		}()
	}
	wg.Wait()
	return m
}

func (m *MCPManager) Close() {
	var wg sync.WaitGroup
	for _, s := range m.Servers {
		if s.t != nil {
			wg.Add(1)
			go func() { defer wg.Done(); s.t.Close() }()
		}
	}
	wg.Wait()
}

var badToolChars = regexp.MustCompile(`[^a-zA-Z0-9_-]`)

func mcpToolName(server, tool string) string {
	n := badToolChars.ReplaceAllString(server+"__"+tool, "_")
	if len(n) > 64 {
		n = n[:64]
	}
	return n
}

func (m *MCPManager) Register(reg *Registry) {
	reg.RemoveMCP()
	for _, s := range m.Servers {
		if s.t == nil {
			continue
		}
		for _, tool := range s.Tools {
			schema := string(tool.InputSchema)
			if strings.TrimSpace(schema) == "" || schema == "null" {
				schema = `{"type":"object","properties":{}}`
			}
			reg.Add(&Tool{
				Name:   mcpToolName(s.Name, tool.Name),
				Desc:   strings.TrimSpace("[" + s.Name + "] " + tool.Description),
				Schema: schema,
				Ask:    !s.Cfg.Trust,
				MCP:    true,
				Show: func(a map[string]any) string {
					b, _ := json.Marshal(a)
					return truncateMiddle(string(b), 400)
				},
				Run: func(ctx context.Context, a map[string]any) (string, error) {
					return s.CallTool(ctx, tool.Name, a)
				},
			})
		}
	}
}

func (m *MCPManager) Status() string {
	if len(m.Servers) == 0 {
		return "no MCP servers configured (lai mcp add ...)"
	}
	var b strings.Builder
	for _, s := range m.Servers {
		if s.Err != nil {
			fmt.Fprintf(&b, "%s %s: %v\n", c(red, "✗"), s.Name, s.Err)
			continue
		}
		trust := ""
		if s.Cfg.Trust {
			trust = " (trusted)"
		}
		fmt.Fprintf(&b, "%s %s%s — %s, %d tools\n", c(green, "✓"), s.Name, trust, s.Info, len(s.Tools))
		for _, t := range s.Tools {
			d := strings.SplitN(t.Description, "\n", 2)[0]
			fmt.Fprintf(&b, "    %s %s\n", mcpToolName(s.Name, t.Name), c(dim, truncateMiddle(d, 90)))
		}
	}
	return strings.TrimRight(b.String(), "\n")
}
