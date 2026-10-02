package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

func progressNode(snapshot AgentRunSnapshot, id string) AgentRunNode {
	for _, node := range snapshot.Nodes {
		if node.ID == id {
			return node
		}
	}
	return AgentRunNode{}
}

func progressRecorded(runID string) (*RunTracker, *[]AgentRunSnapshot) {
	snapshots := []AgentRunSnapshot{}
	return NewRunTracker(runID, func(snapshot AgentRunSnapshot) error { snapshots = append(snapshots, snapshot); return nil }), &snapshots
}

func TestTeamProgressHeadOverrideAndAwaitingApproval(t *testing.T) {
	for _, override := range []bool{false, true} {
		t.Run(map[bool]string{false: "head", true: "override"}[override], func(t *testing.T) {
			tracker, snapshots := progressRecorded("test-run")
			ctx := WithRunTracker(context.Background(), tracker)
			tracker.StartPlanning()
			headCalls, workerCalls := 0, 0
			head := teamLLMFunc(func(context.Context, string, string) (string, error) {
				headCalls++
				if progressNode((*snapshots)[len(*snapshots)-1], "head").Status != "running" {
					t.Error("head was not running during selection")
				}
				return `{"connection_id":"open","model":"model-b","reason":"SECRET-REASON"}`, nil
			})
			uc, service, _, update := teamFixture(t, head, func(_ domain.AIConnection, model string) (LLMClient, error) {
				return teamLLMFunc(func(context.Context, string, string) (string, error) {
					workerCalls++
					last := (*snapshots)[len(*snapshots)-1]
					if node := progressNode(last, "agent"); node.Status != "running" || node.Title != "Worker" || node.Model != model {
						t.Errorf("worker lifecycle/identity: %+v", node)
					}
					if progressNode(last, "head").Status == "running" {
						t.Error("head still running after worker started")
					}
					return `{"type":"plan","message":"SECRET-RESPONSE","plan":{"intent":"SECRET-INTENT","actions":[{"type":"execute_command","args":{"device_id":"a","command":"echo SECRET-COMMAND"}}]}}`, nil
				}), nil
			})
			if override {
				update.Agents[0].ModelOverride = &domain.AgentModelRef{ConnectionID: "open", Model: "model-b"}
				if _, err := service.Put(context.Background(), "orch", update); err != nil {
					t.Fatal(err)
				}
			}
			runner := &countingRunner{}
			uc.actions.cmd = runner
			resp, err := uc.Chat(ctx, ChatRequest{OrchestrationID: "orch", AgentID: "worker", Message: "SECRET-TASK"})
			if err != nil {
				t.Fatal(err)
			}
			tracker.CompleteChat(resp)
			last := (*snapshots)[len(*snapshots)-1]
			if last.Phase != "awaiting_approval" || progressNode(last, "agent").Status != "completed" || progressNode(last, "approval").Status != "waiting" || progressNode(last, "action-0").Status != "queued" || progressNode(last, "summary").Status != "queued" || runner.calls != 0 || workerCalls != 1 {
				t.Fatalf("awaiting approval = %+v calls=%d", last, runner.calls)
			}
			wantHead, wantCalls := "completed", 1
			if override {
				wantHead, wantCalls = "skipped", 0
			}
			if progressNode(last, "head").Status != wantHead || headCalls != wantCalls {
				t.Fatalf("head: %+v calls=%d", progressNode(last, "head"), headCalls)
			}
			for _, edge := range []AgentRunEdge{{"root", "head", "delegation"}, {"root", "agent", "delegation"}, {"head", "agent", "sequence"}, {"agent", "approval", "delegation"}, {"approval", "action-0", "sequence"}, {"action-0", "summary", "sequence"}} {
				found := false
				for _, got := range last.Edges {
					if got == edge {
						found = true
					}
				}
				if !found {
					t.Errorf("missing edge: %+v", edge)
				}
			}
			data, _ := json.Marshal(snapshots)
			if strings.Contains(string(data), "SECRET-") {
				t.Fatal("progress disclosed prompt, reason, credential, args or output")
			}
		})
	}
}

type progressRunnerFunc func(context.Context, string, string, int) (*domain.TaskResult, error)

func (f progressRunnerFunc) ExecuteOnDevice(ctx context.Context, device, command string, timeout int) (*domain.TaskResult, error) {
	return f(ctx, device, command, timeout)
}

func progressPlan() Plan {
	return Plan{Intent: "SECRET-INTENT", Actions: []Action{{Type: "execute_command", Args: json.RawMessage(`{"device_id":"a","command":"echo SECRET-COMMAND"}`)}, {Type: "execute_command", Args: json.RawMessage(`{"device_id":"a","command":"echo second"}`)}}}
}

