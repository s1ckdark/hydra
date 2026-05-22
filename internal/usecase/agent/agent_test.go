package agent

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

func TestAgent_Chat_ReturnsPlanFromLLM(t *testing.T) {
	llm := &stubLLM{responses: []string{
		`{"type":"plan","message":"ok","plan":{"intent":"x","actions":[{"type":"list_devices","args":{}}]}}`,
	}}
	devices := &stubDeviceLister{devices: []*domain.Device{{ID: "a", Name: "alpha"}}}
	a := NewAgentUseCase(llm, NewActionRegistry(devices, nil, nil, nil, nil, nil), NewValidator(devices, nil))
	resp, err := a.Chat(context.Background(), ChatRequest{Message: "ping"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if resp.Type != ChatTypePlan || resp.Plan == nil {
		t.Fatalf("got %+v", resp)
	}
}

func TestAgent_Execute_RunsActionsSequentially(t *testing.T) {
	devices := &stubDeviceLister{devices: []*domain.Device{{ID: "a", Name: "alpha", Status: domain.DeviceStatusOnline}}}
	a := NewAgentUseCase(nil, NewActionRegistry(devices, nil, nil, nil, nil, nil), NewValidator(devices, nil))
	plan := Plan{Actions: []Action{
		{Type: "list_devices", Args: json.RawMessage(`{}`)},
	}}
	out, err := a.Execute(context.Background(), plan)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(out.Results) != 1 || out.Results[0].Status != "ok" {
		t.Fatalf("got %+v", out)
	}
}

func TestAgent_Execute_RejectsInvalidPlan(t *testing.T) {
	devices := &stubDeviceLister{devices: []*domain.Device{{ID: "a", Name: "alpha"}}}
	a := NewAgentUseCase(nil, NewActionRegistry(devices, nil, nil, nil, nil, nil), NewValidator(devices, nil))
	plan := Plan{Actions: []Action{
		{Type: "execute_command", Args: json.RawMessage(`{"device_id":"ghost","command":"ls"}`)},
	}}
	out, err := a.Execute(context.Background(), plan)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(out.Results) != 1 || out.Results[0].Status != "error" {
		t.Fatalf("expected validation error in result, got %+v", out)
	}
}
