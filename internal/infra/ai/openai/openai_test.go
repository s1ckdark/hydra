package openai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCompleteUsesCompletionTokensOnlyForOpenAI(t *testing.T) {
	for _, cloud := range []bool{true, false} {
		t.Run(map[bool]string{true: "openai", false: "compatible"}[cloud], func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				if body["model"] != "o3-exact-version" {
					t.Error("model changed")
				}
				if cloud && (body["max_completion_tokens"] == nil || body["max_tokens"] != nil) {
					t.Error("OpenAI request uses wrong token parameter")
				}
				if !cloud && (body["max_tokens"] == nil || body["max_completion_tokens"] != nil) {
					t.Error("compatible token parameter changed")
				}
				_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"ok"}}]}`))
			}))
			defer server.Close()
			p := NewLocalProvider(server.URL, "o3-exact-version")
			if cloud {
				p = NewProvider("test-key", "o3-exact-version")
				p.endpoint = server.URL
			}
			if out, err := p.Complete(context.Background(), "system", "task"); err != nil || out != "ok" {
				t.Fatalf("%q %v", out, err)
			}
		})
	}
}