func progressSelection(t *testing.T, uc *AgentUseCase) *ModelSelection {
	t.Helper()
	resp, err := uc.Chat(context.Background(), ChatRequest{OrchestrationID: "orch", AgentID: "worker"})
	if err != nil {
		t.Fatal(err)
	}
	return resp.ModelSelection
}

func TestExecutionProgressTracksActionsAndSummaryFailures(t *testing.T) {
	for _, summaryFailure := range []bool{false, true} {
		t.Run(map[bool]string{false: "action-failure", true: "summary-failure"}[summaryFailure], func(t *testing.T) {
			uc, _, _, _ := teamFixture(t, &stubLLM{responses: []string{`{"connection_id":"open","model":"model-a"}`}}, func(domain.AIConnection, string) (LLMClient, error) {
				return teamLLMFunc(func(_ context.Context, system, _ string) (string, error) {
					if strings.HasPrefix(system, "You explain") {
						if summaryFailure {
							return "", errors.New("SECRET-UPSTREAM-ERROR")
						}
						return "SECRET-SUMMARY", nil
					}
					return `{"type":"ask","message":"ready"}`, nil
				}), nil
			})
			selection := progressSelection(t, uc)
			tracker, snapshots := progressRecorded("execute-run")
			ctx := WithRunTracker(context.Background(), tracker)
			plan := progressPlan()
			tracker.StartExecution(plan)
			calls := 0
			uc.actions.cmd = progressRunnerFunc(func(context.Context, string, string, int) (*domain.TaskResult, error) {
				if progressNode((*snapshots)[len(*snapshots)-1], "action-"+string(rune('0'+calls))).Status != "running" {
					t.Error("action was not marked running before dispatch")
				}
				calls++
				if calls == 1 && !summaryFailure {
					return nil, errors.New("SECRET-ACTION-ERROR")
				}
				return &domain.TaskResult{Output: map[string]interface{}{"stdout": "SECRET-OUTPUT"}}, nil
			})
			resp, err := uc.ExecuteRequest(ctx, ExecuteRequest{Plan: plan, ModelSelection: selection})
			if err != nil {
				t.Fatal(err)
			}
			tracker.CompleteExecution(resp)
			last := (*snapshots)[len(*snapshots)-1]
			if calls != 2 || last.Phase != "failed" || progressNode(last, "agent").Status != "failed" || progressNode(last, "action-1").Status != "completed" {
				t.Fatalf("failed execution lifecycle: %+v", last)
			}
			if summaryFailure {
				if progressNode(last, "summary").Status != "failed" || progressNode(last, "action-0").Status != "completed" {
					t.Fatal("summary failure changed completed actions")
				}
			} else if progressNode(last, "action-0").Status != "failed" || progressNode(last, "summary").Status != "completed" {
				t.Fatal("action error/summary states incorrect")
			}
			data, _ := json.Marshal(snapshots)
			if strings.Contains(string(data), "SECRET-") {
				t.Fatal("progress leaked execution data")
			}
		})
	}
}

func TestExecutionOwningAgentRunsThroughActionsAndSummary(t *testing.T) {
	uc, _, _, _ := teamFixture(t, &stubLLM{responses: []string{`{"connection_id":"open","model":"model-a"}`}}, func(domain.AIConnection, string) (LLMClient, error) {
		return teamLLMFunc(func(_ context.Context, system, _ string) (string, error) {
			if strings.HasPrefix(system, "You explain") {
				return "Done.", nil
			}
			return `{"type":"ask","message":"ready"}`, nil
		}), nil
	})
	selection := progressSelection(t, uc)
	tracker, snapshots := progressRecorded("owner-run")
	plan := progressPlan()
	tracker.StartExecution(plan)
	if progressNode((*snapshots)[0], "agent").Status != "queued" {
		t.Fatal("agent ran before validation")
	}
	uc.actions.cmd = &countingRunner{}
	resp, err := uc.ExecuteRequest(WithRunTracker(context.Background(), tracker), ExecuteRequest{Plan: plan, ModelSelection: selection})
	if err != nil {
		t.Fatal(err)
	}
	tracker.CompleteExecution(resp)
	seen := map[string]bool{}
	for _, snapshot := range *snapshots {
		for _, id := range []string{"action-0", "action-1", "summary"} {
			if progressNode(snapshot, id).Status != "running" {
				continue
			}
			seen[id] = true
			owner := progressNode(snapshot, "agent")
			if owner.Status != "running" || owner.Title != "Worker" || owner.AgentID != "worker" || owner.StartedAt == nil || owner.FinishedAt != nil || owner.Message != "Executing the approved plan" {
				t.Fatalf("active %s has inactive owner: %+v", id, owner)
			}
		}
	}
	if len(seen) != 3 {
		t.Fatalf("missing active stages: %v", seen)
	}
	last := (*snapshots)[len(*snapshots)-1]
	owner := progressNode(last, "agent")
	if last.Phase != "completed" || owner.Status != "completed" || owner.FinishedAt == nil {
		t.Fatalf("execution owner did not finish: %+v", owner)
	}
}

