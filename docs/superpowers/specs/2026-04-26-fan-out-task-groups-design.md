# Fan-out Task Groups (Parallel Batch) — Design

## Context

Hydra's task system today is one-task-at-a-time: every `POST /api/tasks` produces a single `domain.Task` that the supervisor dispatches to one worker. Real workloads almost always come as a **batch of independent tasks** — "run these 50 inferences across the GPU pool, tell me when they're all done" — and the only way to express that today is to fire 50 separate POSTs and track 50 task IDs by hand.

This design adds a parallel-batch primitive: clients submit N tasks as one request, the server returns a single `groupId`, the supervisor distributes the tasks across capable workers, and clients poll one endpoint to see aggregate progress and a final status. Sharded inference (C-α) and DAG workflows (C-γ) are explicitly **not** in scope — those are separate features with different data models. This spec covers only the C-β path.

## Goals

- Submit N independent tasks in one HTTP call; receive a single `groupId`.
- Poll `GET /api/groups/:id` to see aggregate progress and per-task results.
- Surface a tri-state outcome (`completed` / `partial` / `failed`) so 99/100-success cases are distinguishable from a total failure.
- Reuse the existing capability filter, rule-based scorer, and AI scheduler — no fork in the scheduling path.
- Strict additive: existing single-task POST continues to work unchanged.

## Non-Goals

- Sharded inference / data-slicing of a single task across workers (C-α).
- DAG workflows / task-to-task dependencies (C-γ).
- Group cancellation (`DELETE /api/groups/:id`).
- Group webhook callbacks or WebSocket subscription — polling only.
- Group-level retention/TTL — groups and tasks live forever in v1.
- A `GET /api/groups` list endpoint — usable backlog item once a UI exists, but not for v1.
- Group-level scheduling priority — per-task `priority` already covers this.
- Per-group AI scheduling override — per-task `aiSchedule` already exists; clients that want a uniform policy set it on every task in the batch.

## Architecture overview

```
                                                         ┌─────────────────┐
 Client ── POST /api/tasks/batch ──┐                    │  task_groups    │
                                   │                    │  (hybrid)       │
                                   ▼                    ├─────────────────┤
                          ┌────────────────┐  group_id  │ id, name        │
                          │ APITaskBatch-  │◀───────────│ created_at      │
                          │ Create         │            │ created_by      │
                          └────────────────┘            │ total_tasks     │
                                   │                    │ metadata JSON   │
                                   │ Enqueue N tasks    └─────────────────┘
                                   │ + groupId on each          ▲
                                   ▼                            │
                          ┌────────────────┐                    │ JOIN
                          │  TaskQueue     │                    │
                          │  (existing)    │                    │
                          └────────────────┘                    │
                                   │                            │
                                   ▼                            │
                          ┌────────────────┐                    │
                          │ TaskSupervisor │                    │
                          │ ScheduleNow x1 │                    │
                          │ (existing)     │                    │
                          └────────────────┘                    │
                                                                │
 Client ── GET /api/groups/:id ◀───────────────────────────────┘
                                  status: running|completed|partial|failed
                                  totals: completed N, failed M, queued K, running R
                                  tasks[] (optional: ?detail=full)
```

Two persistence shapes:

- **`task_groups` table** — one row per group, immutable identity (id, name, created_at, created_by, total_tasks, metadata). Survives task cleanup.
- **`tasks.group_id` column** — every task either belongs to one group (FK) or stands alone (NULL).

Aggregate group status is **derived** from member tasks at every read — there is no counter to drift out of sync. The `total_tasks` column is the only batch-level fact stored separately, kept immutable so partial completion stays meaningful even if individual task rows are later deleted.

## Data model

### Migration

```sql
-- migrations/00X_task_groups.sql
CREATE TABLE IF NOT EXISTS task_groups (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL DEFAULT '',
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  TEXT NOT NULL DEFAULT '',
    total_tasks INTEGER NOT NULL,
    metadata    TEXT NOT NULL DEFAULT '{}'
);

ALTER TABLE tasks ADD COLUMN group_id TEXT REFERENCES task_groups(id);
CREATE INDEX IF NOT EXISTS idx_tasks_group_id ON tasks(group_id);
```

### Domain types — `internal/domain/task_group.go` (new file)

