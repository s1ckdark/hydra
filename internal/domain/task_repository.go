package domain

import (
	"context"
	"time"
)

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

	// MarkStaleTasksFailed flips every task with status in {queued, assigned,
	// running} that was created before `before` to status=failed with a
	// recovery error message. Returns the number of rows updated. Used at
	// server boot to clean up orphans from a previous run that the in-memory
	// queue did not re-hydrate. The cutoff is typically (server boot time -
	// small grace window) so brand-new tasks created after this boot are not
	// affected.
	MarkStaleTasksFailed(ctx context.Context, before time.Time) (int, error)
}
