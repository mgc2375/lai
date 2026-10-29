package main

import (
	"context"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type fakeBackend struct {
	reply string
	block chan struct{} // when set, Chat waits for it (or for cancellation)
}

func (f *fakeBackend) Chat(ctx context.Context, msgs []Message, tools []ToolDef, emit func(int, string)) (Message, Stats, error) {
	if f.block != nil {
		select {
		case <-f.block:
		case <-ctx.Done():
		}
	}
	if ctx.Err() == nil {
		emit(outText, f.reply)
	}
	return Message{Role: "assistant", Content: f.reply}, Stats{}, nil
}

const testKey = "0123456789abcdef0123456789abcdef0123456789abcdef"

func testServer(t *testing.T, be Backend) (*httptest.Server, *server) {
	t.Helper()
	a := newAgent(defaultConfig(), be, newRegistry(), nil, false, nil)
	srv := newServer(a, testKey, "test")
	srv.failDelay = 0
	ts := httptest.NewServer(srv.handler())
	t.Cleanup(ts.Close)
	return ts, srv
}

func do(t *testing.T, method, url, ctype, body string, hdr map[string]string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := http.DefaultClient.Do(req.WithContext(ctx))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

var bearer = map[string]string{"Authorization": "Bearer " + testKey}

func TestServeAuth(t *testing.T) {
	ts, _ := testServer(t, &fakeBackend{reply: "x"})
	if code, _ := do(t, "GET", ts.URL+"/api/state", "", "", nil); code != 401 {
		t.Fatalf("no key: %d", code)
	}
	if code, body := do(t, "GET", ts.URL+"/", "", "", nil); code != 401 || !strings.Contains(body, "access key") {
		t.Fatalf("login page: %d", code)
	}
	if code, _ := do(t, "GET", ts.URL+"/?key=wrong", "", "", nil); code != 401 {
		t.Fatalf("wrong key: %d", code)
	}
	if code, _ := do(t, "GET", ts.URL+"/api/state", "", "", map[string]string{"Authorization": "Bearer nope"}); code != 401 {
		t.Fatalf("wrong bearer: %d", code)
	}
	if code, _ := do(t, "GET", ts.URL+"/api/state", "", "", bearer); code != 200 {
		t.Fatalf("bearer: %d", code)
	}

	// the link from the terminal logs in with a cookie, then the page loads
	jar, _ := cookiejar.New(nil)
	c := &http.Client{Jar: jar}
	resp, err := c.Get(ts.URL + "/?key=" + testKey)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(b), "<title>lai</title>") {
		t.Fatalf("cookie login: %d", resp.StatusCode)
	}
	if strings.Contains(resp.Request.URL.String(), "key=") {
		t.Fatal("the key stayed in the address bar")
	}
	if resp, err = c.Get(ts.URL + "/api/state"); err != nil || resp.StatusCode != 200 {
		t.Fatalf("cookie on api: %v %v", err, resp)
	}
	resp.Body.Close()
}

func TestServeLockout(t *testing.T) {
	ts, _ := testServer(t, &fakeBackend{reply: "x"})
	bad := map[string]string{"Authorization": "Bearer wrong"}
	for i := 0; i < 10; i++ {
		do(t, "GET", ts.URL+"/api/state", "", "", bad)
	}
	if code, _ := do(t, "GET", ts.URL+"/api/state", "", "", bearer); code != 429 {
		t.Fatalf("after 10 wrong keys even the right one waits: %d", code)
	}
}

func TestServeChat(t *testing.T) {
	ts, _ := testServer(t, &fakeBackend{reply: "hi there"})
	if code, _ := do(t, "POST", ts.URL+"/api/chat", "text/plain", `{"message":"x"}`, bearer); code != 415 {
		t.Fatalf("non-JSON: %d", code)
	}
	if code, _ := do(t, "POST", ts.URL+"/api/chat", "application/json", `{"message":"  "}`, bearer); code != 400 {
		t.Fatalf("empty: %d", code)
	}
	if code, _ := do(t, "POST", ts.URL+"/api/chat", "application/json", `{"message":"hello"}`, bearer); code != 202 {
		t.Fatalf("chat: %d", code)
	}
	code, body := do(t, "GET", ts.URL+"/api/stream?from=0", "", "", bearer)
	if code != 200 || !strings.Contains(body, "› hello") || !strings.Contains(body, "hi there") {
		t.Fatalf("stream: %d %q", code, body)
	}
	// resuming from an offset only returns what's new
	_, rest := do(t, "GET", ts.URL+"/api/stream?from="+strconv.Itoa(len(body)), "", "", bearer)
	if rest != "" {
		t.Fatalf("resume returned %q", rest)
	}
	if code, _ := do(t, "POST", ts.URL+"/api/clear", "", "", bearer); code != 200 {
		t.Fatalf("clear: %d", code)
	}
	if _, body = do(t, "GET", ts.URL+"/api/stream?from=0", "", "", bearer); body != "" {
		t.Fatalf("transcript survived clear: %q", body)
	}
}

func TestServeBusyAndStop(t *testing.T) {
	be := &fakeBackend{reply: "late", block: make(chan struct{})}
	ts, _ := testServer(t, be)
	if code, _ := do(t, "POST", ts.URL+"/api/chat", "application/json", `{"message":"one"}`, bearer); code != 202 {
		t.Fatalf("first: %d", code)
	}
	if code, _ := do(t, "POST", ts.URL+"/api/chat", "application/json", `{"message":"two"}`, bearer); code != 409 {
		t.Fatalf("second while busy: %d", code)
	}
	if code, _ := do(t, "POST", ts.URL+"/api/clear", "", "", bearer); code != 409 {
		t.Fatalf("clear while busy: %d", code)
	}
	if code, _ := do(t, "POST", ts.URL+"/api/stop", "", "", bearer); code != 200 {
		t.Fatalf("stop: %d", code)
	}
	// the stream ends once the stopped reply finishes
	_, body := do(t, "GET", ts.URL+"/api/stream?from=0", "", "", bearer)
	if !strings.Contains(body, "[interrupted]") {
		t.Fatalf("stopped reply: %q", body)
	}
}

func TestLoadKey(t *testing.T) {
	dir := t.TempDir()
	k1, err := loadKey(dir)
	if err != nil || len(k1) < 32 {
		t.Fatalf("key %q %v", k1, err)
	}
	k2, _ := loadKey(dir)
	if k1 != k2 {
		t.Fatal("key changed between runs")
	}
	if fi, _ := os.Stat(filepath.Join(dir, "serve.key")); fi.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode %v", fi.Mode())
	}
}