```go
type TaskGroupStatus string
const (
    TaskGroupStatusRunning   TaskGroupStatus = "running"
    TaskGroupStatusCompleted TaskGroupStatus = "completed"
    TaskGroupStatusPartial   TaskGroupStatus = "partial"
    TaskGroupStatusFailed    TaskGroupStatus = "failed"
)

type TaskGroup struct {
    ID         string                 `json:"id"`
    Name       string                 `json:"name,omitempty"`
    CreatedAt  time.Time              `json:"createdAt"`
    CreatedBy  string                 `json:"createdBy,omitempty"`
    TotalTasks int                    `json:"totalTasks"`
    Metadata   map[string]interface{} `json:"metadata,omitempty"`
}

type TaskGroupSnapshot struct {
    TaskGroup
    Status    TaskGroupStatus `json:"status"`
    Completed int             `json:"completed"`
    Failed    int             `json:"failed"`
    Running   int             `json:"running"`
    Queued    int             `json:"queued"`
    Tasks     []*Task         `json:"tasks,omitempty"`
}

func DeriveGroupStatus(tasks []*Task, total int) TaskGroupStatus {
    var completed, failed, terminal int
    for _, t := range tasks {
        switch t.Status {
        case TaskStatusCompleted:
            completed++; terminal++
        case TaskStatusFailed, TaskStatusCancelled:
            failed++; terminal++
        }
    }
    if terminal < total { return TaskGroupStatusRunning }
    if failed == 0      { return TaskGroupStatusCompleted }
    if completed == 0   { return TaskGroupStatusFailed }
    return TaskGroupStatusPartial
}
```

### Task addition

```go
type Task struct {
    // ...existing fields
    GroupID string `json:"groupId,omitempty" db:"group_id"`
}
```

## API surface

### `POST /api/tasks/batch` — new

Mounted under the same Tailscale-auth middleware group as the existing mutating task routes.

**Request body:**

```json
{
  "name": "morning-batch-001",
  "metadata": { "owner": "dave" },
  "tasks": [
    {
      "type": "infer",
      "priority": "normal",
      "requiredCapabilities": ["gpu"],
      "payload": { "input": "row1" },
      "timeout": 60,
      "maxRetries": 1,
      "aiSchedule": null
    },
    { "type": "infer", "payload": { "input": "row2" } },
    { "type": "infer", "payload": { "input": "row3" } }
  ]
}
```

`name` and `metadata` are optional. Each entry in `tasks` is the same shape the existing `POST /api/tasks` already accepts; per-task `aiSchedule` is honoured.

**Validation (returns 400 on failure, no group row written):**

- `tasks` empty or missing → "tasks: must contain at least one task"
- Any task missing `type` → "tasks[i]: type is required"
- `metadata` not a JSON object (string/array/null) → "metadata: must be a JSON object"

**Response 201:**

```json
{
  "id": "20260426010203-abc123",
  "name": "morning-batch-001",
  "createdAt": "2026-04-26T01:02:03+09:00",
  "totalTasks": 3,
  "metadata": { "owner": "dave" },
  "status": "running",
  "completed": 0, "failed": 0, "running": 0, "queued": 3,
  "tasks": [
    { "id": "...", "groupId": "20260426...", "status": "queued", ... },
    { "id": "...", "groupId": "20260426...", "status": "queued", ... },
    { "id": "...", "groupId": "20260426...", "status": "queued", ... }
  ]
}
```

The embedded `tasks[]` is the freshly-inserted set, in the **same order as the request**, so the client can pair task IDs back to its inputs without an extra lookup. Subsequent polls use the lightweight default response.

### `GET /api/groups/:id` — new

**Default lightweight response:**

```json
{
  "id": "...", "name": "...", "createdAt": "...", "createdBy": "...",
  "totalTasks": 3, "metadata": {...},
  "status": "partial",
  "completed": 2, "failed": 1, "running": 0, "queued": 0
}
```

**With `?detail=full`:** same shape plus `tasks: [...]` (every task object joined from `tasks WHERE group_id=?`).

**404** when no `task_groups` row exists.

### `POST /api/tasks` (existing) — unchanged

`groupId` is included in the response object (empty string for ungrouped tasks). No request shape change. No behaviour change.

## Scheduling integration

The supervisor's `scheduleQueue` does not need to know batches exist — it walks the priority-ordered queue and assigns each task on its own merits. The integration point is on the **POST handler**: enqueue all N tasks first, then call `taskSupervisor.ScheduleNow(ctx)` exactly once. Calling ScheduleNow per task would rebuild snapshots and re-fetch every device through Tailscale N times for no benefit.

```go
// internal/web/handler/task_handler.go
func (h *Handler) APITaskBatchCreate(c echo.Context) error {
    // 1. Parse + validate
    // 2. Begin DB transaction
    // 3. Insert task_groups row
    // 4. For each task: generateID, set GroupID, taskQueue.Enqueue, repos.Tasks.Save
    // 5. Commit (or rollback on any error)
    // 6. taskSupervisor.ScheduleNow(ctx)  -- exactly once
    // 7. Build TaskGroupSnapshot with embedded tasks
    // 8. 201 Created
}
```

