package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// lai serve: the same agent behind a small web page, so a phone can send
// messages to a running session and read the replies. It listens on
// 127.0.0.1 only and every request needs the access key; put a tunnel
// (ngrok) in front of it to reach it from outside.

//go:embed web.html
var webPage []byte

const loginPage = `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>lai</title><style>body{font:16px system-ui;background:#0f1115;color:#e6e6e6;display:grid;place-items:center;height:100vh;margin:0}form{display:grid;gap:10px;width:min(90vw,360px)}input,button{font:inherit;padding:12px;border-radius:8px;border:1px solid #2a2f3a}input{background:#181b22;color:inherit}button{background:#4ade80;border:0;font-weight:600}</style><form method=post action=/login><b>lai</b><input name=key type=password placeholder="access key" autocomplete=current-password autofocus><button>Open</button></form>`

const maxTranscript = 4 << 20 // bytes of output kept for reconnecting clients

var errBusy = errors.New("a reply is already running")

// session is the one shared conversation. Everything the agent prints is kept
// as a transcript, so a phone that reloads or loses signal can catch up from
// the byte offset it had reached.
type session struct {
	mu     sync.Mutex
	buf    []byte
	base   int // absolute offset of buf[0]
	busy   bool
	cancel context.CancelFunc
	ch     chan struct{} // closed and replaced whenever something changes
}

func newSession() *session { return &session{ch: make(chan struct{})} }

// wake notifies waiting streams; call with mu held.
func (s *session) wake() {
	close(s.ch)
	s.ch = make(chan struct{})
}

func (s *session) Write(p []byte) (int, error) {
	s.mu.Lock()
	s.buf = append(s.buf, p...)
	if len(s.buf) > maxTranscript {
		drop := len(s.buf) - maxTranscript/2
		for drop < len(s.buf) && s.buf[drop]&0xC0 == 0x80 { // keep UTF-8 intact
			drop++
		}
		s.buf = append([]byte(nil), s.buf[drop:]...)
		s.base += drop
	}
	s.wake()
	s.mu.Unlock()
	return len(p), nil
}

// start runs one turn in the background.
func (s *session) start(a *Agent, msg string) error {
	s.mu.Lock()
	if s.busy {
		s.mu.Unlock()
		return errBusy
	}
	s.busy = true
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.mu.Unlock()

	fmt.Fprintf(s, "\n› %s\n\n", msg)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				fmt.Fprintf(s, "error: %v\n", r)
			}
			cancel()
			s.mu.Lock()
			s.busy = false
			s.cancel = nil
			s.wake()
			s.mu.Unlock()
		}()
		if err := a.TurnCtx(ctx, msg); err != nil {
			fmt.Fprintf(s, "error: %v\n", err)
		}
	}()
	return nil
}

func (s *session) stop() {
	s.mu.Lock()
	if s.cancel != nil {
		s.cancel()
	}
	s.mu.Unlock()
}

type server struct {
	agent     *Agent
	sess      *session
	key       string
	model     string
	failDelay time.Duration // pause after a wrong key
	fmu       sync.Mutex
	fails     []time.Time
}

func newServer(a *Agent, key, model string) *server {
	sess := newSession()
	a.out = sess
	return &server{agent: a, sess: sess, key: key, model: model, failDelay: 400 * time.Millisecond}
}

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.root)
	mux.HandleFunc("/login", s.login)
	mux.HandleFunc("/api/state", s.guard(s.apiState))
	mux.HandleFunc("/api/stream", s.guard(s.apiStream))
	mux.HandleFunc("/api/chat", s.guard(s.apiChat))
	mux.HandleFunc("/api/stop", s.guard(s.apiStop))
	mux.HandleFunc("/api/clear", s.guard(s.apiClear))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Cache-Control", "no-store")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
		mux.ServeHTTP(w, r)
	})
}

// ---- authentication ----

func (s *server) keyOK(k string) bool {
	return subtle.ConstantTimeCompare([]byte(k), []byte(s.key)) == 1
}

// check reports whether a credential was sent and whether it was right.
func (s *server) check(r *http.Request) (presented, ok bool) {
	if c, err := r.Cookie("lai_key"); err == nil && c.Value != "" {
		presented = true
		if s.keyOK(c.Value) {
			return true, true
		}
	}
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		presented = true
		if s.keyOK(strings.TrimPrefix(h, "Bearer ")) {
			return true, true
		}
	}
	return presented, false
}

// locked is true after too many wrong keys in the last minute.
func (s *server) locked() bool {
	s.fmu.Lock()
	defer s.fmu.Unlock()
	s.prune()
	return len(s.fails) >= 10
}

