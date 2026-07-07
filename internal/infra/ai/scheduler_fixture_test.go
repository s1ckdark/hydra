package ai

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

// 픽스처는 Python sim(python/src/hydra_client/sim.py)과의 점수 패리티 계약이다.
// 스케줄러 로직을 바꿨다면:
//   HYDRA_UPDATE_FIXTURES=1 go test ./internal/infra/ai/ -run TestSchedulerFixtures
// 로 재생성한 뒤 python 테스트(test_sim_parity.py)를 통과시키고 함께 커밋할 것.

type fixtureGPU struct {
	Index        int     `json:"index"`
	MemoryFreeMB int     `json:"memoryFreeMB"`
	Utilization  float64 `json:"utilization"`
}

type fixtureWorker struct {
	DeviceID        string       `json:"deviceId"`
	Capabilities    []string     `json:"capabilities"`
	GPUUtilization  float64      `json:"gpuUtilization"`
	MemoryFreeGB    float64      `json:"memoryFreeGB"`
	CPUUsage        float64      `json:"cpuUsage"`
	RunningJobs     int          `json:"runningJobs"`
	GPUCount        int          `json:"gpuCount"`
	GPUMemoryFreeMB int          `json:"gpuMemoryFreeMB"`
	GPUs            []fixtureGPU `json:"gpus,omitempty"`
}

type fixtureTask struct {
	Priority             string                       `json:"priority"`
	RequiredCapabilities []string                     `json:"requiredCapabilities,omitempty"`
	PreferredDeviceID    string                       `json:"preferredDeviceId,omitempty"`
	BlockedDeviceIDs     []string                     `json:"blockedDeviceIds,omitempty"`
	ResourceReqs         *domain.ResourceRequirements `json:"resourceReqs,omitempty"`
}

type fixtureCase struct {
	Name          string        `json:"name"`
	Task          fixtureTask   `json:"task"`
	Worker        fixtureWorker `json:"worker"`
	ExpectedScore float64       `json:"expectedScore"`
}

const fixturePath = "../../../python/tests/fixtures/scheduler/cases.json"

func baseWorker() fixtureWorker {
	return fixtureWorker{
		DeviceID: "gpu1", Capabilities: []string{"gpu", "compute"},
		GPUUtilization: 20, MemoryFreeGB: 32, CPUUsage: 10,
		RunningJobs: 1, GPUCount: 2, GPUMemoryFreeMB: 40000,
	}
}

