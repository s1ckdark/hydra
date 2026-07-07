package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/internal/domain"
)

// newTestHandlerWithQueue builds a Handler wired only with an in-memory
// TaskQueue, following the same lightweight construction pattern used by
// task_group_handler_test.go (no DB/sqlite in this package's test graph).
func newTestHandlerWithQueue(t *testing.T) (*Handler, *domain.TaskQueue) {
	t.Helper()
	tq := domain.NewTaskQueue()
	h := &Handler{taskQueue: tq}
	return h, tq
}

func TestAPITaskCreateBindsResourceReqs(t *testing.T) {
	h, q := newTestHandlerWithQueue(t)

	body := `{"type":"command","payload":{"command":"echo hi"},` +
		`"resourceReqs":{"gpuMemoryMB":16000,"gpuCount":2,"cpuCores":4,"memoryMB":8192}}`
	req := httptest.NewRequest(http.MethodPost, "/api/tasks", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	if err := h.APITaskCreate(c); err != nil {
		t.Fatalf("APITaskCreate: %v", err)
	}
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}

	var got domain.Task
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	r := got.ResourceReqs
	if r == nil {
		t.Fatal("ResourceReqs not bound (nil)")
	}
	if r.GPUMemoryMB != 16000 || r.GPUCount != 2 || r.CPUCores != 4 || r.MemoryMB != 8192 {
		t.Fatalf("ResourceReqs = %+v", r)
	}
	// 큐에 들어간 task 에도 반영됐는지 확인
	if in := q.Get(got.ID); in == nil || in.ResourceReqs == nil || in.ResourceReqs.GPUCount != 2 {
		t.Fatalf("queued task ResourceReqs = %+v", in)
	}
}

func TestAPITaskCreateRejectsNegativeResourceReqs(t *testing.T) {
	h, q := newTestHandlerWithQueue(t)

	body := `{"type":"command","payload":{"command":"echo hi"},` +
		`"resourceReqs":{"gpuCount":-1}}`
	req := httptest.NewRequest(http.MethodPost, "/api/tasks", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	if err := h.APITaskCreate(c); err != nil {
		t.Fatalf("APITaskCreate: %v", err)
	}
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "negative values not allowed") {
		t.Errorf("body = %s, want negative-values error", rec.Body.String())
	}
	if q.PendingCount() != 0 {
		t.Errorf("task should not be enqueued, queue = %d", q.PendingCount())
	}
}
