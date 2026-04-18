package ai

import (
	"testing"

	"github.com/dave/naga/internal/domain"
)

func fullyLoaded(id string) WorkerSnapshot {
	return WorkerSnapshot{
		DeviceID:        id,
		Capabilities:    []string{"gpu", "cuda"},
		GPUUtilization:  20,
		MemoryFreeGB:    32,
		CPUUsage:        25,
		RunningJobs:     0,
		GPUCount:        1,
		GPUMemoryFreeMB: 24000,
	}
}

func TestScoreForTask_PicksHigherCapacity(t *testing.T) {
	weak := fullyLoaded("weak")
	weak.GPUUtilization = 80
	weak.MemoryFreeGB = 4
	strong := fullyLoaded("strong")

	task := &domain.Task{Priority: domain.TaskPriorityNormal}
	if got := PickBestWorker(task, []WorkerSnapshot{weak, strong}); got == nil || got.DeviceID != "strong" {
		t.Fatalf("expected strong worker, got %+v", got)
	}
}

func TestScoreForTask_BlockedDeviceRejected(t *testing.T) {
	w := fullyLoaded("w1")
	task := &domain.Task{
		Priority:         domain.TaskPriorityNormal,
		BlockedDeviceIDs: []string{"w1"},
	}
	if s := ScoreForTask(task, w); s != ineligible {
		t.Fatalf("blocked worker should be ineligible, got %v", s)
	}
}

func TestScoreForTask_InsufficientGPUMemoryRejected(t *testing.T) {
	w := fullyLoaded("w1")
	w.GPUMemoryFreeMB = 8000
	task := &domain.Task{
		Priority:     domain.TaskPriorityNormal,
		ResourceReqs: &domain.ResourceRequirements{GPUMemoryMB: 16000},
	}
	if s := ScoreForTask(task, w); s != ineligible {
		t.Fatalf("task needing 16GB should be rejected on 8GB-free worker, got %v", s)
	}
}

func TestScoreForTask_CapabilityMismatchRejected(t *testing.T) {
	w := fullyLoaded("w1")
	w.Capabilities = []string{"cpu"}
	task := &domain.Task{
		Priority:             domain.TaskPriorityNormal,
		RequiredCapabilities: []string{"gpu"},
	}
	if s := ScoreForTask(task, w); s != ineligible {
		t.Fatalf("worker missing required capability should be rejected, got %v", s)
	}
}

func TestScoreForTask_UrgentBoostsScore(t *testing.T) {
	w := fullyLoaded("w1")
	normal := &domain.Task{Priority: domain.TaskPriorityNormal}
	urgent := &domain.Task{Priority: domain.TaskPriorityUrgent}

	nScore := ScoreForTask(normal, w)
	uScore := ScoreForTask(urgent, w)
	if uScore <= nScore {
		t.Fatalf("urgent should boost score: normal=%v urgent=%v", nScore, uScore)
	}
	// Urgent multiplier is 2.0
	if got, want := uScore, nScore*2.0; got != want {
		t.Fatalf("urgent should be 2x normal: got %v want %v", got, want)
	}
}

func TestPickBestWorker_NoneEligible(t *testing.T) {
	w := fullyLoaded("w1")
	w.GPUMemoryFreeMB = 100
	task := &domain.Task{
		Priority:     domain.TaskPriorityNormal,
		ResourceReqs: &domain.ResourceRequirements{GPUMemoryMB: 16000},
	}
	if got := PickBestWorker(task, []WorkerSnapshot{w}); got != nil {
		t.Fatalf("expected nil, got %+v", got)
	}
}

func TestPickBestWorker_SkipsBlockedPicksOther(t *testing.T) {
	a := fullyLoaded("a")
	b := fullyLoaded("b")
	task := &domain.Task{
		Priority:         domain.TaskPriorityNormal,
		BlockedDeviceIDs: []string{"a"},
	}
	got := PickBestWorker(task, []WorkerSnapshot{a, b})
	if got == nil || got.DeviceID != "b" {
		t.Fatalf("expected b, got %+v", got)
	}
}
