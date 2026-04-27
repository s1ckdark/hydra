package domain

import "context"

// TaskRepository is the persistence boundary for tasks. It lives in the
// domain package so the TaskQueue can depend on it without importing
// internal/repository (which would create a cycle).
type TaskRepository interface {
	// Save inserts or updates a task. UPSERT semantics by id.
	Save(ctx context.Context, task *Task) error

	// Delete removes a task by id. Reserved for future cleanup.
	Delete(ctx context.Context, id string) error

	// GetByID fetches one task. Implementations should return sql.ErrNoRows
	// (or an equivalent wrapped error) when the id is not found.
	GetByID(ctx context.Context, id string) (*Task, error)

	// GetByGroup returns every task belonging to a fan-out group, oldest
	// first. Returns an empty slice (not nil) when the group has no tasks.
	GetByGroup(ctx context.Context, groupID string) ([]*Task, error)
}
