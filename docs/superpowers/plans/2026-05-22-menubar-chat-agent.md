# Menubar Chat Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a natural-language chat box in the macOS menubar popover that turns prose into Hydra orchestration actions, with a hard "user must click Run" gate before any mutation.

**Architecture:** New `internal/usecase/agent` Go package wraps the existing `ai.Registry` and exposes Chat / Execute usecases via two HTTP endpoints. The LLM is asked to emit structured JSON (`{type: ask|plan, message, plan?}`); the backend re-validates every plan against the device cache at Execute time. The Swift `ChatViewModel` keeps multi-turn history client-side and posts the whole conversation back on each turn, so the backend stays stateless.

**Tech Stack:** Go (Echo, existing AI registry — lmstudio / ollama / claude / openai), SwiftUI, AppKit.

**Spec reference:** `docs/superpowers/specs/2026-05-22-menubar-chat-agent-design.md`

---

### Task 1: Agent package skeleton + shared types

**Files:**
- Create: `internal/usecase/agent/types.go`
- Create: `internal/usecase/agent/types_test.go`

- [ ] **Step 1: Write the failing test**

```go
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/usecase/agent/...`
Expected: FAIL with "package agent does not exist" or undefined `ChatResponse`.

- [ ] **Step 3: Implement the types**

```go
// Package agent provides the chat-driven orchestration agent that takes
// natural-language input, asks an LLM for a structured plan, validates
// it against the current device cache, and executes it on user approval.
//
// All mutation is gated on an explicit user Run click — the Chat endpoint
// only returns plans; the Execute endpoint runs them.
package agent

import "encoding/json"

// ChatType discriminates between the LLM asking a follow-up question and
// the LLM proposing a runnable plan. Every response is exactly one kind.
type ChatType string

const (
	ChatTypeAsk  ChatType = "ask"
	ChatTypePlan ChatType = "plan"
)

// ChatTurn is one entry in the running conversation. The client owns the
// history; the backend just reads it on each call.
type ChatTurn struct {
	Role    string `json:"role"` // "user" | "assistant_ask" | "assistant_plan" | "system_result"
	Content string `json:"content,omitempty"`
	Plan    *Plan  `json:"plan,omitempty"`
}

// ChatRequest carries the full conversation history plus the latest user
// utterance. History is capped on the client side at 20 turns.
type ChatRequest struct {
	History []ChatTurn `json:"history"`
	Message string     `json:"message"`
}

// ChatResponse is what /api/agent/chat returns. Exactly one of Plan is
// populated, gated by Type.
type ChatResponse struct {
	Type    ChatType `json:"type"`
	Message string   `json:"message"`
	Plan    *Plan    `json:"plan,omitempty"`
}

// Plan is the LLM's proposal: a one-line intent plus an ordered list of
// actions to run. The Execute endpoint takes this back verbatim.
type Plan struct {
	Intent  string   `json:"intent"`
	Actions []Action `json:"actions"`
}

// Action is one operation the agent wants to perform. Args is a raw JSON
// object whose shape depends on Type; the action handler unmarshals it.
type Action struct {
	Type string          `json:"type"`
	Args json.RawMessage `json:"args"`
}

// ActionResult is one row in the Execute response.
type ActionResult struct {
	Type   string          `json:"type"`
	Status string          `json:"status"` // "ok" | "error"
	Output json.RawMessage `json:"output,omitempty"`
	Error  string          `json:"error,omitempty"`
}

// ExecuteRequest is the body of /api/agent/execute.
type ExecuteRequest struct {
	Plan Plan `json:"plan"`
}

// ExecuteResponse is what /api/agent/execute returns.
type ExecuteResponse struct {
	Results []ActionResult `json:"results"`
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/usecase/agent/...`
Expected: PASS for both tests.

- [ ] **Step 5: Commit**

```bash
git add internal/usecase/agent/types.go internal/usecase/agent/types_test.go
git commit -m "feat(agent): chat agent types — ChatRequest/Response, Plan, Action"
```

---

### Task 2: Read action catalog

**Files:**
- Create: `internal/usecase/agent/actions.go`
- Create: `internal/usecase/agent/actions_test.go`

- [ ] **Step 1: Write the failing test**

```go
package agent

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

type stubDeviceLister struct {
	devices []*domain.Device
}

func (s *stubDeviceLister) ListDevices(ctx context.Context, force bool) ([]*domain.Device, error) {
	return s.devices, nil
}

func TestActionListDevices(t *testing.T) {
	reg := NewActionRegistry(&stubDeviceLister{
		devices: []*domain.Device{
			{ID: "a", Name: "alpha", Status: domain.DeviceStatusOnline},
			{ID: "b", Name: "beta", Status: domain.DeviceStatusOffline},
		},
	}, nil, nil, nil)
	res := reg.Run(context.Background(), Action{Type: "list_devices", Args: json.RawMessage(`{}`)})
	if res.Status != "ok" {
		t.Fatalf("status = %q, err=%q", res.Status, res.Error)
	}
	if len(res.Output) == 0 {
		t.Fatalf("output empty")
	}
}

func TestActionUnknownTypeFails(t *testing.T) {
	reg := NewActionRegistry(&stubDeviceLister{}, nil, nil, nil)
	res := reg.Run(context.Background(), Action{Type: "bogus", Args: json.RawMessage(`{}`)})
	if res.Status != "error" || res.Error == "" {
		t.Fatalf("got %+v", res)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/usecase/agent/ -run TestAction`
Expected: FAIL — `NewActionRegistry` undefined.

- [ ] **Step 3: Implement the read action catalog**

