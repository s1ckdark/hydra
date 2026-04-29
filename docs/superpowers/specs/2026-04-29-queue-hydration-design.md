# Queue Hydration on Restart — Design

**Date:** 2026-04-29
**Status:** Draft → User review pending
**Branch:** `claude/queue-hydration`

## Summary

Replace the current boot-time "mark all non-terminal tasks failed" policy with hydration into the in-memory `TaskQueue`. Add a reconcile pass after a 60 s grace window so workers that fail to reconnect have their tasks reassigned, not stranded.

This is **wiring**, not infrastructure. Persistence already exists (`internal/repository/sqlite/task.go`), is wired into the queue (`cmd/server/main.go:153` calls `domain.NewTaskQueue().WithRepo(repos.Tasks)`), and every mutation method already shadow-writes via `q.persist(task)`. The remaining gap is read-back at boot.

## Problem

Today, `cmd/server/main.go:96` calls `repos.Tasks.MarkStaleTasksFailed(bootCutoff)` immediately after opening the database. Every task that was `pending`/`queued`/`assigned`/`running` at the moment of the previous shutdown becomes `failed`. The in-memory queue then rebuilds empty.

Consequences:

- A REST `POST /api/tasks` made one second before a routine restart is silently failed, with the message "marked failed at startup."
- A worker reporting `MsgTaskResult` for a `running` task it owned across the restart hits a queue that has no record of the task (the task is `failed` in DB but not in-memory). The result is dropped.
- The disconnect handler only fires when a worker drops while the server is up — it does not cover the case where the **server** is the side that restarted.

The persistence machinery to do better is fully built and shipped — it is just not used at boot.

## Goals

1. Tasks that were `pending` / `queued` at restart are picked up and scheduled normally after restart.
2. Tasks that were `assigned` / `running` at restart remain attached to their original worker. If that worker reconnects within a grace window, scheduling continues; if not, the task is reassigned (not failed).
3. Workers reporting `MsgTaskResult` for a task they owned across the restart are accepted (the queue still knows the task).
4. No regression versus current scheduling, retry, or live-disconnect-reassign behavior.

## Non-goals

- **Completed-task retention / TTL cleanup.** Out of scope; follow-up PR.
- **Worker-driven reconciliation** (workers reporting their owned-task list at reconnect). The watchdog reasons about reconnect timing instead.
- **Schema changes.** The `tasks` table is already shipped (`internal/repository/sqlite/sqlite.go:236`) with all needed columns. Slices live as JSON-encoded text, payload/result/resource_reqs as JSON. We do not change this.
- **Persist-failure semantics.** Current behavior is fail-soft: `taskqueue.go`'s `persist()` logs on repo error and the in-memory mutation proceeds. We keep this — it favors availability of task acceptance over strict durability, which is the right default given SQLite's reliability and the ability to re-derive lost rows from observable behavior.
- **Async batched persist.** Queue is in sync mode at construction; no change.
- **Config exposure for `bootGracePeriod`.** Hardcoded constant; promote to `Server.BootGracePeriod` in a follow-up if operations need to tune it.

## Architecture

### What already exists

| Concern | Location | Notes |
|---|---|---|
| `tasks` table + indexes | `internal/repository/sqlite/sqlite.go:236-264` | Single-table, JSON columns for slices |
| `domain.TaskRepository` interface | `internal/repository/repository.go:91` | Lives in `domain` to avoid import cycle |
| `TaskRepository` impl | `internal/repository/sqlite/task.go` | `Save` (upsert), `Delete`, `GetByID`, `GetByGroup`, `MarkStaleTasksFailed` |
| Queue → repo wiring | `cmd/server/main.go:153` | `domain.NewTaskQueue().WithRepo(repos.Tasks)` (sync mode) |
| Per-mutation shadow-write | `internal/domain/taskqueue.go` | Every mutator (`Enqueue`, `AssignToDevice`, `UpdateStatus`, `SetResult`, `ReassignTasksFromDevice`, `CheckTimeouts` retry path) calls `q.persist(task)` |
| Live-disconnect reassign | `cmd/server/main.go:159-166` | `wsHub.SetDisconnectHandler` calls `taskQueue.ReassignTasksFromDevice(deviceID)` |

