package sqlite

import (
	"context"
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
		Priority: domain.TaskPriorityNormal,
		Payload:  map[string]interface{}{"cmd": "echo a"},
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
