package sqlite

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

func newTaskRepoForTest(t *testing.T) *TaskRepository {
	t.Helper()
	db, err := NewDB(":memory:")
	if err != nil {
		t.Fatalf("NewDB: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return NewTaskRepository(db.db)
}

func TestTaskRepo_SaveInsertThenUpdate(t *testing.T) {
	r := newTaskRepoForTest(t)
	ctx := context.Background()

	task := &domain.Task{
		ID: "t1", Type: "shell", Status: domain.TaskStatusQueued,
		Priority:  domain.TaskPriorityNormal,
		Payload:   map[string]interface{}{"cmd": "echo a"},
		CreatedAt: time.Now().UTC().Truncate(time.Second),
	}
	if err := r.Save(ctx, task); err != nil {
		t.Fatalf("insert: %v", err)
	}

	task.Status = domain.TaskStatusCompleted
	task.AssignedDeviceID = "dev-1"
	if err := r.Save(ctx, task); err != nil {
		t.Fatalf("update: %v", err)
	}

	got, err := r.GetByID(ctx, "t1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Status != domain.TaskStatusCompleted || got.AssignedDeviceID != "dev-1" {
		t.Errorf("after update: %+v", got)
	}
}

func TestTaskRepo_JSONFieldRoundtrip(t *testing.T) {
	r := newTaskRepoForTest(t)
	ctx := context.Background()

	task := &domain.Task{
		ID: "t2", Type: "infer", Status: domain.TaskStatusQueued,
		Priority:             domain.TaskPriorityHigh,
		RequiredCapabilities: []string{"gpu", "cuda"},
		BlockedDeviceIDs:     []string{"bad-1"},
		Payload:              map[string]interface{}{"input": "x", "n": float64(42)},
		ResourceReqs:         &domain.ResourceRequirements{GPUMemoryMB: 16000, CPUCores: 4},
	}
	if err := r.Save(ctx, task); err != nil {
		t.Fatalf("save: %v", err)
	}
	got, err := r.GetByID(ctx, "t2")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if len(got.RequiredCapabilities) != 2 || got.RequiredCapabilities[0] != "gpu" {
		t.Errorf("RequiredCapabilities lost: %v", got.RequiredCapabilities)
	}
	if got.Payload["n"] != float64(42) {
		t.Errorf("Payload lost: %v", got.Payload)
	}
	if got.ResourceReqs == nil || got.ResourceReqs.GPUMemoryMB != 16000 {
		t.Errorf("ResourceReqs lost: %+v", got.ResourceReqs)
	}
}

func TestTaskRepo_AISchedulePointerEncoding(t *testing.T) {
	r := newTaskRepoForTest(t)
	ctx := context.Background()
	tru, fal := true, false

	cases := []struct {
		id  string
		val *bool
	}{
		{"a", nil},
		{"b", &tru},
		{"c", &fal},
	}
	for _, c := range cases {
		task := &domain.Task{ID: c.id, Type: "shell", Status: domain.TaskStatusQueued, AISchedule: c.val}
		if err := r.Save(ctx, task); err != nil {
			t.Fatalf("save %s: %v", c.id, err)
		}
		got, err := r.GetByID(ctx, c.id)
		if err != nil {
			t.Fatalf("get %s: %v", c.id, err)
		}
		switch {
		case c.val == nil && got.AISchedule != nil:
			t.Errorf("%s: nil round-tripped to %v", c.id, *got.AISchedule)
		case c.val != nil && got.AISchedule == nil:
			t.Errorf("%s: %v round-tripped to nil", c.id, *c.val)
		case c.val != nil && got.AISchedule != nil && *c.val != *got.AISchedule:
			t.Errorf("%s: %v round-tripped to %v", c.id, *c.val, *got.AISchedule)
		}
	}
}

func TestTaskRepo_MarkStaleTasksFailed(t *testing.T) {
	r := newTaskRepoForTest(t)
	ctx := context.Background()
	old := time.Now().UTC().Add(-1 * time.Hour)
	fresh := time.Now().UTC()

	staleQueued := &domain.Task{ID: "s1", Type: "shell", Status: domain.TaskStatusQueued, CreatedAt: old}
	staleAssigned := &domain.Task{ID: "s2", Type: "shell", Status: domain.TaskStatusAssigned, CreatedAt: old, AssignedDeviceID: "d1"}
	staleRunning := &domain.Task{ID: "s3", Type: "shell", Status: domain.TaskStatusRunning, CreatedAt: old}
	freshQueued := &domain.Task{ID: "f1", Type: "shell", Status: domain.TaskStatusQueued, CreatedAt: fresh}
	terminalCompleted := &domain.Task{ID: "c1", Type: "shell", Status: domain.TaskStatusCompleted, CreatedAt: old}
	terminalFailed := &domain.Task{ID: "c2", Type: "shell", Status: domain.TaskStatusFailed, CreatedAt: old, Error: "prior failure"}

	for _, tk := range []*domain.Task{staleQueued, staleAssigned, staleRunning, freshQueued, terminalCompleted, terminalFailed} {
		if err := r.Save(ctx, tk); err != nil {
			t.Fatalf("save %s: %v", tk.ID, err)
		}
	}

	cutoff := time.Now().UTC().Add(-1 * time.Minute)
	n, err := r.MarkStaleTasksFailed(ctx, cutoff)
	if err != nil {
		t.Fatalf("MarkStaleTasksFailed: %v", err)
	}
	if n != 3 {
		t.Errorf("affected = %d, want 3 (only s1/s2/s3)", n)
	}

	// The 3 stale non-terminal tasks should now be failed.
	for _, id := range []string{"s1", "s2", "s3"} {
		got, err := r.GetByID(ctx, id)
		if err != nil {
			t.Fatalf("get %s: %v", id, err)
		}
		if got.Status != domain.TaskStatusFailed {
			t.Errorf("%s status = %s, want failed", id, got.Status)
		}
		if got.Error != "server restarted; status unknown" {
			t.Errorf("%s error = %q", id, got.Error)
		}
	}

	// The fresh queued task and the two terminal tasks must NOT have been touched.
	if got, _ := r.GetByID(ctx, "f1"); got == nil || got.Status != domain.TaskStatusQueued {
		t.Errorf("f1 should still be queued, got %+v", got)
	}
	if got, _ := r.GetByID(ctx, "c1"); got == nil || got.Status != domain.TaskStatusCompleted {
		t.Errorf("c1 should still be completed, got %+v", got)
	}
	if got, _ := r.GetByID(ctx, "c2"); got == nil || got.Error != "prior failure" {
		t.Errorf("c2 prior error overwritten: %+v", got)
	}
}

func TestTaskRepo_GetByGroup_EmptyReturnsEmptySlice(t *testing.T) {
	r := newTaskRepoForTest(t)
	got, err := r.GetByGroup(context.Background(), "no-such-group")
	if err != nil {
		t.Fatalf("GetByGroup: %v", err)
	}
	if got == nil {
		t.Errorf("expected empty slice, got nil")
	}
	if len(got) != 0 {
		t.Errorf("expected length 0, got %d", len(got))
	}
}

func TestTaskRepo_GetByGroup(t *testing.T) {
	r := newTaskRepoForTest(t)
	ctx := context.Background()
	for _, id := range []string{"x1", "x2", "x3"} {
		_ = r.Save(ctx, &domain.Task{ID: id, Type: "shell", Status: domain.TaskStatusQueued, GroupID: "g1"})
	}
	_ = r.Save(ctx, &domain.Task{ID: "y1", Type: "shell", Status: domain.TaskStatusQueued, GroupID: "g2"})

	got, err := r.GetByGroup(ctx, "g1")
	if err != nil {
		t.Fatalf("GetByGroup: %v", err)
	}
	if len(got) != 3 {
		t.Errorf("len = %d, want 3 (got=%v)", len(got), got)
	}
}

func TestTaskRepo_LoadNonTerminal_FiltersTerminal(t *testing.T) {
	r := newTaskRepoForTest(t)
	ctx := context.Background()

	statuses := []domain.TaskStatus{
		domain.TaskStatusPending,
		domain.TaskStatusQueued,
		domain.TaskStatusAssigned,
		domain.TaskStatusRunning,
		domain.TaskStatusCompleted,
		domain.TaskStatusFailed,
		domain.TaskStatusCancelled,
	}
	for i, st := range statuses {
		task := &domain.Task{
			ID:        fmt.Sprintf("t%d", i),
			Type:      "shell",
			Status:    st,
			Priority:  domain.TaskPriorityNormal,
			CreatedAt: time.Now().UTC().Truncate(time.Second).Add(time.Duration(i) * time.Second),
		}
		if err := r.Save(ctx, task); err != nil {
			t.Fatalf("save %s: %v", st, err)
		}
	}

	got, err := r.LoadNonTerminal(ctx)
	if err != nil {
		t.Fatalf("LoadNonTerminal: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("got %d tasks, want 4 non-terminal", len(got))
	}
	for _, task := range got {
		switch task.Status {
		case domain.TaskStatusCompleted, domain.TaskStatusFailed, domain.TaskStatusCancelled:
			t.Errorf("LoadNonTerminal returned terminal status %s for %s", task.Status, task.ID)
		}
	}
}

func TestTaskRepo_LoadNonTerminal_EmptyDB(t *testing.T) {
	r := newTaskRepoForTest(t)
	got, err := r.LoadNonTerminal(context.Background())
	if err != nil {
		t.Fatalf("LoadNonTerminal: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %d, want 0 on empty DB", len(got))
	}
}

func TestTaskRoundTripAssignedGPUIndexes(t *testing.T) {
	r := newTaskRepoForTest(t)
	ctx := context.Background()

	task := &domain.Task{
		ID: "t-gpu", Type: "command", Status: domain.TaskStatusAssigned,
		Priority: domain.TaskPriorityNormal, CreatedAt: time.Now(),
		AssignedGPUIndexes: []int{0, 3},
	}
	if err := r.Save(ctx, task); err != nil {
		t.Fatal(err)
	}
	got, err := r.GetByID(ctx, "t-gpu")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got.AssignedGPUIndexes, []int{0, 3}) {
		t.Fatalf("AssignedGPUIndexes = %v, want [0 3]", got.AssignedGPUIndexes)
	}

	// Empty value round-trip should be safe (no per-GPU pinning).
	task2 := &domain.Task{ID: "t-nogpu", Type: "command",
		Status: domain.TaskStatusQueued, Priority: domain.TaskPriorityNormal, CreatedAt: time.Now()}
	if err := r.Save(ctx, task2); err != nil {
		t.Fatal(err)
	}
	got2, err := r.GetByID(ctx, "t-nogpu")
	if err != nil {
		t.Fatal(err)
	}
	if len(got2.AssignedGPUIndexes) != 0 {
		t.Fatalf("expected empty indexes, got %v", got2.AssignedGPUIndexes)
	}
}

func TestTaskRepo_LoadNonTerminal_PreservesAllFields(t *testing.T) {
	r := newTaskRepoForTest(t)
	ctx := context.Background()

	original := &domain.Task{
		ID:                   "t-roundtrip",
		Type:                 "shell",
		Status:               domain.TaskStatusAssigned,
		Priority:             domain.TaskPriorityHigh,
		RequiredCapabilities: []string{"gpu", "compute"},
		BlockedDeviceIDs:     []string{"dev-bad"},
		AssignedDeviceID:     "dev-1",
		Payload:              map[string]interface{}{"cmd": "echo hi"},
		ResourceReqs:         &domain.ResourceRequirements{GPUMemoryMB: 4096, CPUCores: 4},
		CreatedAt:            time.Now().UTC().Truncate(time.Second),
		RetryCount:           1,
		MaxRetries:           3,
	}
	if err := r.Save(ctx, original); err != nil {
		t.Fatalf("save: %v", err)
	}

	got, err := r.LoadNonTerminal(ctx)
	if err != nil {
		t.Fatalf("LoadNonTerminal: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d, want 1", len(got))
	}
	loaded := got[0]
	if loaded.ID != "t-roundtrip" {
		t.Errorf("ID = %q", loaded.ID)
	}
	if loaded.Status != domain.TaskStatusAssigned {
		t.Errorf("Status = %q", loaded.Status)
	}
	if len(loaded.RequiredCapabilities) != 2 || loaded.RequiredCapabilities[0] != "gpu" {
		t.Errorf("RequiredCapabilities = %v", loaded.RequiredCapabilities)
	}
	if len(loaded.BlockedDeviceIDs) != 1 || loaded.BlockedDeviceIDs[0] != "dev-bad" {
		t.Errorf("BlockedDeviceIDs = %v", loaded.BlockedDeviceIDs)
	}
	if loaded.AssignedDeviceID != "dev-1" {
		t.Errorf("AssignedDeviceID = %q", loaded.AssignedDeviceID)
	}
	if loaded.ResourceReqs == nil || loaded.ResourceReqs.GPUMemoryMB != 4096 {
		t.Errorf("ResourceReqs = %+v", loaded.ResourceReqs)
	}
}