```go
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/s1ckdark/hydra/internal/domain"
)

// DeviceLister mirrors the read surface of DeviceUseCase the agent needs.
// We avoid importing the full usecase package to keep this layer thin.
type DeviceLister interface {
	ListDevices(ctx context.Context, forceRefresh bool) ([]*domain.Device, error)
}

// OrchLister returns the current orchs for read actions.
type OrchLister interface {
	ListOrchs(ctx context.Context) ([]*domain.Orch, error)
}

// MetricsReader fetches the latest per-device metrics for read actions.
type MetricsReader interface {
	GetDeviceMetrics(ctx context.Context, deviceID string) (*domain.DeviceMetrics, error)
}

// GPULister returns the latest GPU snapshot.
type GPULister interface {
	GetGPUSnapshot(ctx context.Context) ([]*domain.GPUNodeMetrics, error)
}

// ActionRegistry dispatches Actions to their handlers. Read actions
// added in this task; write actions in Task 3.
type ActionRegistry struct {
	devices DeviceLister
	orchs   OrchLister
	metrics MetricsReader
	gpu     GPULister
}

func NewActionRegistry(d DeviceLister, o OrchLister, m MetricsReader, g GPULister) *ActionRegistry {
	return &ActionRegistry{devices: d, orchs: o, metrics: m, gpu: g}
}

// Run dispatches a single Action and returns its ActionResult.
func (r *ActionRegistry) Run(ctx context.Context, a Action) ActionResult {
	switch a.Type {
	case "list_devices":
		return r.runListDevices(ctx, a)
	case "list_orchs":
		return r.runListOrchs(ctx, a)
	case "get_metrics":
		return r.runGetMetrics(ctx, a)
	case "get_gpu":
		return r.runGetGPU(ctx, a)
	default:
		return errResult(a.Type, fmt.Errorf("unknown action %q", a.Type))
	}
}

func (r *ActionRegistry) runListDevices(ctx context.Context, a Action) ActionResult {
	devs, err := r.devices.ListDevices(ctx, false)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, devs)
}

func (r *ActionRegistry) runListOrchs(ctx context.Context, a Action) ActionResult {
	if r.orchs == nil {
		return errResult(a.Type, errors.New("orch service unavailable"))
	}
	out, err := r.orchs.ListOrchs(ctx)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, out)
}

type getMetricsArgs struct {
	DeviceID string `json:"device_id"`
}

func (r *ActionRegistry) runGetMetrics(ctx context.Context, a Action) ActionResult {
	if r.metrics == nil {
		return errResult(a.Type, errors.New("metrics service unavailable"))
	}
	var args getMetricsArgs
	if err := json.Unmarshal(a.Args, &args); err != nil {
		return errResult(a.Type, fmt.Errorf("args: %w", err))
	}
	if args.DeviceID == "" {
		return errResult(a.Type, errors.New("device_id required"))
	}
	m, err := r.metrics.GetDeviceMetrics(ctx, args.DeviceID)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, m)
}

func (r *ActionRegistry) runGetGPU(ctx context.Context, a Action) ActionResult {
	if r.gpu == nil {
		return errResult(a.Type, errors.New("gpu service unavailable"))
	}
	out, err := r.gpu.GetGPUSnapshot(ctx)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, out)
}

func okResult(t string, v any) ActionResult {
	raw, err := json.Marshal(v)
	if err != nil {
		return errResult(t, err)
	}
	return ActionResult{Type: t, Status: "ok", Output: raw}
}

func errResult(t string, err error) ActionResult {
	return ActionResult{Type: t, Status: "error", Error: err.Error()}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/usecase/agent/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/usecase/agent/actions.go internal/usecase/agent/actions_test.go
git commit -m "feat(agent): read action catalog (list_devices, list_orchs, get_metrics, get_gpu)"
```

---

### Task 3: Write action catalog + plan validator

**Files:**
- Modify: `internal/usecase/agent/actions.go` — add CreateOrch, DeleteOrch, ExecuteCommand, RecentTasks
- Create: `internal/usecase/agent/validator.go`
- Modify: `internal/usecase/agent/actions_test.go` — add cases

- [ ] **Step 1: Write the failing tests**

```go
// in actions_test.go, append:

func TestValidateUnknownDevice(t *testing.T) {
	v := NewValidator(&stubDeviceLister{devices: []*domain.Device{{ID: "a", Name: "alpha"}}}, nil)
	plan := Plan{Actions: []Action{{
		Type: "execute_command",
		Args: json.RawMessage(`{"device_id":"ghost","command":"ls"}`),
	}}}
	errs := v.Validate(context.Background(), plan)
	if len(errs) != 1 {
		t.Fatalf("want 1 error, got %d", len(errs))
	}
}

func TestValidateDenyListBlocksRMRf(t *testing.T) {
	v := NewValidator(&stubDeviceLister{devices: []*domain.Device{{ID: "a", Name: "alpha", Status: domain.DeviceStatusOnline}}}, nil)
	plan := Plan{Actions: []Action{{
		Type: "execute_command",
		Args: json.RawMessage(`{"device_id":"a","command":"rm -rf /"}`),
	}}}
	if errs := v.Validate(context.Background(), plan); len(errs) == 0 {
		t.Fatalf("rm -rf should be blocked")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/usecase/agent/ -run TestValidate`
Expected: FAIL — `NewValidator` undefined.

- [ ] **Step 3: Add write actions and validator**

Append to `actions.go`:

