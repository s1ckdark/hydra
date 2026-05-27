package agent

import (
	"context"
	"fmt"
	"strings"
)

// CommandRequest asks the assistant to turn a natural-language request
// into a single shell command for a target host.
type CommandRequest struct {
	Prompt     string `json:"prompt"`
	OS         string `json:"os"`         // "Linux"/"macOS"/… optional, improves accuracy
	DeviceName string `json:"deviceName"` // optional, for grounding only
}

// CommandResponse is the generated command, or a refusal when the model
// judged the request destructive.
type CommandResponse struct {
	Command string `json:"command"`
	Refused bool   `json:"refused"`
	Reason  string `json:"reason,omitempty"`
}

// GenerateCommand turns a natural-language request into one shell command
// via a single LLM round-trip. It never executes anything — the caller
// reviews the command and runs it through the normal execute path. The
// model is instructed to REFUSE destructive requests; sanitizeCommand is
// a second net that surfaces that refusal to the caller.
func (a *AgentUseCase) GenerateCommand(ctx context.Context, req CommandRequest) (CommandResponse, error) {
	if a.llm == nil {
		return CommandResponse{}, fmt.Errorf("command assistant: no LLM configured")
	}
	if strings.TrimSpace(req.Prompt) == "" {
		return CommandResponse{}, fmt.Errorf("empty prompt")
	}
	osName := strings.TrimSpace(req.OS)
	if osName == "" {
		osName = "Linux"
	}
	out, err := a.llm.Complete(ctx, commandSystemPrompt(osName, req.DeviceName), req.Prompt)
	if err != nil {
		return CommandResponse{}, fmt.Errorf("llm: %w", err)
	}
	return sanitizeCommand(out), nil
}

func commandSystemPrompt(osName, deviceName string) string {
	host := "a host"
	if strings.TrimSpace(deviceName) != "" {
		host = "the host '" + deviceName + "'"
	}
	return "You translate a natural-language request into a SINGLE shell command to run on " + host +
		" running " + osName + ".\n" +
		"Output ONLY the command on one line — no markdown, no backticks, no leading $ prompt, no explanation.\n" +
		"Prefer read-only, non-destructive commands. If the request is destructive or dangerous " +
		"(e.g. rm -rf, mkfs, dd onto a device, shutdown, reboot, fork bombs, overwriting system files), " +
		"reply with exactly: REFUSED: <short reason>."
}

// sanitizeCommand extracts a single clean command line from the model's
// raw text: strips ``` fences and inline backticks, drops a leading "$ "
// shell-prompt artifact, collapses to the first non-empty line, and
// surfaces an explicit REFUSED marker as a refusal.
func sanitizeCommand(raw string) CommandResponse {
	s := strings.TrimSpace(raw)

	// Strip a surrounding ``` fenced block, including an optional language tag.
	if strings.HasPrefix(s, "```") {
		s = strings.TrimPrefix(s, "```")
		if nl := strings.IndexByte(s, '\n'); nl >= 0 {
			s = s[nl+1:]
		}
		if i := strings.LastIndex(s, "```"); i >= 0 {
			s = s[:i]
		}
		s = strings.TrimSpace(s)
	}

	// First non-empty line.
	var line string
	for _, l := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(l); t != "" {
			line = t
			break
		}
	}

	line = strings.TrimSpace(strings.Trim(line, "`"))
	line = strings.TrimSpace(strings.TrimPrefix(line, "$ "))

	if strings.HasPrefix(strings.ToUpper(line), "REFUSED:") {
		return CommandResponse{
			Refused: true,
			Reason:  strings.TrimSpace(line[len("REFUSED:"):]),
		}
	}
	return CommandResponse{Command: line}
}
