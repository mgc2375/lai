package main

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestInlineToolCalls(t *testing.T) {
	content, calls := parseInlineToolCalls(`ok <tool_call>{"name":"bash","arguments":{"command":"ls"}}</tool_call>`)
	if len(calls) != 1 || calls[0].Function.Name != "bash" || calls[0].Function.Arguments != `{"command":"ls"}` || content != "ok" {
		t.Fatalf("got %q %+v", content, calls)
	}
	_, calls = parseInlineToolCalls(`<tool_call>{"name":"x","arguments":"{\"a\":1}"}</tool_call>`)
	if len(calls) != 1 || calls[0].Function.Arguments != `{"a":1}` {
		t.Fatalf("string args: %+v", calls)
	}
}

func TestCapBuffer(t *testing.T) {
	b := &capBuffer{max: 10}
	b.Write([]byte("hello"))
	b.Write([]byte("0123456789world"))
	if s := b.String(); !strings.HasPrefix(s, "hello") || !strings.HasSuffix(s, "world") || !strings.Contains(s, "dropped") {
		t.Fatalf("got %q", s)
	}
}

func TestRunShell(t *testing.T) {
	out := runShell(context.Background(), defaultShell(), "echo hi; exit 3", "", 5*time.Second)
	if !strings.Contains(out, "hi") || !strings.Contains(out, "[exit code 3]") {
		t.Fatalf("got %q", out)
	}
	start := time.Now()
	out = runShell(context.Background(), defaultShell(), "sleep 30 & sleep 30", "", 300*time.Millisecond)
	if !strings.Contains(out, "timed out") || time.Since(start) > 5*time.Second {
		t.Fatalf("timeout not enforced: %q after %s", out, time.Since(start))
	}
}

func TestEditFile(t *testing.T) {
	p := t.TempDir() + "/f.txt"
	os.WriteFile(p, []byte("a b a"), 0o644)
	var edit *Tool
	for _, tl := range builtinTools(defaultConfig()) {
		if tl.Name == "edit_file" {
			edit = tl
		}
	}
	if _, err := edit.Run(context.Background(), map[string]any{"path": p, "old_string": "a", "new_string": "z"}); err == nil {
		t.Fatal("non-unique edit should fail")
	}
	if _, err := edit.Run(context.Background(), map[string]any{"path": p, "old_string": "a", "new_string": "z", "replace_all": true}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "z b z" {
		t.Fatalf("got %q", b)
	}
}

func TestEngineErrorText(t *testing.T) {
	if got := (&apiError{Body: "vk::Queue::submit: ErrorDeviceLost"}).Error(); got != "engine: vk::Queue::submit: ErrorDeviceLost" {
		t.Fatalf("got %q", got)
	}
	if !isContextError(&apiError{Body: "the request exceeds the available context size"}) {
		t.Fatal("engine context errors must still trigger compaction")
	}
}
