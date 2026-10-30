package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// a minimal MCP HTTP+SSE server: GET /sse streams events, POST /msg takes requests
func mockSSEServer(t *testing.T) *httptest.Server {
	t.Helper()
	var mu sync.Mutex
	var flush http.Flusher
	var w2 http.ResponseWriter
	mux := http.NewServeMux()
	mux.HandleFunc("/sse", func(w http.ResponseWriter, r *http.Request) {
		fl, ok := w.(http.Flusher)
		if !ok {
			t.Fatal("no flusher")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		mu.Lock()
		flush, w2 = fl, w
		mu.Unlock()
		fmt.Fprintf(w, "event: endpoint\ndata: /msg?sid=abc\n\n")
		fl.Flush()
		<-r.Context().Done()
	})
	mux.HandleFunc("/msg", func(w http.ResponseWriter, r *http.Request) {
		var req rpcIn
		json.NewDecoder(r.Body).Decode(&req)
		w.WriteHeader(202)
		// reply over the SSE stream
		var result any
		switch req.Method {
		case "initialize":
			result = map[string]any{"protocolVersion": mcpProtocol, "serverInfo": map[string]any{"name": "mock-sse", "version": "1"}}
		case "tools/list":
			result = map[string]any{"tools": []map[string]any{{"name": "ping", "description": "p", "inputSchema": map[string]any{"type": "object"}}}}
		case "tools/call":
			result = map[string]any{"content": []map[string]any{{"type": "text", "text": "pong"}}}
		default:
			return
		}
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(req.ID), "result": result})
		mu.Lock()
		defer mu.Unlock()
		fmt.Fprintf(w2, "event: message\ndata: %s\n\n", b)
		flush.Flush()
	})
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return ts
}

func TestSSETransport(t *testing.T) {
	ts := mockSSEServer(t)
	srv := connectMCP(context.Background(), "mock", MCPServerConfig{URL: ts.URL + "/sse", Trust: true})
	if srv.Err != nil {
		t.Fatalf("connect: %v", srv.Err)
	}
	if srv.Info != "mock-sse 1" {
		t.Fatalf("serverInfo: %q", srv.Info)
	}
	if len(srv.Tools) != 1 || srv.Tools[0].Name != "ping" {
		t.Fatalf("tools: %+v", srv.Tools)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := srv.CallTool(ctx, "ping", nil)
	if err != nil || out != "pong" {
		t.Fatalf("call: %q %v", out, err)
	}
	srv.t.Close()
}

func TestSSESelection(t *testing.T) {
	// a /sse url picks the SSE transport; a plain one picks streamable HTTP
	if _, ok := newTransportFor(MCPServerConfig{URL: "http://x/sse"}).(*sseTransport); !ok {
		t.Fatal("/sse should select SSE")
	}
	if _, ok := newTransportFor(MCPServerConfig{URL: "http://x/mcp"}).(*httpTransport); !ok {
		t.Fatal("/mcp should select streamable HTTP")
	}
	if _, ok := newTransportFor(MCPServerConfig{URL: "http://x/mcp", Transport: "sse"}).(*sseTransport); !ok {
		t.Fatal("transport:sse should force SSE")
	}
}
