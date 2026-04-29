# Queue Hydration on Restart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace boot-time `MarkStaleTasksFailed` (which marks every pre-boot non-terminal task as `failed`) with hydration of the in-memory `TaskQueue` from sqlite, plus a one-shot 60-second reconcile pass that reassigns tasks from workers that fail to reconnect.

**Architecture:** The persistence machinery is already in place — `internal/repository/sqlite/task.go` writes every queue mutation, and `cmd/server/main.go:153` wires `domain.NewTaskQueue().WithRepo(repos.Tasks)` in sync mode. What's missing is read-back at boot. This PR adds (a) `TaskRepository.LoadNonTerminal` for boot-time read, (b) `TaskQueue.AttachAssigned` to replay assigned/running tasks without re-persisting, (c) a `HydrateQueue` usecase helper that dispatches loaded tasks to the queue based on status, (d) a wire-up in `cmd/server/main.go` that replaces the existing `MarkStaleTasksFailed` call, and (e) a `reconcileBoot` method on `TaskSupervisor` that fires once after a 60-second grace window and reassigns tasks whose worker is not currently connected.

**Tech Stack:** Go (existing repo). SQLite via `database/sql`. Standard `testing` package, table-style tests, in-memory sqlite (`:memory:`) per the `newTaskRepoForTest` pattern at `internal/repository/sqlite/task_test.go:11`.

**Spec:** [`docs/superpowers/specs/2026-04-29-queue-hydration-design.md`](../specs/2026-04-29-queue-hydration-design.md) — read this first if anything below is unclear.

**Verification:** All tasks must pass `go test ./...` from the worktree root. The final task includes a manual smoke test described in §Manual Verification at the end of this plan.

---

## Task 1: Add `LoadNonTerminal` to TaskRepository

**What:** Read-back path for the boot hydrate. Returns every task whose status is not in `{completed, failed, cancelled}`, ordered by `created_at` ASC.

**Files:**
- Modify: `internal/domain/task_repository.go` (add method to interface)
- Modify: `internal/repository/sqlite/task.go` (add impl after `GetByGroup`)
- Modify: `internal/repository/sqlite/task_test.go` (add tests after the last existing test)

---

- [ ] **Step 1.1: Read the existing interface**

Run: `cat internal/domain/task_repository.go`
Note the existing methods (`Save`, `Delete`, `GetByID`, `GetByGroup`, `MarkStaleTasksFailed`). The new `LoadNonTerminal` will sit at the end of the interface block.

---

- [ ] **Step 1.2: Write three failing tests in `internal/repository/sqlite/task_test.go`**

Append to the file (after the last existing test):

```go
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
```

If `fmt` is not yet imported in this test file, add it to the import block.

---

- [ ] **Step 1.3: Run the new tests to verify they fail to compile**

Run from the worktree root:

```bash
go test ./internal/repository/sqlite/ -run TestTaskRepo_LoadNonTerminal -v
```

Expected: compilation error along the lines of `r.LoadNonTerminal undefined (type *TaskRepository has no field or method LoadNonTerminal)`.

---

- [ ] **Step 1.4: Add `LoadNonTerminal` to the interface**

In `internal/domain/task_repository.go`, add the method to the `TaskRepository` interface (place it just before the closing brace of the interface, after `MarkStaleTasksFailed`):

```go
	// LoadNonTerminal returns every task whose status is not terminal
	// (i.e. not completed, failed, or cancelled). Used at server boot
	// to rehydrate the in-memory queue.
	LoadNonTerminal(ctx context.Context) ([]*Task, error)
```

---

- [ ] **Step 1.5: Implement `LoadNonTerminal` in the sqlite repo**

In `internal/repository/sqlite/task.go`, add the method after `GetByGroup` and before the `taskSelectColumns` constant:

