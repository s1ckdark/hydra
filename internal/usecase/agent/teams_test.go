package agent

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/repository"
)

type teamOrchs map[string]*domain.Orch

func (o teamOrchs) GetOrch(_ context.Context, id string) (*domain.Orch, error) {
	if result := o[id]; result != nil {
		return result, nil
	}
	return nil, domain.ErrOrchNotFound
}

type teamLLMFunc func(context.Context, string, string) (string, error)

func (f teamLLMFunc) Complete(ctx context.Context, system, prompt string) (string, error) {
	return f(ctx, system, prompt)
}

func teamFixture(t *testing.T, head LLMClient, factory TeamLLMFactory) (*AgentUseCase, *TeamService, *repository.FileAgentTeams, TeamUpdate) {
	t.Helper()
	store := repository.NewFileAgentTeams(filepath.Join(t.TempDir(), "agent-teams.json"))
	orch := teamOrchs{"orch": {ID: "orch", CoordinatorID: "a", WorkerIDs: []string{"orch:nested"}}, "nested": {ID: "nested", CoordinatorID: "nested-head", WorkerIDs: []string{"b", "orch:orch"}}, "other": {ID: "other", CoordinatorID: "outside"}}
	service := NewTeamService(store, orch, factory)
	keyA, keyB := "SECRET-A", "SECRET-B"
	update := TeamUpdate{Connections: []ConnectionUpdate{
		{AIConnection: domain.AIConnection{ID: "open", Name: "OpenAI", Provider: "openai", Models: []string{"model-a", "model-b"}}, APIKey: &keyA},
		{AIConnection: domain.AIConnection{ID: "claude", Name: "Claude", Provider: "claude", Models: []string{"model-c"}}, APIKey: &keyB},
	}, Agents: []domain.AIAgent{{ID: "worker", Name: "Worker", Role: "Review concurrency bugs"}}}
	if _, err := service.Put(context.Background(), "orch", update); err != nil {
		t.Fatal(err)
	}
	devices := &stubDeviceLister{devices: []*domain.Device{{ID: "a"}, {ID: "b"}, {ID: "outside"}, {ID: "nested-head"}}}
	uc := NewAgentUseCase(head, NewActionRegistry(devices, nil, nil, nil, nil, nil), NewValidator(devices, nil))
	uc.SetTeamService(service)
	return uc, service, store, update
}

