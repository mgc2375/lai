package main

import (
	"encoding/json"
	"fmt"
	"os"
)

// importMCP reads an MCP config written for another client and merges its
// servers into lai's config. It accepts both shapes:
//   - OpenCode:        {"mcp": {name: {type, command:[...], environment, url, headers, enabled, timeout}}}
//   - Claude Desktop:  {"mcpServers": {name: {command, args, env, url, headers, disabled}}}
//
// Existing servers of the same name are replaced. Returns how many were imported.
func importMCP(cfgPath, srcPath string) (int, error) {
	raw, err := os.ReadFile(srcPath)
	if err != nil {
		return 0, err
	}
	var src struct {
		MCP        map[string]json.RawMessage `json:"mcp"`
		MCPServers map[string]json.RawMessage `json:"mcpServers"`
	}
	if err := json.Unmarshal(raw, &src); err != nil {
		return 0, fmt.Errorf("%s: %w", srcPath, err)
	}
	entries := src.MCP
	opencode := true
	if len(entries) == 0 {
		entries, opencode = src.MCPServers, false
	}
	if len(entries) == 0 {
		return 0, fmt.Errorf("%s has no \"mcp\" or \"mcpServers\" section", srcPath)
	}

	converted := map[string]MCPServerConfig{}
	for name, rawEntry := range entries {
		var e struct {
			Type        string            `json:"type"`
			Command     json.RawMessage   `json:"command"` // OpenCode: array; Claude: string
			Args        []string          `json:"args"`
			Environment map[string]string `json:"environment"`
			Env         map[string]string `json:"env"`
			URL         string            `json:"url"`
			Headers     map[string]string `json:"headers"`
			Enabled     *bool             `json:"enabled"`
			Disabled    bool              `json:"disabled"`
			Timeout     int               `json:"timeout"`
		}
		if err := json.Unmarshal(rawEntry, &e); err != nil {
			return 0, fmt.Errorf("server %q: %w", name, err)
		}
		out := MCPServerConfig{URL: e.URL, Headers: e.Headers, Env: e.Env}
		if e.Environment != nil {
			out.Env = e.Environment
		}
		// command is a string in Claude's format, an array in OpenCode's
		if len(e.Command) > 0 {
			var arr []string
			if json.Unmarshal(e.Command, &arr) == nil {
				if len(arr) > 0 {
					out.Command, out.Args = arr[0], arr[1:]
				}
			} else {
				var str string
				if json.Unmarshal(e.Command, &str) == nil {
					out.Command = str
				}
			}
		}
		if len(e.Args) > 0 { // Claude keeps args separate
			out.Args = e.Args
		}
		if opencode {
			out.Disabled = e.Enabled != nil && !*e.Enabled
		} else {
			out.Disabled = e.Disabled
		}
		if e.Timeout > 0 { // OpenCode is ms, lai is seconds
			if opencode {
				out.Timeout = e.Timeout / 1000
			} else {
				out.Timeout = e.Timeout
			}
		}
		if out.Command == "" && out.URL == "" {
			continue // nothing runnable (e.g. an OAuth-only stub)
		}
		converted[name] = out
	}
	if len(converted) == 0 {
		return 0, fmt.Errorf("%s has no usable MCP servers", srcPath)
	}

	err = editRawConfig(cfgPath, func(m map[string]any) error {
		servers, _ := m["mcpServers"].(map[string]any)
		if servers == nil {
			servers = map[string]any{}
			m["mcpServers"] = servers
		}
		for name, sc := range converted {
			b, _ := json.Marshal(sc)
			var v any
			json.Unmarshal(b, &v)
			servers[name] = v
		}
		return nil
	})
	return len(converted), err
}