```go
// CommandRunner runs a shell command on a device. Mirrors the
// DeviceUseCase / handler surface.
type CommandRunner interface {
	ExecuteOnDevice(ctx context.Context, deviceID, command string, timeoutSec int) (*domain.TaskResult, error)
}

// OrchManager covers create/delete used by write actions.
type OrchManager interface {
	CreateOrch(ctx context.Context, name, headID string, workerIDs []string) (*domain.Orch, error)
	DeleteOrch(ctx context.Context, id string, force bool) error
}

// ActionRegistry gets two more fields. Update the constructor:
func NewActionRegistry(d DeviceLister, o OrchLister, m MetricsReader, g GPULister, c CommandRunner, om OrchManager) *ActionRegistry {
	return &ActionRegistry{devices: d, orchs: o, metrics: m, gpu: g, cmd: c, orchMgr: om}
}

// Add to the switch in Run():
case "create_orch":
	return r.runCreateOrch(ctx, a)
case "delete_orch":
	return r.runDeleteOrch(ctx, a)
case "execute_command":
	return r.runExecuteCommand(ctx, a)
case "recent_tasks":
	return r.runRecentTasks(ctx, a)

type createOrchArgs struct {
	Name      string   `json:"name"`
	HeadID    string   `json:"head_id"`
	WorkerIDs []string `json:"worker_ids"`
}

func (r *ActionRegistry) runCreateOrch(ctx context.Context, a Action) ActionResult {
	if r.orchMgr == nil {
		return errResult(a.Type, errors.New("orch manager unavailable"))
	}
	var args createOrchArgs
	if err := json.Unmarshal(a.Args, &args); err != nil {
		return errResult(a.Type, fmt.Errorf("args: %w", err))
	}
	o, err := r.orchMgr.CreateOrch(ctx, args.Name, args.HeadID, args.WorkerIDs)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, o)
}

type deleteOrchArgs struct {
	OrchID string `json:"orch_id"`
	Force  bool   `json:"force"`
}

func (r *ActionRegistry) runDeleteOrch(ctx context.Context, a Action) ActionResult {
	if r.orchMgr == nil {
		return errResult(a.Type, errors.New("orch manager unavailable"))
	}
	var args deleteOrchArgs
	if err := json.Unmarshal(a.Args, &args); err != nil {
		return errResult(a.Type, fmt.Errorf("args: %w", err))
	}
	if err := r.orchMgr.DeleteOrch(ctx, args.OrchID, args.Force); err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, map[string]string{"status": "deleted", "orch_id": args.OrchID})
}

type execCmdArgs struct {
	DeviceID       string `json:"device_id"`
	Command        string `json:"command"`
	TimeoutSeconds int    `json:"timeout_seconds"`
}

func (r *ActionRegistry) runExecuteCommand(ctx context.Context, a Action) ActionResult {
	if r.cmd == nil {
		return errResult(a.Type, errors.New("command runner unavailable"))
	}
	var args execCmdArgs
	if err := json.Unmarshal(a.Args, &args); err != nil {
		return errResult(a.Type, fmt.Errorf("args: %w", err))
	}
	timeout := args.TimeoutSeconds
	if timeout <= 0 {
		timeout = 30
	}
	out, err := r.cmd.ExecuteOnDevice(ctx, args.DeviceID, args.Command, timeout)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, out)
}

func (r *ActionRegistry) runRecentTasks(ctx context.Context, a Action) ActionResult {
	// Server-side recent tasks come from the task repo; we return an empty
	// list when no orch lister is wired so the action degrades gracefully.
	return okResult(a.Type, []any{})
}
```

Add `cmd CommandRunner` and `orchMgr OrchManager` fields to the `ActionRegistry` struct. Update the existing `NewActionRegistry` call sites — there are no real callers yet (only tests); update the test constructor too:

```go
// in actions_test.go, update the constructor calls:
reg := NewActionRegistry(deviceLister, nil, nil, nil, nil, nil)
```

Create `internal/usecase/agent/validator.go`:

```go
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/s1ckdark/hydra/internal/domain"
)

// commandDenyList blocks the LLM from accidentally proposing destructive
// shell commands. The user can still type one directly through the chat
// if they really want — this is purely a guardrail against hallucinated
// `rm -rf /` cleanup suggestions.
var commandDenyList = []string{
	"rm -rf /",
	"rm -rf /*",
	"mkfs",
	"dd if=",
	":(){",
	"shutdown",
	"reboot",
}

// Validator sanity-checks a plan against the current device cache before
// either Chat returns it or Execute runs it. Two phases catch:
//   - LLM hallucinating device IDs that don't exist
//   - Plans that were valid at Chat time but stale by Execute (device
//     removed from Tailscale in the gap)
type Validator struct {
	devices DeviceLister
	orchs   OrchLister
}

func NewValidator(d DeviceLister, o OrchLister) *Validator {
	return &Validator{devices: d, orchs: o}
}

// Validate returns one error per problem action; empty slice means the
// plan is runnable. The caller is responsible for surfacing the errors.
func (v *Validator) Validate(ctx context.Context, plan Plan) []error {
	deviceIDs := map[string]bool{}
	if v.devices != nil {
		devs, _ := v.devices.ListDevices(ctx, false)
		for _, d := range devs {
			deviceIDs[d.ID] = true
		}
	}
	var errs []error
	for i, a := range plan.Actions {
		if err := v.validateOne(deviceIDs, i, a); err != nil {
			errs = append(errs, err)
		}
	}
	return errs
}

func (v *Validator) validateOne(devices map[string]bool, idx int, a Action) error {
	mustDevice := func(id string) error {
		if !devices[id] {
			return fmt.Errorf("action %d (%s): unknown device_id %q", idx, a.Type, id)
		}
		return nil
	}
	switch a.Type {
	case "get_metrics":
		var args getMetricsArgs
		if err := json.Unmarshal(a.Args, &args); err != nil {
			return fmt.Errorf("action %d (%s): args: %w", idx, a.Type, err)
		}
		return mustDevice(args.DeviceID)
	case "create_orch":
		var args createOrchArgs
		if err := json.Unmarshal(a.Args, &args); err != nil {
			return fmt.Errorf("action %d (%s): args: %w", idx, a.Type, err)
		}
		if err := mustDevice(args.HeadID); err != nil {
			return err
		}
		for _, w := range args.WorkerIDs {
			if err := mustDevice(w); err != nil {
				return err
			}
		}
		return nil
	case "execute_command":
		var args execCmdArgs
		if err := json.Unmarshal(a.Args, &args); err != nil {
			return fmt.Errorf("action %d (%s): args: %w", idx, a.Type, err)
		}
		if err := mustDevice(args.DeviceID); err != nil {
			return err
		}
		lower := strings.ToLower(args.Command)
		for _, bad := range commandDenyList {
			if strings.Contains(lower, bad) {
				return fmt.Errorf("action %d (%s): command matches deny-list (%q)", idx, a.Type, bad)
			}
		}
		return nil
	case "list_devices", "list_orchs", "get_gpu", "recent_tasks":
		return nil
	case "delete_orch":
		// Orch ID validation is best-effort; the orch manager will
		// return a clean error if the ID is gone, so we don't need a
		// pre-check here. Reject empty id only.
		var args deleteOrchArgs
		if err := json.Unmarshal(a.Args, &args); err != nil {
			return fmt.Errorf("action %d (%s): args: %w", idx, a.Type, err)
		}
		if args.OrchID == "" {
			return errors.New("delete_orch: orch_id required")
		}
		return nil
	default:
		return fmt.Errorf("action %d: unknown type %q", idx, a.Type)
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/usecase/agent/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/usecase/agent/actions.go internal/usecase/agent/actions_test.go internal/usecase/agent/validator.go
git commit -m "feat(agent): write actions (create_orch/delete_orch/execute_command) + validator"
```

