package agent

import (
	"context"
	"errors"
	"testing"
)

type stubLLM struct {
	calls     int
	responses []string
}

func (s *stubLLM) Complete(ctx context.Context, system, prompt string) (string, error) {
	if s.calls >= len(s.responses) {
		return "", errors.New("no more stub responses")
	}
	out := s.responses[s.calls]
	s.calls++
	return out, nil
}

func TestParseChatResponse_ValidPlan(t *testing.T) {
	llm := &stubLLM{responses: []string{
		`{"type":"plan","message":"sure","plan":{"intent":"x","actions":[{"type":"list_devices","args":{}}]}}`,
	}}
	resp, err := AskOnce(context.Background(), llm, "sys", "ping")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if resp.Type != ChatTypePlan {
		t.Fatalf("type = %q", resp.Type)
	}
}

func TestParseChatResponse_RetriesOnGarbage(t *testing.T) {
	llm := &stubLLM{responses: []string{
		"this is not json at all",
		`{"type":"ask","message":"clarify?"}`,
	}}
	resp, err := AskOnce(context.Background(), llm, "sys", "ping")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if resp.Type != ChatTypeAsk {
		t.Fatalf("type = %q", resp.Type)
	}
	if llm.calls != 2 {
		t.Fatalf("expected 2 LLM calls, got %d", llm.calls)
	}
}

func TestParseChatResponse_SecondFailureFallsBackToAsk(t *testing.T) {
	llm := &stubLLM{responses: []string{"garbage one", "garbage two"}}
	resp, err := AskOnce(context.Background(), llm, "sys", "ping")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if resp.Type != ChatTypeAsk {
		t.Fatalf("type = %q", resp.Type)
	}
	if resp.Message == "" {
		t.Fatal("expected fallback message")
	}
}
