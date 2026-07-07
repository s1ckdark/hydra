package domain

import (
	"reflect"
	"testing"
	"time"
)

func newTask(id string, priority TaskPriority) *Task {
	return &Task{ID: id, Priority: priority}
}

func TestListQueuedByPriority_OrderedUrgentFirst(t *testing.T) {
	q := NewTaskQueue()
	q.Enqueue(newTask("a", TaskPriorityNormal))
	q.Enqueue(newTask("b", TaskPriorityUrgent))
	q.Enqueue(newTask("c", TaskPriorityLow))
	q.Enqueue(newTask("d", TaskPriorityHigh))

	got := q.ListQueuedByPriority()
	if len(got) != 4 {
		t.Fatalf("expected 4 queued, got %d", len(got))
	}
	order := []string{got[0].ID, got[1].ID, got[2].ID, got[3].ID}
	want := []string{"b", "d", "a", "c"}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("priority order wrong: got %v want %v", order, want)
		}
	}
}

func TestListQueuedByPriority_SkipsNonQueued(t *testing.T) {
	q := NewTaskQueue()
	q.Enqueue(newTask("a", TaskPriorityNormal))
	q.Enqueue(newTask("b", TaskPriorityNormal))
	q.AssignToDevice("a", "dev-1", nil)

	got := q.ListQueuedByPriority()
	if len(got) != 1 || got[0].ID != "b" {
		t.Fatalf("expected only b, got %+v", got)
	}
}

func TestAssignToDevice_MovesToAssigned(t *testing.T) {
	q := NewTaskQueue()
	q.Enqueue(newTask("a", TaskPriorityNormal))

	assigned := q.AssignToDevice("a", "dev-1", nil)
	if assigned == nil {
		t.Fatal("expected task to be assigned")
	}
	if assigned.Status != TaskStatusAssigned {
		t.Fatalf("expected status assigned, got %s", assigned.Status)
	}
	if assigned.AssignedDeviceID != "dev-1" {
		t.Fatalf("expected device dev-1, got %s", assigned.AssignedDeviceID)
	}
	if assigned.AssignedAt == nil {
		t.Fatal("expected AssignedAt to be set")
	}
	if q.PendingCount() != 0 {
		t.Fatalf("expected empty queue, got %d pending", q.PendingCount())
	}
}

func TestAssignToDevice_ReturnsNilWhenNotQueued(t *testing.T) {
	q := NewTaskQueue()
	q.Enqueue(newTask("a", TaskPriorityNormal))
	q.AssignToDevice("a", "dev-1", nil)

	// Second attempt on same task — already assigned.
	if got := q.AssignToDevice("a", "dev-2", nil); got != nil {
		t.Fatalf("expected nil for already-assigned task, got %+v", got)
	}
	// Unknown task.
	if got := q.AssignToDevice("missing", "dev-1", nil); got != nil {
		t.Fatalf("expected nil for unknown task, got %+v", got)
	}
}

func TestReassignTasksFromDevice_PopulatesBlockedIDs(t *testing.T) {
	q := NewTaskQueue()
	t1 := newTask("t1", TaskPriorityNormal)
	t1.MaxRetries = 2
	q.Enqueue(t1)
	q.AssignToDevice("t1", "dev-a", nil)

	q.ReassignTasksFromDevice("dev-a")

	got := q.Get("t1")
	if got == nil {
		t.Fatal("task should still exist")
	}
	if got.Status != TaskStatusQueued {
		t.Fatalf("expected requeued, got %s", got.Status)
	}
	if len(got.BlockedDeviceIDs) != 1 || got.BlockedDeviceIDs[0] != "dev-a" {
		t.Fatalf("expected blocked=[dev-a], got %v", got.BlockedDeviceIDs)
	}

	// Second failure on different worker accumulates the block list.
	q.AssignToDevice("t1", "dev-b", nil)
	q.ReassignTasksFromDevice("dev-b")
	got = q.Get("t1")
	if len(got.BlockedDeviceIDs) != 2 {
		t.Fatalf("expected 2 blocked, got %v", got.BlockedDeviceIDs)
	}
}

func TestAttachAssigned_AddsToTasksMapNotQueue(t *testing.T) {
	q := NewTaskQueue()
	task := newTask("t1", TaskPriorityNormal)
	task.Status = TaskStatusAssigned
	task.AssignedDeviceID = "dev-1"

	q.AttachAssigned(task)

	if got := q.Get("t1"); got == nil {
		t.Fatal("Get should return the task after AttachAssigned")
	}
	if pending := q.ListQueuedByPriority(); len(pending) != 0 {
		t.Errorf("ListQueuedByPriority should be empty after AttachAssigned, got %d", len(pending))
	}
	assigned := q.GetAssignedTasks("dev-1")
	if len(assigned) != 1 || assigned[0].ID != "t1" {
		t.Errorf("GetAssignedTasks(dev-1) = %v; want [t1]", assigned)
	}
}

func TestAttachAssigned_DoesNotPersist(t *testing.T) {
	r := &recordingRepo{}
	q := NewTaskQueue().WithRepo(r)

	task := newTask("t1", TaskPriorityNormal)
	task.Status = TaskStatusRunning
	q.AttachAssigned(task)

	if got := r.count(); got != 0 {
		t.Errorf("AttachAssigned should not call repo.Save; got %d calls", got)
	}
}

