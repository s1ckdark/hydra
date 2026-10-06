package handler

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

type streamLLMFunc func(context.Context, string, string) (string, error)

func (f streamLLMFunc) Complete(ctx context.Context, system, prompt string) (string, error) {
	return f(ctx, system, prompt)
}

type streamDevices struct{}

func (streamDevices) ListDevices(context.Context, bool) ([]*domain.Device, error) {
	return []*domain.Device{{ID: "a"}}, nil
}

type streamRunner struct {
	calls     int
	failFirst bool
}

func (r *streamRunner) ExecuteOnDevice(context.Context, string, string, int) (*domain.TaskResult, error) {
	r.calls++
	if r.failFirst && r.calls == 1 {
		return nil, errors.New("SECRET-ACTION-ERROR")
	}
	return &domain.TaskResult{Output: map[string]interface{}{"stdout": "SECRET-OUTPUT"}}, nil
}

func streamHandler(llm agent.LLMClient, runner agent.CommandRunner) *Handler {
	devices := streamDevices{}
	uc := agent.NewAgentUseCase(llm, agent.NewActionRegistry(devices, nil, nil, nil, runner, nil), agent.NewValidator(devices, nil))
	h := &Handler{}
	h.SetAgentUseCase(uc)
	return h
}

type decodedAgentEvent struct {
	name string
	data json.RawMessage
}

func agentEvents(t *testing.T, body string) []decodedAgentEvent {
	t.Helper()
	events := []decodedAgentEvent{}
	for _, block := range strings.Split(body, "\n\n") {
		if strings.TrimSpace(block) == "" {
			continue
		}
		lines := strings.Split(block, "\n")
		if len(lines) != 2 || !strings.HasPrefix(lines[0], "event: ") || !strings.HasPrefix(lines[1], "data: ") {
			t.Fatalf("invalid SSE frame: %q", block)
		}
		data := json.RawMessage(strings.TrimPrefix(lines[1], "data: "))
		if !json.Valid(data) {
			t.Fatal("invalid event JSON")
		}
		events = append(events, decodedAgentEvent{strings.TrimPrefix(lines[0], "event: "), data})
	}
	return events
}

func eventNode(snapshot agent.AgentRunSnapshot, id string) agent.AgentRunNode {
	for _, node := range snapshot.Nodes {
		if node.ID == id {
			return node
		}
	}
	return agent.AgentRunNode{}
}