func TestTeamExplicitOverrideBypassesHeadAndPreservesExactModel(t *testing.T) {
	head := &stubLLM{}
	var chosen []string
	uc, service, _, update := teamFixture(t, head, func(c domain.AIConnection, model string) (LLMClient, error) {
		chosen = append(chosen, c.Provider+"/"+model)
		if c.APIKey != "SECRET-B" {
			t.Fatal("worker did not get its own key")
		}
		return teamLLMFunc(func(ctx context.Context, system, prompt string) (string, error) {
			if !strings.Contains(system, "Review concurrency bugs") {
				t.Error("agent role absent")
			}
			if strings.Contains(system+prompt, "SECRET-") {
				t.Error("secret in worker prompt")
			}
			return `{"type":"ask","message":"ready"}`, nil
		}), nil
	})
	update.Agents[0].ModelOverride = &domain.AgentModelRef{ConnectionID: "claude", Model: "model-c"}
	if _, err := service.Put(context.Background(), "orch", update); err != nil {
		t.Fatal(err)
	}
	var req ChatRequest
	if err := json.Unmarshal([]byte(`{"orchestration_id":"orch","agent_id":"worker","message":"review"}`), &req); err != nil {
		t.Fatal(err)
	}
	resp, err := uc.Chat(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if head.calls != 0 || len(chosen) != 1 || chosen[0] != "claude/model-c" || resp.ModelSelection.Source != "override" || resp.ModelSelection.TeamRevision == "" {
		t.Fatalf("routing: %+v, %v", resp.ModelSelection, chosen)
	}
}

func TestTeamHeadChoosesFromSafeCatalogAndUsesWorker(t *testing.T) {
	var headCalls, workerCalls int
	head := teamLLMFunc(func(ctx context.Context, system, prompt string) (string, error) {
		headCalls++
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > 21*time.Second {
			t.Error("head has no bounded timeout")
		}
		if strings.Contains(prompt, "SECRET-") || strings.Contains(prompt, "api_key") || strings.Contains(prompt, "endpoint") {
			t.Error("head received private connection data")
		}
		if !strings.Contains(prompt, "Review concurrency bugs") || !strings.Contains(prompt, "find race") || !strings.Contains(prompt, "model-b") {
			t.Error("missing task, role or catalog")
		}
		return `{"connection_id":"open","model":"model-b","reason":"best for task"}`, nil
	})
	uc, _, _, _ := teamFixture(t, head, func(c domain.AIConnection, model string) (LLMClient, error) {
		if c.Provider != "openai" || model != "model-b" || c.APIKey != "SECRET-A" {
			t.Fatal("wrong provider/model/key")
		}
		return teamLLMFunc(func(context.Context, string, string) (string, error) {
			workerCalls++
			return `{"type":"ask","message":"ready"}`, nil
		}), nil
	})
	resp, err := uc.Chat(context.Background(), ChatRequest{OrchestrationID: "orch", AgentID: "worker", Message: "find race"})
	if err != nil || headCalls != 1 || workerCalls != 1 || resp.ModelSelection.Source != "head" || resp.ModelSelection.Reason != "best for task" {
		t.Fatalf("response: %+v, %v", resp, err)
	}
}

func TestTeamConfiguredHeadAndInvalidHeadResponses(t *testing.T) {
	for _, raw := range []string{`{"connection_id":"open","model":"unregistered"}`, `{"connection_id":"unknown","model":"model-a"}`, `not-json-SECRET-A`} {
		t.Run(raw, func(t *testing.T) {
			global := &stubLLM{}
			calls := 0
			uc, service, _, update := teamFixture(t, global, func(c domain.AIConnection, model string) (LLMClient, error) {
				calls++
				if c.ID != "claude" || model != "model-c" {
					t.Fatal("wrong team head")
				}
				return &stubLLM{responses: []string{raw}}, nil
			})
			update.HeadModel = &domain.AgentModelRef{ConnectionID: "claude", Model: "model-c"}
			if _, err := service.Put(context.Background(), "orch", update); err != nil {
				t.Fatal(err)
			}
			_, err := uc.Chat(context.Background(), ChatRequest{OrchestrationID: "orch", AgentID: "worker", Message: "hello"})
			if err == nil || strings.Contains(err.Error(), "SECRET-A") || calls != 1 || global.calls != 0 {
				t.Fatalf("unsafe invalid-head handling: %v", err)
			}
		})
	}
}

type countingRunner struct {
	calls int
	after func()
}

func (r *countingRunner) ExecuteOnDevice(context.Context, string, string, int) (*domain.TaskResult, error) {
	r.calls++
	if r.after != nil {
		r.after()
	}
	return &domain.TaskResult{Output: map[string]interface{}{"stdout": "ok"}}, nil
}

func TestTeamExecuteRechecksScopeBetweenActions(t *testing.T) {
	for _, change := range []string{"delete_orch", "remove_member", "update_team"} {
		t.Run(change, func(t *testing.T) {
			uc, service, _, update := teamFixture(t, &stubLLM{responses: []string{`{"connection_id":"open","model":"model-a"}`}}, func(domain.AIConnection, string) (LLMClient, error) {
				return &stubLLM{responses: []string{`{"type":"ask","message":"ok"}`}}, nil
			})
			runner := &countingRunner{after: func() {
				switch change {
				case "delete_orch":
					delete(service.orchs.(teamOrchs), "orch")
				case "remove_member":
					service.orchs.(teamOrchs)["orch"].CoordinatorID = "another-device"
				case "update_team":
					if _, err := service.Put(context.Background(), "orch", update); err != nil {
						t.Fatal(err)
					}
				}
			}}
			uc.actions.cmd = runner
			resp, err := uc.Chat(context.Background(), ChatRequest{OrchestrationID: "orch", AgentID: "worker"})
			if err != nil {
				t.Fatal(err)
			}
			action := Action{Type: "execute_command", Args: json.RawMessage(`{"device_id":"a","command":"echo ok"}`)}
			result, err := uc.ExecuteRequest(context.Background(), ExecuteRequest{ModelSelection: resp.ModelSelection, Plan: Plan{Actions: []Action{action, action}}})
			if err != nil || runner.calls != 1 || len(result.Results) != 2 || result.Results[0].Status != "ok" || result.Results[1].Status != "error" || result.Summary != "" {
				t.Fatalf("scope change was ignored: %+v %v", result, err)
			}
		})
	}
}

func TestTeamExecuteReusesSelectionForSummary(t *testing.T) {
	head := &stubLLM{responses: []string{`{"connection_id":"open","model":"model-b","reason":"chosen"}`}}
	models := []string{}
	uc, _, _, _ := teamFixture(t, head, func(c domain.AIConnection, model string) (LLMClient, error) {
		models = append(models, model)
		return teamLLMFunc(func(_ context.Context, system, prompt string) (string, error) {
			if strings.HasPrefix(system, "You explain the results") {
				if !strings.Contains(prompt, "execute_command [ok]") {
					t.Error("summary did not receive execution results")
				}
				return "The command completed successfully.", nil
			}
			return `{"type":"plan","message":"run","plan":{"intent":"check","actions":[{"type":"execute_command","args":{"device_id":"b","command":"echo ok"}}]}}`, nil
		}), nil
	})
	runner := &countingRunner{}
	uc.actions.cmd = runner
	resp, err := uc.Chat(context.Background(), ChatRequest{OrchestrationID: "orch", AgentID: "worker", Message: "check"})
	if err != nil {
		t.Fatal(err)
	}
	if runner.calls != 0 {
		t.Fatal("chat executed actions")
	}
	result, err := uc.ExecuteRequest(context.Background(), ExecuteRequest{Plan: *resp.Plan, ModelSelection: resp.ModelSelection})
	if err != nil || runner.calls != 1 || head.calls != 1 || len(models) != 2 || models[0] != "model-b" || models[1] != "model-b" || result.Summary != "The command completed successfully." {
		t.Fatalf("execution: %+v %v models=%v", result, err, models)
	}
}

func TestTeamExecuteRejectsStaleSelectionBeforeActions(t *testing.T) {
	for _, change := range []string{"endpoint", "provider", "key", "role", "model", "agent", "source", "revision", "connection", "other-orch"} {
		t.Run(change, func(t *testing.T) {
			uc, service, _, update := teamFixture(t, &stubLLM{responses: []string{`{"connection_id":"open","model":"model-a"}`}}, func(domain.AIConnection, string) (LLMClient, error) {
				return &stubLLM{responses: []string{`{"type":"ask","message":"ok"}`}}, nil
			})
			runner := &countingRunner{}
			uc.actions.cmd = runner
			resp, err := uc.Chat(context.Background(), ChatRequest{OrchestrationID: "orch", AgentID: "worker"})
			if err != nil {
				t.Fatal(err)
			}
			save := true
			switch change {
			case "endpoint":
				update.Connections[0].Endpoint = "https://new.example/v1"
			case "provider":
				update.Connections[0].Provider = "zai"
			case "key":
				key := "new-secret"
				update.Connections[0].APIKey = &key
			case "role":
				update.Agents[0].Role = "new role"
			case "model":
				update.Connections[0].Models = []string{"model-b"}
			case "agent":
				update.Agents = nil
			case "source":
				resp.ModelSelection.Source = "override"
				save = false
			case "revision":
				resp.ModelSelection.TeamRevision = ""
				save = false
			case "connection":
				resp.ModelSelection.ConnectionID = "missing"
				save = false
			case "other-orch":
				resp.ModelSelection.OrchestrationID = "other"
				save = false
			}
			if save {
				if _, err := service.Put(context.Background(), "orch", update); err != nil {
					t.Fatal(err)
				}
			}
			_, err = uc.ExecuteRequest(context.Background(), ExecuteRequest{ModelSelection: resp.ModelSelection, Plan: Plan{Actions: []Action{{Type: "execute_command", Args: json.RawMessage(`{"device_id":"a","command":"echo ok"}`)}}}})
			if err == nil || runner.calls != 0 {
				t.Fatalf("stale selection executed: %v", err)
			}
		})
	}
}

func TestTeamExecuteValidatesWholePlanAndScopeBeforeActions(t *testing.T) {
	for _, bad := range []Action{
		{Type: "execute_command", Args: json.RawMessage(`{"device_id":"outside","command":"echo bad"}`)},
		{Type: "execute_command", Args: json.RawMessage(`{"device_id":"a","command":"rm -rf /"}`)},
		{Type: "get_metrics", Args: json.RawMessage(`{"device_id":"outside"}`)},
		{Type: "delete_orch", Args: json.RawMessage(`{"orch_id":"other"}`)},
		{Type: "create_orch", Args: json.RawMessage(`{"name":"bad","head_id":"a"}`)},
		{Type: "invented", Args: json.RawMessage(`{}`)},
	} {
		t.Run(bad.Type+string(bad.Args), func(t *testing.T) {
			uc, _, _, _ := teamFixture(t, &stubLLM{responses: []string{`{"connection_id":"open","model":"model-a"}`}}, func(domain.AIConnection, string) (LLMClient, error) {
				return &stubLLM{responses: []string{`{"type":"ask","message":"ok"}`}}, nil
			})
			runner := &countingRunner{}
			uc.actions.cmd = runner
			resp, err := uc.Chat(context.Background(), ChatRequest{OrchestrationID: "orch", AgentID: "worker"})
			if err != nil {
				t.Fatal(err)
			}
			_, err = uc.ExecuteRequest(context.Background(), ExecuteRequest{ModelSelection: resp.ModelSelection, Plan: Plan{Actions: []Action{{Type: "execute_command", Args: json.RawMessage(`{"device_id":"a","command":"echo first"}`)}, bad}}})
			if err == nil || runner.calls != 0 {
				t.Fatalf("partially executed invalid plan: %v", err)
			}
		})
	}
}

func TestTeamMissingScopeNeverFallsBackToLegacy(t *testing.T) {
	head := &stubLLM{responses: []string{`{"type":"ask","message":"legacy"}`}}
	uc, _, _, _ := teamFixture(t, head, nil)
	for _, raw := range []string{`{"orchestration_id":"orch"}`, `{"agent_id":"worker"}`, `{"orchestration_id":"","agent_id":""}`, `{"orchestration_id":null}`} {
		var req ChatRequest
		if err := json.Unmarshal([]byte(raw), &req); err != nil {
			t.Fatal(err)
		}
		if _, err := uc.Chat(context.Background(), req); err == nil {
			t.Errorf("accepted incomplete scope: %s", raw)
		}
	}
	for _, raw := range []string{`{"model_selection":null}`, `{"model_selection":{}}`, `{"orchestration_id":"orch"}`, `{"agent_id":"worker"}`} {
		var req ExecuteRequest
		if err := json.Unmarshal([]byte(raw), &req); err != nil {
			t.Fatal(err)
		}
		if _, err := uc.ExecuteRequest(context.Background(), req); err == nil {
			t.Errorf("accepted incomplete selection: %s", raw)
		}
	}
	if head.calls != 0 {
		t.Fatal("incomplete scope called legacy LLM")
	}
	resp, err := uc.Chat(context.Background(), ChatRequest{Message: "legacy"})
	if err != nil || resp.Message != "legacy" || resp.ModelSelection != nil {
		t.Fatalf("legacy changed: %+v, %v", resp, err)
	}
}

func TestTeamProviderErrorNeverLeaksSecrets(t *testing.T) {
	uc, _, _, _ := teamFixture(t, teamLLMFunc(func(context.Context, string, string) (string, error) {
		return "", errors.New("SECRET-A https://private.endpoint")
	}), nil)
	_, err := uc.Chat(context.Background(), ChatRequest{OrchestrationID: "orch", AgentID: "worker"})
	if err == nil || strings.Contains(err.Error(), "SECRET") || strings.Contains(err.Error(), "private.endpoint") {
		t.Fatalf("unsafe error: %v", err)
	}
}