### What this PR adds

```
cmd/server/main.go (boot path):

  before:                                       after:
  ┌──────────────────────────────────┐          ┌──────────────────────────────────────────┐
  │ open sqlite                      │          │ open sqlite                              │
  │ MarkStaleTasksFailed(now)        │   →      │ loaded := repos.Tasks.LoadNonTerminal()  │
  │ NewTaskQueue().WithRepo(repos)   │          │ NewTaskQueue().WithRepo(repos)           │
  │                                  │          │ for each loaded:                         │
  │                                  │          │   queued/pending → queue.Enqueue         │
  │                                  │          │   assigned/running → queue.AttachAssigned│
  └──────────────────────────────────┘          └──────────────────────────────────────────┘

internal/usecase/task_supervisor.go:

  Run loop adds a one-shot bootReconcile invocation 60 s after start:
  for each task in ListByStatus(assigned)+ListByStatus(running):
    if !hub.IsConnected(task.AssignedDeviceID):
       queue.ReassignTasksFromDevice(task.AssignedDeviceID)   // dedupe via device set
```

## Component design

### C1 — `LoadNonTerminal` + `AttachAssigned` (commit 1)

#### `domain.TaskRepository.LoadNonTerminal`

```go
// internal/repository/repository.go
type TaskRepository interface {
    Save(ctx context.Context, t *domain.Task) error
    Delete(ctx context.Context, id string) error
    GetByID(ctx context.Context, id string) (*domain.Task, error)
    GetByGroup(ctx context.Context, groupID string) ([]*domain.Task, error)
    MarkStaleTasksFailed(ctx context.Context, before time.Time) (int, error)
    LoadNonTerminal(ctx context.Context) ([]*domain.Task, error)   // NEW
}
```

Implementation:

```go
// internal/repository/sqlite/task.go
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

Reuses existing `taskSelectColumns` and `scanTasks` — no new deserialization code.

#### `domain.TaskQueue.AttachAssigned`

```go
// internal/domain/taskqueue.go

// AttachAssigned re-inserts a task that already has a non-pending status —
// typically replayed from the repository at boot. The task lands in q.tasks
// (so Get/ListByStatus see it) but is NOT placed in q.queue, since it is
// not awaiting initial scheduling.
//
// Caller is responsible for ensuring task.Status is one of:
//   TaskStatusAssigned, TaskStatusRunning
// For TaskStatusQueued / TaskStatusPending, use Enqueue.
//
// AttachAssigned does not call persist — the task already exists in the repo.
func (q *TaskQueue) AttachAssigned(t *Task) {
    q.mu.Lock()
    defer q.mu.Unlock()
    q.tasks[t.ID] = t
}
```

This is intentionally minimal. It is the inverse of forgetting — restoring memory state to match what is already on disk, without round-tripping through persist.

### C2 — Boot hydration (commit 2)

`cmd/server/main.go` (replacing the existing `MarkStaleTasksFailed` block at line 85-100):

```go
// Hydrate the task queue from sqlite. Tasks that were queued at the
// previous shutdown re-enter the scheduler; tasks that were already
// assigned to a worker stay attached so the worker can report results
// when it reconnects. The boot-reconcile pass in TaskSupervisor handles
// workers that fail to reconnect within the grace window.
loaded, err := repos.Tasks.LoadNonTerminal(context.Background())
if err != nil {
    log.Fatalf("[startup] hydrate task queue: %v", err)
}

taskQueue := domain.NewTaskQueue().WithRepo(repos.Tasks)

var (
    nQueued, nAssigned, nRunning, nPending int
)
for _, t := range loaded {
    switch t.Status {
    case domain.TaskStatusPending, domain.TaskStatusQueued:
        taskQueue.Enqueue(t)
        if t.Status == domain.TaskStatusPending {
            nPending++
        } else {
            nQueued++
        }
    case domain.TaskStatusAssigned:
        taskQueue.AttachAssigned(t)
        nAssigned++
    case domain.TaskStatusRunning:
        taskQueue.AttachAssigned(t)
        nRunning++
    default:
        log.Printf("[startup] unexpected non-terminal status %q for task %s; skipping", t.Status, t.ID)
    }
}
log.Printf("[startup] hydrated tasks: pending=%d queued=%d assigned=%d running=%d (total=%d)",
    nPending, nQueued, nAssigned, nRunning, len(loaded))

