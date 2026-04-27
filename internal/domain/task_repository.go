package domain

import "context"

// TaskRepository is the persistence boundary for tasks. It lives in the
// domain package so the TaskQueue can depend on it without importing
// internal/repository (which would create a cycle).
type TaskRepository interface {
	// Save inserts or updates a task. Implementations should treat the
	// id as the identity key (UPSERT semantics).
	Save(ctx context.Context, task *Task) error

	// Delete removes a task by id. Currently unused; reserved for future
	// retention/cleanup logic.
	Delete(ctx context.Context, id string) error
}