```go
// LoadNonTerminal returns every task whose status is not in a terminal
// state (completed/failed/cancelled). Used at server boot to rehydrate
// the in-memory queue.
func (r *TaskRepository) LoadNonTerminal(ctx context.Context) ([]*domain.Task, error) {
	rows, err := r.db.QueryContext(ctx,
		taskSelectColumns+
			` WHERE status NOT IN (?, ?, ?) ORDER BY created_at ASC`,
		string(domain.TaskStatusCompleted),
		string(domain.TaskStatusFailed),
		string(domain.TaskStatusCancelled),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanTasks(rows)
}
```

The compile-time `var _ domain.TaskRepository = (*TaskRepository)(nil)` assertion at the bottom of the file now requires this method to satisfy the interface; this guarantees the wiring.

---

- [ ] **Step 1.6: Run the tests; expect PASS**

```bash
go test ./internal/repository/sqlite/ -run TestTaskRepo_LoadNonTerminal -v
```

Expected: 3 tests pass.

---

- [ ] **Step 1.7: Run the entire repo test suite**

```bash
go test ./internal/repository/sqlite/...
```

Expected: all existing tests still pass. (Adding a method to an interface can break other in-package implementations; verify no fakes/mocks are missing the method.)

---

- [ ] **Step 1.8: Run go vet / go build to confirm interface satisfaction across the module**

```bash
go build ./...
```

Expected: builds clean. If anything implements `domain.TaskRepository` outside `internal/repository/sqlite/`, this catches it.

---

- [ ] **Step 1.9: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/queue-hydration
git add internal/domain/task_repository.go internal/repository/sqlite/task.go internal/repository/sqlite/task_test.go
git commit -m "feat(persistence): add TaskRepository.LoadNonTerminal for boot hydrate

Returns every task whose status is not in (completed, failed, cancelled),
ordered by created_at ASC. Reuses taskSelectColumns and scanTasks for
deserialization. Three tests cover status filtering, empty DB, and
field round-trip.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add `AttachAssigned` to TaskQueue

**What:** A queue method that re-inserts a task with non-pending status (assigned or running) into `q.tasks` without enqueueing it for scheduling. Used at boot to replay tasks already attached to a worker.

**Files:**
- Modify: `internal/domain/taskqueue.go` (new method)
- Modify: `internal/domain/taskqueue_test.go` (new tests)

---

- [ ] **Step 2.1: Write two failing tests in `internal/domain/taskqueue_test.go`**

Append after the last existing test:

```go
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

	if r.saveCalls != 0 {
		t.Errorf("AttachAssigned should not call repo.Save; got %d calls", r.saveCalls)
	}
}

// recordingRepo is a TaskRepository fake that counts Save calls.
type recordingRepo struct {
	saveCalls int
}

func (r *recordingRepo) Save(ctx context.Context, t *Task) error {
	r.saveCalls++
	return nil
}
func (r *recordingRepo) Delete(ctx context.Context, id string) error           { return nil }
func (r *recordingRepo) GetByID(ctx context.Context, id string) (*Task, error) { return nil, nil }
func (r *recordingRepo) GetByGroup(ctx context.Context, gid string) ([]*Task, error) {
	return nil, nil
}
func (r *recordingRepo) MarkStaleTasksFailed(ctx context.Context, before time.Time) (int, error) {
	return 0, nil
}
func (r *recordingRepo) LoadNonTerminal(ctx context.Context) ([]*Task, error) { return nil, nil }
```

If `context` and `time` are not yet imported in `taskqueue_test.go`, add them.

---

- [ ] **Step 2.2: Run new tests, verify compile failure**

```bash
go test ./internal/domain/ -run TestAttachAssigned -v
```

Expected: compile error `q.AttachAssigned undefined (type *TaskQueue has no field or method AttachAssigned)`.

---

- [ ] **Step 2.3: Implement `AttachAssigned` in `internal/domain/taskqueue.go`**

Add after the `Enqueue` method (which lives near the top of the file):

