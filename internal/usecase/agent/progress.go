package agent

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// AgentRunSnapshot is transient request progress. It deliberately carries no
// prompts, command arguments, action output, endpoints, or credentials.
type AgentRunSnapshot struct {
	RunID     string         `json:"run_id"`
	Phase     string         `json:"phase"`
	UpdatedAt time.Time      `json:"updated_at"`
	Nodes     []AgentRunNode `json:"nodes"`
	Edges     []AgentRunEdge `json:"edges"`
}

type AgentRunNode struct {
	ID         string     `json:"id"`
	ParentID   string     `json:"parent_id,omitempty"`
	Kind       string     `json:"kind"`
	Title      string     `json:"title"`
	Status     string     `json:"status"`
	Order      int        `json:"order"`
	AgentID    string     `json:"agent_id,omitempty"`
	Provider   string     `json:"provider,omitempty"`
	Model      string     `json:"model,omitempty"`
	ActionType string     `json:"action_type,omitempty"`
	StartedAt  *time.Time `json:"started_at,omitempty"`
	FinishedAt *time.Time `json:"finished_at,omitempty"`
	Message    string     `json:"message,omitempty"`
}

type AgentRunEdge struct {
	From string `json:"from"`
	To   string `json:"to"`
	Kind string `json:"kind"`
}

type ProgressSink func(AgentRunSnapshot) error

// Full snapshots are intentionally bounded to avoid quadratic stream growth.
const MaxProgressActions = 100

// RunTracker belongs to one HTTP request and is never retained globally. The
// sink is serialized; after a write failure no more writes are attempted.
type RunTracker struct {
	mu       sync.Mutex
	snapshot AgentRunSnapshot
	sink     ProgressSink
	sinkErr  error
}

type runTrackerKey struct{}

func NewRunTracker(runID string, sink ProgressSink) *RunTracker {
	return &RunTracker{snapshot: AgentRunSnapshot{RunID: runID, Nodes: []AgentRunNode{}, Edges: []AgentRunEdge{}}, sink: sink}
}

func WithRunTracker(ctx context.Context, tracker *RunTracker) context.Context {
	return context.WithValue(ctx, runTrackerKey{}, tracker)
}

func runTracker(ctx context.Context) *RunTracker {
	t, _ := ctx.Value(runTrackerKey{}).(*RunTracker)
	return t
}

func (t *RunTracker) change(fn func()) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	fn()
	t.snapshot.UpdatedAt = time.Now().UTC()
	if t.sink != nil && t.sinkErr == nil {
		// Each emitted snapshot owns its slices; a consumer may retain it.
		snapshot := t.snapshot
		snapshot.Nodes = append([]AgentRunNode{}, t.snapshot.Nodes...)
		snapshot.Edges = append([]AgentRunEdge{}, t.snapshot.Edges...)
		t.sinkErr = t.sink(snapshot)
	}
}

func (t *RunTracker) node(id string) *AgentRunNode {
	for i := range t.snapshot.Nodes {
		if t.snapshot.Nodes[i].ID == id {
			return &t.snapshot.Nodes[i]
		}
	}
	return nil
}

func (t *RunTracker) add(node AgentRunNode) {
	if t.node(node.ID) != nil {
		return
	}
	t.snapshot.Nodes = append(t.snapshot.Nodes, node)
	if node.ParentID != "" {
		t.edge(node.ParentID, node.ID, "delegation")
	}
}

func (t *RunTracker) edge(from, to, kind string) {
	edge := AgentRunEdge{From: from, To: to, Kind: kind}
	for _, existing := range t.snapshot.Edges {
		if existing == edge {
			return
		}
	}
	t.snapshot.Edges = append(t.snapshot.Edges, edge)
}