h.SetTaskQueue(taskQueue)
// ... rest of main.go unchanged
```

`MarkStaleTasksFailed` is removed from boot. It remains on the repository as a public method (used by ad-hoc cleanup tooling and tests) but is no longer invoked automatically.

### C3 — Boot reconcile in supervisor (commit 3)

`internal/usecase/task_supervisor.go`:

```go
const bootGracePeriod = 60 * time.Second

func (s *TaskSupervisor) Run(ctx context.Context) {
    bootDeadline := time.Now().Add(bootGracePeriod)
    bootReconciled := false

    ticker := time.NewTicker(s.tickInterval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            if !bootReconciled && time.Now().After(bootDeadline) {
                s.reconcileBoot()
                bootReconciled = true
            }
            s.tick(ctx)   // existing logic
        }
    }
}

// reconcileBoot reassigns assigned/running tasks whose worker has not
// reconnected within bootGracePeriod. Runs exactly once.
func (s *TaskSupervisor) reconcileBoot() {
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

Per-device dedupe: if a worker had three tasks, we call `ReassignTasksFromDevice` once for it (not three times).

#### Why 60 s

The cluster-agent's heartbeat interval defaults to 3 s and `FailureTimeout` to 15 s. `HeartbeatMonitor.evictStale` uses `timeout * 3 = 45 s` as its stale threshold (`internal/agent/heartbeat.go:46`). Sixty seconds gives a worker that follows normal-cycle reconnect timing comfortable headroom; it is not so long that an actually-dead worker stalls task throughput indefinitely.

#### Behavior in the gap

Between server boot (t=0) and `t=60 s`:

- Workers reconnect via WS; the hub starts tracking them.
- A worker that owned a `running` task across the restart and has just reconnected sends `MsgTaskResult` when its task finishes. The task is in the in-memory queue (via `AttachAssigned`); the result is processed normally and the task transitions to `completed` (with the corresponding repo write).
- A worker that owned an `assigned` task but had not yet started it can pick up a different task in normal scheduling — but its specific assignment remains until reconcileBoot or until the worker itself disconnects (which fires the live disconnect handler).

After `t=60 s`:

- `reconcileBoot` runs once. Any worker that failed to reconnect has its tasks reassigned. From that moment on, only the live disconnect handler is responsible for handling worker drops.

## Error handling

| Where | Failure | Behavior |
|---|---|---|
| Boot `LoadNonTerminal` | sqlite returns error | `log.Fatalf` — server fails fast (corrupt DB / disk full) |
| Boot hydrate per-task | unknown status (defensive) | log + skip; do not crash |
| Per-mutation `q.persist` | sqlite write fails | log only; in-memory mutation proceeds (existing fail-soft behavior, unchanged) |
| `reconcileBoot` | `ReassignTasksFromDevice` itself does not return error | tasks that exhausted retries inside reassign get marked failed by the queue's existing logic; we log only |

## Testing

### New unit tests

- `internal/repository/sqlite/task_test.go`
  - `TestLoadNonTerminal_FiltersTerminal` — insert one of each status; load returns only pending/queued/assigned/running.
  - `TestLoadNonTerminal_EmptyDB` — returns empty slice, nil error.
  - `TestLoadNonTerminal_PreservesAllFields` — round-trip a task with non-empty `RequiredCapabilities`, `BlockedDeviceIDs`, `Payload`, `ResourceReqs` — assert post-load matches pre-save (modulo time-precision normalization that already exists).
- `internal/domain/taskqueue_test.go`
  - `TestAttachAssigned_AddsToTasksMapNotQueue` — after `AttachAssigned`, `Get(id)` returns the task but `ListQueuedByPriority` does not.
  - `TestAttachAssigned_DoesNotPersist` — pass a mock repo; assert `Save` is not called.
- `internal/usecase/task_supervisor_test.go`
  - `TestReconcileBoot_ReassignsOrphans` — mock `Hub` returns false for one of two assigned-device IDs; assert reassign called for that one only.
  - `TestReconcileBoot_RunsOnce` — advance time twice past deadline; assert reconcile body runs exactly once (track via mock counter).
  - `TestReconcileBoot_DedupesByDevice` — 3 tasks on same device → 1 reassign call.

### Integration test

- `cmd/server/main_test.go` (new minimal test, or extend existing) — start server with seeded sqlite (3 tasks: queued, assigned to live worker, assigned to dead worker), let supervisor tick once past grace window, assert: queued task picked up, live-worker task remains assigned, dead-worker task reassigned.

  *Note:* If `main_test.go` does not exist yet and would require nontrivial harness, this becomes a manual smoke test instead — see below.

### Manual smoke test (verification before merge)

1. Build: `make build`
2. Run server with sqlite at `/tmp/hydra-hyd.db` (clean).
3. Run two `wstub` instances: `wstub --device-ids=A` and `wstub --device-ids=B`, each declaring `--capabilities=compute`.
4. `POST /api/tasks` (5 tasks, `requiredCapabilities=["compute"]`). Confirm distribution.
5. `kill -INT` the server while tasks are in-flight.
6. `sqlite3 /tmp/hydra-hyd.db "SELECT id, status, assigned_device_id FROM tasks"` — expect mixed queued/assigned/running.
7. Restart server. Within 60 s start `wstub --device-ids=A` again but do **not** restart B.
8. Watch logs: `[startup] hydrated tasks: …`, then 60 s later `[supervisor] boot reconcile: reassigned N tasks from non-reconnected worker B`.
9. `curl /api/tasks` — A's tasks complete normally; B's tasks were reassigned to A and complete.
10. Restart server again with no in-flight tasks; confirm `hydrated tasks: pending=0 queued=0 assigned=0 running=0` and no spurious reassigns.

## File map

**New code:**

- `internal/repository/sqlite/task.go` — add `LoadNonTerminal` (≈12 lines)
- `internal/domain/taskqueue.go` — add `AttachAssigned` (≈8 lines)

**Modified:**

- `internal/repository/repository.go` — add `LoadNonTerminal` to `TaskRepository` interface
- `internal/repository/sqlite/task_test.go` — new test cases
- `internal/domain/taskqueue_test.go` — new test cases
- `internal/usecase/task_supervisor.go` — boot reconcile logic (≈40 lines)
- `internal/usecase/task_supervisor_test.go` — reconcile coverage
- `cmd/server/main.go` — replace `MarkStaleTasksFailed` block with hydration loop (~25 lines net change)

**Deleted:** none. `MarkStaleTasksFailed` stays on the repo as a public method even though it is no longer auto-invoked at boot.

## Risks

1. **Stale `running` task whose worker is genuinely dead.** Reconcile catches this at t=60 s and reassigns. Worst case: a task spends 60 s in `running` after restart before being reassigned — much better than current "instantly failed."
2. **Worker reconnects right at the grace boundary.** Race: hub registers worker at t=59.9 s, reconcile fires at t=60.x s. With per-tick check (typical tick = a few seconds), the reconcile may see the worker as connected — fine. If it sees not-yet-connected, the reassign happens, the worker reconnects, sees its task missing, idles. Acceptable: the reassigned task runs on whoever picked it up. No double execution because the original worker's MsgTaskResult goes to a task that no longer exists in queue (silently dropped, same as today's no-task-known case).
3. **Hub.IsConnected semantics.** Need to confirm this returns false for both "never connected this run" and "connected then dropped." If it only tracks current connections (and a previously-connected worker that just disconnected returns false), behavior is correct. Verify in implementation.
4. **`MarkStaleTasksFailed` orphaned on repo.** Keeping the method costs nothing and preserves an escape hatch for ops/tests. Documented in task.go as no longer auto-invoked.

## Open questions

None at spec time. Hub.IsConnected semantics (Risk 3) verified during implementation.

## Follow-ups (separate PRs)

1. Completed-task TTL cleanup goroutine + `Server.TaskRetentionDays` config.
2. Promote `bootGracePeriod` to config if operations request it.
3. Worker-driven reconciliation protocol (option C from brainstorming) — only if reconcile-with-grace proves too aggressive.
4. Optional admin endpoint to inspect persisted task state (`GET /api/internal/tasks?status=...`) — depends on TTL being in place.
