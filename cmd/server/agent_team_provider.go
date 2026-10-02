package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

// teamLLM keeps team credentials isolated, honors exact model IDs/endpoints,
// and never follows redirects with a connection's credentials.
type teamLLM struct {
	connection domain.AIConnection
	model      string
	endpoint   string
	client     *http.Client
}

func buildTeamLLM(c domain.AIConnection, model string) (agent.LLMClient, error) {
	if _, ok := (domain.AIAgentTeam{Connections: []domain.AIConnection{c}}).Resolve(domain.AgentModelRef{ConnectionID: c.ID, Model: model}); !ok {
		return nil, errors.New("model is not registered")
	}
	if err := (domain.AIAgentTeam{Connections: []domain.AIConnection{c}}).Validate(); err != nil {
		return nil, err
	}
	endpoint := strings.TrimRight(c.Endpoint, "/")
	suffix := "/chat/completions"
	switch c.Provider {
	case "claude":
		if endpoint == "" {
			endpoint = "https://api.anthropic.com/v1"
		}
		u, _ := url.Parse(endpoint)
		if u.Path == "" {
			endpoint += "/v1"
		}
		suffix = "/messages"
	case "openai":
		if endpoint == "" {
			endpoint = "https://api.openai.com/v1"
		}
		u, _ := url.Parse(endpoint)
		if u.Path == "" {
			endpoint += "/v1"
		}
	case "zai":
		if endpoint == "" {
			endpoint = zaiDefaultEndpoint
		}
	case "ollama":
		suffix = "/api/chat"
	case "lmstudio", "openai_compatible":
		// Host-only URLs use the standard /v1 base. Explicit API bases
		// (including vendor-specific paths) and completion URLs are kept.
		u, _ := url.Parse(endpoint)
		if u.Path == "" {
			endpoint += "/v1"
		}
	}
	if !strings.HasSuffix(endpoint, suffix) {
		endpoint += suffix
	}
	return &teamLLM{connection: c, model: model, endpoint: endpoint, client: &http.Client{
		Timeout:       120 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func (p *teamLLM) Complete(ctx context.Context, system, prompt string) (string, error) {
	messages := []map[string]string{}
	if system != "" && p.connection.Provider != "claude" {
		messages = append(messages, map[string]string{"role": "system", "content": system})
	}
	messages = append(messages, map[string]string{"role": "user", "content": prompt})
	body := map[string]any{"model": p.model, "messages": messages}
	switch p.connection.Provider {
	case "claude":
		body["system"], body["max_tokens"] = system, 4096
	case "openai":
		// Chat Completions counts both visible output and reasoning in this
		// limit. max_tokens is deprecated and rejected by o-series models.
		body["max_completion_tokens"] = 4096
	case "ollama":
		body["stream"] = false
		body["options"] = map[string]int{"num_predict": 4096}
	default:
		body["max_tokens"] = 4096
	}
	data, err := json.Marshal(body)
	if err != nil {
		return "", errors.New("could not encode model request")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.endpoint, bytes.NewReader(data))
	if err != nil {
		return "", errors.New("could not construct model request")
	}
	req.Header.Set("Content-Type", "application/json")
	if p.connection.Provider == "claude" {
		req.Header.Set("x-api-key", p.connection.APIKey)
		req.Header.Set("anthropic-version", "2023-06-01")
	} else if p.connection.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+p.connection.APIKey)
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return "", errors.New("model request failed or timed out")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("model endpoint returned HTTP %d", resp.StatusCode)
	}
	var result struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&result); err != nil {
		return "", errors.New("model endpoint returned an invalid response")
	}
	var output string
	switch p.connection.Provider {
	case "claude":
		for _, block := range result.Content {
			output += block.Text
		}
	case "ollama":
		output = result.Message.Content
	default:
		if len(result.Choices) > 0 {
			output = result.Choices[0].Message.Content
		}
	}
	if strings.TrimSpace(output) == "" {
		return "", errors.New("model endpoint returned no text")
	}
	return output, nil
}