func TestReplay_PreservesStatusAndCreatedAt(t *testing.T) {
	q := NewTaskQueue()
	created := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)

	// A task as it would be loaded from sqlite: explicit CreatedAt and
	// Status TaskStatusPending. Enqueue would overwrite both; Replay must not.
	task := &Task{
		ID:        "t1",
		Priority:  TaskPriorityNormal,
		Status:    TaskStatusPending,
		CreatedAt: created,
	}

	q.Replay(task)

	got := q.Get("t1")
	if got == nil {
		t.Fatal("Replay did not place task in tasks map")
	}
	if got.Status != TaskStatusPending {
		t.Errorf("Replay mutated Status: got %q, want %q (Pending)", got.Status, TaskStatusPending)
	}
	if !got.CreatedAt.Equal(created) {
		t.Errorf("Replay mutated CreatedAt: got %v, want %v", got.CreatedAt, created)
	}
}

func TestAssignToDeviceRecordsGPUIndexes(t *testing.T) {
	q := NewTaskQueue()
	task := &Task{ID: "t1", Type: "command", Status: TaskStatusPending, Priority: TaskPriorityNormal}
	q.Enqueue(task)
	got := q.AssignToDevice("t1", "gpu1", []int{0, 3})
	if got == nil {
		t.Fatal("assign returned nil")
	}
	if !reflect.DeepEqual(got.AssignedGPUIndexes, []int{0, 3}) {
		t.Fatalf("indexes = %v", got.AssignedGPUIndexes)
	}
}

func TestReassignClearsGPUIndexes(t *testing.T) {
	q := NewTaskQueue()
	task := &Task{ID: "t1", Type: "command", Status: TaskStatusPending,
		Priority: TaskPriorityNormal, MaxRetries: 3}
	q.Enqueue(task)
	q.AssignToDevice("t1", "gpu1", []int{2})
	reassigned := q.ReassignTasksFromDevice("gpu1")
	if len(reassigned) != 1 {
		t.Fatalf("reassigned = %d", len(reassigned))
	}
	if len(reassigned[0].AssignedGPUIndexes) != 0 {
		t.Fatalf("indexes not cleared: %v", reassigned[0].AssignedGPUIndexes)
	}
}

func TestReplay_AddsToPriorityQueue(t *testing.T) {
	q := NewTaskQueue()
	q.Replay(&Task{ID: "t1", Priority: TaskPriorityHigh, Status: TaskStatusQueued})
	q.Replay(&Task{ID: "t2", Priority: TaskPriorityLow, Status: TaskStatusQueued})

	pending := q.ListQueuedByPriority()
	if len(pending) != 2 {
		t.Fatalf("ListQueuedByPriority = %d; want 2", len(pending))
	}
	// High priority must come first.
	if pending[0].ID != "t1" {
		t.Errorf("priority order broken: got %v", []string{pending[0].ID, pending[1].ID})
	}
}

func TestReplay_DoesNotPersist(t *testing.T) {
	r := &recordingRepo{}
	q := NewTaskQueue().WithRepo(r)

	q.Replay(&Task{ID: "t1", Priority: TaskPriorityNormal, Status: TaskStatusQueued})

	if r.count() != 0 {
		t.Errorf("Replay should not call repo.Save; got %d", r.count())
	}
}

// --- A1: terminal-state guards ---
//
// A late worker report must not resurrect a task the server already
// considers terminal (cancelled/failed), except for the one worker
// contract we must preserve: completed -> failed (the worker reports a
// result first, which sets completed, then overrides with failed on a
// nonzero exit code).

func TestSetResult_CancelledTaskStaysCancelled(t *testing.T) {
	q := NewTaskQueue()
	task := newTask("t1", TaskPriorityNormal)
	task.Status = TaskStatusCancelled
	q.AttachAssigned(task)

	got := q.SetResult("t1", &TaskResult{Output: map[string]interface{}{"x": 1}})
	if got == nil {
		t.Fatal("SetResult returned nil")
	}
	if got.Status != TaskStatusCancelled {
		t.Errorf("status = %v, want cancelled", got.Status)
	}
	if got.Result != nil {
		t.Errorf("Result = %+v, want nil (late result must not attach)", got.Result)
	}
}

func TestUpdateStatus_CancelledTaskRejectsRunning(t *testing.T) {
	q := NewTaskQueue()
	task := newTask("t1", TaskPriorityNormal)
	task.Status = TaskStatusCancelled
	q.AttachAssigned(task)

	got := q.UpdateStatus("t1", TaskStatusRunning)
	if got == nil {
		t.Fatal("UpdateStatus returned nil")
	}
	if got.Status != TaskStatusCancelled {
		t.Errorf("status = %v, want cancelled (terminal guard should reject running)", got.Status)
	}
}

func TestUpdateStatus_CompletedToFailedAllowed(t *testing.T) {
	q := NewTaskQueue()
	task := newTask("t1", TaskPriorityNormal)
	task.Status = TaskStatusCompleted
	q.AttachAssigned(task)

	got := q.UpdateStatus("t1", TaskStatusFailed)
	if got == nil {
		t.Fatal("UpdateStatus returned nil")
	}
	if got.Status != TaskStatusFailed {
		t.Errorf("status = %v, want failed (completed->failed worker contract must keep working)", got.Status)
	}
}

func TestSetResult_FailedTaskStaysFailed(t *testing.T) {
	q := NewTaskQueue()
	task := newTask("t1", TaskPriorityNormal)
	task.Status = TaskStatusFailed
	q.AttachAssigned(task)

	got := q.SetResult("t1", &TaskResult{Output: map[string]interface{}{"x": 1}})
	if got == nil {
		t.Fatal("SetResult returned nil")
	}
	if got.Status != TaskStatusFailed {
		t.Errorf("status = %v, want failed", got.Status)
	}
	if got.Result != nil {
		t.Errorf("Result = %+v, want nil (late result must not attach)", got.Result)
	}
}
