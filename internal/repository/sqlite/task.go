package sqlite

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

// TaskRepository persists domain.Task rows. It is the write-through target
// for domain.TaskQueue mutations.
type TaskRepository struct {
	db dbExecutor
}

func NewTaskRepository(db dbExecutor) *TaskRepository {
	return &TaskRepository{db: db}
}

// Save inserts or updates a task by id (UPSERT).
func (r *TaskRepository) Save(ctx context.Context, t *domain.Task) error {
	reqCaps, _ := json.Marshal(t.RequiredCapabilities)
	if t.RequiredCapabilities == nil {
		reqCaps = []byte("[]")
	}
	blocked, _ := json.Marshal(t.BlockedDeviceIDs)
	if t.BlockedDeviceIDs == nil {
		blocked = []byte("[]")
	}
	payload, _ := json.Marshal(t.Payload)
	if t.Payload == nil {
		payload = []byte("{}")
	}
	var result []byte
	if t.Result != nil {
		result, _ = json.Marshal(t.Result)
	}
	var resourceReqs []byte
	if t.ResourceReqs != nil {
		resourceReqs, _ = json.Marshal(t.ResourceReqs)
	}

	_, err := r.db.ExecContext(ctx, `
		INSERT INTO tasks (
			id, parent_id, orch_id, type, status, priority,
			required_capabilities, preferred_device_id, assigned_device_id,
			payload, result, error,
			created_at, assigned_at, started_at, completed_at,
			timeout_ns, retry_count, max_retries, created_by,
			resource_reqs, blocked_device_ids, ai_schedule, group_id
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		-- Write-once (identity/payload/timeout): id, parent_id, orch_id, type, payload, timeout_ns, max_retries, created_at, created_by
		-- Mutable (lifecycle/routing): status, priority, assigned_device_id, result, error, assigned_at, started_at, completed_at, retry_count, required_capabilities, blocked_device_ids, ai_schedule, group_id
		ON CONFLICT(id) DO UPDATE SET
			status = excluded.status,
			priority = excluded.priority,
			assigned_device_id = excluded.assigned_device_id,
			result = excluded.result,
			error = excluded.error,
			assigned_at = excluded.assigned_at,
			started_at = excluded.started_at,
			completed_at = excluded.completed_at,
			retry_count = excluded.retry_count,
			required_capabilities = excluded.required_capabilities,
			blocked_device_ids = excluded.blocked_device_ids,
			ai_schedule = excluded.ai_schedule,
			group_id = excluded.group_id
	`,
		t.ID, t.ParentID, t.OrchID, t.Type, string(t.Status), string(t.Priority),
		string(reqCaps), t.PreferredDeviceID, t.AssignedDeviceID,
		string(payload), string(result), t.Error,
		t.CreatedAt, t.AssignedAt, t.StartedAt, t.CompletedAt,
		int64(t.Timeout), t.RetryCount, t.MaxRetries, t.CreatedBy,
		string(resourceReqs), string(blocked), encodeAISchedule(t.AISchedule), t.GroupID,
	)
	return err
}

// Delete removes a task by id. Currently unused at runtime.
func (r *TaskRepository) Delete(ctx context.Context, id string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM tasks WHERE id = ?`, id)
	return err
}

// GetByID fetches one task. Returns sql.ErrNoRows when missing.
func (r *TaskRepository) GetByID(ctx context.Context, id string) (*domain.Task, error) {
	row := r.db.QueryRowContext(ctx, taskSelectColumns+` WHERE id = ?`, id)
	return scanTask(row)
}

// GetByGroup returns every task for a group, oldest first.
func (r *TaskRepository) GetByGroup(ctx context.Context, groupID string) ([]*domain.Task, error) {
	rows, err := r.db.QueryContext(ctx,
		taskSelectColumns+` WHERE group_id = ? ORDER BY created_at ASC`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanTasks(rows)
}

const taskSelectColumns = `
	SELECT id, parent_id, orch_id, type, status, priority,
		   required_capabilities, preferred_device_id, assigned_device_id,
		   payload, result, error,
		   created_at, assigned_at, started_at, completed_at,
		   timeout_ns, retry_count, max_retries, created_by,
		   resource_reqs, blocked_device_ids, ai_schedule, group_id
	FROM tasks`

type taskRowScanner interface {
	Scan(dest ...interface{}) error
}

func scanTask(row taskRowScanner) (*domain.Task, error) {
	var (
		t                                          domain.Task
		status, priority                           string
		reqCaps, blocked, payload, result, resReqs string
		aiSched                                    string
		assignedAt, startedAt, completedAt         sql.NullTime
		timeoutNS                                  int64
	)
	err := row.Scan(
		&t.ID, &t.ParentID, &t.OrchID, &t.Type, &status, &priority,
		&reqCaps, &t.PreferredDeviceID, &t.AssignedDeviceID,
		&payload, &result, &t.Error,
		&t.CreatedAt, &assignedAt, &startedAt, &completedAt,
		&timeoutNS, &t.RetryCount, &t.MaxRetries, &t.CreatedBy,
		&resReqs, &blocked, &aiSched, &t.GroupID,
	)
	if err != nil {
		return nil, err
	}
	t.Status = domain.TaskStatus(status)
	t.Priority = domain.TaskPriority(priority)
	t.Timeout = time.Duration(timeoutNS)
	if assignedAt.Valid {
		v := assignedAt.Time
		t.AssignedAt = &v
	}
	if startedAt.Valid {
		v := startedAt.Time
		t.StartedAt = &v
	}
	if completedAt.Valid {
		v := completedAt.Time
		t.CompletedAt = &v
	}
	if reqCaps != "" {
		if err := json.Unmarshal([]byte(reqCaps), &t.RequiredCapabilities); err != nil {
			log.Printf("[taskrepo] required_capabilities unmarshal failed for task %s: %v", t.ID, err)
		}
	}
	if blocked != "" {
		if err := json.Unmarshal([]byte(blocked), &t.BlockedDeviceIDs); err != nil {
			log.Printf("[taskrepo] blocked_device_ids unmarshal failed for task %s: %v", t.ID, err)
		}
	}
	if payload != "" {
		if err := json.Unmarshal([]byte(payload), &t.Payload); err != nil {
			log.Printf("[taskrepo] payload unmarshal failed for task %s: %v", t.ID, err)
		}
	}
	if result != "" {
		var r domain.TaskResult
		if err := json.Unmarshal([]byte(result), &r); err != nil {
			log.Printf("[taskrepo] result unmarshal failed for task %s: %v", t.ID, err)
		} else {
			t.Result = &r
		}
	}
	if resReqs != "" {
		var rr domain.ResourceRequirements
		if err := json.Unmarshal([]byte(resReqs), &rr); err != nil {
			log.Printf("[taskrepo] resource_reqs unmarshal failed for task %s: %v", t.ID, err)
		} else {
			t.ResourceReqs = &rr
		}
	}
	t.AISchedule = decodeAISchedule(aiSched)
	return &t, nil
}

func scanTasks(rows *sql.Rows) ([]*domain.Task, error) {
	var out []*domain.Task
	for rows.Next() {
		t, err := scanTask(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func encodeAISchedule(p *bool) string {
	if p == nil {
		return ""
	}
	if *p {
		return "true"
	}
	return "false"
}

func decodeAISchedule(s string) *bool {
	switch s {
	case "true":
		v := true
		return &v
	case "false":
		v := false
		return &v
	default:
		return nil
	}
}

// Compile-time interface satisfaction.
var _ domain.TaskRepository = (*TaskRepository)(nil)