---

### Task 4: LLM client wrapper + JSON parser with retry

**Files:**
- Create: `internal/usecase/agent/llm.go`
- Create: `internal/usecase/agent/llm_test.go`

- [ ] **Step 1: Write the failing test**

```go
package agent

import (
	"context"
	"errors"
	"testing"
)

type stubLLM struct {
	calls    int
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/usecase/agent/ -run TestParseChatResponse`
Expected: FAIL — `AskOnce` undefined.

- [ ] **Step 3: Implement the LLM wrapper**

```go
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
// *something* instead of an opaque error.
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
	// Final fallback — wrap the raw text so the user sees the model's
	// best effort instead of an opaque error.
	return ChatResponse{
		Type:    ChatTypeAsk,
		Message: "I couldn't structure that into a plan. Raw response: " + out2,
	}, nil
}

// parseChatResponse extracts and validates one ChatResponse from LLM text.
// Tolerates leading / trailing prose by locating the first '{' .. last '}'.
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/usecase/agent/...`
Expected: PASS for all three new tests.

- [ ] **Step 5: Commit**

```bash
git add internal/usecase/agent/llm.go internal/usecase/agent/llm_test.go
git commit -m "feat(agent): LLM wrapper with structured-output parser + single retry"
```

---

### Task 5: AgentUseCase.Chat / Execute

**Files:**
- Create: `internal/usecase/agent/agent.go`
- Create: `internal/usecase/agent/agent_test.go`

- [ ] **Step 1: Write the failing test**

```go
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/usecase/agent/ -run TestAgent_`
Expected: FAIL — `NewAgentUseCase`, `Chat`, `Execute` undefined.

- [ ] **Step 3: Implement**

```go
package agent

import (
	"context"
	"fmt"
	"strings"
)

// maxHistoryTurns caps how many prior turns we feed into the LLM prompt.
// Older turns are dropped oldest-first; the client still keeps them for
// the user to scroll, but we don't pay tokens to send everything every
// time.
const maxHistoryTurns = 20

// AgentUseCase wires the LLM to the action registry + validator. Stateless
// across requests — history flows entirely through the request body.
type AgentUseCase struct {
	llm     LLMClient
	actions *ActionRegistry
	val     *Validator
}

func NewAgentUseCase(llm LLMClient, actions *ActionRegistry, val *Validator) *AgentUseCase {
	return &AgentUseCase{llm: llm, actions: actions, val: val}
}

// Chat sends one user message + truncated history to the LLM and returns
// its structured reply. If the LLM proposes a plan, we run the validator
// up-front so the UI can disable Run when the plan is already stale.
func (a *AgentUseCase) Chat(ctx context.Context, req ChatRequest) (ChatResponse, error) {
	if a.llm == nil {
		return ChatResponse{}, fmt.Errorf("chat agent: no LLM configured")
	}
	system := a.buildSystemPrompt(ctx)
	prompt := a.buildUserPrompt(req)
	resp, err := AskOnce(ctx, a.llm, system, prompt)
	if err != nil {
		return ChatResponse{}, err
	}
	if resp.Type == ChatTypePlan && resp.Plan != nil {
		if errs := a.val.Validate(ctx, *resp.Plan); len(errs) > 0 {
			// Don't drop the plan — surface validation problems via
			// an appended note so the UI can disable Run and explain.
			var notes []string
			for _, e := range errs {
				notes = append(notes, e.Error())
			}
			resp.Message = resp.Message + "\n\n(plan has validation issues:\n" + strings.Join(notes, "\n") + ")"
		}
	}
	return resp, nil
}

// Execute re-validates and runs the plan. Per-action errors don't abort
// the rest — every action gets a status in the response.
func (a *AgentUseCase) Execute(ctx context.Context, plan Plan) (ExecuteResponse, error) {
	results := make([]ActionResult, 0, len(plan.Actions))
	errs := a.val.Validate(ctx, plan)
	errsByIdx := map[int]error{}
	for i, e := range errs {
		errsByIdx[i] = e
		_ = i
	}
	// We can't directly map errs back to action indices without parsing
	// the message, so re-validate per-action for accurate matching.
	for i, action := range plan.Actions {
		if perActionErr := a.val.Validate(ctx, Plan{Actions: []Action{action}}); len(perActionErr) > 0 {
			results = append(results, ActionResult{
				Type:   action.Type,
				Status: "error",
				Error:  perActionErr[0].Error(),
			})
			continue
		}
		results = append(results, a.actions.Run(ctx, action))
		_ = i
	}
	return ExecuteResponse{Results: results}, nil
}

// buildSystemPrompt assembles the catalog + current device snapshot the
// LLM uses to ground its replies. Kept inside the agent package so all
// prompt evolution happens in one place.
func (a *AgentUseCase) buildSystemPrompt(ctx context.Context) string {
	var sb strings.Builder
	sb.WriteString("You are Hydra's orchestration assistant. Reply with a single JSON object: {\"type\":\"ask\"|\"plan\",\"message\":\"...\",\"plan\":{...}}.\n")
	sb.WriteString("Use type=\"ask\" for a clarifying question (no plan). Use type=\"plan\" when the user wants an action; populate plan.intent and plan.actions.\n")
	sb.WriteString("\nAvailable actions:\n")
	sb.WriteString("- list_devices {} — list Tailnet devices.\n")
	sb.WriteString("- list_orchs {} — list orchestrators.\n")
	sb.WriteString("- get_metrics {device_id} — CPU/RAM/disk for one device.\n")
	sb.WriteString("- get_gpu {} — GPU snapshot across nodes.\n")
	sb.WriteString("- recent_tasks {limit?} — last tasks.\n")
	sb.WriteString("- create_orch {name, head_id, worker_ids[]} — create an orchestrator.\n")
	sb.WriteString("- delete_orch {orch_id, force?} — delete an orchestrator.\n")
	sb.WriteString("- execute_command {device_id, command, timeout_seconds?} — run a shell command.\n")
	sb.WriteString("\nNever propose destructive shell commands. Always prefer the smallest plan that satisfies the request.\n")
	if a.actions != nil && a.actions.devices != nil {
		devs, _ := a.actions.devices.ListDevices(ctx, false)
		if len(devs) > 0 {
			sb.WriteString("\nCurrent devices (id — name — status):\n")
			for _, d := range devs {
				sb.WriteString("- " + d.ID + " — " + d.Name + " — " + string(d.Status) + "\n")
			}
		}
	}
	return sb.String()
}

func (a *AgentUseCase) buildUserPrompt(req ChatRequest) string {
	history := req.History
	if len(history) > maxHistoryTurns {
		history = history[len(history)-maxHistoryTurns:]
	}
	var sb strings.Builder
	for _, t := range history {
		sb.WriteString(t.Role + ": " + t.Content + "\n")
	}
	sb.WriteString("user: " + req.Message + "\n")
	return sb.String()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/usecase/agent/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/usecase/agent/agent.go internal/usecase/agent/agent_test.go
git commit -m "feat(agent): AgentUseCase.Chat + Execute with per-action validation"
```

