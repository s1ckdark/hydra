package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

func newGroupRepoForTest(t *testing.T) *TaskGroupRepository {
	t.Helper()
	db, err := NewDB(":memory:")
	if err != nil {
		t.Fatalf("NewDB: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return NewTaskGroupRepository(db.db)
}

func TestTaskGroupRepo_SaveAndGet(t *testing.T) {
	r := newGroupRepoForTest(t)
	ctx := context.Background()

	g := &domain.TaskGroup{
		ID:         "g1",
		Name:       "morning-batch",
		CreatedAt:  time.Now().UTC().Truncate(time.Second),
		CreatedBy:  "dave",
		TotalTasks: 7,
		Metadata:   map[string]interface{}{"owner": "dave"},
	}
	if err := r.Save(ctx, g); err != nil {
		t.Fatalf("save: %v", err)
	}
	got, err := r.GetByID(ctx, "g1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Name != "morning-batch" || got.TotalTasks != 7 || got.Metadata["owner"] != "dave" {
		t.Errorf("round-trip mismatch: %+v", got)
	}
}

func TestTaskGroupRepo_GetByID_NotFound(t *testing.T) {
	r := newGroupRepoForTest(t)
	_, err := r.GetByID(context.Background(), "missing")
	if !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("err = %v, want sql.ErrNoRows", err)
	}
}
