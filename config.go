package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// MCPServerConfig uses the same shape as Claude Desktop / Cursor "mcpServers"
// entries, so existing configs can be pasted in as-is.
type MCPServerConfig struct {
	Command  string            `json:"command,omitempty"`
	Args     []string          `json:"args,omitempty"`
	Env      map[string]string `json:"env,omitempty"`
	URL      string            `json:"url,omitempty"`
	Headers  map[string]string `json:"headers,omitempty"`
	Disabled bool              `json:"disabled,omitempty"`
	Trust    bool              `json:"trust,omitempty"`   // run this server's tools without asking
	Timeout  int               `json:"timeout,omitempty"` // seconds per tool call (default 300)
}

type Config struct {
	Model          string                     `json:"model"`   // GGUF path, or model name on a remote server
	URL            string                     `json:"url"`     // OpenAI-compatible server to use instead of lai-engine
	APIKey         string                     `json:"api_key"` // for url
	Engine         string                     `json:"engine"`  // path to lai-engine (default: next to lai, then PATH)
	CtxSize        int                        `json:"ctx_size"`
	GPULayers      int                        `json:"gpu_layers"`  // -1 = llama.cpp default
	Threads        int                        `json:"threads"`     // 0 = one per physical core
	KVCache        string                     `json:"kv_cache"`    // q8_0 (default), q4_0 for less RAM, f16 for full precision
	FlashAttn      string                     `json:"flash_attn"`  // auto (default), on or off
	UBatch         int                        `json:"ubatch"`      // prompt chunk size; the compute buffer grows with it
	CPUMoE         bool                       `json:"moe_on_cpu"`  // keep MoE expert weights in RAM, the rest on the GPU
	KVInRAM        bool                       `json:"kv_in_ram"`   // KV cache in system RAM: much longer context on a small GPU, slower
	KVLimitMB      int                        `json:"kv_limit_mb"` // cap on KV-cache size; context is shortened to fit (0 = no cap)
	Temperature    *float64                   `json:"temperature"` // sampling: unset = llama.cpp default
	TopP           *float64                   `json:"top_p"`
	TopK           *int                       `json:"top_k"`
	MinP           *float64                   `json:"min_p"`
	RepeatPenalty  *float64                   `json:"repeat_penalty"`
	Thinking       *bool                      `json:"thinking"` // false skips the reasoning step on models that have one
	MaxTokens      int                        `json:"max_tokens"`
	SystemPrompt   string                     `json:"system_prompt"` // appended to the built-in prompt
	AutoApprove    bool                       `json:"auto_approve"`
	Shell          string                     `json:"shell"`
	CommandTimeout int                        `json:"command_timeout"` // seconds
	MaxOutput      int                        `json:"max_output"`      // chars of tool output sent back to the model
	MaxSteps       int                        `json:"max_steps"`       // tool rounds per prompt
	MCPServers     map[string]MCPServerConfig `json:"mcpServers"`

	path string
}

// sampling returns the request fields for the sampling settings that are set.
func (c *Config) sampling() map[string]any {
	m := map[string]any{}
	if c.Temperature != nil {
		m["temperature"] = *c.Temperature
	}
	if c.TopP != nil {
		m["top_p"] = *c.TopP
	}
	if c.TopK != nil {
		m["top_k"] = *c.TopK
	}
	if c.MinP != nil {
		m["min_p"] = *c.MinP
	}
	if c.RepeatPenalty != nil {
		m["repeat_penalty"] = *c.RepeatPenalty
	}
	if c.MaxTokens > 0 {
		m["max_tokens"] = c.MaxTokens
	}
	return m
}

func configDir() string {
	if d := os.Getenv("XDG_CONFIG_HOME"); d != "" {
		return filepath.Join(d, "lai")
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config", "lai")
}

func dataDir() string {
	if d := os.Getenv("LAI_HOME"); d != "" {
		return d
	}
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return filepath.Join(d, "lai")
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".local", "share", "lai")
}

func logsDir() string {
	d := filepath.Join(dataDir(), "logs")
	os.MkdirAll(d, 0o755)
	return d
}

func defaultConfigPath() string {
	if p := os.Getenv("LAI_CONFIG"); p != "" {
		return p
	}
	// a config.json beside the binary wins, so a folder on a USB drive
	// (lai, lai-engine, config.json) works on its own after every boot
	if d := exeDir(); d != "" {
		if p := filepath.Join(d, "config.json"); fileExists(p) {
			return p
		}
	}
	return filepath.Join(configDir(), "config.json")
}

// exeDir is the real directory of the running binary, following symlinks.
func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	return filepath.Dir(exe)
}

func defaultShell() string {
	for _, s := range []string{"/bin/bash", "/usr/bin/bash", "/bin/sh"} {
		if _, err := os.Stat(s); err == nil {
			return s
		}
	}
	return "sh"
}

func defaultConfig() *Config {
	return &Config{
		CtxSize:        8192,
		AutoApprove:    true, // built for a sandboxed machine; set false to be asked first
		GPULayers:      -1,
		KVCache:        "q8_0",
		FlashAttn:      "auto",
		UBatch:         256,
		CPUMoE:         true,
		Shell:          defaultShell(),
		CommandTimeout: 120,
		MaxOutput:      16000,
		MaxSteps:       40,
		MCPServers:     map[string]MCPServerConfig{},
	}
}

func loadConfig(path string) (*Config, error) {
	if path == "" {
		path = defaultConfigPath()
	}
	cfg := defaultConfig()
	cfg.path = path
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return cfg, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if cfg.MCPServers == nil {
		cfg.MCPServers = map[string]MCPServerConfig{}
	}
	return cfg, nil
}

// editRawConfig edits the config file as a generic map so keys lai doesn't
// know about survive the rewrite.
func editRawConfig(path string, fn func(m map[string]any) error) error {
	m := map[string]any{}
	b, err := os.ReadFile(path)
	if err == nil {
		if err := json.Unmarshal(b, &m); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := fn(m); err != nil {
		return err
	}
	out, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, append(out, '\n'), 0o600)
}

func writeDefaultConfig(path string) error {
	return editRawConfig(path, func(m map[string]any) error {
		d := defaultConfig()
		m["model"] = ""
		m["url"] = ""
		m["ctx_size"] = d.CtxSize
		m["gpu_layers"] = d.GPULayers
		m["threads"] = 0
		m["kv_cache"] = d.KVCache
		m["ubatch"] = d.UBatch
		m["moe_on_cpu"] = d.CPUMoE
		m["auto_approve"] = d.AutoApprove
		m["command_timeout"] = d.CommandTimeout
		m["max_output"] = d.MaxOutput
		m["max_steps"] = d.MaxSteps
		m["system_prompt"] = ""
		m["mcpServers"] = map[string]any{}
		return nil
	})
}
