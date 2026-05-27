package agent

import (
	"context"
	"testing"
)

func TestSanitizeCommand(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		want    string
		refused bool
	}{
		{"plain", "ls -la", "ls -la", false},
		{"fenced_bash", "```bash\nnvidia-smi\n```", "nvidia-smi", false},
		{"fenced_plain", "```\ndf -h\n```", "df -h", false},
		{"inline_backticks", "`uptime`", "uptime", false},
		{"dollar_prompt", "$ free -m", "free -m", false},
		{"multiline_takes_first", "top -bn1\n# explanation here", "top -bn1", false},
		{"leading_whitespace", "   whoami  ", "whoami", false},
		{"refused", "REFUSED: rm -rf is destructive", "", true},
		{"refused_lowercase_marker", "refused: too risky", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := sanitizeCommand(c.raw)
			if got.Refused != c.refused {
				t.Fatalf("refused = %v, want %v (raw %q)", got.Refused, c.refused, c.raw)
			}
			if !c.refused && got.Command != c.want {
				t.Fatalf("command = %q, want %q", got.Command, c.want)
			}
			if c.refused && got.Reason == "" {
				t.Fatalf("expected a refusal reason for %q", c.raw)
			}
		})
	}
}

func TestGenerateCommand_HappyPath(t *testing.T) {
	uc := NewAgentUseCase(&stubLLM{responses: []string{"```bash\nnvidia-smi --query-gpu=utilization.gpu --format=csv,noheader\n```"}}, nil, nil)
	resp, err := uc.GenerateCommand(context.Background(), CommandRequest{Prompt: "show gpu usage", OS: "Linux", DeviceName: "y-gpu-1"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if resp.Refused {
		t.Fatalf("unexpected refusal: %q", resp.Reason)
	}
	if resp.Command != "nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader" {
		t.Fatalf("command = %q", resp.Command)
	}
}

func TestGenerateCommand_Refusal(t *testing.T) {
	uc := NewAgentUseCase(&stubLLM{responses: []string{"REFUSED: wiping the disk is destructive"}}, nil, nil)
	resp, err := uc.GenerateCommand(context.Background(), CommandRequest{Prompt: "erase everything", OS: "Linux"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !resp.Refused || resp.Command != "" {
		t.Fatalf("expected refusal, got command %q refused=%v", resp.Command, resp.Refused)
	}
}

func TestGenerateCommand_EmptyPromptErrors(t *testing.T) {
	uc := NewAgentUseCase(&stubLLM{responses: []string{"ls"}}, nil, nil)
	if _, err := uc.GenerateCommand(context.Background(), CommandRequest{Prompt: "   "}); err == nil {
		t.Fatal("expected error for empty prompt")
	}
}

func TestGenerateCommand_NoLLMErrors(t *testing.T) {
	uc := NewAgentUseCase(nil, nil, nil)
	if _, err := uc.GenerateCommand(context.Background(), CommandRequest{Prompt: "ls"}); err == nil {
		t.Fatal("expected error when no LLM is configured")
	}
}
