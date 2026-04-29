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
			queue.Replay(t)
			stats.Pending++
		case domain.TaskStatusQueued:
			queue.Replay(t)
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
