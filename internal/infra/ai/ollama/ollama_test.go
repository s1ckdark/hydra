package ollama

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/infra/ai"
)

// --- Unit tests (mock server) ---

func newMockOllama(t *testing.T, response string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/chat":
			if r.Method != http.MethodPost {
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			var req chatRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				http.Error(w, "bad request", http.StatusBadRequest)
				return
			}
			resp := chatResponse{
				Model:   req.Model,
				Message: message{Role: "assistant", Content: response},
				Done:    true,
			}
			json.NewEncoder(w).Encode(resp)

		case "/api/tags":
			json.NewEncoder(w).Encode(map[string]interface{}{
				"models": []ModelInfo{
					{Name: "test-model:7b", Model: "test-model:7b", Size: 4000000000,
						Details: ModelDetails{Family: "test", ParameterSize: "7B", QuantizationLevel: "Q4_K_M"}},
				},
			})

		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	}))
}

func TestNewProvider_Defaults(t *testing.T) {
	p := NewProvider("", "")
	if p.endpoint != defaultEndpoint {
		t.Errorf("expected default endpoint %q, got %q", defaultEndpoint, p.endpoint)
	}
	if p.model != defaultModel {
		t.Errorf("expected default model %q, got %q", defaultModel, p.model)
	}
}

func TestNewProvider_Custom(t *testing.T) {
	p := NewProvider("http://gpu:11434", "qwen3.5:9b")
	if p.endpoint != "http://gpu:11434" {
		t.Errorf("expected custom endpoint, got %q", p.endpoint)
	}
	if p.model != "qwen3.5:9b" {
		t.Errorf("expected custom model, got %q", p.model)
	}
}

func TestSelectHead_Mock(t *testing.T) {
	server := newMockOllama(t, `{"node_id": "worker-2", "reason": "lowest GPU utilization"}`)
	defer server.Close()

	p := NewProvider(server.URL, "test-model")
	candidates := []domain.ElectionCandidate{
		{NodeID: "worker-1", GPUUtilization: 80, MemoryFreeGB: 4},
		{NodeID: "worker-2", GPUUtilization: 20, MemoryFreeGB: 16},
	}

	nodeID, reason, err := p.SelectHead(context.Background(), candidates)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if nodeID != "worker-2" {
		t.Errorf("expected worker-2, got %s", nodeID)
	}
	if reason == "" {
		t.Error("expected non-empty reason")
	}
}

func TestScheduleTask_Mock(t *testing.T) {
	server := newMockOllama(t, `{"device_id": "device-1", "reason": "most free GPU", "confidence": 0.85}`)
	defer server.Close()

	p := NewProvider(server.URL, "test-model")
	task := &domain.Task{
		ID:   "task-1",
		Type: "command",
	}
	workers := []ai.WorkerSnapshot{
		{DeviceID: "device-1", GPUUtilization: 10, MemoryFreeGB: 24, CPUUsage: 30},
		{DeviceID: "device-2", GPUUtilization: 70, MemoryFreeGB: 8, CPUUsage: 60},
	}

	decision, err := p.ScheduleTask(context.Background(), task, workers)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if decision.DeviceID != "device-1" {
		t.Errorf("expected device-1, got %s", decision.DeviceID)
	}
	if decision.Confidence != 0.85 {
		t.Errorf("expected confidence 0.85, got %f", decision.Confidence)
	}
}

func TestEstimateCapacity_Mock(t *testing.T) {
	server := newMockOllama(t, `{"available_gpu_percent": 70, "available_memory_gb": 12.5, "estimated_slots": 3, "bottleneck": "gpu", "recommendation": "can handle more tasks"}`)
	defer server.Close()

	p := NewProvider(server.URL, "test-model")
	worker := ai.WorkerSnapshot{
		DeviceID: "device-1", GPUUtilization: 30, MemoryFreeGB: 12.5, CPUUsage: 20,
	}

	estimate, err := p.EstimateCapacity(context.Background(), worker, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if estimate.EstimatedSlots != 3 {
		t.Errorf("expected 3 slots, got %d", estimate.EstimatedSlots)
	}
	if estimate.Bottleneck != "gpu" {
		t.Errorf("expected bottleneck gpu, got %s", estimate.Bottleneck)
	}
}

func TestHealth_Mock(t *testing.T) {
	server := newMockOllama(t, "")
	defer server.Close()

	p := NewProvider(server.URL, "test-model")
	if err := p.Health(context.Background()); err != nil {
		t.Fatalf("health check failed: %v", err)
	}
}

func TestHealth_Unreachable(t *testing.T) {
	p := NewProvider("http://localhost:1", "test-model")
	err := p.Health(context.Background())
	if err == nil {
		t.Error("expected error for unreachable server")
	}
}

func TestListModels_Mock(t *testing.T) {
	server := newMockOllama(t, "")
	defer server.Close()

	p := NewProvider(server.URL, "test-model")
	models, err := p.ListModels(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(models) != 1 {
		t.Fatalf("expected 1 model, got %d", len(models))
	}
	if models[0].Name != "test-model:7b" {
		t.Errorf("expected test-model:7b, got %s", models[0].Name)
	}
}

func TestChat_EmptyResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(chatResponse{
			Model:   "test",
			Message: message{Role: "assistant", Content: ""},
			Done:    true,
		})
	}))
	defer server.Close()

	p := NewProvider(server.URL, "test-model")
	_, _, err := p.SelectHead(context.Background(), []domain.ElectionCandidate{
		{NodeID: "w1"},
	})
	if err == nil {
		t.Error("expected error for empty response")
	}
}