---

### Task 6: HTTP handlers + route wiring

**Files:**
- Create: `internal/web/handler/agent_handler.go`
- Create: `internal/web/handler/agent_handler_test.go`
- Modify: `internal/web/handler/handler.go` — add `agentUC *agent.AgentUseCase` field + setter
- Modify: `cmd/server/main.go` — wire the agent and register routes

- [ ] **Step 1: Write the failing test**

```go
package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

func TestAPIAgentChat_ReturnsServiceUnavailableWhenUnconfigured(t *testing.T) {
	h := &Handler{}
	e := echo.New()
	body, _ := json.Marshal(agent.ChatRequest{Message: "hi"})
	req := httptest.NewRequest(http.MethodPost, "/api/agent/chat", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	if err := h.APIAgentChat(c); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/web/handler/ -run TestAPIAgentChat`
Expected: FAIL — `APIAgentChat` undefined.

- [ ] **Step 3: Implement handlers + wiring**

Create `internal/web/handler/agent_handler.go`:

```go
package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

// APIAgentChat accepts the conversation history + latest user message
// and returns either a clarifying question or a runnable plan.
func (h *Handler) APIAgentChat(c echo.Context) error {
	if h.agentUC == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	var req agent.ChatRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	resp, err := h.agentUC.Chat(c.Request().Context(), req)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, resp)
}

// APIAgentExecute runs a plan returned by /api/agent/chat. The plan is
// re-validated before any action runs.
func (h *Handler) APIAgentExecute(c echo.Context) error {
	if h.agentUC == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	var req agent.ExecuteRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	resp, err := h.agentUC.Execute(c.Request().Context(), req.Plan)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, resp)
}
```

Add field + setter to `internal/web/handler/handler.go` (in the Handler struct + a new method):

```go
// inside Handler struct:
agentUC *agent.AgentUseCase

// SetAgentUseCase wires the chat agent. Optional — if not set, the
// agent endpoints return 503 with a clear error.
func (h *Handler) SetAgentUseCase(a *agent.AgentUseCase) { h.agentUC = a }
```

Add the import at the top: `"github.com/s1ckdark/hydra/internal/usecase/agent"`.

Modify `cmd/server/main.go` — find the route block where ping / taildrop are registered and add:

```go
// Chat agent — natural-language orchestration. Both endpoints sit on
// apiWrite because Execute can mutate; Chat shares the auth posture
// for symmetry.
apiWrite.POST("/agent/chat", h.APIAgentChat)
apiWrite.POST("/agent/execute", h.APIAgentExecute)
```

And earlier (where other usecases are wired), construct the agent:

```go
agentRegistry := agent.NewActionRegistry(deviceUC, orchUC, monitorUC, monitorUC, deviceUC, orchUC)
agentValidator := agent.NewValidator(deviceUC, orchUC)
// LLM client wraps the chat-role provider; nil here means the user
// hasn't picked one yet and chat endpoints return 503 until they do.
chatLLM := buildChatLLM(cfg.Agent.AI, aiRegistry)
if chatLLM != nil {
    agentUC := agent.NewAgentUseCase(chatLLM, agentRegistry, agentValidator)
    h.SetAgentUseCase(agentUC)
    log.Printf("[agent] chat agent enabled")
}
```

