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
	llm         LLMClient
	actions     *ActionRegistry
	val         *Validator
	instruction string // user-defined system instruction, appended to prompts
}

func NewAgentUseCase(llm LLMClient, actions *ActionRegistry, val *Validator) *AgentUseCase {
	return &AgentUseCase{llm: llm, actions: actions, val: val}
}

// SetInstruction sets a user-defined instruction appended to the agent's and
// command assistant's system prompts. Empty clears it.
func (a *AgentUseCase) SetInstruction(s string) { a.instruction = s }

// Chat sends one user message + truncated history to the LLM and returns
// its structured reply. If the LLM proposes a plan, we run the validator
// up-front so the UI can disable Run when the plan is already stale.
// Validation issues are appended to the response message rather than
// dropped — the user (and the LLM in the next turn) can see them.
func (a *AgentUseCase) Chat(ctx context.Context, req ChatRequest) (ChatResponse, error) {
	if a.llm == nil {
		return ChatResponse{}, fmt.Errorf("chat agent: no LLM configured")
	}
	instruction := req.Instruction
	if instruction == "" {
		instruction = a.instruction
	}
	system := a.buildSystemPrompt(ctx, instruction)
	prompt := a.buildUserPrompt(req)
	resp, err := AskOnce(ctx, a.llm, system, prompt)
	if err != nil {
		return ChatResponse{}, err
	}
	if resp.Type == ChatTypePlan && resp.Plan != nil {
		errs := a.val.Validate(ctx, *resp.Plan)
		// Weaker models (e.g. GLM turbo variants) sometimes emit actions with
		// an empty or invented "type" that parse as JSON but fail validation.
		// Feed the concrete errors back for ONE corrective attempt before
		// surfacing them — most models fix it given the exact complaint.
		if len(errs) > 0 {
			repair := prompt + "\n\nYour previous plan failed validation:\n" + joinErrs(errs) +
				"\n\nReply again with a corrected plan. Every action's \"type\" must be one of the listed action types, copied exactly and non-empty."
			if resp2, err2 := AskOnce(ctx, a.llm, system, repair); err2 == nil &&
				resp2.Type == ChatTypePlan && resp2.Plan != nil {
				if errs2 := a.val.Validate(ctx, *resp2.Plan); len(errs2) == 0 {
					return resp2, nil
				} else {
					resp, errs = resp2, errs2
				}
			}
		}
		if len(errs) > 0 {
			resp.Message = resp.Message + "\n\n(plan has validation issues:\n" + joinErrs(errs) + ")"
		}
	}
	return resp, nil
}

func joinErrs(errs []error) string {
	notes := make([]string, 0, len(errs))
	for _, e := range errs {
		notes = append(notes, e.Error())
	}
	return strings.Join(notes, "\n")
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
	return ExecuteResponse{Results: results, Summary: a.summarizeResults(ctx, plan, results)}, nil
}

// summarizeResults asks the LLM for a short natural-language explanation of
// what the executed actions did and found, so the UI can show a human
// summary above the raw terminal output. Empty when no LLM is configured or
// the call fails — the raw results still stand on their own.
func (a *AgentUseCase) summarizeResults(ctx context.Context, plan Plan, results []ActionResult) string {
	if a.llm == nil || len(results) == 0 {
		return ""
	}
	var sb strings.Builder
	sb.WriteString("Intent: " + plan.Intent + "\n\nAction results:\n")
	for i, r := range results {
		fmt.Fprintf(&sb, "- action %d: %s [%s]\n", i+1, r.Type, r.Status)
		if r.Error != "" {
			sb.WriteString("  error: " + truncate(r.Error, 500) + "\n")
		} else if len(r.Output) > 0 {
			sb.WriteString("  output: " + truncate(string(r.Output), 1500) + "\n")
		}
	}
	system := "You explain the results of executed actions to a user in 1-3 plain, " +
		"natural-language sentences. State what was done and the key finding from the " +
		"output. Be concise and factual. No markdown, no code fences."
	out, err := a.llm.Complete(ctx, system, sb.String())
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "…(truncated)"
}

// buildSystemPrompt assembles the catalog + current device snapshot the
// LLM uses to ground its replies. Kept inside the agent package so all
// prompt evolution happens in one place.
func (a *AgentUseCase) buildSystemPrompt(ctx context.Context, instruction string) string {
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
	sb.WriteString("\nEvery action MUST be an object with a non-empty \"type\" copied EXACTLY from the list above and an \"args\" object (use {} when there are no args). Never emit an empty, abbreviated, or invented type.\n")
	sb.WriteString("Example reply for \"list devices\": {\"type\":\"plan\",\"message\":\"Listing devices.\",\"plan\":{\"intent\":\"list devices\",\"actions\":[{\"type\":\"list_devices\",\"args\":{}}]}}\n")
	sb.WriteString("Example reply for \"disk usage on sff\": {\"type\":\"plan\",\"message\":\"Checking disk usage on sff.\",\"plan\":{\"intent\":\"disk usage on sff\",\"actions\":[{\"type\":\"execute_command\",\"args\":{\"device_id\":\"<id>\",\"command\":\"df -h\"}}]}}\n")
	if a.actions != nil && a.actions.devices != nil {
		devs, _ := a.actions.devices.ListDevices(ctx, false)
		if len(devs) > 0 {
			sb.WriteString("\nCurrent devices (id — name — status):\n")
			for _, d := range devs {
				sb.WriteString("- " + d.ID + " — " + d.Name + " — " + string(d.Status) + "\n")
			}
		}
	}
	if instruction != "" {
		sb.WriteString("\nAdditional user instructions (follow these unless they conflict with safety):\n" + instruction + "\n")
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
