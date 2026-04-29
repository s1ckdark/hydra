package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

// stubTaskRepo is a TaskRepository fake whose LoadNonTerminal returns a
// canned slice and whose other methods are no-ops sufficient for hydrate
// callers (Save is invoked by the queue's persist path, but our test
// uses NewTaskQueue without WithRepo so persist is dormant).
type stubTaskRepo struct {
	loaded   []*domain.Task
	loadErr  error
	loadCall int
}

func (s *stubTaskRepo) Save(ctx context.Context, t *domain.Task) error { return nil }
func (s *stubTaskRepo) Delete(ctx context.Context, id string) error    { return nil }
func (s *stubTaskRepo) GetByID(ctx context.Context, id string) (*domain.Task, error) {
	return nil, nil
}
func (s *stubTaskRepo) GetByGroup(ctx context.Context, gid string) ([]*domain.Task, error) {
	return nil, nil
}
func (s *stubTaskRepo) MarkStaleTasksFailed(ctx context.Context, before time.Time) (int, error) {
	return 0, nil
}
func (s *stubTaskRepo) LoadNonTerminal(ctx context.Context) ([]*domain.Task, error) {
	s.loadCall++
	return s.loaded, s.loadErr
}

func TestHydrateQueue_DispatchesByStatus(t *testing.T) {
	repo := &stubTaskRepo{
		loaded: []*domain.Task{
			{ID: "p1", Status: domain.TaskStatusPending, Priority: domain.TaskPriorityNormal, CreatedAt: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)},
			{ID: "q1", Status: domain.TaskStatusQueued, Priority: domain.TaskPriorityNormal},
			{ID: "a1", Status: domain.TaskStatusAssigned, Priority: domain.TaskPriorityNormal, AssignedDeviceID: "dev-1"},
			{ID: "r1", Status: domain.TaskStatusRunning, Priority: domain.TaskPriorityNormal, AssignedDeviceID: "dev-2"},
		},
	}
	queue := domain.NewTaskQueue()

	stats, err := HydrateQueue(context.Background(), repo, queue)
	if err != nil {
		t.Fatalf("HydrateQueue: %v", err)
	}
	if stats.Pending != 1 || stats.Queued != 1 || stats.Assigned != 1 || stats.Running != 1 {
		t.Errorf("stats = %+v; want pending=queued=assigned=running=1", stats)
	}

	if got := queue.Get("p1"); got == nil || got.Status != domain.TaskStatusPending {
		t.Errorf("p1 not loaded as pending: %+v", got)
	}
	if got := queue.Get("p1"); got != nil {
		want := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
		if !got.CreatedAt.Equal(want) {
			t.Errorf("p1.CreatedAt = %v; want %v (Replay must preserve)", got.CreatedAt, want)
		}
	}
	if got := queue.Get("a1"); got == nil || got.Status != domain.TaskStatusAssigned {
		t.Errorf("a1 not attached as assigned: %+v", got)
	}

	pending := queue.ListQueuedByPriority()
	if len(pending) != 1 {
		t.Errorf("ListQueuedByPriority = %d; want 1 (queued only; pending preserves status)", len(pending))
	}

	assignedDev1 := queue.GetAssignedTasks("dev-1")
	if len(assignedDev1) != 1 || assignedDev1[0].ID != "a1" {
		t.Errorf("dev-1 assigned = %v; want [a1]", assignedDev1)
	}
}

func TestHydrateQueue_EmptyRepo_NoOp(t *testing.T) {
	repo := &stubTaskRepo{loaded: nil}
	queue := domain.NewTaskQueue()

	stats, err := HydrateQueue(context.Background(), repo, queue)
	if err != nil {
		t.Fatalf("HydrateQueue: %v", err)
	}
	if stats.Pending+stats.Queued+stats.Assigned+stats.Running+stats.Skipped != 0 {
		t.Errorf("stats = %+v; want all-zero", stats)
	}
}

func TestHydrateQueue_PropagatesLoadError(t *testing.T) {
	wantErr := errors.New("boom")
	repo := &stubTaskRepo{loadErr: wantErr}
	queue := domain.NewTaskQueue()

	if _, err := HydrateQueue(context.Background(), repo, queue); !errors.Is(err, wantErr) {
		t.Errorf("HydrateQueue err = %v; want wraps %v", err, wantErr)
	}
}

func TestHydrateQueue_SkipsUnexpectedStatus(t *testing.T) {
	// Defensive: if a terminal status leaks through (LoadNonTerminal bug,
	// or future status added), HydrateQueue should skip it and report
	// Skipped count rather than mis-categorizing.
	repo := &stubTaskRepo{
		loaded: []*domain.Task{
			{ID: "x1", Status: domain.TaskStatusCompleted, Priority: domain.TaskPriorityNormal},
		},
	}
	queue := domain.NewTaskQueue()

	stats, err := HydrateQueue(context.Background(), repo, queue)
	if err != nil {
		t.Fatalf("HydrateQueue: %v", err)
	}
	if stats.Skipped != 1 {
		t.Errorf("Skipped = %d; want 1", stats.Skipped)
	}
	if got := queue.Get("x1"); got != nil {
		t.Errorf("completed task should not be loaded; got %+v", got)
	}
}