func fixtureCases() []fixtureCase {
	cases := []fixtureCase{
		{Name: "baseline_normal", Task: fixtureTask{Priority: "normal"}, Worker: baseWorker()},
		{Name: "priority_urgent", Task: fixtureTask{Priority: "urgent"}, Worker: baseWorker()},
		{Name: "priority_high", Task: fixtureTask{Priority: "high"}, Worker: baseWorker()},
		{Name: "priority_low", Task: fixtureTask{Priority: "low"}, Worker: baseWorker()},
		{Name: "priority_unknown_defaults_normal", Task: fixtureTask{Priority: "weird"}, Worker: baseWorker()},
		{Name: "blocked_device", Task: fixtureTask{Priority: "normal",
			BlockedDeviceIDs: []string{"gpu1"}}, Worker: baseWorker()},
		{Name: "pinned_other_device", Task: fixtureTask{Priority: "normal",
			PreferredDeviceID: "gpu9"}, Worker: baseWorker()},
		{Name: "pinned_this_device", Task: fixtureTask{Priority: "normal",
			PreferredDeviceID: "gpu1"}, Worker: baseWorker()},
		{Name: "missing_capability", Task: fixtureTask{Priority: "normal",
			RequiredCapabilities: []string{"gpu", "cuda12"}}, Worker: baseWorker()},
		{Name: "gpu_mem_does_not_fit", Task: fixtureTask{Priority: "normal",
			ResourceReqs: &domain.ResourceRequirements{GPUMemoryMB: 50000}}, Worker: baseWorker()},
		{Name: "gpu_mem_exact_fit", Task: fixtureTask{Priority: "normal",
			ResourceReqs: &domain.ResourceRequirements{GPUMemoryMB: 40000}}, Worker: baseWorker()},
		{Name: "ram_does_not_fit", Task: fixtureTask{Priority: "normal",
			ResourceReqs: &domain.ResourceRequirements{MemoryMB: 64 * 1024}}, Worker: baseWorker()},
	}
	// queueScore 클램프 경계: RunningJobs 10 → 0, 12 → 0 (음수 방지)
	w := baseWorker()
	w.RunningJobs = 10
	cases = append(cases, fixtureCase{Name: "queue_clamp_at_10",
		Task: fixtureTask{Priority: "normal"}, Worker: w})
	w2 := baseWorker()
	w2.RunningJobs = 12
	cases = append(cases, fixtureCase{Name: "queue_clamp_below_zero",
		Task: fixtureTask{Priority: "normal"}, Worker: w2})

	// --- per-GPU packing cases (spec §6) ---
	pergpu := func(gpus ...fixtureGPU) fixtureWorker {
		w := baseWorker()
		w.GPUs = gpus
		return w
	}
	rr := func(memMB, count int) *domain.ResourceRequirements {
		return &domain.ResourceRequirements{GPUMemoryMB: memMB, GPUCount: count}
	}
	cases = append(cases,
		fixtureCase{Name: "pergpu_split_vram_rejected",
			Task:   fixtureTask{Priority: "normal", ResourceReqs: rr(20000, 0)},
			Worker: pergpu(fixtureGPU{0, 10000, 20}, fixtureGPU{1, 10000, 30})},
		fixtureCase{Name: "pergpu_single_best_fit_uses_selected_util",
			Task:   fixtureTask{Priority: "normal", ResourceReqs: rr(16000, 0)},
			Worker: pergpu(fixtureGPU{0, 24000, 10}, fixtureGPU{1, 20000, 50})},
		fixtureCase{Name: "pergpu_exact_fit_passes",
			Task:   fixtureTask{Priority: "normal", ResourceReqs: rr(20000, 1)},
			Worker: pergpu(fixtureGPU{0, 20000, 40})},
		fixtureCase{Name: "pergpu_two_of_three",
			Task:   fixtureTask{Priority: "normal", ResourceReqs: rr(16000, 2)},
			Worker: pergpu(fixtureGPU{0, 8000, 90}, fixtureGPU{1, 24000, 30}, fixtureGPU{2, 20000, 10})},
		fixtureCase{Name: "pergpu_count_insufficient",
			Task:   fixtureTask{Priority: "normal", ResourceReqs: rr(8000, 3)},
			Worker: pergpu(fixtureGPU{0, 10000, 0}, fixtureGPU{1, 10000, 0})},
		fixtureCase{Name: "pergpu_count_only_no_mem",
			Task:   fixtureTask{Priority: "normal", ResourceReqs: rr(0, 2)},
			Worker: pergpu(fixtureGPU{0, 100, 10}, fixtureGPU{1, 200, 20}, fixtureGPU{2, 50, 30})},
		fixtureCase{Name: "pergpu_no_gpu_requirement_uses_node_util",
			Task:   fixtureTask{Priority: "normal"},
			Worker: pergpu(fixtureGPU{0, 10000, 5}, fixtureGPU{1, 10000, 95})},
		fixtureCase{Name: "fallback_no_pergpu_multi_rejected",
			Task: fixtureTask{Priority: "normal", ResourceReqs: rr(1000, 2)}, Worker: baseWorker()},
		fixtureCase{Name: "fallback_no_pergpu_single_fits",
			Task: fixtureTask{Priority: "normal", ResourceReqs: rr(16000, 0)}, Worker: baseWorker()},
	)

	for i := range cases {
		cases[i].ExpectedScore = ScoreForTask(
			toDomainTask(cases[i].Task), toSnapshot(cases[i].Worker))
	}
	return cases
}

func toDomainTask(f fixtureTask) *domain.Task {
	return &domain.Task{
		Priority:             domain.TaskPriority(f.Priority),
		RequiredCapabilities: f.RequiredCapabilities,
		PreferredDeviceID:    f.PreferredDeviceID,
		BlockedDeviceIDs:     f.BlockedDeviceIDs,
		ResourceReqs:         f.ResourceReqs,
	}
}

func toSnapshot(f fixtureWorker) WorkerSnapshot {
	snap := WorkerSnapshot{
		DeviceID: f.DeviceID, Capabilities: f.Capabilities,
		GPUUtilization: f.GPUUtilization, MemoryFreeGB: f.MemoryFreeGB,
		CPUUsage: f.CPUUsage, RunningJobs: f.RunningJobs,
		GPUCount: f.GPUCount, GPUMemoryFreeMB: f.GPUMemoryFreeMB,
	}
	for _, g := range f.GPUs {
		snap.GPUs = append(snap.GPUs, GPUFree{Index: g.Index, MemoryFreeMB: g.MemoryFreeMB, Utilization: g.Utilization})
	}
	return snap
}

func TestSchedulerFixtures(t *testing.T) {
	cases := fixtureCases()
	blob, err := json.MarshalIndent(cases, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	blob = append(blob, '\n')

	if os.Getenv("HYDRA_UPDATE_FIXTURES") == "1" {
		if err := os.MkdirAll(filepath.Dir(fixturePath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(fixturePath, blob, 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("fixtures written: %s (%d cases)", fixturePath, len(cases))
		return
	}

	committed, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("fixture missing (run with HYDRA_UPDATE_FIXTURES=1 to generate): %v", err)
	}
	var committedCases []fixtureCase
	if err := json.Unmarshal(committed, &committedCases); err != nil {
		t.Fatalf("fixture corrupt: %v", err)
	}
	if len(committedCases) != len(cases) {
		t.Fatalf("fixture has %d cases, current logic produces %d — regenerate",
			len(committedCases), len(cases))
	}
	for i, c := range cases {
		if committedCases[i].Name != c.Name ||
			math.Abs(committedCases[i].ExpectedScore-c.ExpectedScore) > 1e-9 {
			t.Errorf("case %q: committed score %v != current %v — scheduler logic drifted, regenerate fixtures",
				c.Name, committedCases[i].ExpectedScore, c.ExpectedScore)
		}
	}
}
