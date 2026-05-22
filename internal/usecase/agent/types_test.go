package agent

import (
	"encoding/json"
	"testing"
)

func TestChatResponse_PlanRoundtrip(t *testing.T) {
	raw := `{"type":"plan","message":"ok","plan":{"intent":"x","actions":[{"type":"list_devices","args":{}}]}}`
	var resp ChatResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.Type != ChatTypePlan {
		t.Fatalf("type = %q, want plan", resp.Type)
	}
	if resp.Plan == nil || resp.Plan.Intent != "x" || len(resp.Plan.Actions) != 1 {
		t.Fatalf("plan = %+v", resp.Plan)
	}
	if resp.Plan.Actions[0].Type != "list_devices" {
		t.Fatalf("action.type = %q", resp.Plan.Actions[0].Type)
	}
}

func TestChatResponse_AskHasNoPlan(t *testing.T) {
	raw := `{"type":"ask","message":"which node?"}`
	var resp ChatResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.Type != ChatTypeAsk || resp.Plan != nil {
		t.Fatalf("got %+v", resp)
	}
}
