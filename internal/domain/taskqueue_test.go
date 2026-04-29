package domain

import (
	"testing"
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
	q.AssignToDevice("a", "dev-1")

	got := q.ListQueuedByPriority()
	if len(got) != 1 || got[0].ID != "b" {
		t.Fatalf("expected only b, got %+v", got)
	}
}

func TestAssignToDevice_MovesToAssigned(t *testing.T) {
	q := NewTaskQueue()
	q.Enqueue(newTask("a", TaskPriorityNormal))

	assigned := q.AssignToDevice("a", "dev-1")
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
	q.AssignToDevice("a", "dev-1")

	// Second attempt on same task — already assigned.
	if got := q.AssignToDevice("a", "dev-2"); got != nil {
		t.Fatalf("expected nil for already-assigned task, got %+v", got)
	}
	// Unknown task.
	if got := q.AssignToDevice("missing", "dev-1"); got != nil {
		t.Fatalf("expected nil for unknown task, got %+v", got)
	}
}

func TestReassignTasksFromDevice_PopulatesBlockedIDs(t *testing.T) {
	q := NewTaskQueue()
	t1 := newTask("t1", TaskPriorityNormal)
	t1.MaxRetries = 2
	q.Enqueue(t1)
	q.AssignToDevice("t1", "dev-a")

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
	q.AssignToDevice("t1", "dev-b")
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