func (s *server) prune() {
	cut := time.Now().Add(-time.Minute)
	i := 0
	for i < len(s.fails) && s.fails[i].Before(cut) {
		i++
	}
	s.fails = s.fails[i:]
}

func (s *server) noteFail() {
	s.fmu.Lock()
	s.prune()
	s.fails = append(s.fails, time.Now())
	s.fmu.Unlock()
	time.Sleep(s.failDelay)
}

func (s *server) guard(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.locked() {
			http.Error(w, "too many wrong keys; wait a minute", http.StatusTooManyRequests)
			return
		}
		presented, ok := s.check(r)
		if !ok {
			if presented {
				s.noteFail()
			}
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (s *server) setCookie(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name: "lai_key", Value: s.key, Path: "/", MaxAge: 30 * 24 * 3600,
		HttpOnly: true, SameSite: http.SameSiteLaxMode,
		Secure: r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https",
	})
}

func (s *server) showLogin(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusUnauthorized)
	w.Write([]byte(loginPage))
}

// root serves the chat page. /?key=... logs in with the link from the
// terminal and then redirects, so the key doesn't stay in the address bar.
func (s *server) root(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if s.locked() {
		http.Error(w, "too many wrong keys; wait a minute", http.StatusTooManyRequests)
		return
	}
	if k := r.URL.Query().Get("key"); k != "" {
		if s.keyOK(k) {
			s.setCookie(w, r)
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		s.noteFail()
		s.showLogin(w)
		return
	}
	presented, ok := s.check(r)
	if ok {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(webPage)
		return
	}
	if presented {
		s.noteFail()
	}
	s.showLogin(w)
}

func (s *server) login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if s.locked() {
		http.Error(w, "too many wrong keys; wait a minute", http.StatusTooManyRequests)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if s.keyOK(strings.TrimSpace(r.PostForm.Get("key"))) {
		s.setCookie(w, r)
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	s.noteFail()
	s.showLogin(w)
}

// ---- API ----

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func (s *server) apiState(w http.ResponseWriter, r *http.Request) {
	s.sess.mu.Lock()
	st := map[string]any{"busy": s.sess.busy, "base": s.sess.base, "size": s.sess.base + len(s.sess.buf), "model": s.model}
	s.sess.mu.Unlock()
	writeJSON(w, 200, st)
}

// apiStream sends the transcript from byte offset ?from= and keeps going
// while a reply is running. It ends when the reply is done, or after 25s so
// idle proxies don't cut it; the page then asks /api/state and reconnects.
func (s *server) apiStream(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	from, _ := strconv.Atoi(r.URL.Query().Get("from"))
	sess := s.sess
	sess.mu.Lock()
	if from < sess.base {
		from = sess.base
	}
	if end := sess.base + len(sess.buf); from > end {
		from = end
	}
	sess.mu.Unlock()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("X-Lai-From", strconv.Itoa(from))
	w.WriteHeader(http.StatusOK)

	deadline := time.After(25 * time.Second)
	for {
		sess.mu.Lock()
		if from < sess.base { // trimmed under us: let the client resync
			sess.mu.Unlock()
			return
		}
		end := sess.base + len(sess.buf)
		var chunk []byte
		if from < end {
			chunk = append([]byte(nil), sess.buf[from-sess.base:]...)
		}
		busy, ch := sess.busy, sess.ch
		sess.mu.Unlock()
		if len(chunk) > 0 {
			if _, err := w.Write(chunk); err != nil {
				return
			}
			fl.Flush()
			from = end
			continue
		}
		if !busy {
			return
		}
		select {
		case <-ch:
		case <-r.Context().Done():
			return
		case <-deadline:
			return
		}
	}
}

func (s *server) apiChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	// a JSON content type can't be sent by a cross-site form, which closes CSRF
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		http.Error(w, "send JSON", http.StatusUnsupportedMediaType)
		return
	}
	var body struct {
		Message string `json:"message"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil {
		http.Error(w, "bad JSON", http.StatusBadRequest)
		return
	}
	msg := strings.TrimSpace(body.Message)
	if msg == "" {
		http.Error(w, "empty message", http.StatusBadRequest)
		return
	}
	if err := s.sess.start(s.agent, msg); err != nil {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

func (s *server) apiStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	s.sess.stop()
	w.WriteHeader(http.StatusOK)
}

func (s *server) apiClear(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	s.sess.mu.Lock()
	defer s.sess.mu.Unlock()
	if s.sess.busy {
		http.Error(w, errBusy.Error(), http.StatusConflict)
		return
	}
	s.agent.reset()
	s.sess.buf, s.sess.base = nil, 0
	s.sess.wake()
	w.WriteHeader(http.StatusOK)
}

// ---- setup ----

// loadKey returns the access key. LAI_SERVE_KEY, if set, is used verbatim
// (so you can pin a fixed key for a client). Otherwise it reads serve.key in
// dir, creating a random one the first time.
func loadKey(dir string) (string, error) {
	if k := strings.TrimSpace(os.Getenv("LAI_SERVE_KEY")); k != "" {
		return k, nil
	}
	p := filepath.Join(dir, "serve.key")
	if b, err := os.ReadFile(p); err == nil {
		if k := strings.TrimSpace(string(b)); len(k) >= 32 {
			return k, nil
		}
	}
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	k := hex.EncodeToString(raw)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return k, os.WriteFile(p, []byte(k+"\n"), 0o600)
}

// startNgrok runs `ngrok http` for the static domain and stops it on exit.
func startNgrok(domain string, port int) error {
	bin, err := exec.LookPath("ngrok")
	if err != nil {
		bin = filepath.Join(exeDir(), "ngrok") // install.sh puts it next to lai
		if !fileExists(bin) {
			return errors.New("ngrok isn't installed (rerun install.sh with NGROK_AUTHTOKEN set)")
		}
	}
	logPath := filepath.Join(logsDir(), "ngrok.log")
	logf, err := os.Create(logPath)
	if err != nil {
		return err
	}
	cmd := exec.Command(bin, "http", strconv.Itoa(port), "--url", "https://"+domain, "--log", "stdout")
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = childAttr()
	if err := cmd.Start(); err != nil {
		logf.Close()
		return err
	}
	done := make(chan struct{})
	go func() {
		cmd.Wait()
		logf.Close()
		close(done)
	}()
	onCleanup(func() {
		syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
	})
	select {
	case <-done:
		return fmt.Errorf("ngrok exited:\n%s\n(log: %s)", tailFile(logPath, 8), logPath)
	case <-time.After(4 * time.Second):
	}
	if b, _ := os.ReadFile(logPath); strings.Contains(string(b), "ERR_NGROK") {
		return fmt.Errorf("ngrok failed:\n%s\n(log: %s)", tailFile(logPath, 8), logPath)
	}
	return nil
}

func cmdServe(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	cfgPath := fs.String("c", "", "config file")
	model := fs.String("m", "", "path to a .gguf file")
	port := fs.Int("port", 8090, "local port (always bound to 127.0.0.1)")
	domain := fs.String("ngrok", "", "start an ngrok tunnel on this static domain (default: ngrok_domain in the config)")
	public := fs.String("public", "", "public URL to print the phone link for")
	noMCP := fs.Bool("no-mcp", false, "don't start MCP servers")
	fs.Parse(args)

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		return err
	}
	if *model != "" {
		cfg.Model = *model
	}
	useColor = false // plain text for the web page

	llm, name, err := backend(cfg)
	if err != nil {
		return err
	}
	tools := newRegistry()
	var mgr *MCPManager
	for _, t := range builtinTools(cfg) {
		tools.Add(t)
	}
	if !*noMCP && len(cfg.MCPServers) > 0 {
		mgr = startMCP(cfg.MCPServers)
		onCleanup(mgr.Close)
		mgr.Register(tools)
	}
	a := newAgent(cfg, llm, tools, mgr, true, nil)

	key, err := loadKey(filepath.Dir(cfg.path))
	if err != nil {
		return err
	}
	srv := newServer(a, key, name)
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		return err
	}
	hs := &http.Server{Handler: srv.handler(), ReadHeaderTimeout: 10 * time.Second}
	onCleanup(func() { hs.Close() })

	pub := strings.TrimRight(*public, "/")
	if *domain == "" {
		*domain = cfg.NgrokDomain
	}
	if *domain != "" {
		d := strings.TrimRight(strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(*domain), "https://"), "http://"), "/")
		if err := startNgrok(d, *port); err != nil {
			return err
		}
		pub = "https://" + d
	}

	fmt.Printf("lai serve · %s · listening on 127.0.0.1:%d (local only)\n", name, *port)
	if !cfg.AutoApprove {
		fmt.Println("note: auto_approve is off, so tool calls from the web page will be refused")
	}
	if pub != "" {
		fmt.Printf("\nphone link, keep it secret (it logs in):\n  %s/?key=%s\n", pub, key)
	} else {
		fmt.Printf("\nopen http://127.0.0.1:%d/?key=%s\nreach it from outside with:  ngrok http --url=YOUR-DOMAIN %d\n", *port, key, *port)
	}
	if err := hs.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