```go
// AttachAssigned re-inserts a task that already has a non-pending status
// (assigned or running), typically replayed from the repository at boot.
// The task lands in q.tasks (so Get / ListByStatus / GetAssignedTasks see
// it) but is NOT placed in q.queue, since it is not awaiting initial
// scheduling.
//
// The caller is responsible for ensuring task.Status is one of:
//   TaskStatusAssigned, TaskStatusRunning
// Use Enqueue for TaskStatusQueued / TaskStatusPending.
//
// AttachAssigned does not call persist — the task is already present in
// the repo (it came from there).
func (q *TaskQueue) AttachAssigned(t *Task) {
	if t == nil {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.tasks[t.ID] = t
}
```

---

- [ ] **Step 2.4: Run tests; expect PASS**

```bash
go test ./internal/domain/ -run TestAttachAssigned -v
```

Expected: 2 tests pass.

---

- [ ] **Step 2.5: Run the full domain test suite to catch regressions**

```bash
go test ./internal/domain/...
```

Expected: every existing test still passes.

---

- [ ] **Step 2.6: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/queue-hydration
git add internal/domain/taskqueue.go internal/domain/taskqueue_test.go
git commit -m "feat(persistence): add TaskQueue.AttachAssigned for boot replay

Re-inserts an already-assigned/running task into q.tasks without queueing
it for scheduling and without round-tripping through persist (the task
is already on disk). Used at server boot to restore in-memory state for
tasks whose worker may still hold them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Add `HydrateQueue` usecase helper

**What:** A free function in `internal/usecase` that takes a `domain.TaskRepository` and a `*domain.TaskQueue`, calls `LoadNonTerminal`, and dispatches each task to the queue using `Enqueue` or `AttachAssigned` based on status. Returns counts for logging plus an error for fail-fast at boot.

**Files:**
- Create: `internal/usecase/queue_hydration.go`
- Create: `internal/usecase/queue_hydration_test.go`

---

- [ ] **Step 3.1: Write the failing test in `internal/usecase/queue_hydration_test.go`**

Create the file with:

```go
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

func (s *stubTaskRepo) Save(ctx context.Context, t *domain.Task) error  { return nil }
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
			{ID: "p1", Status: domain.TaskStatusPending, Priority: domain.TaskPriorityNormal},
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
	if got := queue.Get("a1"); got == nil || got.Status != domain.TaskStatusAssigned {
		t.Errorf("a1 not attached as assigned: %+v", got)
	}

	pending := queue.ListQueuedByPriority()
	if len(pending) != 2 {
		t.Errorf("ListQueuedByPriority = %d; want 2 (pending+queued)", len(pending))
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
```

---

- [ ] **Step 3.2: Run tests, verify compile failure**

```bash
go test ./internal/usecase/ -run TestHydrateQueue -v
```

Expected: `undefined: HydrateQueue` and `undefined: HydrateStats`.

---

- [ ] **Step 3.3: Implement `HydrateQueue` in `internal/usecase/queue_hydration.go`**

Create the file with:

