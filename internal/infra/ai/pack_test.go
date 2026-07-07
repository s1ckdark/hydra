package ai

import (
	"reflect"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

func gpuWorker(gpus ...GPUFree) WorkerSnapshot {
	return WorkerSnapshot{
		DeviceID: "gpu1", Capabilities: []string{"gpu"},
		GPUMemoryFreeMB: 40000, GPUs: gpus,
	}
}

func reqs(memMB, count int) *domain.Task {
	return &domain.Task{Priority: domain.TaskPriorityNormal,
		ResourceReqs: &domain.ResourceRequirements{GPUMemoryMB: memMB, GPUCount: count}}
}

func TestPackGPUs(t *testing.T) {
	cases := []struct {
		name   string
		task   *domain.Task
		w      WorkerSnapshot
		want   []int
		wantOK bool
	}{
		{"no_reqs_no_constraint", &domain.Task{}, gpuWorker(GPUFree{0, 10000, 20}), nil, true},
		{"zero_reqs_no_constraint", reqs(0, 0), gpuWorker(GPUFree{0, 10000, 20}), nil, true},
		{"split_vram_rejected", // 스펙의 회귀 케이스: 10GB×2에 20GB 요구
			reqs(20000, 0), gpuWorker(GPUFree{0, 10000, 20}, GPUFree{1, 10000, 30}), nil, false},
		{"single_best_fit_smallest_sufficient",
			reqs(16000, 0), gpuWorker(GPUFree{0, 24000, 10}, GPUFree{1, 20000, 50}), []int{1}, true},
		{"negative_count_clamped_to_one",
			reqs(16000, -1), gpuWorker(GPUFree{0, 24000, 10}, GPUFree{1, 20000, 50}), []int{1}, true},
		{"exact_fit_passes",
			reqs(20000, 1), gpuWorker(GPUFree{0, 20000, 10}), []int{0}, true},
		{"two_of_three_best_fit_indexes_sorted",
			reqs(16000, 2), gpuWorker(GPUFree{0, 8000, 90}, GPUFree{1, 24000, 30}, GPUFree{2, 20000, 10}),
			[]int{1, 2}, true}, // 적격 {1:24000, 2:20000} → 작은 것부터 {2,1} 선택 → 인덱스 정렬 {1,2}
		{"count_insufficient",
			reqs(8000, 3), gpuWorker(GPUFree{0, 10000, 0}, GPUFree{1, 10000, 0}), nil, false},
		{"count_only_no_mem",
			reqs(0, 2), gpuWorker(GPUFree{0, 100, 0}, GPUFree{1, 200, 0}, GPUFree{2, 50, 0}),
			[]int{0, 2}, true}, // mem 0 → 전부 적격, 여유 작은 순 {2:50, 0:100} → 정렬 {0,2}
		{"tie_broken_by_index",
			reqs(1000, 1), gpuWorker(GPUFree{1, 5000, 0}, GPUFree{0, 5000, 0}), []int{0}, true},
		{"fallback_no_pergpu_single_fits",
			reqs(16000, 0), WorkerSnapshot{GPUMemoryFreeMB: 40000}, nil, true},
		{"fallback_no_pergpu_single_no_fit",
			reqs(50000, 1), WorkerSnapshot{GPUMemoryFreeMB: 40000}, nil, false},
		{"fallback_no_pergpu_multi_rejected",
			reqs(1000, 2), WorkerSnapshot{GPUMemoryFreeMB: 40000}, nil, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := PackGPUs(c.task, c.w)
			if ok != c.wantOK {
				t.Fatalf("ok = %v, want %v", ok, c.wantOK)
			}
			if c.want == nil {
				if len(got) != 0 {
					t.Fatalf("indexes = %v, want empty", got)
				}
			} else if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("indexes = %v, want %v", got, c.want)
			}
		})
	}
}
