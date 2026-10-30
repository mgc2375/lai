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
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// sseTransport speaks the older MCP "HTTP+SSE" transport (protocol 2024-11-05):
// a long-lived GET opens an event stream; the server's first "endpoint" event
// gives the path to POST requests to, and JSON-RPC responses come back as
// "message" events on the stream. Still used by Docker-packaged servers such
// as sudohakan/kali-mcp-server.
type sseTransport struct {
	base    string
	headers map[string]string
	client  *http.Client

	postURL chan string // receives the endpoint URL once, from the read loop
	nextID  atomic.Int64
	pmu     sync.Mutex
	pending map[int64]chan *rpcIn
	done    chan struct{}
	closeF  func()
}

func newSSE(sc MCPServerConfig) *sseTransport {
	return &sseTransport{
		base:    os.ExpandEnv(sc.URL),
		headers: sc.Headers,
		client:  &http.Client{},
		postURL: make(chan string, 1),
		pending: map[int64]chan *rpcIn{},
		done:    make(chan struct{}),
	}
}

// open starts the event-stream GET and blocks until the endpoint arrives.
// connectMCP calls Call right after construction, which triggers this.
func (t *sseTransport) open(ctx context.Context) error {
	streamCtx, cancel := context.WithCancel(context.Background())
	t.closeF = cancel
	req, err := http.NewRequestWithContext(streamCtx, "GET", t.base, nil)
	if err != nil {
		cancel()
		return err
	}
	req.Header.Set("Accept", "text/event-stream")
	for k, v := range t.headers {
		req.Header.Set(k, os.ExpandEnv(v))
	}
	resp, err := t.client.Do(req)
	if err != nil {
		cancel()
		return err
	}
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		resp.Body.Close()
		cancel()
		return fmt.Errorf("sse %s: http %d: %s", t.base, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	go func() {
		defer resp.Body.Close()
		t.readLoop(resp.Body)
		close(t.done)
	}()
	// wait for the endpoint event
	select {
	case ep := <-t.postURL:
		t.postURL <- ep // put it back so send() can read it
		return nil
	case <-t.done:
		return errors.New("sse stream closed before the endpoint event")
	case <-ctx.Done():
		cancel()
		return ctx.Err()
	case <-time.After(30 * time.Second):
		cancel()
		return errors.New("timed out waiting for the sse endpoint event")
	}
}

// readLoop parses the SSE stream: "event:" names the type, "data:" carries the
// payload, a blank line dispatches the event.
func (t *sseTransport) readLoop(r io.Reader) {
	br := bufio.NewReaderSize(r, 64*1024)
	var event string
	var data bytes.Buffer
	gotEndpoint := false
	for {
		line, err := br.ReadString('\n')
		trimmed := strings.TrimRight(line, "\r\n")
		switch {
		case strings.HasPrefix(trimmed, "event:"):
			event = strings.TrimSpace(trimmed[len("event:"):])
		case strings.HasPrefix(trimmed, "data:"):
			data.WriteString(strings.TrimPrefix(strings.TrimPrefix(trimmed[len("data:"):], " "), ""))
			data.WriteByte('\n')
		case trimmed == "": // dispatch
			payload := strings.TrimRight(data.String(), "\n")
			data.Reset()
			if payload == "" && event == "" {
				break
			}
			if event == "endpoint" || (!gotEndpoint && event == "") {
				if u := t.resolveEndpoint(payload); u != "" {
					gotEndpoint = true
					select {
					case t.postURL <- u:
					default:
					}
				}
			} else { // "message" (or default): a JSON-RPC response
				t.dispatch([]byte(payload))
			}
			event = ""
		}
		if err != nil {
			return
		}
	}
}

// resolveEndpoint turns the endpoint payload (an absolute or relative URL)
// into an absolute POST URL against the stream's origin.
func (t *sseTransport) resolveEndpoint(payload string) string {
	payload = strings.TrimSpace(payload)
	if payload == "" {
		return ""
	}
	base, err := url.Parse(t.base)
	if err != nil {
		return payload
	}
	ref, err := url.Parse(payload)
	if err != nil {
		return ""
	}
	return base.ResolveReference(ref).String()
}

func (t *sseTransport) dispatch(payload []byte) {
	var m rpcIn
	if json.Unmarshal(payload, &m) != nil {
		return
	}
	if m.Method != "" { // server-initiated request/notification: ignore
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

func (t *sseTransport) endpoint() (string, error) {
	select {
	case ep := <-t.postURL:
		t.postURL <- ep
		return ep, nil
	case <-t.done:
		return "", errors.New("sse stream closed")
	}
}

func (t *sseTransport) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	// the first call opens the stream and learns the POST endpoint
	if t.closeF == nil {
		if err := t.open(ctx); err != nil {
			return nil, err
		}
	}
	ep, err := t.endpoint()
	if err != nil {
		return nil, err
	}
	id := t.nextID.Add(1)
	ch := make(chan *rpcIn, 1)
	t.pmu.Lock()
	t.pending[id] = ch
	t.pmu.Unlock()
	if err := t.post(ctx, ep, rpcOut{JSONRPC: "2.0", ID: id, Method: method, Params: params}); err != nil {
		t.pmu.Lock()
		delete(t.pending, id)
		t.pmu.Unlock()
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
		return nil, ctx.Err()
	case <-t.done:
		return nil, errors.New("sse stream closed")
	}
}

func (t *sseTransport) post(ctx context.Context, ep string, payload any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", ep, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range t.headers {
		req.Header.Set(k, os.ExpandEnv(v))
	}
	resp, err := t.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode >= 300 {
		return fmt.Errorf("sse post: http %d", resp.StatusCode)
	}
	return nil
}

func (t *sseTransport) Notify(method string, params any) error {
	ep, err := t.endpoint()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return t.post(ctx, ep, rpcOut{JSONRPC: "2.0", Method: method, Params: params})
}

func (t *sseTransport) Close() {
	if t.closeF != nil {
		t.closeF()
	}
	select {
	case <-t.done:
	case <-time.After(time.Second):
	}
}