func TestChat_ServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "internal error", http.StatusInternalServerError)
	}))
	defer server.Close()

	p := NewProvider(server.URL, "test-model")
	_, _, err := p.SelectHead(context.Background(), []domain.ElectionCandidate{
		{NodeID: "w1"},
	})
	if err == nil {
		t.Error("expected error for server error response")
	}
}

func TestChat_InvalidJSON(t *testing.T) {
	server := newMockOllama(t, `not valid json`)
	defer server.Close()

	p := NewProvider(server.URL, "test-model")
	_, _, err := p.SelectHead(context.Background(), []domain.ElectionCandidate{
		{NodeID: "w1"},
	})
	if err == nil {
		t.Error("expected error for invalid JSON response")
	}
}

// --- Integration tests (real Ollama server) ---

func TestIntegration_SelectHead(t *testing.T) {
	if os.Getenv("OLLAMA_INTEGRATION") == "" {
		t.Skip("set OLLAMA_INTEGRATION=1 to run integration tests")
	}

	endpoint := os.Getenv("OLLAMA_ENDPOINT")
	if endpoint == "" {
		endpoint = "http://localhost:11434"
	}
	model := os.Getenv("OLLAMA_MODEL")
	if model == "" {
		model = "gpt-oss:20b"
	}

	p := NewProvider(endpoint, model)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Health check first
	if err := p.Health(ctx); err != nil {
		t.Fatalf("ollama not reachable: %v", err)
	}

	candidates := []domain.ElectionCandidate{
		{NodeID: "gpu-node-1", GPUUtilization: 80, MemoryFreeGB: 4, RunningJobs: 5},
		{NodeID: "gpu-node-2", GPUUtilization: 20, MemoryFreeGB: 32, RunningJobs: 1},
		{NodeID: "gpu-node-3", GPUUtilization: 50, MemoryFreeGB: 16, RunningJobs: 3},
	}

	nodeID, reason, err := p.SelectHead(ctx, candidates)
	if err != nil {
		t.Fatalf("SelectHead failed: %v", err)
	}

	t.Logf("Selected: %s, Reason: %s", nodeID, reason)

	// Verify the response is one of the candidates
	valid := false
	for _, c := range candidates {
		if c.NodeID == nodeID {
			valid = true
			break
		}
	}
	if !valid {
		t.Errorf("selected node %q is not in candidates", nodeID)
	}
}

func TestIntegration_ScheduleTask(t *testing.T) {
	if os.Getenv("OLLAMA_INTEGRATION") == "" {
		t.Skip("set OLLAMA_INTEGRATION=1 to run integration tests")
	}

	endpoint := os.Getenv("OLLAMA_ENDPOINT")
	if endpoint == "" {
		endpoint = "http://localhost:11434"
	}
	model := os.Getenv("OLLAMA_MODEL")
	if model == "" {
		model = "gpt-oss:20b"
	}

	p := NewProvider(endpoint, model)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	task := &domain.Task{
		ID:                   "task-gpu-render",
		Type:                 "command",
		RequiredCapabilities: []string{"gpu"},
	}
	workers := []ai.WorkerSnapshot{
		{DeviceID: "device-a", Capabilities: []string{"gpu", "nvenc"}, GPUUtilization: 10, MemoryFreeGB: 24, CPUUsage: 15, GPUCount: 2},
		{DeviceID: "device-b", Capabilities: []string{"gpu"}, GPUUtilization: 85, MemoryFreeGB: 4, CPUUsage: 70, GPUCount: 1},
	}

	decision, err := p.ScheduleTask(ctx, task, workers)
	if err != nil {
		t.Fatalf("ScheduleTask failed: %v", err)
	}

	t.Logf("Decision: device=%s, reason=%s, confidence=%.2f", decision.DeviceID, decision.Reason, decision.Confidence)

	if decision.DeviceID != "device-a" && decision.DeviceID != "device-b" {
		t.Errorf("unexpected device_id %q", decision.DeviceID)
	}
	if decision.Confidence < 0 || decision.Confidence > 1 {
		t.Errorf("confidence %.2f out of range [0,1]", decision.Confidence)
	}
}

func TestIntegration_ListModels(t *testing.T) {
	if os.Getenv("OLLAMA_INTEGRATION") == "" {
		t.Skip("set OLLAMA_INTEGRATION=1 to run integration tests")
	}

	endpoint := os.Getenv("OLLAMA_ENDPOINT")
	if endpoint == "" {
		endpoint = "http://localhost:11434"
	}

	p := NewProvider(endpoint, "")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	models, err := p.ListModels(ctx)
	if err != nil {
		t.Fatalf("ListModels failed: %v", err)
	}

	t.Logf("Available models: %d", len(models))
	for _, m := range models {
		t.Logf("  - %s (%s, %s)", m.Name, m.Details.ParameterSize, m.Details.QuantizationLevel)
	}

	if len(models) == 0 {
		t.Error("expected at least one model")
	}
}
