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

// AgentUseCase wires the LLM to the action registry + validator.
// Stateless across requests — history flows entirely through the
// request body.
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
// Validation issues are appended to the response message rather than
// dropped — the user (and the LLM in the next turn) can see them.
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
			var notes []string
			for _, e := range errs {
				notes = append(notes, e.Error())
			}
			resp.Message = resp.Message + "\n\n(plan has validation issues:\n" + strings.Join(notes, "\n") + ")"
		}
	}
	return resp, nil
}

// Execute re-validates the plan per-action and runs each. Per-action
// errors don't abort the rest — every action gets a status in the
// response.
func (a *AgentUseCase) Execute(ctx context.Context, plan Plan) (ExecuteResponse, error) {
	results := make([]ActionResult, 0, len(plan.Actions))
	for _, action := range plan.Actions {
		if perActionErr := a.val.Validate(ctx, Plan{Actions: []Action{action}}); len(perActionErr) > 0 {
			results = append(results, ActionResult{
				Type:   action.Type,
				Status: "error",
				Error:  perActionErr[0].Error(),
			})
			continue
		}
		results = append(results, a.actions.Run(ctx, action))
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