func TestScopedProgressValidationAndScopeInvalidationSkipActions(t *testing.T) {
	for _, beforeDispatch := range []bool{false, true} {
		t.Run(map[bool]string{true: "preflight", false: "between-actions"}[beforeDispatch], func(t *testing.T) {
			uc, service, _, _ := teamFixture(t, &stubLLM{responses: []string{`{"connection_id":"open","model":"model-a"}`}}, func(domain.AIConnection, string) (LLMClient, error) {
				return &stubLLM{responses: []string{`{"type":"ask","message":"ready"}`}}, nil
			})
			selection := progressSelection(t, uc)
			plan := progressPlan()
			if beforeDispatch {
				plan.Actions[1].Args = json.RawMessage(`{"device_id":"outside","command":"echo blocked"}`)
			}
			tracker, snapshots := progressRecorded("scope-run")
			tracker.StartExecution(plan)
			ctx := WithRunTracker(context.Background(), tracker)
			runner := &countingRunner{after: func() { delete(service.orchs.(teamOrchs), "orch") }}
			uc.actions.cmd = runner
			resp, err := uc.ExecuteRequest(ctx, ExecuteRequest{Plan: plan, ModelSelection: selection})
			if beforeDispatch {
				if err == nil || runner.calls != 0 {
					t.Fatal("preflight ran an action")
				}
				tracker.Fail(false)
				for _, snapshot := range *snapshots {
					if progressNode(snapshot, "action-0").Status == "running" {
						t.Fatal("blocked action shown running")
					}
				}
			} else {
				if err != nil || runner.calls != 1 {
					t.Fatalf("scope invalidation: calls=%d err=%v", runner.calls, err)
				}
				tracker.CompleteExecution(resp)
			}
			last := (*snapshots)[len(*snapshots)-1]
			if last.Phase != "failed" || progressNode(last, "action-1").Status != "skipped" || progressNode(last, "summary").Status != "skipped" {
				t.Fatalf("blocked progress: %+v", last)
			}
		})
	}
}

func TestProgressSinkCancellationPreventsDispatchForLegacyAndScoped(t *testing.T) {
	for _, scoped := range []bool{false, true} {
		t.Run(map[bool]string{true: "scoped", false: "legacy"}[scoped], func(t *testing.T) {
			uc, _, _, _ := teamFixture(t, &stubLLM{responses: []string{`{"connection_id":"open","model":"model-a"}`}}, func(domain.AIConnection, string) (LLMClient, error) {
				return &stubLLM{responses: []string{`{"type":"ask","message":"ready"}`}}, nil
			})
			var selection *ModelSelection
			if scoped {
				selection = progressSelection(t, uc)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			tracker := NewRunTracker("cancel-run", func(snapshot AgentRunSnapshot) error {
				if progressNode(snapshot, "action-0").Status == "running" {
					cancel()
					return errors.New("disconnected")
				}
				return nil
			})
			plan := progressPlan()
			tracker.StartExecution(plan)
			ctx = WithRunTracker(ctx, tracker)
			runner := &countingRunner{}
			uc.actions.cmd = runner
			_, err := uc.ExecuteRequest(ctx, ExecuteRequest{Plan: plan, ModelSelection: selection})
			if !errors.Is(err, context.Canceled) || runner.calls != 0 {
				t.Fatalf("dispatch after sink failure: calls=%d err=%v", runner.calls, err)
			}
			tracker.Fail(true)
			if tracker.snapshot.Phase != "cancelled" {
				t.Fatal("cancelled run marked completed")
			}
		})
	}
}

func TestProgressBoundsMetadataAndDoesNotEchoUnknownAction(t *testing.T) {
	tracker, snapshots := progressRecorded("bounds-run")
	tracker.StartExecution(Plan{Actions: []Action{{Type: "SECRET-UNKNOWN-ACTION", Args: json.RawMessage(`{"command":"SECRET-ARGS"}`)}}})
	tracker.Agent(strings.Repeat("a", 10000), strings.Repeat("i", 10000), "openai", strings.Repeat("m", 10000))
	last := (*snapshots)[len(*snapshots)-1]
	if node := progressNode(last, "agent"); len(node.Title) > 520 || node.AgentID != "" || node.Model != "" {
		t.Fatalf("unbounded metadata: titlelen=%d", len(node.Title))
	}
	data, _ := json.Marshal(snapshots)
	if strings.Contains(string(data), "SECRET-") {
		t.Fatal("unknown action disclosed raw data")
	}
}