func TestAgentStreamFlushesInitialProgressBeforeBlockedLLM(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	h := streamHandler(streamLLMFunc(func(ctx context.Context, _, _ string) (string, error) {
		close(entered)
		select {
		case <-release:
			return `{"type":"ask","message":"ready","run_id":"invented"}`, nil
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}), nil)
	e := echo.New()
	e.POST("/api/agent/chat", h.APIAgentChat)
	server := httptest.NewServer(e)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, server.URL+"/api/agent/chat?stream=1", strings.NewReader(`{"message":"hello"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.Header.Get("Content-Type") != "text/event-stream" || resp.Header.Get("Cache-Control") != "no-cache" {
		t.Fatal("stream headers missing")
	}
	reader := bufio.NewReader(resp.Body)
	first, err := reader.ReadString('\n')
	if err != nil || first != "event: progress\n" {
		t.Fatalf("initial event was not flushed: %q %v", first, err)
	}
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal("LLM was not entered")
	}
	close(release)
	rest, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	events := agentEvents(t, first+string(rest))
	last := events[len(events)-1]
	if last.name != "chat_result" {
		t.Fatalf("final event = %q", last.name)
	}
	var result agent.ChatResponse
	if err := json.Unmarshal(last.data, &result); err != nil {
		t.Fatal(err)
	}
	if _, err := uuid.Parse(result.RunID); err != nil || result.RunID == "invented" {
		t.Fatal("chat run_id was not server-generated")
	}
	for _, event := range events {
		if event.name == "progress" {
			var snapshot agent.AgentRunSnapshot
			_ = json.Unmarshal(event.data, &snapshot)
			if snapshot.RunID != result.RunID {
				t.Fatal("progress/result run IDs differ")
			}
			if eventNode(snapshot, "head").Status == "running" {
				t.Fatal("legacy chat invented a head call")
			}
		}
	}
}

func streamRequest(t *testing.T, h *Handler, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	var err error
	if strings.Contains(path, "/execute") {
		err = h.APIAgentExecute(c)
	} else {
		err = h.APIAgentChat(c)
	}
	if err != nil {
		t.Fatal(err)
	}
	return rec
}

func TestAgentStreamExecuteReusesRunIDAndReportsActualFailures(t *testing.T) {
	runner := &streamRunner{failFirst: true}
	h := streamHandler(streamLLMFunc(func(context.Context, string, string) (string, error) { return "Summary ready", nil }), runner)
	runID := uuid.NewString()
	body := `{"run_id":"` + runID + `","plan":{"intent":"SECRET-INTENT","actions":[{"type":"execute_command","args":{"device_id":"a","command":"echo SECRET-COMMAND"}},{"type":"execute_command","args":{"device_id":"a","command":"echo second"}}]}}`
	rec := streamRequest(t, h, "/api/agent/execute?stream=1", body)
	if rec.Code != 200 || !rec.Flushed || runner.calls != 2 {
		t.Fatalf("execute stream: code=%d calls=%d", rec.Code, runner.calls)
	}
	events := agentEvents(t, rec.Body.String())
	stages := []string{}
	var lastSnapshot agent.AgentRunSnapshot
	for _, event := range events {
		if event.name == "progress" {
			if strings.Contains(string(event.data), "SECRET-") {
				t.Fatal("snapshot leaked action data")
			}
			_ = json.Unmarshal(event.data, &lastSnapshot)
			if lastSnapshot.RunID != runID {
				t.Fatal("run_id not preserved")
			}
			for _, id := range []string{"action-0", "action-1", "summary"} {
				if eventNode(lastSnapshot, id).Status == "running" {
					stages = append(stages, id)
				}
			}
		}
	}
	if strings.Join(stages, ",") != "action-0,action-1,summary" {
		t.Fatalf("actual stage order = %v", stages)
	}
	if lastSnapshot.Phase != "failed" || eventNode(lastSnapshot, "action-0").Status != "failed" || eventNode(lastSnapshot, "action-1").Status != "completed" {
		t.Fatal("action failure marked run successful")
	}
	last := events[len(events)-1]
	if last.name != "execute_result" {
		t.Fatal("missing execute_result")
	}
	var result agent.ExecuteResponse
	_ = json.Unmarshal(last.data, &result)
	if result.RunID != runID || len(result.Results) != 2 || result.Summary != "Summary ready" {
		t.Fatalf("final result mismatch: %+v", result)
	}
}

func TestAgentStreamErrorsAreSanitizedAndNonstreamUnchanged(t *testing.T) {
	h := streamHandler(streamLLMFunc(func(context.Context, string, string) (string, error) {
		return "", errors.New("SECRET-UPSTREAM https://private.invalid/?key=SECRET")
	}), nil)
	rec := streamRequest(t, h, "/api/agent/chat?stream=1", `{"message":"hello"}`)
	if strings.Contains(rec.Body.String(), "SECRET") || strings.Contains(rec.Body.String(), "private.invalid") {
		t.Fatal("stream leaked provider error")
	}
	events := agentEvents(t, rec.Body.String())
	if events[len(events)-1].name != "error" {
		t.Fatal("missing error event")
	}
	var last agent.AgentRunSnapshot
	_ = json.Unmarshal(events[len(events)-2].data, &last)
	if last.Phase != "failed" || eventNode(last, "agent").Status != "failed" {
		t.Fatal("failure not reflected in progress")
	}
	h = streamHandler(streamLLMFunc(func(context.Context, string, string) (string, error) { return `{"type":"ask","message":"hello"}`, nil }), nil)
	rec = streamRequest(t, h, "/api/agent/chat", `{"message":"hello"}`)
	if rec.Code != 200 || strings.Contains(rec.Header().Get("Content-Type"), "event-stream") || strings.Contains(rec.Body.String(), "run_id") || strings.Contains(rec.Body.String(), "event:") {
		t.Fatalf("nonstream format changed: %s", rec.Body)
	}
	var result agent.ChatResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil || result.Message != "hello" {
		t.Fatal("nonstream result changed")
	}
}

type failingAgentWriter struct {
	header    http.Header
	body      bytes.Buffer
	failWrite func([]byte) bool
	failFlush bool
}

func (w *failingAgentWriter) Header() http.Header { return w.header }
func (w *failingAgentWriter) WriteHeader(int)     {}
func (w *failingAgentWriter) Write(data []byte) (int, error) {
	if w.failWrite != nil && w.failWrite(data) {
		return 0, errors.New("disconnected")
	}
	return w.body.Write(data)
}
func (w *failingAgentWriter) FlushError() error {
	if w.failFlush {
		return errors.New("flush disconnected")
	}
	return nil
}

func TestAgentStreamWriteAndFlushFailuresCancelBeforeFurtherActions(t *testing.T) {
	for _, mode := range []string{"initial-write", "initial-flush", "after-first-action"} {
		t.Run(mode, func(t *testing.T) {
			runner := &streamRunner{}
			summaryCalls := 0
			h := streamHandler(streamLLMFunc(func(context.Context, string, string) (string, error) { summaryCalls++; return "summary", nil }), runner)
			writer := &failingAgentWriter{header: make(http.Header), failFlush: mode == "initial-flush"}
			writer.failWrite = func(data []byte) bool {
				if mode == "initial-write" {
					return true
				}
				if mode != "after-first-action" {
					return false
				}
				text := string(data)
				start := strings.Index(text, "data: ")
				if start < 0 {
					return false
				}
				var snapshot agent.AgentRunSnapshot
				if json.Unmarshal([]byte(strings.TrimSpace(text[start+6:])), &snapshot) != nil {
					return false
				}
				return eventNode(snapshot, "action-0").Status == "completed"
			}
			req := httptest.NewRequest(http.MethodPost, "/api/agent/execute?stream=1", strings.NewReader(`{"plan":{"actions":[{"type":"execute_command","args":{"device_id":"a","command":"echo first"}},{"type":"execute_command","args":{"device_id":"a","command":"echo second"}}]}}`))
			req.Header.Set("Content-Type", "application/json")
			if err := h.APIAgentExecute(echo.New().NewContext(req, writer)); err != nil {
				t.Fatal(err)
			}
			want := 0
			if mode == "after-first-action" {
				want = 1
			}
			if runner.calls != want || summaryCalls != 0 {
				t.Fatalf("dispatch after disconnect: calls=%d summary=%d", runner.calls, summaryCalls)
			}
		})
	}
}

func TestAgentStreamClientCancellationReachesBlockedModel(t *testing.T) {
	entered, cancelled := make(chan struct{}), make(chan struct{})
	h := streamHandler(streamLLMFunc(func(ctx context.Context, _, _ string) (string, error) {
		close(entered)
		<-ctx.Done()
		close(cancelled)
		return "", ctx.Err()
	}), nil)
	e := echo.New()
	e.POST("/api/agent/chat", h.APIAgentChat)
	server := httptest.NewServer(e)
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, server.URL+"/api/agent/chat?stream=1", strings.NewReader(`{"message":"hello"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("model never started")
	}
	cancel()
	_ = resp.Body.Close()
	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("disconnect did not cancel provider request")
	}
}

func TestAgentStreamWriteDeadlineDoesNotExpireDuringIdleModelWork(t *testing.T) {
	h := streamHandler(streamLLMFunc(func(ctx context.Context, _, _ string) (string, error) {
		timer := time.NewTimer(5200 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-timer.C:
			return `{"type":"ask","message":"ready"}`, nil
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}), nil)
	e := echo.New()
	e.POST("/api/agent/chat", h.APIAgentChat)
	server := httptest.NewServer(e)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, server.URL+"/api/agent/chat?stream=1", strings.NewReader(`{"message":"hello"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil || !strings.Contains(string(body), "event: chat_result") {
		t.Fatalf("write deadline expired during model work: %v %s", err, body)
	}
}

func TestAgentStreamRejectsInvalidRunIDAndOversizedPlansBeforeExecution(t *testing.T) {
	runner := &streamRunner{}
	h := streamHandler(streamLLMFunc(func(context.Context, string, string) (string, error) {
		t.Error("unexpected model call")
		return "", nil
	}), runner)
	actions := make([]agent.Action, agent.MaxProgressActions+1)
	for i := range actions {
		actions[i] = agent.Action{Type: "list_devices", Args: json.RawMessage(`{}`)}
	}
	largePlan, _ := json.Marshal(agent.ExecuteRequest{Plan: agent.Plan{Actions: actions}})
	for _, body := range []string{`{"run_id":"SECRET-invalid","plan":{"actions":[]}}`, string(largePlan), `{"message":"` + strings.Repeat("x", 1<<20) + `"}`} {
		rec := streamRequest(t, h, "/api/agent/execute?stream=1", body)
		if rec.Code != 400 || rec.Flushed || strings.Contains(rec.Body.String(), "SECRET") || runner.calls != 0 {
			t.Fatalf("invalid stream opened or executed: %d %s", rec.Code, rec.Body)
		}
	}
	response, _ := json.Marshal(agent.ChatResponse{Type: agent.ChatTypePlan, Plan: &agent.Plan{Actions: actions}})
	h = streamHandler(streamLLMFunc(func(context.Context, string, string) (string, error) { return string(response), nil }), runner)
	rec := streamRequest(t, h, "/api/agent/chat?stream=1", `{"message":"plan"}`)
	if strings.Contains(rec.Body.String(), `"phase":"awaiting_approval"`) || strings.Contains(rec.Body.String(), "event: chat_result") || !strings.Contains(rec.Body.String(), "event: error") || runner.calls != 0 {
		t.Fatal("oversized generated plan reached approval")
	}
}