```go
package usecase

import (
	"context"
	"fmt"
	"log"

	"github.com/s1ckdark/hydra/internal/domain"
)

// HydrateStats counts what HydrateQueue did, for boot-time logging.
type HydrateStats struct {
	Pending  int
	Queued   int
	Assigned int
	Running  int
	Skipped  int
}

// Total returns the sum of all dispatch counters.
func (s HydrateStats) Total() int {
	return s.Pending + s.Queued + s.Assigned + s.Running + s.Skipped
}

// HydrateQueue loads non-terminal tasks from repo and replays them into
// queue. Pending and queued tasks are Enqueued (so they re-enter the
// scheduler); assigned and running tasks are AttachAssigned (so they
// remain bound to their original worker until reconcile or worker
// reconnect resolves them).
//
// Any task with a status outside the expected non-terminal set is logged
// and counted in Skipped; this defends against schema drift or a buggy
// LoadNonTerminal returning unexpected rows. We do not fail the boot for
// it — better to start with a partial queue than not at all.
//
// A non-nil error from repo.LoadNonTerminal is wrapped and returned so
// the caller can decide whether to abort startup.
func HydrateQueue(ctx context.Context, repo domain.TaskRepository, queue *domain.TaskQueue) (HydrateStats, error) {
	loaded, err := repo.LoadNonTerminal(ctx)
	if err != nil {
		return HydrateStats{}, fmt.Errorf("load non-terminal tasks: %w", err)
	}

	var stats HydrateStats
	for _, t := range loaded {
		switch t.Status {
		case domain.TaskStatusPending:
			queue.Enqueue(t)
			stats.Pending++
		case domain.TaskStatusQueued:
			queue.Enqueue(t)
			stats.Queued++
		case domain.TaskStatusAssigned:
			queue.AttachAssigned(t)
			stats.Assigned++
		case domain.TaskStatusRunning:
			queue.AttachAssigned(t)
			stats.Running++
		default:
			log.Printf("[hydrate] task %s has unexpected status %q; skipping", t.ID, t.Status)
			stats.Skipped++
		}
	}
	return stats, nil
}
```

---

- [ ] **Step 3.4: Run tests, expect PASS**

```bash
go test ./internal/usecase/ -run TestHydrateQueue -v
```

Expected: 4 tests pass.

---

- [ ] **Step 3.5: Run full usecase tests**

```bash
go test ./internal/usecase/...
```

Expected: clean.

---

- [ ] **Step 3.6: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/queue-hydration
git add internal/usecase/queue_hydration.go internal/usecase/queue_hydration_test.go
git commit -m "feat(persistence): add HydrateQueue usecase helper

Loads non-terminal tasks from TaskRepository and dispatches them into a
TaskQueue based on status — pending/queued tasks are Enqueued for normal
scheduling, assigned/running tasks are AttachAssigned to remain bound
to their worker. Returns counts for boot-time logging.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Wire `HydrateQueue` into `cmd/server/main.go`

**What:** Replace the boot-time `repos.Tasks.MarkStaleTasksFailed(...)` block with a call to `HydrateQueue` between sqlite open and queue construction. `MarkStaleTasksFailed` itself stays on the repo as a public method (used by ad-hoc tooling and tests) but is no longer auto-invoked at boot.

**Files:**
- Modify: `cmd/server/main.go`

This task has no unit test (it is glue code in `main`). Verification is via `go build` plus the manual smoke test at the end of this plan.

---

- [ ] **Step 4.1: Locate the existing block to replace**

Run:

```bash
grep -nB 2 -A 15 "MarkStaleTasksFailed" cmd/server/main.go
```

Expected output: a comment block (lines ~85-94) explaining the cleanup, then the `bootCutoff := time.Now()` and `repos.Tasks.MarkStaleTasksFailed(...)` call (around lines 95-100). Note the exact line numbers — they may have drifted from the spec's reference (line 96).

---

- [ ] **Step 4.2: Replace the block**

Find the existing block. It looks roughly like:

```go
	// One-shot orphan cleanup: any task left non-terminal from a prior run
	// can never converge (the in-memory TaskQueue rebuilds empty on boot). Mark
	// them failed with an explanatory message so consuming groups transition
	// to partial/failed correctly.
	//
	// Cutoff = current wall-clock. Routes (the only way to create new tasks
	// in this run) aren't registered until later in main(), so no fresh task
	// ...
	bootCutoff := time.Now()
	if affected, err := repos.Tasks.MarkStaleTasksFailed(context.Background(), bootCutoff); err != nil {
		log.Printf("[startup] stale-task cleanup failed: %v", err)
	} else if affected > 0 {
		log.Printf("[startup] marked %d stale tasks failed (pre-boot)", affected)
	}
```

Replace it with:

