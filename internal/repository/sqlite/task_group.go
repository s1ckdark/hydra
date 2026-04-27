package sqlite

import (
	"context"
	"encoding/json"
	"log"

	"github.com/s1ckdark/hydra/internal/domain"
)

// TaskGroupRepository persists fan-out batch identity. Aggregate progress
// is derived from the joined tasks at read time, not stored here.
type TaskGroupRepository struct {
	db dbExecutor
}

func NewTaskGroupRepository(db dbExecutor) *TaskGroupRepository {
	return &TaskGroupRepository{db: db}
}

// Save inserts or updates (UPSERT). Updating an existing group only changes
// name and metadata; identity fields (id, created_at, created_by, total_tasks)
// are immutable by convention.
func (r *TaskGroupRepository) Save(ctx context.Context, g *domain.TaskGroup) error {
	metadata, _ := json.Marshal(g.Metadata)
	if g.Metadata == nil {
		metadata = []byte("{}")
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO task_groups (
			id, name, created_at, created_by, total_tasks, metadata
		) VALUES (?, ?, ?, ?, ?, ?)
		-- Identity fields (id, created_at, created_by, total_tasks) are
		-- immutable by convention; only name and metadata can change.
		ON CONFLICT(id) DO UPDATE SET
			name = excluded.name,
			metadata = excluded.metadata
	`, g.ID, g.Name, g.CreatedAt, g.CreatedBy, g.TotalTasks, string(metadata))
	return err
}

// GetByID fetches one group. Returns sql.ErrNoRows when missing.
func (r *TaskGroupRepository) GetByID(ctx context.Context, id string) (*domain.TaskGroup, error) {
	row := r.db.QueryRowContext(ctx, `
		SELECT id, name, created_at, created_by, total_tasks, metadata
		FROM task_groups WHERE id = ?`, id)

	var (
		g        domain.TaskGroup
		metadata string
	)
	if err := row.Scan(&g.ID, &g.Name, &g.CreatedAt, &g.CreatedBy, &g.TotalTasks, &metadata); err != nil {
		return nil, err
	}
	if metadata != "" {
		if err := json.Unmarshal([]byte(metadata), &g.Metadata); err != nil {
			log.Printf("[taskgrouprepo] metadata unmarshal failed for group %s: %v", g.ID, err)
		}
	}
	return &g, nil
}