func (t *RunTracker) status(id, status, message string) {
	node := t.node(id)
	if node == nil {
		return
	}
	now := time.Now().UTC()
	node.Status, node.Message = status, message
	if status == "running" && node.StartedAt == nil {
		node.StartedAt = &now
	}
	switch status {
	case "completed", "failed", "skipped", "cancelled":
		node.FinishedAt = &now
	default:
		node.FinishedAt = nil
	}
}

func (t *RunTracker) StartPlanning() {
	t.change(func() {
		t.snapshot.Phase = "planning"
		t.add(AgentRunNode{ID: "root", Kind: "root", Title: "Orchestration", Status: "running", Order: 0})
		t.status("root", "running", "")
		t.add(AgentRunNode{ID: "head", ParentID: "root", Kind: "head", Title: "Head model selection", Status: "queued", Order: 10})
		t.add(AgentRunNode{ID: "agent", ParentID: "root", Kind: "agent", Title: "Orchestration assistant", Status: "queued", Order: 20})
		t.edge("head", "agent", "sequence")
	})
}

func (t *RunTracker) Agent(name, id, provider, model string) {
	t.change(func() {
		if node := t.node("agent"); node != nil {
			if name != "" {
				node.Title = progressTitle(name)
			}
			if id != "" {
				node.AgentID = progressMetadata(id)
			}
			if provider != "" {
				node.Provider = progressMetadata(provider)
			}
			if model != "" {
				node.Model = progressMetadata(model)
			}
		}
	})
}

func (t *RunTracker) Head(provider, model, status, message string) {
	t.change(func() {
		if node := t.node("head"); node != nil {
			node.Provider, node.Model = progressMetadata(provider), progressMetadata(model)
			t.status("head", status, message)
		}
	})
}

func progressMetadata(value string) string {
	if len(value) > 512 {
		return ""
	} // Omit, never invent a shortened model ID.
	return value
}

func progressTitle(value string) string {
	runes := []rune(value)
	if len(runes) > 128 {
		return string(runes[:128]) + "…"
	}
	return value
}

func (t *RunTracker) BeginAgent() {
	t.change(func() {
		// A legacy/global chat calls its configured model directly.
		if head := t.node("head"); head != nil && head.Status == "queued" {
			t.status("head", "skipped", "Using the global chat model directly")
		}
		t.status("agent", "running", "Preparing a response")
	})
}

func (t *RunTracker) FinishAgent(ctx context.Context, err error) {
	status, message := "completed", "Response prepared"
	if err != nil {
		status, message = "failed", "Response could not be prepared"
	}
	if ctx.Err() != nil {
		status, message = "cancelled", "Request cancelled"
	}
	t.change(func() { t.status("agent", status, message) })
}

func progressActionType(value string) (string, string) {
	switch value {
	case "list_devices":
		return value, "List devices"
	case "list_orchs":
		return value, "List orchestrations"
	case "get_metrics":
		return value, "Read device metrics"
	case "get_gpu":
		return value, "Read GPU metrics"
	case "recent_tasks":
		return value, "Read recent tasks"
	case "create_orch":
		return value, "Create orchestration"
	case "delete_orch":
		return value, "Delete orchestration"
	case "execute_command":
		return value, "Execute command"
	default:
		return "", "Unsupported action"
	}
}

func (t *RunTracker) planNodes(plan Plan, approved bool) {
	status := "waiting"
	if approved {
		status = "completed"
	}
	t.add(AgentRunNode{ID: "approval", ParentID: "agent", Kind: "approval", Title: "User approval", Status: status, Order: 30})
	t.status("approval", status, "")
	previous := "approval"
	for i, action := range plan.Actions {
		id := fmt.Sprintf("action-%d", i)
		actionType, title := progressActionType(action.Type)
		t.add(AgentRunNode{ID: id, ParentID: "agent", Kind: "action", Title: title, Status: "queued", Order: 40 + i, ActionType: actionType})
		t.edge(previous, id, "sequence")
		previous = id
	}
	t.add(AgentRunNode{ID: "summary", ParentID: "agent", Kind: "summary", Title: "Summarize results", Status: "queued", Order: 40 + len(plan.Actions)})
	t.edge(previous, "summary", "sequence")
}