```go
	// Hydrate the in-memory task queue from sqlite. Tasks that were queued
	// at the previous shutdown re-enter the scheduler; tasks that were
	// already assigned to a worker stay attached so the worker can report
	// results when it reconnects. The boot-reconcile pass in TaskSupervisor
	// handles workers that fail to reconnect within the grace window.
	hydratedQueue := domain.NewTaskQueue().WithRepo(repos.Tasks)
	hydrateStats, err := usecase.HydrateQueue(context.Background(), repos.Tasks, hydratedQueue)
	if err != nil {
		log.Fatalf("[startup] hydrate task queue: %v", err)
	}
	log.Printf("[startup] hydrated tasks: pending=%d queued=%d assigned=%d running=%d skipped=%d (total=%d)",
		hydrateStats.Pending, hydrateStats.Queued, hydrateStats.Assigned, hydrateStats.Running, hydrateStats.Skipped, hydrateStats.Total())
```

Then locate the existing line `taskQueue := domain.NewTaskQueue().WithRepo(repos.Tasks)` (around line 153 per the spec), and replace it with:

```go
	taskQueue := hydratedQueue
```

This avoids constructing the queue twice. Both the original line and the new construction in the hydrate block should not coexist.

If `usecase` is not yet imported at the top of main.go, add the import path:

```go
	"github.com/s1ckdark/hydra/internal/usecase"
```

(It almost certainly is already imported — `taskSupervisor := usecase.NewTaskSupervisor(...)` exists later in the same file.)

---

- [ ] **Step 4.3: Build the server**

```bash
go build ./cmd/server
```

Expected: clean build, no errors. If `usecase` was not imported, you will get a compile error pointing it out.

---

- [ ] **Step 4.4: Run the full module test suite for regressions**

```bash
go test ./...
```

Expected: all existing tests pass. (No test directly exercises main.go but a number of tests touch the same packages we just changed.)

---

- [ ] **Step 4.5: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/queue-hydration
git add cmd/server/main.go
git commit -m "feat(persistence): hydrate task queue from sqlite at boot

Replace the boot-time MarkStaleTasksFailed call (which marked every
pre-boot non-terminal task as 'failed') with a HydrateQueue call that
reloads tasks into the in-memory queue. Pending/queued tasks re-enter
the scheduler; assigned/running tasks stay attached to their worker
until either the worker reconnects and reports results, or the
boot-reconcile pass in TaskSupervisor reassigns them.

MarkStaleTasksFailed remains on the repo as a public method (used by
ad-hoc tooling and tests) but is no longer auto-invoked at boot.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Boot reconcile in TaskSupervisor

**What:** A one-shot reconcile that fires 60 seconds after `TaskSupervisor.Start` begins. For each `assigned`/`running` task whose `AssignedDeviceID` is not currently connected to the WS hub, it calls `ReassignTasksFromDevice` (deduplicated per device) so the task re-enters the scheduling pool.

**Files:**
- Modify: `internal/usecase/task_supervisor.go`
- Modify: `internal/usecase/task_supervisor_test.go`

---

- [ ] **Step 5.1: Read the existing supervisor structure**

Run:

```bash
grep -nA 5 "func (s \*TaskSupervisor) Start\|func (s \*TaskSupervisor) check" internal/usecase/task_supervisor.go | head -30
```

Note the existing `Start` signature (`Start(ctx context.Context)`), the ticker pattern, and the call to `s.check(ctx)`.

---

- [ ] **Step 5.2: Write failing tests in `internal/usecase/task_supervisor_test.go`**

Append after the last existing test:

