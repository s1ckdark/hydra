package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// LLMClient is the minimal completion interface the agent needs.
// Implementations adapt the existing ai.Registry providers.
type LLMClient interface {
	Complete(ctx context.Context, system, prompt string) (string, error)
}

// AskOnce runs one LLM call and parses the response as a ChatResponse.
// If the first response isn't valid JSON of the expected shape, the
// model gets one retry with the parser error appended. If the retry
// also fails, we wrap the raw text as a plain ask so the user sees
// *something* useful instead of an opaque error.
func AskOnce(ctx context.Context, llm LLMClient, system, user string) (ChatResponse, error) {
	out, err := llm.Complete(ctx, system, user)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("llm: %w", err)
	}
	resp, parseErr := parseChatResponse(out)
	if parseErr == nil {
		return resp, nil
	}

	retryPrompt := user + "\n\nYour previous response was: " + out +
		"\n\nThat did not parse: " + parseErr.Error() +
		"\n\nReply with ONLY a single JSON object matching the schema."
	out2, err := llm.Complete(ctx, system, retryPrompt)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("llm retry: %w", err)
	}
	resp, parseErr2 := parseChatResponse(out2)
	if parseErr2 == nil {
		return resp, nil
	}
	return ChatResponse{
		Type:    ChatTypeAsk,
		Message: "I couldn't structure that into a plan. Raw response: " + out2,
	}, nil
}

// parseChatResponse extracts and validates one ChatResponse from LLM text.
// Tolerates leading/trailing prose by locating the first '{' .. last '}'.
func parseChatResponse(raw string) (ChatResponse, error) {
	trimmed := strings.TrimSpace(raw)
	start := strings.Index(trimmed, "{")
	end := strings.LastIndex(trimmed, "}")
	if start < 0 || end <= start {
		return ChatResponse{}, fmt.Errorf("no JSON object in response")
	}
	candidate := trimmed[start : end+1]

	var resp ChatResponse
	if err := json.Unmarshal([]byte(candidate), &resp); err != nil {
		return ChatResponse{}, fmt.Errorf("unmarshal: %w", err)
	}
	switch resp.Type {
	case ChatTypeAsk:
		return resp, nil
	case ChatTypePlan:
		if resp.Plan == nil {
			return ChatResponse{}, fmt.Errorf("type=plan but plan field missing")
		}
		return resp, nil
	default:
		return ChatResponse{}, fmt.Errorf("unknown type %q", resp.Type)
	}
}