func (t *RunTracker) CompleteChat(resp ChatResponse) {
	t.change(func() {
		if resp.Type == ChatTypePlan && resp.Plan != nil {
			t.planNodes(*resp.Plan, false)
			t.snapshot.Phase = "awaiting_approval"
			t.status("root", "waiting", "Waiting for an explicit Run")
		} else {
			t.snapshot.Phase = "completed"
			t.status("root", "completed", "Response completed")
		}
	})
}

func (t *RunTracker) StartExecution(plan Plan) {
	t.change(func() {
		t.snapshot.Phase = "executing"
		t.add(AgentRunNode{ID: "root", Kind: "root", Title: "Orchestration", Status: "running", Order: 0})
		t.status("root", "running", "Validating the approved plan")
		t.add(AgentRunNode{ID: "agent", ParentID: "root", Kind: "agent", Title: "Orchestration assistant", Status: "queued", Order: 20, Message: "Waiting for plan validation"})
		t.planNodes(plan, true)
	})
}

func (t *RunTracker) Action(index int, status, message string) {
	t.change(func() {
		if status == "running" {
			t.beginExecutionAgent()
		}
		t.status(fmt.Sprintf("action-%d", index), status, message)
	})
}

// This is the agent's approved execution workflow, including tools and summary;
// it does not imply a model call during tool dispatch. Action-running updates
// occur only after the use case's validation and cancellation guards succeed.
func (t *RunTracker) beginExecutionAgent() {
	if t.snapshot.Phase != "executing" {
		return
	}
	if node := t.node("agent"); node != nil && node.Status == "queued" {
		t.status("agent", "running", "Executing the approved plan")
	}
}

func (t *RunTracker) SkipActions(from, count int, message string) {
	t.change(func() {
		for i := from; i < count; i++ {
			t.status(fmt.Sprintf("action-%d", i), "skipped", message)
		}
		t.status("summary", "skipped", "Summary was not requested")
	})
}

func (t *RunTracker) Summary(status, message string) {
	t.change(func() {
		if status == "running" {
			t.beginExecutionAgent()
		}
		t.status("summary", status, message)
	})
}

func (t *RunTracker) CompleteExecution(resp ExecuteResponse) {
	t.change(func() {
		failed := false
		for _, result := range resp.Results {
			if result.Status != "ok" {
				failed = true
			}
		}
		for _, node := range t.snapshot.Nodes {
			if node.Status == "failed" || node.Status == "cancelled" {
				failed = true
			}
		}
		if summary := t.node("summary"); summary != nil && summary.Status == "queued" {
			t.status("summary", "skipped", "Summary was not requested")
		}
		if failed {
			t.snapshot.Phase = "failed"
			t.status("agent", "failed", "One or more execution steps did not complete")
			t.status("root", "failed", "One or more steps did not complete")
		} else {
			t.snapshot.Phase = "completed"
			t.status("agent", "completed", "Approved execution completed")
			t.status("root", "completed", "Execution completed")
		}
	})
}

// Fail uses static messages only. Callers must not pass upstream error text.
func (t *RunTracker) Fail(cancelled bool) {
	t.change(func() {
		phase, status, message := "failed", "failed", "Request failed"
		if cancelled {
			phase, status, message = "cancelled", "cancelled", "Request cancelled"
		}
		t.snapshot.Phase = phase
		for i := range t.snapshot.Nodes {
			node := t.snapshot.Nodes[i]
			switch node.Status {
			case "running", "waiting":
				t.status(node.ID, status, message)
			case "queued":
				if cancelled {
					t.status(node.ID, "cancelled", message)
				} else {
					t.status(node.ID, "skipped", "Step was not run")
				}
			}
		}
		t.status("root", status, message)
	})
}
