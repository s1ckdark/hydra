package usecase

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/infra/ai"
	"github.com/s1ckdark/hydra/internal/web/ws"
)

// TestTaskSupervisor_ConcurrentSettersNoRace exercises the setter paths
// against the scheduling read paths so `go test -race` flags any race.
// resolveAlwaysConsult is only called from within the s.mu-locked region
// (via scheduleQueue), so the reader goroutine uses ScheduleNow which
// acquires s.mu before reading the same fields.
func TestTaskSupervisor_ConcurrentSettersNoRace(t *testing.T) {
	taskQueue := domain.NewTaskQueue()
	s := NewTaskSupervisor(taskQueue, nil, nil, nil)

	var wg sync.WaitGroup
	stop := make(chan struct{})

	// Writer goroutine: hammers both setters concurrently.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
				s.SetAlwaysConsultAI(true)
				s.SetAIArbiter(nil, 0.10, 5, 3*time.Second)
				s.SetAlwaysConsultAI(false)
			}
		}
	}()

	// Reader goroutine: ScheduleNow acquires s.mu and calls scheduleQueue
	// which internally calls resolveAlwaysConsult — reads the same fields.
	// Using ScheduleNow (not resolveAlwaysConsult directly) because
	// resolveAlwaysConsult is only safe to call while holding s.mu.
	wg.Add(1)
	go func() {
		defer wg.Done()
		ctx := context.Background()
		for {
			select {
			case <-stop:
				return
			default:
				s.ScheduleNow(ctx)
			}
		}
	}()

	time.Sleep(50 * time.Millisecond)
	close(stop)
	wg.Wait()
}

func TestReconcileBoot_ReassignsTasksFromDisconnectedWorkers(t *testing.T) {
	taskQueue := domain.NewTaskQueue()
	hub := ws.NewHub() // no clients registered → IsConnected returns false for all
	s := NewTaskSupervisor(taskQueue, hub, nil, nil)

	// Two assigned tasks across two devices, both disconnected.
	taskQueue.Enqueue(&domain.Task{ID: "t1", Priority: domain.TaskPriorityNormal, MaxRetries: 3})
	taskQueue.AssignToDevice("t1", "dev-1", nil)
	taskQueue.Enqueue(&domain.Task{ID: "t2", Priority: domain.TaskPriorityNormal, MaxRetries: 3})
	taskQueue.AssignToDevice("t2", "dev-2", nil)

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
		taskQueue.AssignToDevice(id, "dev-A", nil)
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
	taskQueue.AssignToDevice("t1", "dev-1", nil)

	s.reconcileBoot(context.Background()) // must not panic

	if got := taskQueue.Get("t1"); got.Status != domain.TaskStatusAssigned {
		t.Errorf("t1.Status = %q; want unchanged when hub is nil", got.Status)
	}
}

func TestBuildWorkerSnapshotPopulatesPerGPU(t *testing.T) {
	dev := &domain.Device{ID: "gpu1", GPUCount: 2}
	metrics := &domain.DeviceMetrics{
		GPU: &domain.GPUMetrics{GPUs: []domain.SingleGPUMetrics{
			{Index: 0, MemoryFree: 20000 * 1024 * 1024, UsagePercent: 15},
			{Index: 1, MemoryFree: 4000 * 1024 * 1024, UsagePercent: 90},
		}},
	}
	snap := buildWorkerSnapshot(dev, metrics, 0)
	if len(snap.GPUs) != 2 {
		t.Fatalf("GPUs = %v", snap.GPUs)
	}
	if snap.GPUs[0].MemoryFreeMB != 20000 || snap.GPUs[1].Utilization != 90 {
		t.Fatalf("GPUs = %+v", snap.GPUs)
	}
}

func TestBumpGPUReservationSubtracts(t *testing.T) {
	snaps := []ai.WorkerSnapshot{{DeviceID: "gpu1",
		GPUs: []ai.GPUFree{{Index: 0, MemoryFreeMB: 20000}, {Index: 1, MemoryFreeMB: 24000}}}}
	bumpGPUReservation(snaps, "gpu1", []int{1}, 16000)
	if snaps[0].GPUs[1].MemoryFreeMB != 8000 {
		t.Fatalf("free = %d", snaps[0].GPUs[1].MemoryFreeMB)
	}
	if snaps[0].GPUs[0].MemoryFreeMB != 20000 {
		t.Fatalf("untouched GPU changed: %d", snaps[0].GPUs[0].MemoryFreeMB)
	}
}
