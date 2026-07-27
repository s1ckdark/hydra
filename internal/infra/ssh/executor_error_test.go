package ssh

import (
	"errors"
	"strings"
	"testing"
)

func TestFirstNonEmptyLine(t *testing.T) {
	cases := []struct {
		name, in, want string
	}{
		{"empty", "", ""},
		{"whitespace only", "  \n\t\n", ""},
		// nvidia-smi는 NVML 실패 원인을 stdout으로 출력한다
		{"nvml mismatch", "Failed to initialize NVML: Driver/library version mismatch\nNVML library version: 595.84\n", "Failed to initialize NVML: Driver/library version mismatch"},
		{"leading blank lines", "\n\n  cause here\nrest", "cause here"},
	}
	for _, c := range cases {
		if got := firstNonEmptyLine(c.in); got != c.want {
			t.Errorf("%s: firstNonEmptyLine(%q) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func TestFirstNonEmptyLineTruncatesLongLines(t *testing.T) {
	long := strings.Repeat("x", 500)
	got := firstNonEmptyLine(long)
	if len(got) != 200 {
		t.Errorf("len = %d, want 200", len(got))
	}
}

func TestRemoteCommandErrorPrefersStderrThenStdout(t *testing.T) {
	base := errors.New("Process exited with status 18")

	// stderr가 있으면 stderr가 원인
	err := remoteCommandError(base, "stdout noise", "real cause\n")
	if got := err.Error(); got != "command error: real cause" {
		t.Errorf("stderr case = %q", got)
	}

	// stderr가 비면 stdout 첫 줄 + 원래 에러를 함께 표기
	err = remoteCommandError(base, "Failed to initialize NVML: Driver/library version mismatch\nNVML library version: 595.84", "")
	want := "command error: Failed to initialize NVML: Driver/library version mismatch (Process exited with status 18)"
	if got := err.Error(); got != want {
		t.Errorf("stdout case = %q, want %q", got, want)
	}

	// 둘 다 비면 원래 에러 그대로
	if got := remoteCommandError(base, "", "  \n"); !errors.Is(got, base) {
		t.Errorf("empty case should return base err, got %v", got)
	}
}
