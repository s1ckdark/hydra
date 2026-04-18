package usecase

import (
	"context"
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/dave/naga/internal/domain"
	"github.com/dave/naga/internal/infra/ai"
	"github.com/dave/naga/internal/web/ws"
)

// TaskSupervisor periodically reassigns work from failed/timed-out workers
// and push-schedules queued tasks onto the best available worker.
type TaskSupervisor struct {
	taskQueue    *domain.TaskQueue
	wsHub        *ws.Hub
	deviceUC     *DeviceUseCase
	monitorUC    *MonitorUseCase
	mu           sync.Mutex
	knownWorkers map[string]time.Time // deviceID -> last seen time
	interval     time.Duration
}

func NewTaskSupervisor(taskQueue *domain.TaskQueue, wsHub *ws.Hub, deviceUC *DeviceUseCase, monitorUC *MonitorUseCase) *TaskSupervisor {
	return &TaskSupervisor{
		taskQueue:    taskQueue,
		wsHub:        wsHub,
		deviceUC:     deviceUC,
		monitorUC:    monitorUC,
		knownWorkers: make(map[string]time.Time),
		interval:     10 * time.Second,
	}
}

// Start begins the supervision loop
func (s *TaskSupervisor) Start(ctx context.Context) {
	log.Println("[supervisor] task supervisor started")
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Println("[supervisor] task supervisor stopped")
			return
		case <-ticker.C:
			s.check(ctx)
		}
	}
}

func (s *TaskSupervisor) check(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// 1. Reassign tasks from disconnected workers back to the queue.
	if s.wsHub != nil {
		connectedDevices := make(map[string]bool)
		for _, id := range s.wsHub.ConnectedDevices() {
			connectedDevices[id] = true
			s.knownWorkers[id] = time.Now()
		}
		for deviceID, lastSeen := range s.knownWorkers {
			if !connectedDevices[deviceID] && time.Since(lastSeen) > 30*time.Second {
				assignedTasks := s.taskQueue.GetAssignedTasks(deviceID)
				if len(assignedTasks) > 0 {
					log.Printf("[supervisor] worker %s disconnected with %d assigned tasks, reassigning", deviceID, len(assignedTasks))
					reassigned := s.taskQueue.ReassignTasksFromDevice(deviceID)
					for _, task := range reassigned {
						log.Printf("[supervisor] task %s requeued (was on %s)", task.ID, deviceID)
					}
				}
				delete(s.knownWorkers, deviceID)
			}
		}
	}

	// 2. Timed-out running tasks flow back into the queue.
	timedOut := s.taskQueue.CheckTimeouts()
	for _, task := range timedOut {
		log.Printf("[supervisor] task %s timed out, requeued", task.ID)
	}

	// 3. Push-schedule everything currently queued onto the best worker.
	s.scheduleQueue(ctx)
}

// scheduleQueue walks the priority-ordered queue once and assigns each task
// to its highest-scoring eligible connected worker. Running-jobs counts are
// updated in the local snapshot slice so later tasks in the same tick see
// accurate load and spread across workers instead of piling on one.
func (s *TaskSupervisor) scheduleQueue(ctx context.Context) {
	if s.wsHub == nil || s.deviceUC == nil {
		return
	}
	connected := s.wsHub.ConnectedDevices()
	if len(connected) == 0 {
		return
	}
	snaps := make([]ai.WorkerSnapshot, 0, len(connected))
	for _, id := range connected {
		dev, err := s.deviceUC.GetDevice(ctx, id)
		if err != nil {
			continue
		}
		var metrics *domain.DeviceMetrics
		if s.monitorUC != nil {
			metrics = s.monitorUC.GetLatestCached(id)
		}
		running := len(s.taskQueue.GetAssignedTasks(id))
		snaps = append(snaps, buildWorkerSnapshot(dev, metrics, running))
	}
	if len(snaps) == 0 {
		return
	}

	for _, task := range s.taskQueue.ListQueuedByPriority() {
		best := ai.PickBestWorker(task, snaps)
		if best == nil {
			continue
		}
		assigned := s.taskQueue.AssignToDevice(task.ID, best.DeviceID)
		if assigned == nil {
			continue // raced: another pass claimed it
		}
		s.notifyDeviceOfTask(best.DeviceID, assigned)
		bumpRunningJobs(snaps, best.DeviceID)
	}
}

func buildWorkerSnapshot(dev *domain.Device, metrics *domain.DeviceMetrics, runningJobs int) ai.WorkerSnapshot {
	snap := ai.WorkerSnapshot{
		DeviceID:     dev.ID,
		Capabilities: dev.Capabilities,
		RunningJobs:  runningJobs,
		GPUCount:     dev.GPUCount,
	}
	if metrics == nil || metrics.HasError() {
		return snap
	}
	snap.CPUUsage = metrics.CPU.UsagePercent
	snap.MemoryFreeGB = float64(metrics.Memory.Free) / (1024 * 1024 * 1024)
	if metrics.GPU != nil && len(metrics.GPU.GPUs) > 0 {
		var utilSum float64
		var freeBytes uint64
		for _, g := range metrics.GPU.GPUs {
			utilSum += g.UsagePercent
			freeBytes += g.MemoryFree
		}
		snap.GPUUtilization = utilSum / float64(len(metrics.GPU.GPUs))
		snap.GPUMemoryFreeMB = int(freeBytes / (1024 * 1024))
	}
	return snap
}

func bumpRunningJobs(snaps []ai.WorkerSnapshot, deviceID string) {
	for i := range snaps {
		if snaps[i].DeviceID == deviceID {
			snaps[i].RunningJobs++
			return
		}
	}
}

// notifyDeviceOfTask sends a task assignment notification via WebSocket
func (s *TaskSupervisor) notifyDeviceOfTask(deviceID string, task *domain.Task) {
	if s.wsHub == nil {
		return
	}

	payload, err := json.Marshal(task)
	if err != nil {
		return
	}

	msg := &ws.Message{
		Type:      ws.MsgTaskAssign,
		DeviceID:  deviceID,
		TaskID:    task.ID,
		Payload:   payload,
		Timestamp: time.Now(),
	}

	if err := s.wsHub.SendToDevice(deviceID, msg); err != nil {
		log.Printf("[supervisor] failed to send task %s to %s: %v", task.ID, deviceID, err)
	}
}
