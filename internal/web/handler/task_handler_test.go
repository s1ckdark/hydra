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

func TestAPITaskCreateRejectsNegativeCPUCores(t *testing.T) {
	h, q := newTestHandlerWithQueue(t)

	body := `{"type":"command","payload":{"command":"echo hi"},` +
		`"resourceReqs":{"cpuCores":-1}}`
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

// APITaskUpdateStatus(cancelled) on an unassigned queued task must return
// 200 and must not panic even though h.wsHub is nil — the cancel-notify
// codepath is only entered when AssignedDeviceID != "" AND h.wsHub != nil,
// so an unassigned task should skip it entirely. Actual WS delivery to an
// assigned device needs a live hub and is out of scope here (reviewed by
// inspection instead — see task_handler.go APITaskUpdateStatus).
func TestAPITaskUpdateStatus_CancelUnassignedTask_NoWsHubNoPanic(t *testing.T) {
	h, q := newTestHandlerWithQueue(t)
	task := &domain.Task{ID: "t1", Status: domain.TaskStatusQueued}
	q.Enqueue(task)

	body := `{"status":"cancelled"}`
	req := httptest.NewRequest(http.MethodPut, "/api/tasks/t1/status", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("t1")

	if err := h.APITaskUpdateStatus(c); err != nil {
		t.Fatalf("APITaskUpdateStatus: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	var got domain.Task
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Status != domain.TaskStatusCancelled {
		t.Errorf("status = %v, want cancelled", got.Status)
	}
}

// A late cancel request against an already-terminal task (e.g. completed)
// must not panic and must not report the task as cancelled: the queue's
// terminal-state guard rejects the transition and returns the task
// unchanged, so the handler's response should reflect the task's actual
// (unchanged) status, not the requested one.
func TestAPITaskUpdateStatus_CancelAlreadyCompletedTask_StaysCompleted(t *testing.T) {
	h, q := newTestHandlerWithQueue(t)
	task := &domain.Task{ID: "t1", Status: domain.TaskStatusQueued}
	q.Enqueue(task)
	q.AssignToDevice("t1", "dev1", nil)
	q.UpdateStatus("t1", domain.TaskStatusCompleted)

	body := `{"status":"cancelled"}`
	req := httptest.NewRequest(http.MethodPut, "/api/tasks/t1/status", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("t1")

	if err := h.APITaskUpdateStatus(c); err != nil {
		t.Fatalf("APITaskUpdateStatus: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	var got domain.Task
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Status != domain.TaskStatusCompleted {
		t.Errorf("status = %v, want completed (terminal guard should reject the cancel)", got.Status)
	}
}

// --- D2: status whitelist validation ---
//
// An unknown status string (e.g. "bogus") must be rejected with 400 before
// it ever reaches h.taskQueue.UpdateStatus, so it can't be written into a
// task's Status field. A known status on a non-terminal task must still
// go through normally.

func TestAPITaskUpdateStatus_UnknownStatusRejected(t *testing.T) {
	h, q := newTestHandlerWithQueue(t)
	task := &domain.Task{ID: "t1", Status: domain.TaskStatusQueued}
	q.Enqueue(task)

	body := `{"status":"bogus"}`
	req := httptest.NewRequest(http.MethodPut, "/api/tasks/t1/status", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("t1")

	if err := h.APITaskUpdateStatus(c); err != nil {
		t.Fatalf("APITaskUpdateStatus: %v", err)
	}
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "invalid status: bogus") {
		t.Errorf("body = %s, want invalid-status error mentioning the bad value", rec.Body.String())
	}
	if got := q.Get("t1"); got == nil || got.Status != domain.TaskStatusQueued {
		t.Errorf("task status = %+v, want unchanged (queued)", got)
	}
}

func TestAPITaskUpdateStatus_KnownStatusAccepted(t *testing.T) {
	h, q := newTestHandlerWithQueue(t)
	task := &domain.Task{ID: "t1", Status: domain.TaskStatusQueued}
	q.Enqueue(task)

	body := `{"status":"running"}`
	req := httptest.NewRequest(http.MethodPut, "/api/tasks/t1/status", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("t1")

	if err := h.APITaskUpdateStatus(c); err != nil {
		t.Fatalf("APITaskUpdateStatus: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}

	var got domain.Task
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Status != domain.TaskStatusRunning {
		t.Errorf("status = %v, want running", got.Status)
	}
}