```go
func TestReconcileBoot_ReassignsTasksFromDisconnectedWorkers(t *testing.T) {
	taskQueue := domain.NewTaskQueue()
	hub := ws.NewHub() // no clients registered → IsConnected returns false for all
	s := NewTaskSupervisor(taskQueue, hub, nil, nil)

	// Two assigned tasks across two devices, both disconnected.
	taskQueue.Enqueue(&domain.Task{ID: "t1", Priority: domain.TaskPriorityNormal, MaxRetries: 3})
	taskQueue.AssignToDevice("t1", "dev-1")
	taskQueue.Enqueue(&domain.Task{ID: "t2", Priority: domain.TaskPriorityNormal, MaxRetries: 3})
	taskQueue.AssignToDevice("t2", "dev-2")

	s.reconcileBoot(context.Background())

	for _, id := range []string{"t1", "t2"} {
		got := taskQueue.Get(id)
		if got == nil {
			t.Fatalf("%s missing", id)
		}
		if got.Status != domain.TaskStatusQueued {
			t.Errorf("%s.Status = %q; want queued (reassigned)", id, got.Status)
		}
		if got.AssignedDeviceID != "" {
			t.Errorf("%s.AssignedDeviceID = %q; want empty after reassign", id, got.AssignedDeviceID)
		}
	}
}

func TestReconcileBoot_DedupesByDevice(t *testing.T) {
	taskQueue := domain.NewTaskQueue()
	hub := ws.NewHub()
	s := NewTaskSupervisor(taskQueue, hub, nil, nil)

	// Three tasks, all on the same device.
	for _, id := range []string{"t1", "t2", "t3"} {
		taskQueue.Enqueue(&domain.Task{ID: id, Priority: domain.TaskPriorityNormal, MaxRetries: 3})
		taskQueue.AssignToDevice(id, "dev-A")
	}

	s.reconcileBoot(context.Background())

	for _, id := range []string{"t1", "t2", "t3"} {
		got := taskQueue.Get(id)
		if got.Status != domain.TaskStatusQueued {
			t.Errorf("%s.Status = %q; want queued", id, got.Status)
		}
	}
	// All three should have RetryCount=1 from the single ReassignTasksFromDevice call.
	// Two reassign calls would yield RetryCount=2.
	for _, id := range []string{"t1", "t2", "t3"} {
		if rc := taskQueue.Get(id).RetryCount; rc != 1 {
			t.Errorf("%s.RetryCount = %d; want 1 (dedup proves single reassign call)", id, rc)
		}
	}
}

func TestReconcileBoot_SkipsEmptyAssignedDeviceID(t *testing.T) {
	taskQueue := domain.NewTaskQueue()
	hub := ws.NewHub()
	s := NewTaskSupervisor(taskQueue, hub, nil, nil)

	// Defensive: a malformed task with status=assigned but no device should
	// not crash reconcile and should not match any reassign.
	taskQueue.AttachAssigned(&domain.Task{
		ID:       "t-orphan",
		Status:   domain.TaskStatusAssigned,
		Priority: domain.TaskPriorityNormal,
	})

	s.reconcileBoot(context.Background()) // must not panic

	got := taskQueue.Get("t-orphan")
	if got == nil {
		t.Fatal("t-orphan removed; should remain in queue")
	}
	if got.Status != domain.TaskStatusAssigned {
		t.Errorf("status = %q; want unchanged (assigned)", got.Status)
	}
}

func TestReconcileBoot_NilHubIsNoOp(t *testing.T) {
	taskQueue := domain.NewTaskQueue()
	s := NewTaskSupervisor(taskQueue, nil, nil, nil)

	taskQueue.Enqueue(&domain.Task{ID: "t1", Priority: domain.TaskPriorityNormal, MaxRetries: 3})
	taskQueue.AssignToDevice("t1", "dev-1")

	s.reconcileBoot(context.Background()) // must not panic

	if got := taskQueue.Get("t1"); got.Status != domain.TaskStatusAssigned {
		t.Errorf("t1.Status = %q; want unchanged when hub is nil", got.Status)
	}
}
```

If `ws` is not yet imported in this test file, add `"github.com/s1ckdark/hydra/internal/web/ws"` to the import block.

---

- [ ] **Step 5.3: Run the new tests, expect compile failure**

```bash
go test ./internal/usecase/ -run TestReconcileBoot -v
```