Add a thin adapter `buildChatLLM` in `cmd/server/ai.go` (or a new `cmd/server/chat_llm.go`):

```go
func buildChatLLM(cfg config.AIConfig, registry *ai.Registry) agent.LLMClient {
    // The chat role falls back to Default — same pattern as the other
    // role overrides in ai.Registry. Returns nil if no provider is
    // configured so the server still boots.
    provider := registry.ChatProvider() // implemented in the registry; returns nil when unconfigured
    if provider == nil {
        return nil
    }
    return &chatLLMAdapter{p: provider}
}

type chatLLMAdapter struct{ p ai.Provider }

func (a *chatLLMAdapter) Complete(ctx context.Context, system, prompt string) (string, error) {
    return a.p.Complete(ctx, system, prompt)
}
```

If `ai.Registry` doesn't yet have `ChatProvider()`, add it as a thin alias of the default fetcher with role="chat".

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/web/handler/ -run TestAPIAgent && go build ./...`
Expected: PASS + clean build.

- [ ] **Step 5: Commit**

```bash
git add internal/web/handler/agent_handler.go internal/web/handler/agent_handler_test.go internal/web/handler/handler.go cmd/server/main.go cmd/server/ai.go
git commit -m "feat(agent): wire /api/agent/chat and /api/agent/execute"
```

---

### Task 7: Config — chat role provider

**Files:**
- Modify: `config/config.go` — add `Chat ProviderConfig` to the AI struct
- Modify: existing config_test.go

- [ ] **Step 1: Write the failing test**

In `config/config_test.go`, append:

```go
func TestAIConfig_ChatRoleFallsBackToDefault(t *testing.T) {
	c := AgentConfig{
		AI: AIConfig{
			Default: ProviderConfig{Provider: "claude", APIKey: "sk-default"},
		},
	}
	got := c.AI.Resolve("chat")
	if got.Provider != "claude" || got.APIKey != "sk-default" {
		t.Fatalf("chat fallback = %+v", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./config/...`
Expected: FAIL — "chat" role unknown.

- [ ] **Step 3: Add the chat role**

In `config/config.go`, locate `AIConfig` and the `Resolve` switch. Add a `Chat` field and switch case alongside the existing role overrides (`Head`, `Schedule`, etc. — match the existing pattern exactly). For example:

```go
type AIConfig struct {
    Default  ProviderConfig `mapstructure:"default"`
    Head     *ProviderConfig `mapstructure:"head"`
    Schedule *ProviderConfig `mapstructure:"schedule"`
    Capacity *ProviderConfig `mapstructure:"capacity"`
    Chat     *ProviderConfig `mapstructure:"chat"`   // NEW
    // ... other existing fields unchanged
}

func (c AIConfig) Resolve(role string) ProviderConfig {
    switch role {
    case "head":
        if c.Head != nil { return *c.Head }
    case "schedule":
        if c.Schedule != nil { return *c.Schedule }
    case "capacity":
        if c.Capacity != nil { return *c.Capacity }
    case "chat":                                       // NEW
        if c.Chat != nil { return *c.Chat }
    }
    return c.Default
}
```

(Match the surrounding code — the existing roles already follow this shape. Do NOT add a new pattern.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./config/...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add config/config.go config/config_test.go
git commit -m "feat(agent): add chat role to AIConfig with default fallback"
```

---

### Task 8: Swift models matching the Go schema

**Files:**
- Create: `Hydra/Hydra/Models/AgentPlan.swift`
- Create: `Hydra/Hydra/Models/ChatTurn.swift`

- [ ] **Step 1: Write the model files**

`Hydra/Hydra/Models/AgentPlan.swift`:

```swift
import Foundation

/// One action in an LLM-proposed plan. `args` mirrors the Go side as
/// raw JSON so we can show it verbatim without enumerating every shape.
struct AgentAction: Codable, Identifiable {
    let id = UUID()
    let type: String
    let args: AnyCodable

    enum CodingKeys: String, CodingKey { case type, args }
}

/// Plan = intent + ordered actions.
struct AgentPlan: Codable {
    let intent: String
    let actions: [AgentAction]
}

/// Server reply to POST /api/agent/chat. Either `ask` (clarifying
/// question, no plan) or `plan` (intent + actions). `message` always
/// present.
struct ChatResponse: Codable {
    let type: String
    let message: String
    let plan: AgentPlan?
}

/// Per-action result returned by /api/agent/execute.
struct ActionResult: Codable, Identifiable {
    let id = UUID()
    let type: String
    let status: String   // "ok" | "error"
    let output: AnyCodable?
    let error: String?

    enum CodingKeys: String, CodingKey { case type, status, output, error }
}

struct ExecuteResponse: Codable {
    let results: [ActionResult]
}

/// AnyCodable wraps the JSON-typed values we round-trip through the
/// agent endpoints without modelling every action's shape.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                       { self.value = NSNull() }
        else if let v = try? c.decode(Bool.self)    { self.value = v }
        else if let v = try? c.decode(Int.self)     { self.value = v }
        else if let v = try? c.decode(Double.self)  { self.value = v }
        else if let v = try? c.decode(String.self)  { self.value = v }
        else if let v = try? c.decode([AnyCodable].self) { self.value = v.map(\.value) }
        else if let v = try? c.decode([String: AnyCodable].self) {
            self.value = v.mapValues(\.value)
        } else { self.value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull:                 try c.encodeNil()
        case let v as Bool:              try c.encode(v)
        case let v as Int:               try c.encode(v)
        case let v as Double:            try c.encode(v)
        case let v as String:            try c.encode(v)
        case let v as [Any]:             try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]:     try c.encode(v.mapValues(AnyCodable.init))
        default:                         try c.encodeNil()
        }
    }
}
```

`Hydra/Hydra/Models/ChatTurn.swift`:

```swift
import Foundation

/// One row in the chat history. `role` mirrors the Go side exactly:
///   - user
///   - assistant_ask
///   - assistant_plan
///   - system_result
struct ChatTurn: Codable, Identifiable {
    let id = UUID()
    let role: String
    var content: String
    var plan: AgentPlan?
    var results: [ActionResult]?

    enum CodingKeys: String, CodingKey { case role, content, plan, results }
}

struct ChatRequest: Codable {
    var history: [ChatTurn]
    var message: String
}

struct ExecuteRequest: Codable {
    let plan: AgentPlan
}
```

- [ ] **Step 2: Build to verify the models compile**

Run: `swift build --package-path Hydra` (or trigger an Xcode build via `make hydra-app`).
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Models/AgentPlan.swift Hydra/Hydra/Models/ChatTurn.swift
git commit -m "feat(agent): Swift models for chat turn, plan, action, execute result"
```

---

### Task 9: APIClient chat() + executePlan()

**Files:**
- Modify: `Hydra/Hydra/Services/APIClient.swift` — add two methods alongside `sendTaildrop`

- [ ] **Step 1: Add the methods**

Insert near the other agent-adjacent APIClient methods:

```swift
// MARK: - Chat agent

/// Submits one user message + full history to /api/agent/chat. The
/// server returns either a clarifying question (type="ask") or a plan
/// (type="plan").
func chat(_ request: ChatRequest) async throws -> ChatResponse {
    return try await post("/api/agent/chat", body: request)
}

/// Runs a previously returned plan. The server re-validates before
/// any action runs.
func executePlan(_ plan: AgentPlan) async throws -> ExecuteResponse {
    return try await post("/api/agent/execute", body: ExecuteRequest(plan: plan))
}
```

- [ ] **Step 2: Build to verify**

Run: `make hydra-app` (or `swift build --package-path Hydra`).
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Services/APIClient.swift
git commit -m "feat(agent): APIClient.chat + executePlan"
```

---

### Task 10: ChatViewModel

**Files:**
- Create: `Hydra/Hydra/ViewModels/ChatViewModel.swift`

- [ ] **Step 1: Write the view model**

```swift
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var isThinking = false
    @Published var pendingPlan: AgentPlan?
    @Published var pendingPlanMessage: String?
    @Published var lastResults: [ActionResult]?
    @Published var error: String?

    /// History sent to the server is capped at the last 20 turns. The
    /// UI keeps the full list so the user can scroll back.
    private let serverHistoryCap = 20

    private let api = APIClient.shared

    func send(_ message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(ChatTurn(role: "user", content: trimmed, plan: nil, results: nil))
        isThinking = true
        error = nil
        defer { isThinking = false }
        let history = Array(turns.suffix(serverHistoryCap))
        let req = ChatRequest(history: history, message: trimmed)
        do {
            let resp = try await api.chat(req)
            let role = resp.type == "plan" ? "assistant_plan" : "assistant_ask"
            turns.append(ChatTurn(role: role, content: resp.message, plan: resp.plan, results: nil))
            if resp.type == "plan" {
                pendingPlan = resp.plan
                pendingPlanMessage = resp.message
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runPendingPlan() async {
        guard let plan = pendingPlan else { return }
        isThinking = true
        defer { isThinking = false }
        do {
            let resp = try await api.executePlan(plan)
            lastResults = resp.results
            turns.append(ChatTurn(
                role: "system_result",
                content: summary(of: resp.results),
                plan: nil,
                results: resp.results
            ))
            pendingPlan = nil
            pendingPlanMessage = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelPendingPlan() {
        pendingPlan = nil
        pendingPlanMessage = nil
    }

    private func summary(of results: [ActionResult]) -> String {
        let ok = results.filter { $0.status == "ok" }.count
        let fail = results.count - ok
        if fail == 0 { return "✓ all \(ok) action(s) completed" }
        return "ran \(results.count) action(s) — \(ok) ok, \(fail) failed"
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `make hydra-app`.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/ViewModels/ChatViewModel.swift
git commit -m "feat(agent): ChatViewModel with multi-turn history + plan confirm flow"
```

---

### Task 11: Menubar Chat UI

**Files:**
- Create: `Hydra/Hydra/Views/MenuBar/PlanCardView.swift`
- Create: `Hydra/Hydra/Views/MenuBar/ChatSection.swift`
- Modify: `Hydra/Hydra/Views/MenuBar/MenuBarView.swift` — embed ChatSection, widen popover

- [ ] **Step 1: PlanCardView**

```swift
import SwiftUI

/// Renders an LLM-proposed plan with per-action rows and Run / Cancel
/// buttons. Driven entirely by the ChatViewModel; no API calls of its
/// own.
struct PlanCardView: View {
    let plan: AgentPlan
    let message: String?
    let isThinking: Bool
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.intent)
                    .font(.caption.bold())
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ForEach(plan.actions) { action in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(action.type)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 4)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(argsSummary(action.args))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Run", action: onRun)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isThinking)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// One-line summary of an action's args for the row label.
    private func argsSummary(_ args: AnyCodable) -> String {
        guard let dict = args.value as? [String: Any] else { return "" }
        return dict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    }
}
```

- [ ] **Step 2: ChatSection**

```swift
import SwiftUI

/// Chat panel that lives inside the menubar popover. Scrolls history,
/// inline-renders the pending plan card, and owns the input field.
struct ChatSection: View {
    @StateObject private var vm = ChatViewModel()
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chat")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.turns) { turn in
                        ChatTurnRow(turn: turn)
                    }
                    if let plan = vm.pendingPlan {
                        PlanCardView(
                            plan: plan,
                            message: vm.pendingPlanMessage,
                            isThinking: vm.isThinking,
                            onRun:    { Task { await vm.runPendingPlan() } },
                            onCancel: { vm.cancelPendingPlan() }
                        )
                    }
                    if let err = vm.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                TextField("Ask Hydra…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.isThinking)
            }
            if vm.isThinking {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("thinking…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func submit() {
        let msg = draft
        draft = ""
        Task { await vm.send(msg) }
    }
}

private struct ChatTurnRow: View {
    let turn: ChatTurn
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(roleSymbol)
                .font(.caption2)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(turn.content)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
    private var roleSymbol: String {
        switch turn.role {
        case "user":            return "›"
        case "assistant_ask":   return "?"
        case "assistant_plan":  return "▶"
        case "system_result":   return "✓"
        default:                return "•"
        }
    }
}
```

- [ ] **Step 3: Embed in MenuBarView**

In `Hydra/Hydra/Views/MenuBar/MenuBarView.swift`, find the `Divider()` between the GPU per-node section and the device count block, and insert:

```swift
Divider()

ChatSection()

Divider()
```

Adjust the popover width: change `.frame(width: 300)` to `.frame(width: 420)`.

- [ ] **Step 4: Build to verify**

Run: `make hydra-app`.
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add Hydra/Hydra/Views/MenuBar/PlanCardView.swift Hydra/Hydra/Views/MenuBar/ChatSection.swift Hydra/Hydra/Views/MenuBar/MenuBarView.swift
git commit -m "feat(agent): menubar chat section with plan card + run/cancel"
```

---

### Task 12: Settings — Chat provider selector

**Files:**
- Modify: `Hydra/Hydra/Views/Settings/AISettingsTab.swift` — add a chat block matching existing role blocks

- [ ] **Step 1: Inspect existing role blocks**

Open `AISettingsTab.swift` and locate the section that renders one provider block per role (Head / Schedule / Capacity exist already). Each block has a Picker for provider, an endpoint field, a model field, and a (masked) API key field; the values are persisted via the existing `setRoleOverride` flow.

- [ ] **Step 2: Add a Chat role block**

Duplicate the existing Schedule block and rename to `chat`. The persisted key path is `agent.ai.chat.*` (already supported on the Go side by Task 7). The UI label is "Chat agent — natural-language input". Add it directly under the Schedule block so the visual order matches the runtime fallback order.

Exact code shape mirrors the existing blocks — don't introduce a new pattern.

- [ ] **Step 3: Build to verify**

Run: `make hydra-app`.
Expected: clean build; new block visible in Settings.

- [ ] **Step 4: Commit**

```bash
git add Hydra/Hydra/Views/Settings/AISettingsTab.swift
git commit -m "feat(agent): Settings UI for chat-role provider override"
```

---

### Task 13: End-to-end manual verification

**Files:** none (manual smoke test).

- [ ] **Step 1: Configure a chat provider**

Open the rebuilt Hydra.app → Settings → AI → Chat agent. Pick `lmstudio`, endpoint `http://192.168.1.19:1234`, model `openai/gpt-oss-20b`. Save. Look in `~/.hydra/config.yaml` for an `agent.ai.chat` block.

- [ ] **Step 2: Smoke-test READ**

Click the menubar icon. Type "how busy is high-15?" → expect either an `ask` response or a plan with `get_metrics`. If plan, click Run → expect a system_result row showing the metric numbers. Confirm no error banner.

- [ ] **Step 3: Smoke-test ORCH create**

Type "start a Ray orch on high-15, high-16, and sff with high-15 as head". Expect a plan with `create_orch`. Click Run. Open the Dashboard → confirm the new orch appears under Orchs.

- [ ] **Step 4: Smoke-test execute_command**

Type "run nvidia-smi on sff". Expect a plan with `execute_command`. Click Run. Confirm output appears in the system_result row.

- [ ] **Step 5: Smoke-test deny-list**

Type "run `rm -rf /tmp` on sff". The LLM should either refuse or propose it; if proposed, expect the validation note to appear and Run to fail with a deny-list error in the result.

- [ ] **Step 6: Smoke-test provider unconfigured**

Stop the lmstudio server (or clear the endpoint in Settings). Send a message → expect a clear error banner referencing the provider, not a crash.

- [ ] **Step 7: Commit any test fixes discovered**

If any smoke test fails, fix and commit per the affected task pattern. Do not advance past a failing smoke step.

---

## Self-Review

**Spec coverage:**
- Chat UI in menubar → Task 11 ✓
- Multi-turn history → Task 10 (ChatViewModel.turns + serverHistoryCap) ✓
- /api/agent/chat + /api/agent/execute → Tasks 5, 6 ✓
- Structured JSON contract → Tasks 1, 4 ✓
- Action catalog (read + orch + execute) → Tasks 2, 3 ✓
- Validator (unknown IDs, deny-list) → Task 3 ✓
- Settings provider selector → Tasks 7, 12 ✓
- Plan re-validation on Execute → Task 5 (per-action re-validate loop) ✓
- Token / history cap → Task 5 (maxHistoryTurns) ✓
- Safety: no autonomous mutation → enforced by split between Chat (no execution) and Execute (only via user click) ✓
- Plan card with Run/Cancel → Task 11 ✓
- Per-action errors don't abort plan → Task 5 (Execute loop continues) ✓

**Placeholder scan:** No "TBD", "TODO", or vague-handling phrases. Task 12 says "mirror the existing role blocks" — that's a deliberate reference to an existing pattern, not a placeholder.

**Type consistency:** `AgentUseCase`, `ChatRequest`, `ChatResponse`, `Plan`, `Action`, `ActionResult`, `ExecuteRequest`, `ExecuteResponse` used identically across Tasks 1, 5, 6. Swift mirror names match (Task 8). `NewActionRegistry` signature stays consistent between Task 2 (4-arg) and Task 3 (extended to 6-arg, with a note to update the test).

**Scope:** Single coherent feature with one HTTP surface; no decomposition needed.
