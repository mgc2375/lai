package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"regexp"
	"strings"
)

type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
	Name       string     `json:"name,omitempty"`
}

type FunctionCall struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

type ToolCall struct {
	ID       string       `json:"id"`
	Type     string       `json:"type"`
	Function FunctionCall `json:"function"`
}

type FunctionDef struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	Parameters  json.RawMessage `json:"parameters"`
}

type ToolDef struct {
	Type     string      `json:"type"`
	Function FunctionDef `json:"function"`
}

// LLM is a minimal streaming client for any OpenAI-compatible
// /v1/chat/completions endpoint (llama-server, Ollama, vLLM, LM Studio...).
type LLM struct {
	BaseURL  string
	APIKey   string
	Model    string
	sampling map[string]any
	client   *http.Client
}

type Stats struct {
	Tokens    int
	TokPerSec float64
}

func newLLM(base, key, model string, cfg *Config) *LLM {
	base = strings.TrimRight(base, "/")
	if !strings.HasSuffix(base, "/v1") {
		base += "/v1"
	}
	return &LLM{BaseURL: base, APIKey: key, Model: model, sampling: cfg.sampling(), client: &http.Client{}}
}

type apiError struct {
	Status int
	Body   string
}

func (e *apiError) Error() string {
	if e.Status == 0 { // from lai-engine, not an HTTP server
		return "engine: " + strings.TrimSpace(e.Body)
	}
	return fmt.Sprintf("server returned %d: %s", e.Status, strings.TrimSpace(e.Body))
}

func isContextError(err error) bool {
	var ae *apiError
	if !errors.As(err, &ae) {
		return false
	}
	b := strings.ToLower(ae.Body)
	return strings.Contains(b, "context") &&
		(strings.Contains(b, "exceed") || strings.Contains(b, "too long") || strings.Contains(b, "length") || strings.Contains(b, "size"))
}

// firstModel asks the server which models it serves (used when no model is configured).
func (l *LLM) firstModel(ctx context.Context) (string, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", l.BaseURL+"/models", nil)
	if l.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+l.APIKey)
	}
	resp, err := l.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var r struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&r); err != nil || len(r.Data) == 0 {
		return "", errors.New("server lists no models; pass one with -m")
	}
	return r.Data[0].ID, nil
}

const (
	outText = iota
	outThink
)

type streamChunk struct {
	Choices []struct {
		Delta struct {
			Content          string `json:"content"`
			ReasoningContent string `json:"reasoning_content"`
			Reasoning        string `json:"reasoning"`
			ToolCalls        []struct {
				Index    int          `json:"index"`
				ID       string       `json:"id"`
				Function FunctionCall `json:"function"`
			} `json:"tool_calls"`
		} `json:"delta"`
	} `json:"choices"`
	Timings *struct {
		PredictedN         int     `json:"predicted_n"`
		PredictedPerSecond float64 `json:"predicted_per_second"`
	} `json:"timings"`
	Usage *struct {
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// Chat streams one completion. emit receives text and reasoning deltas as
// they arrive. On error the partial message so far is still returned.
func (l *LLM) Chat(ctx context.Context, msgs []Message, tools []ToolDef, emit func(kind int, s string)) (Message, Stats, error) {
	out := Message{Role: "assistant"}
	var st Stats
	payload := map[string]any{"model": l.Model, "messages": msgs, "stream": true}
	if len(tools) > 0 {
		payload["tools"] = tools
	}
	for k, v := range l.sampling {
		payload[k] = v
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return out, st, err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", l.BaseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return out, st, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	if l.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+l.APIKey)
	}
	resp, err := l.client.Do(req)
	if err != nil {
		return out, st, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return out, st, &apiError{Status: resp.StatusCode, Body: string(b)}
	}

	var content strings.Builder
	var calls []*ToolCall
	r := bufio.NewReaderSize(resp.Body, 64*1024)
	for {
		line, rerr := r.ReadString('\n')
		line = strings.TrimSpace(line)
		if data, ok := strings.CutPrefix(line, "data:"); ok {
			data = strings.TrimSpace(data)
			if data == "[DONE]" {
				break
			}
			var ch streamChunk
			if json.Unmarshal([]byte(data), &ch) == nil {
				if ch.Error != nil {
					out.Content = content.String()
					return out, st, errors.New(ch.Error.Message)
				}
				if ch.Timings != nil {
					st.Tokens, st.TokPerSec = ch.Timings.PredictedN, ch.Timings.PredictedPerSecond
				} else if ch.Usage != nil {
					st.Tokens = ch.Usage.CompletionTokens
				}
				for _, c := range ch.Choices {
					d := c.Delta
					if t := d.ReasoningContent + d.Reasoning; t != "" {
						emit(outThink, t)
					}
					if d.Content != "" {
						content.WriteString(d.Content)
						emit(outText, d.Content)
					}
					for _, tc := range d.ToolCalls {
						idx := tc.Index
						// Some servers send every complete call at index 0.
						if tc.ID != "" && idx < len(calls) && calls[idx].ID != "" && calls[idx].ID != tc.ID {
							idx = len(calls)
						}
						for len(calls) <= idx {
							calls = append(calls, &ToolCall{Type: "function"})
						}
						c := calls[idx]
						if tc.ID != "" {
							c.ID = tc.ID
						}
						c.Function.Name += tc.Function.Name
						c.Function.Arguments += tc.Function.Arguments
					}
				}
			}
		}
		if rerr != nil {
			if rerr == io.EOF {
				break
			}
			out.Content = content.String()
			return out, st, rerr
		}
	}

	out.Content = content.String()
	for _, c := range calls {
		if c.Function.Name != "" {
			out.ToolCalls = append(out.ToolCalls, *c)
		}
	}
	if len(out.ToolCalls) == 0 {
		out.Content, out.ToolCalls = parseInlineToolCalls(out.Content)
	}
	for i := range out.ToolCalls {
		if out.ToolCalls[i].ID == "" {
			out.ToolCalls[i].ID = fmt.Sprintf("call_%d_%06d", i, rand.Intn(1e6))
		}
	}
	return out, st, nil
}

var inlineCallRe = regexp.MustCompile(`(?s)<tool_call>\s*(\{.*?\})\s*</tool_call>`)

// parseInlineToolCalls handles models that write Hermes/Qwen-style
// <tool_call>{...}</tool_call> text instead of native tool calls.
func parseInlineToolCalls(content string) (string, []ToolCall) {
	var calls []ToolCall
	for _, m := range inlineCallRe.FindAllStringSubmatch(content, -1) {
		var v struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if json.Unmarshal([]byte(m[1]), &v) != nil || v.Name == "" {
			continue
		}
		args := string(v.Arguments)
		var s string
		if json.Unmarshal(v.Arguments, &s) == nil {
			args = s // arguments given as a JSON string
		}
		if args == "" {
			args = "{}"
		}
		calls = append(calls, ToolCall{Type: "function", Function: FunctionCall{Name: v.Name, Arguments: args}})
	}
	if len(calls) == 0 {
		return content, nil
	}
	return strings.TrimSpace(inlineCallRe.ReplaceAllString(content, "")), calls
}
