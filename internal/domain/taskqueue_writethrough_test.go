package domain

import (
	"context"
	"errors"
	"testing"
	"time"
)

type stubTaskRepo struct {
	saveCalls int
	saveErr   error
	lastTask  *Task
}

func (r *stubTaskRepo) Save(_ context.Context, t *Task) error {
	r.saveCalls++
	r.lastTask = t
	return r.saveErr
}
func (r *stubTaskRepo) Delete(_ context.Context, _ string) error                    { return nil }
func (r *stubTaskRepo) GetByID(_ context.Context, _ string) (*Task, error)          { return nil, nil }
func (r *stubTaskRepo) GetByGroup(_ context.Context, _ string) ([]*Task, error)     { return nil, nil }
func (r *stubTaskRepo) MarkStaleTasksFailed(_ context.Context, _ time.Time) (int, error) {
	return 0, nil
}

func TestTaskQueue_EnqueueWritesThrough(t *testing.T) {
	q := NewTaskQueue()
	repo := &stubTaskRepo{}
	q.WithRepo(repo)

	q.Enqueue(&Task{ID: "t1", Type: "shell"})

	if repo.saveCalls != 1 {
		t.Errorf("save calls = %d, want 1", repo.saveCalls)
	}
	if repo.lastTask == nil || repo.lastTask.ID != "t1" {
		t.Errorf("lastTask = %+v", repo.lastTask)
	}
}

func TestTaskQueue_RepoFailureDoesNotBlockEnqueue(t *testing.T) {
	q := NewTaskQueue()
	repo := &stubTaskRepo{saveErr: errors.New("db down")}
	q.WithRepo(repo)

	q.Enqueue(&Task{ID: "t2", Type: "shell"})

	// In-memory still has it.
	got := q.Get("t2")
	if got == nil {
		t.Fatal("task missing from in-memory queue after repo failure")
	}
	if got.Status != TaskStatusQueued {
		t.Errorf("status = %s, want queued", got.Status)
	}
}

func TestTaskQueue_UpdateStatusWritesThrough(t *testing.T) {
	q := NewTaskQueue()
	repo := &stubTaskRepo{}
	q.WithRepo(repo)
	q.Enqueue(&Task{ID: "t3", Type: "shell"})
	repo.saveCalls = 0 // reset

	q.UpdateStatus("t3", TaskStatusRunning)

	if repo.saveCalls != 1 {
		t.Errorf("save calls = %d, want 1", repo.saveCalls)
	}
}
