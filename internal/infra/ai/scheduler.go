package ai

import (
	"encoding/json"
	"fmt"

	"github.com/dave/naga/internal/domain"
)

// BuildSelectionPrompt constructs the prompt sent to an AI provider for
// head node election. The AI must respond with ONLY valid JSON.
func BuildSelectionPrompt(candidates []domain.ElectionCandidate) string {
	candidateJSON, _ := json.MarshalIndent(candidates, "", "  ")
	return fmt.Sprintf(`You are a orch management AI. The head node has failed and you must select the best replacement.

Candidates:
%s

Select considering: lower GPU utilization, more free memory, lower latency, fewer running jobs.

Respond with ONLY valid JSON:
{"node_id": "<selected_node_id>", "reason": "<brief explanation>"}`, string(candidateJSON))
}

// RuleBasedScheduler is the deterministic fallback scheduler.
// Scoring weights: GPU 40%, Memory 30%, CPU 20%, Queue depth 10%,
// multiplied by a priority factor (urgent 2.0, high 1.3, normal 1.0, low 0.7).
type RuleBasedScheduler struct{}

// ineligible is the sentinel score for a worker that cannot run a task.
const ineligible = -1.0

// Schedule picks the best eligible worker for task. Returns nil if none qualify.
func (s *RuleBasedScheduler) Schedule(task *domain.Task, workers []WorkerSnapshot) *ScheduleDecision {
	best := PickBestWorker(task, workers)
	if best == nil {
		return nil
	}
	return &ScheduleDecision{
		DeviceID:   best.DeviceID,
		Reason:     "rule-based: task-aware score with anti-affinity",
		Confidence: 0.7,
	}
}

// PickBestWorker returns the highest-scoring eligible worker for task, or nil.
func PickBestWorker(task *domain.Task, workers []WorkerSnapshot) *WorkerSnapshot {
	var best *WorkerSnapshot
	bestScore := ineligible
	for i := range workers {
		s := ScoreForTask(task, workers[i])
		if s <= ineligible {
			continue
		}
		if best == nil || s > bestScore {
			bestScore = s
			best = &workers[i]
		}
	}
	return best
}

// ScoreForTask returns a placement score for w given task. Higher = better.
// Returns `ineligible` if w cannot run task due to capability, resource, or
// anti-affinity constraints.
func ScoreForTask(task *domain.Task, w WorkerSnapshot) float64 {
	if task == nil {
		return ineligible
	}
	// Anti-affinity: worker previously failed this task.
	for _, blocked := range task.BlockedDeviceIDs {
		if blocked == w.DeviceID {
			return ineligible
		}
	}
	// Capability match: every required capability must be present.
	if !hasAllCapabilities(w.Capabilities, task.RequiredCapabilities) {
		return ineligible
	}
	// Strict resource check: reject if worker can't physically fit the task.
	if r := task.ResourceReqs; r != nil {
		if r.GPUMemoryMB > 0 && r.GPUMemoryMB > w.GPUMemoryFreeMB {
			return ineligible
		}
		if r.MemoryMB > 0 && float64(r.MemoryMB)/1024.0 > w.MemoryFreeGB {
			return ineligible
		}
	}
	// Soft score: weighted resource availability.
	gpuFree := 100 - w.GPUUtilization
	memScore := w.MemoryFreeGB * 5.0
	cpuFree := 100 - w.CPUUsage
	queueScore := float64(100 - w.RunningJobs*10)
	if queueScore < 0 {
		queueScore = 0
	}
	base := gpuFree*0.4 + memScore*0.3 + cpuFree*0.2 + queueScore*0.1
	return base * priorityMultiplier(task.Priority)
}

func priorityMultiplier(p domain.TaskPriority) float64 {
	switch p {
	case domain.TaskPriorityUrgent:
		return 2.0
	case domain.TaskPriorityHigh:
		return 1.3
	case domain.TaskPriorityLow:
		return 0.7
	default:
		return 1.0
	}
}

func hasAllCapabilities(have, need []string) bool {
	if len(need) == 0 {
		return true
	}
	set := make(map[string]struct{}, len(have))
	for _, c := range have {
		set[c] = struct{}{}
	}
	for _, req := range need {
		if _, ok := set[req]; !ok {
			return false
		}
	}
	return true
}

// BuildTaskSchedulingPrompt constructs the prompt sent to an AI provider for
// task scheduling. The AI must respond with ONLY valid JSON.
func BuildTaskSchedulingPrompt(task *domain.Task, workers []WorkerSnapshot) string {
	taskJSON, _ := json.MarshalIndent(task, "", "  ")
	workersJSON, _ := json.MarshalIndent(workers, "", "  ")
	return fmt.Sprintf(`You are a orch task scheduler. Select the best worker for the given task.

Task:
%s

Available workers:
%s

Choose the worker that best matches the task requirements considering GPU availability, free memory, CPU usage, and current queue depth.

Respond with ONLY valid JSON (no explanation, no markdown):
{"device_id": "<selected_device_id>", "reason": "<brief explanation>", "confidence": <0.0-1.0>}`,
		string(taskJSON), string(workersJSON))
}

// BuildCapacityEstimationPrompt constructs the prompt for capacity estimation.
// The AI must respond with ONLY valid JSON.
func BuildCapacityEstimationPrompt(worker WorkerSnapshot, pendingTasks []*domain.Task) string {
	workerJSON, _ := json.MarshalIndent(worker, "", "  ")
	tasksJSON, _ := json.MarshalIndent(pendingTasks, "", "  ")
	return fmt.Sprintf(`You are a orch resource estimator. Estimate the remaining capacity of the given worker.

Worker:
%s

Pending tasks (already queued):
%s

Estimate how many additional task slots remain and identify the primary bottleneck.

Respond with ONLY valid JSON (no explanation, no markdown):
{"available_gpu_percent": <0-100>, "available_memory_gb": <float>, "estimated_slots": <int>, "bottleneck": "<gpu|memory|cpu|none>", "recommendation": "<brief advice>"}`,
		string(workerJSON), string(tasksJSON))
}