Expected: `undefined: s.reconcileBoot`.

---

- [ ] **Step 5.4: Add `reconcileBoot` and the timing gate in `internal/usecase/task_supervisor.go`**

At the top of the file (after imports), add:

```go
// bootGracePeriod is the time after Start that the supervisor waits
// before reconciling assigned/running tasks against actual worker
// connectivity. Sized comfortably above HeartbeatMonitor's 45s
// staleThreshold so a normally-cycling worker has time to reconnect.
const bootGracePeriod = 60 * time.Second
```

Then update `Start` to track the boot deadline and call `reconcileBoot` exactly once. Replace the existing `Start` method body:

```go
// Start begins the supervision loop
func (s *TaskSupervisor) Start(ctx context.Context) {
	log.Println("[supervisor] task supervisor started")
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()

	bootDeadline := time.Now().Add(bootGracePeriod)
	bootReconciled := false

	for {
		select {
		case <-ctx.Done():
			log.Println("[supervisor] task supervisor stopped")
			return
		case <-ticker.C:
			if !bootReconciled && time.Now().After(bootDeadline) {
				s.reconcileBoot(ctx)
				bootReconciled = true
			}
			s.check(ctx)
		}
	}
}
```

Add the `reconcileBoot` method after `Start` (or wherever methods are grouped):

```go
// reconcileBoot is a one-shot pass invoked after bootGracePeriod elapses.
// It walks the assigned/running task set, identifies workers that have
// not reconnected, and triggers reassignment for them. Workers that did
// reconnect during the grace window keep their tasks; the live disconnect
// handler covers any subsequent drop.
//
// Per-device dedup: if a worker had three assigned tasks, we call
// ReassignTasksFromDevice once for it (the queue method handles all
// non-terminal tasks for that device atomically).
//
// Safe to call when wsHub is nil — used in tests that don't wire a hub.
func (s *TaskSupervisor) reconcileBoot(ctx context.Context) {
	if s.wsHub == nil {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	orphanedDevices := make(map[string]struct{})
	for _, t := range s.taskQueue.ListByStatus(domain.TaskStatusAssigned) {
		if t.AssignedDeviceID == "" {
			continue
		}
		if !s.wsHub.IsConnected(t.AssignedDeviceID) {
			orphanedDevices[t.AssignedDeviceID] = struct{}{}
		}
	}
	for _, t := range s.taskQueue.ListByStatus(domain.TaskStatusRunning) {
		if t.AssignedDeviceID == "" {
			continue
		}
		if !s.wsHub.IsConnected(t.AssignedDeviceID) {
			orphanedDevices[t.AssignedDeviceID] = struct{}{}
		}
	}

	if len(orphanedDevices) == 0 {
		log.Printf("[supervisor] boot reconcile: all assigned/running workers reconnected")
		return
	}

	for deviceID := range orphanedDevices {
		reassigned := s.taskQueue.ReassignTasksFromDevice(deviceID)
		log.Printf("[supervisor] boot reconcile: reassigned %d tasks from non-reconnected worker %s",
			len(reassigned), deviceID)
	}
}
```

---

- [ ] **Step 5.5: Run the new tests, expect PASS**

```bash
go test ./internal/usecase/ -run TestReconcileBoot -v
```

Expected: 4 tests pass.

---

- [ ] **Step 5.6: Run the full usecase test suite**

```bash
go test ./internal/usecase/...
```

Expected: clean. The existing supervisor tests (notably `TestTaskSupervisor_ConcurrentSettersNoRace`) should be unaffected.

---

- [ ] **Step 5.7: Run the full module test suite**

```bash
go test ./...
```

Expected: clean.

---

- [ ] **Step 5.8: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/queue-hydration
git add internal/usecase/task_supervisor.go internal/usecase/task_supervisor_test.go
git commit -m "feat(persistence): boot reconcile reassigns from non-reconnected workers

