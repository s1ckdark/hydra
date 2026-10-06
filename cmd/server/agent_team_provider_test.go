package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

func TestTeamProviderSendsExactModelAndAuthentication(t *testing.T) {
	cases := []struct{ provider, base, path, tokenField, authHeader, authValue, response string }{
		{"openai_compatible", "/v1", "/v1/chat/completions", "max_tokens", "Authorization", "Bearer private-key", `{"choices":[{"message":{"content":"ok"}}]}`},
		{"openai_compatible", "/v1/chat/completions", "/v1/chat/completions", "max_tokens", "Authorization", "Bearer private-key", `{"choices":[{"message":{"content":"ok"}}]}`},
		{"openai_compatible", "", "/v1/chat/completions", "max_tokens", "Authorization", "Bearer private-key", `{"choices":[{"message":{"content":"ok"}}]}`},
		{"openai", "/v1", "/v1/chat/completions", "max_completion_tokens", "Authorization", "Bearer private-key", `{"choices":[{"message":{"content":"ok"}}]}`},
		{"openai", "", "/v1/chat/completions", "max_completion_tokens", "Authorization", "Bearer private-key", `{"choices":[{"message":{"content":"ok"}}]}`},
		{"claude", "/v1", "/v1/messages", "max_tokens", "x-api-key", "private-key", `{"content":[{"type":"text","text":"ok"}]}`},
		{"claude", "", "/v1/messages", "max_tokens", "x-api-key", "private-key", `{"content":[{"type":"text","text":"ok"}]}`},
		{"zai", "/api/coding/paas/v4", "/api/coding/paas/v4/chat/completions", "max_tokens", "Authorization", "Bearer private-key", `{"choices":[{"message":{"content":"ok"}}]}`},
		{"ollama", "", "/api/chat", "options", "Authorization", "Bearer private-key", `{"message":{"content":"ok"}}`},
		{"lmstudio", "/v1", "/v1/chat/completions", "max_tokens", "Authorization", "Bearer private-key", `{"choices":[{"message":{"content":"ok"}}]}`},
	}
	for _, tc := range cases {
		t.Run(tc.provider+tc.base, func(t *testing.T) {
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.URL.Path != tc.path || r.Method != http.MethodPost {
					t.Errorf("request route=%s %s", r.Method, r.URL.Path)
				}
				if got := r.Header.Get(tc.authHeader); got != tc.authValue {
					t.Errorf("authentication header missing")
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				if body["model"] != "exact/model-version:123" {
					t.Errorf("model substituted: %v", body["model"])
				}
				if _, ok := body[tc.tokenField]; !ok {
					t.Errorf("missing token parameter: %s", tc.tokenField)
				}
				if tc.provider == "openai" && body["max_tokens"] != nil {
					t.Error("deprecated OpenAI max_tokens sent")
				}
				if tc.provider == "claude" && (r.Header.Get("anthropic-version") == "" || body["system"] != "system") {
					t.Error("Claude system/version missing")
				}
				if tc.provider == "ollama" && body["stream"] != false {
					t.Error("Ollama stream must be disabled")
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(tc.response))
			}))
			defer server.Close()
			llm, err := buildTeamLLM(domain.AIConnection{ID: "c", Name: "Connection", Provider: tc.provider, Endpoint: server.URL + tc.base, APIKey: "private-key", Models: []string{"exact/model-version:123"}}, "exact/model-version:123")
			if err != nil {
				t.Fatal(err)
			}
			out, err := llm.Complete(context.Background(), "system", "task")
			if err != nil || out != "ok" || calls != 1 {
				t.Fatalf("completion %q %v calls=%d", out, err, calls)
			}
		})
	}
}

func TestTeamProviderNeverRedirectsOrEchoesUpstreamErrors(t *testing.T) {
	targetCalls := 0
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { targetCalls++; t.Error("credentials followed redirect") }))
	defer target.Close()
	for _, provider := range []string{"openai_compatible", "claude"} {
		for _, status := range []int{http.StatusTemporaryRedirect, http.StatusUnauthorized} {
			source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", target.URL)
				w.WriteHeader(status)
				_, _ = w.Write([]byte("private-key"))
			}))
			llm, err := buildTeamLLM(domain.AIConnection{ID: "c", Name: "Connection", Provider: provider, Endpoint: source.URL, APIKey: "private-key", Models: []string{"model"}}, "model")
			if err != nil {
				t.Fatal(err)
			}
			_, err = llm.Complete(context.Background(), "system", "task")
			if err == nil || strings.Contains(err.Error(), "private-key") || strings.Contains(err.Error(), source.URL) {
				t.Fatalf("unsafe error: %v", err)
			}
			source.Close()
		}
	}
	if targetCalls != 0 {
		t.Fatal("redirect followed")
	}
}

func TestTeamProviderRejectsUnregisteredModelAndCancelledContext(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("cancelled request reached endpoint") }))
	defer server.Close()
	c := domain.AIConnection{ID: "c", Name: "Connection", Provider: "openai_compatible", Endpoint: server.URL, Models: []string{"registered"}}
	if _, err := buildTeamLLM(c, "default"); err == nil {
		t.Fatal("accepted unregistered model")
	}
	llm, err := buildTeamLLM(c, "registered")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := llm.Complete(ctx, "system", "task"); err == nil {
		t.Fatal("ignored cancellation")
	}
}