The existing `bumpRunningJobs(snaps, deviceID)` in `scheduleQueue` already updates the in-tick snapshot slice every time a task is assigned, so later tasks in the same pass see the freshly-assigned worker as having one more running job. This makes batch tasks naturally spread across the worker pool through the rule-based Queue weight (10%) — no new round-robin code is required.

Per-task `aiSchedule` (already implemented in B) keeps working inside batches: clients can mix AI-scheduled and rule-based tasks in one batch, and `aiCallBudget=5/tick` continues to cap how many tasks consult the AI per scheduling pass.

## Failure & lifecycle

### Status transitions

```
              (created)
                 │
                 ▼
            ┌────────┐
            │running │ ◀── any task in queued/assigned/running
            └────────┘
                 │
         all tasks terminal
                 │
        ┌────────┼────────┐
        ▼        ▼        ▼
   ┌────────┐ ┌──────┐ ┌──────┐
   │complete│ │partl │ │failed│
   └────────┘ └──────┘ └──────┘
   completed=N  comp+fail   failed=N
   failed=0     mixed       comp=0
```

- Status is computed at every GET. There is no transition trigger, no event hook, and no cached counter.
- `cancelled` tasks are counted as `failed` for the purpose of group status.

### One-way derivation

Group state always flows from tasks; there is no API or internal call that mutates a group's status directly. The only group fields a client can ever set are `name` and `metadata`, and only at batch creation time.

### Edge cases

| Scenario | Behaviour |
|---|---|
| `tasks` is empty | 400, no group row written |
| One task has `type: ""` | 400, full transaction rolled back |
| GET while a transition is mid-flight | Eventually consistent — next GET picks up the new status |
| Tailscale auth missing | 403 (existing middleware) |
| Very large batch (e.g. 10k tasks) | Accepted. Single SQLite transaction handles bulk INSERT well. Operational sizing is a follow-up. |
| Task cleanup deletes some rows later | `total_tasks` stays as originally submitted. Status derivation treats missing rows as "still running" (`terminal < total`), which is the safest interpretation. |

## Files touched

### New
- `internal/domain/task_group.go` — types + `DeriveGroupStatus`
- `internal/repository/repositories.go` — `TaskGroupRepo` interface
- `internal/repository/sqlite/task_group.go` — Save/GetByID
- `internal/repository/sqlite/task_group_test.go`
- `internal/web/handler/task_group_handler.go` — `APITaskBatchCreate`, `APIGetGroup`
- `internal/web/handler/task_group_handler_test.go`
- `migrations/<n>_task_groups.up.sql` and `<n>_task_groups.down.sql`

### Modified
- `internal/domain/task.go` — `GroupID` field
- `internal/repository/sqlite/task.go` — read/write `group_id` in existing CRUD
- `cmd/server/main.go` — register two new routes
- `internal/web/handler/task_handler.go` — include `groupId` in responses (1 line)

## Testing

### Unit
- `TestDeriveGroupStatus_AllCompleted`, `_AllFailed`, `_Partial`, `_OneRunning`, `_LessTasksThanTotal`
- `TestTaskGroupRepo_SaveAndGet`, `_GetByID_NotFound`
- `TestAPITaskBatchCreate_HappyPath`, `_EmptyTasks`, `_InvalidTaskRollsBackTransaction`
- `TestAPIGetGroup_DerivedStatus`, `_DetailFull`, `_NotFound`

### Manual end-to-end
1. **Spread** — three wstubs + 6-task batch → each worker receives roughly 2 tasks.
2. **Capability routing inside batch** — gpu+cpu mixed batch → gpu tasks land only on gpu workers.
3. **Partial transition** — drive selected tasks into `failed` state, confirm group reports `partial`.
4. **DB consistency** — after batch, `SELECT COUNT(*) FROM tasks WHERE group_id=?` matches `total_tasks`.

## Reuse

- `domain.TaskQueue.Enqueue` — already takes a `*Task`; just set `GroupID` before calling.
- `internal/usecase/task_supervisor.TaskSupervisor.ScheduleNow` — added in the prior PR for single-POST scheduling; reused as-is.
- `internal/web/middleware/apikey.go` and the existing Tailscale auth group — same protections as `POST /api/tasks`.
- `domain.TaskStatus` constants — group status derivation depends only on existing terminal states.

## Migration / rollout

- Backwards compatible: clients that only use `POST /api/tasks` and `GET /api/tasks/:id` see no change.
- A migration adds one table and one column; both default-empty for existing rows. No data backfill required.
- The new endpoints are gated behind the same Tailscale auth as the existing mutating routes — no new auth surface.