Adds a one-shot reconcileBoot pass to TaskSupervisor that fires 60s
after Start. For each assigned/running task whose worker is not
currently connected to the WS hub, the task's device is added to a
deduplicated set; ReassignTasksFromDevice is called once per device.

Workers that did reconnect during the 60s grace window keep their
tasks; the existing live-disconnect handler covers any later drop.
Sized above HeartbeatMonitor's 45s staleThreshold so normal-cycle
reconnects fit inside the grace window.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Manual Verification

After all five tasks are complete and committed, run the manual smoke test from the spec:

- [ ] **Step M.1: Build and prepare**

```bash
make build
rm -f /tmp/hydra-hyd.db
```

- [ ] **Step M.2: Start server**

In one terminal:

```bash
HYDRA_DB_PATH=/tmp/hydra-hyd.db ./bin/server
```

(Substitute the actual env var or config path used by the server to point at the sqlite file. If the project always uses `~/.clusterctl/hydra.db`, back up the existing file first and restore after.)

- [ ] **Step M.3: Start two workers**

In two more terminals:

```bash
./bin/wstub --device-ids=A --capabilities=compute
./bin/wstub --device-ids=B --capabilities=compute
```

- [ ] **Step M.4: Submit tasks**

```bash
for i in 1 2 3 4 5; do
  curl -s -X POST http://localhost:8080/api/tasks \
    -H 'content-type: application/json' \
    -d '{"type":"shell","payload":{"cmd":"sleep 30"},"requiredCapabilities":["compute"]}'
done
```

Confirm tasks distribute across A and B.

- [ ] **Step M.5: Restart server mid-flight**

`Ctrl-C` the server. Check sqlite state:

```bash
sqlite3 /tmp/hydra-hyd.db "SELECT id, status, assigned_device_id FROM tasks"
```

Expect mixed `queued` / `assigned` / `running` rows.

- [ ] **Step M.6: Restart server, restart only worker A**

```bash
HYDRA_DB_PATH=/tmp/hydra-hyd.db ./bin/server
```

In its terminal:

```bash
./bin/wstub --device-ids=A --capabilities=compute
```

Do **not** restart B.

- [ ] **Step M.7: Watch logs**

In the server log, expect:
- Within 1s: `[startup] hydrated tasks: pending=… queued=… assigned=… running=…`
- ~60s later: `[supervisor] boot reconcile: reassigned N tasks from non-reconnected worker B`

Then A picks up B's reassigned tasks and runs them.

- [ ] **Step M.8: Verify final state**

```bash
curl -s http://localhost:8080/api/tasks | jq '.[] | {id, status, assignedDeviceId}'
```

Expect every task in `completed` (or near-completed) and all `assignedDeviceId == "A"`.

- [ ] **Step M.9: Cleanup**

```bash
rm -f /tmp/hydra-hyd.db
```

If M.1-M.8 all behave as described, the implementation is verified.

---

## File Map (summary)

| File | Action | Approx LoC change |
|---|---|---|
| `internal/domain/task_repository.go` | modify (add interface method) | +3 |
| `internal/repository/sqlite/task.go` | modify (add `LoadNonTerminal`) | +12 |
| `internal/repository/sqlite/task_test.go` | modify (3 new tests) | +90 |
| `internal/domain/taskqueue.go` | modify (add `AttachAssigned`) | +12 |
| `internal/domain/taskqueue_test.go` | modify (2 new tests + recordingRepo) | +50 |
| `internal/usecase/queue_hydration.go` | create | +50 |
| `internal/usecase/queue_hydration_test.go` | create | +110 |
| `internal/usecase/task_supervisor.go` | modify (Start + reconcileBoot + const) | +50 |
| `internal/usecase/task_supervisor_test.go` | modify (4 new tests) | +90 |
| `cmd/server/main.go` | modify (replace MarkStaleTasksFailed block) | +10 -10 |

Net: ~+450 LoC test, ~+90 LoC production. Five commits.
