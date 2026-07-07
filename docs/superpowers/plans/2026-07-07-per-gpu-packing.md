# per-GPU Packing (2단계) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Go 스케줄러에 GPU 단위 할당을 구현한다 — `gpuCount`장의 GPU 각각에 `gpuMemoryMB` 여유가 있어야 적격, best-fit으로 GPU 인덱스를 선택해 `assignedGpuIndexes`로 워커에 전파(→ `CUDA_VISIBLE_DEVICES`), Python sim/골든 픽스처를 같은 커밋으로 동기 갱신.

**Architecture:** 스코어러(`internal/infra/ai`)에 순수 함수 `PackGPUs`를 추가하고 `ScoreForTask`의 노드-합산 VRAM 체크를 대체한다. 스냅샷(`WorkerSnapshot`)에 GPU별 상태를 싣고, supervisor가 할당 시 선택 인덱스를 task에 기록·영속화·WS 전파한다. Python sim은 같은 산식을 미러링하고 골든 픽스처가 패리티를 강제한다.

**Tech Stack:** Go (기존 hydra 모듈), Python 3.10+ (python/ 패키지, 1단계 완료 상태), SQLite (idempotent ALTER TABLE 마이그레이션 패턴).

**스펙:** `docs/superpowers/specs/2026-07-07-python-client-design.md` §6 (승인됨)

## Global Constraints

- 브랜치: `feature/per-gpu-packing` (main에서 분기; 실행 시작 시 생성)
- 커밋 메시지: 기존 스타일 + 마지막 줄 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Go 검증: 리포 루트에서 `go test ./... && go vet ./...`; Python 검증: `cd python && .venv/bin/python -m pytest tests/ -v`
- **패리티 원자성 (스펙 §10)**: `ScoreForTask` 산식 변경, 픽스처 재생성, Python sim 갱신은 반드시 **한 커밋** (Task 2) — 중간 커밋에서 Go↔Python 점수가 어긋난 상태를 만들지 않는다
- JSON 계약 (스펙 §6, 이름 불변): `ResourceRequirements.gpuCount`(이미 존재), `Task.assignedGpuIndexes` ([]int), `WorkerSnapshot`의 GPU별 상태 `gpus: [{index, memoryFreeMB, utilization}]` — Python `Task.from_json`은 이미 `assignedGpuIndexes`를 파싱하고 worker.py는 이미 `CUDA_VISIBLE_DEVICES`로 변환한다 (1단계 완료분; 이름이 다르면 그쪽이 깨진다)
- 하위호환 (스펙 §6 표): `gpuCount` 0/생략 = 1로 간주하되, **GPU 요구가 전혀 없는 task**(`ResourceReqs` nil 또는 `GPUMemoryMB==0 && GPUCount==0`)는 GPU 제약 없음(선택 없음, 기존과 동일). `assignedGpuIndexes` 미수신 워커는 전 GPU 노출(기존과 동일 — 워커 코드 변경 없음)
- lease 테이블 없음 — tick 내 경합은 스냅샷 차감(`bumpGPUReservation`)으로만 완화 (스펙 §6 수용한 트레이드오프)

## 확정 시맨틱 (Go/Python 동일 — 두 구현 모두 이 표가 진실)

`PackGPUs(task, w)` — 반환 `(indexes []int, ok bool)` / Python `pack_gpus(task, w) -> list[int] | None` (None=부적격, []=GPU 제약 없음):

| 조건 | 결과 |
|---|---|
| `ResourceReqs` nil 또는 (`GPUMemoryMB==0` && `GPUCount==0`) | `([], true)` — GPU 제약 없음 |
| GPU 요구 있음, `effectiveCount = GPUCount>0 ? GPUCount : 1` | 아래 진행 |
| `w.GPUs` 비어 있음 (GPU별 데이터 없음) && `effectiveCount == 1` | 레거시 폴백: `GPUMemoryMB > w.GPUMemoryFreeMB`면 `(nil,false)`, 아니면 `([], true)` (핀 없음) |
| `w.GPUs` 비어 있음 && `effectiveCount >= 2` | `(nil, false)` — GPU별 데이터 없이 멀티 GPU 검증 불가 |
| GPU별 데이터 있음 | 적격 GPU = `MemoryFreeMB >= GPUMemoryMB` (exact fit 통과 — 기존 `>` 거절 경계와 동일). 적격 수 < effectiveCount → `(nil,false)`. 아니면 (여유 VRAM 오름차순, 동률 시 index 오름차순) 정렬 후 앞에서 effectiveCount장 선택, **인덱스 오름차순으로 반환** |

`ScoreForTask` 변경:
- 기존 하드 체크 `GPUMemoryMB > GPUMemoryFreeMB` 삭제 → `PackGPUs` ok==false면 ineligible. RAM 체크는 불변.
- 소프트 점수의 `gpuFree` 항: 선택 GPU가 있으면(`len(indexes)>0`) 선택된 GPU들의 `mean(100 - Utilization)`, 없으면 기존대로 `100 - w.GPUUtilization`. 나머지 항·가중치·우선순위 배수 불변.

## 파일 구조 (전체)

| 파일 | 변경 |
|---|---|
| `internal/infra/ai/provider.go` | `GPUFree` 타입 + `WorkerSnapshot.GPUs` |
| `internal/infra/ai/scheduler.go` | `PackGPUs` + `ScoreForTask` 갱신 |
| `internal/infra/ai/pack_test.go` (신규) | PackGPUs 유닛 |
| `internal/infra/ai/scheduler_fixture_test.go` | fixtureGPU + per-GPU 케이스 9종 |
| `internal/domain/task.go` | `Task.AssignedGPUIndexes` |
| `internal/repository/sqlite/sqlite.go` | `ALTER TABLE tasks ADD COLUMN assigned_gpu_indexes` |
| `internal/repository/sqlite/task.go` | Save/UPSERT/scan에 컬럼 반영 |
| `internal/domain/taskqueue.go` | `AssignToDevice` 시그니처 확장 + 재큐잉 시 인덱스 클리어 |
| `internal/usecase/task_supervisor.go` | 스냅샷 GPUs 채움 + 할당 시 packing + `bumpGPUReservation` |
| `python/src/hydra_client/models.py` | `GPUFree` dataclass + `WorkerSnapshot.gpus` |
| `python/src/hydra_client/sim.py` | `pack_gpus` + score/explain 갱신 |
| `python/src/hydra_client/client.py` | `cluster_snapshot`이 gpus 채움 |
| `python/tests/fixtures/scheduler/cases.json` | 재생성 (14 → 23 케이스) |
| `python/README.md` | per-GPU 노트 갱신 (이제 서버 지원) |

---

### Task 1: Go — GPUFree 타입 + PackGPUs 순수 함수

**Files:**
- Modify: `internal/infra/ai/provider.go:31-41` (WorkerSnapshot)
- Modify: `internal/infra/ai/scheduler.go` (PackGPUs 추가만 — ScoreForTask는 Task 2)
- Test: `internal/infra/ai/pack_test.go` (신규)

**Interfaces:**
- Consumes: `domain.ResourceRequirements`(GPUCount 필드는 1단계에서 추가됨), `domain.Task`
- Produces (이후 태스크가 그대로 사용):
  - `type GPUFree struct { Index int; MemoryFreeMB int; Utilization float64 }` (json 태그: `index`, `memoryFreeMB`, `utilization`)
  - `WorkerSnapshot.GPUs []GPUFree` (json 태그 없음 — 내부 구조체 관례 유지, 픽스처는 별도 직렬화 타입 사용)
  - `func PackGPUs(task *domain.Task, w WorkerSnapshot) ([]int, bool)` — 위 "확정 시맨틱" 표 그대로

- [ ] **Step 1: 실패하는 테스트 작성**

```go
// internal/infra/ai/pack_test.go
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
		name    string
		task    *domain.Task
		w       WorkerSnapshot
		want    []int
		wantOK  bool
	}{
		{"no_reqs_no_constraint", &domain.Task{}, gpuWorker(GPUFree{0, 10000, 20}), nil, true},
		{"zero_reqs_no_constraint", reqs(0, 0), gpuWorker(GPUFree{0, 10000, 20}), nil, true},
		{"split_vram_rejected", // 스펙의 회귀 케이스: 10GB×2에 20GB 요구
			reqs(20000, 0), gpuWorker(GPUFree{0, 10000, 20}, GPUFree{1, 10000, 30}), nil, false},
		{"single_best_fit_smallest_sufficient",
			reqs(16000, 0), gpuWorker(GPUFree{0, 24000, 10}, GPUFree{1, 20000, 50}), []int{1}, true},
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
```

- [ ] **Step 2: 실패 확인**

Run: `go test ./internal/infra/ai/ -run TestPackGPUs -v`
Expected: 컴파일 실패 — `undefined: GPUFree`, `undefined: PackGPUs`

- [ ] **Step 3: 구현**

`internal/infra/ai/provider.go` — WorkerSnapshot 아래에 추가:

```go
// GPUFree is one GPU's schedulable state inside a WorkerSnapshot.
// JSON tags match the per-GPU contract in the 2026-07-07 design spec §6
// (fixtures and the Python sim consume the same camelCase keys).
type GPUFree struct {
	Index        int     `json:"index"`
	MemoryFreeMB int     `json:"memoryFreeMB"`
	Utilization  float64 `json:"utilization"`
}
```

WorkerSnapshot에 필드 추가:

```go
type WorkerSnapshot struct {
	DeviceID        string
	Capabilities    []string
	GPUUtilization  float64
	MemoryFreeGB    float64
	CPUUsage        float64
	RunningJobs     int
	GPUCount        int
	GPUMemoryFreeMB int
	// GPUs carries per-GPU free memory/utilization when the collector
	// provides it. Empty = per-GPU data unavailable; PackGPUs falls back
	// to the aggregate GPUMemoryFreeMB check for single-GPU requests.
	GPUs []GPUFree
}
```

`internal/infra/ai/scheduler.go` — PackGPUs 추가 (ScoreForTask 위):

```go
// PackGPUs selects which GPUs on w the task would occupy.
// Returns (indexes ascending, true) when w can satisfy the task's per-GPU
// requirement; (nil, false) when it cannot. A task with no GPU requirement
// (nil ResourceReqs, or GPUMemoryMB==0 && GPUCount==0) returns (nil, true):
// eligible, nothing pinned. GPUMemoryMB is interpreted per-GPU (spec §6);
// gpuCount 0 means 1. Selection is best-fit: smallest sufficient free VRAM
// first (tie broken by index), so large-VRAM GPUs stay available for
// larger future tasks. Workers without per-GPU data fall back to the
// aggregate check for single-GPU requests and are ineligible for multi-GPU.
func PackGPUs(task *domain.Task, w WorkerSnapshot) ([]int, bool) {
	r := task.ResourceReqs
	if r == nil || (r.GPUMemoryMB == 0 && r.GPUCount == 0) {
		return nil, true
	}
	count := r.GPUCount
	if count == 0 {
		count = 1
	}
	if len(w.GPUs) == 0 {
		if count >= 2 {
			return nil, false
		}
		if r.GPUMemoryMB > w.GPUMemoryFreeMB {
			return nil, false
		}
		return nil, true
	}
	eligible := make([]GPUFree, 0, len(w.GPUs))
	for _, g := range w.GPUs {
		if g.MemoryFreeMB >= r.GPUMemoryMB {
			eligible = append(eligible, g)
		}
	}
	if len(eligible) < count {
		return nil, false
	}
	sort.Slice(eligible, func(i, j int) bool {
		if eligible[i].MemoryFreeMB != eligible[j].MemoryFreeMB {
			return eligible[i].MemoryFreeMB < eligible[j].MemoryFreeMB
		}
		return eligible[i].Index < eligible[j].Index
	})
	indexes := make([]int, count)
	for i := 0; i < count; i++ {
		indexes[i] = eligible[i].Index
	}
	sort.Ints(indexes)
	return indexes, true
}
```

- [ ] **Step 4: 통과 + 전체 회귀 확인**

Run: `go test ./internal/infra/ai/ -v -run TestPackGPUs && go test ./... && go vet ./...`
Expected: 12 서브테스트 PASS, 전체 통과 (ScoreForTask는 아직 미변경이라 기존 픽스처도 그대로 통과)

- [ ] **Step 5: 커밋**

```bash
git add internal/infra/ai/provider.go internal/infra/ai/scheduler.go internal/infra/ai/pack_test.go
git commit -m "feat(ai): GPU별 스냅샷 상태 + PackGPUs best-fit 선택 함수

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Go+Python 원자 커밋 — ScoreForTask per-GPU + 픽스처 재생성 + sim 동기 갱신

**⚠️ 이 태스크의 모든 변경은 하나의 커밋이다** (Global Constraints의 패리티 원자성).

**Files:**
- Modify: `internal/infra/ai/scheduler.go:90-98` (ScoreForTask 하드 체크 대체 + gpuFree 항)
- Modify: `internal/infra/ai/scheduler_fixture_test.go` (fixtureGPU + 케이스 9종 추가)
- Modify: `python/src/hydra_client/models.py` (GPUFree + WorkerSnapshot.gpus)
- Modify: `python/src/hydra_client/sim.py` (pack_gpus + score_for_task + explain)
- Regenerate: `python/tests/fixtures/scheduler/cases.json` (23 케이스)
- Test: `python/tests/test_sim.py` (pack 동작 추가), 기존 `test_sim_parity.py` (자동 커버)

**Interfaces:**
- Consumes: Task 1의 `GPUFree`, `PackGPUs`
- Produces:
  - Go `ScoreForTask` — per-GPU 적격성 + 선택 GPU 평균 여유율 항 (시그니처 불변)
  - Python `models.GPUFree(index, memory_free_mb, utilization)` + `GPUFree.from_json` (camelCase)
  - Python `models.WorkerSnapshot.gpus: list[GPUFree]` (from_json 키 `"gpus"`)
  - Python `sim.pack_gpus(task, w) -> list[int] | None` (None=부적격, []=제약 없음)
  - `sim.score_for_task`/`explain` — Go와 동일 갱신; `ScoreBreakdown`에 `selected_gpus: list[int]` 필드 추가

- [ ] **Step 1: Go — ScoreForTask 갱신**

`scheduler.go`의 자원 체크 블록(현재 91-98행)을 다음으로 교체:

```go
	// Strict resource check: reject if worker can't physically fit the task.
	// GPU fit is per-GPU (spec §6): PackGPUs verifies gpuCount GPUs each with
	// gpuMemoryMB free, replacing the old node-aggregate VRAM check that let
	// a 20GB request land on a 10GB×2 node.
	selectedGPUs, gpuOK := PackGPUs(task, w)
	if !gpuOK {
		return ineligible
	}
	if r := task.ResourceReqs; r != nil {
		if r.MemoryMB > 0 && float64(r.MemoryMB)/1024.0 > w.MemoryFreeGB {
			return ineligible
		}
	}
```

소프트 점수의 gpuFree 항(현재 100행) 교체:

```go
	gpuFree := 100 - w.GPUUtilization
	if len(selectedGPUs) > 0 {
		byIndex := make(map[int]GPUFree, len(w.GPUs))
		for _, g := range w.GPUs {
			byIndex[g.Index] = g
		}
		var freeSum float64
		for _, idx := range selectedGPUs {
			freeSum += 100 - byIndex[idx].Utilization
		}
		gpuFree = freeSum / float64(len(selectedGPUs))
	}
```

- [ ] **Step 2: Go — 픽스처 케이스 추가**

`scheduler_fixture_test.go`에 GPU 직렬화 타입과 케이스 추가:

```go
type fixtureGPU struct {
	Index        int     `json:"index"`
	MemoryFreeMB int     `json:"memoryFreeMB"`
	Utilization  float64 `json:"utilization"`
}
```

`fixtureWorker`에 `GPUs []fixtureGPU json:"gpus,omitempty"` 필드 추가, `toSnapshot`에 변환 추가:

```go
	for _, g := range f.GPUs {
		snap.GPUs = append(snap.GPUs, GPUFree{Index: g.Index, MemoryFreeMB: g.MemoryFreeMB, Utilization: g.Utilization})
	}
```

`fixtureCases()`에 9케이스 추가 (기존 14 유지 — baseWorker는 GPUs 없음이라 단일 GPU 폴백 경로로 여전히 같은 점수):

```go
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
```

주의: 위 append는 기존 `for i := range cases { ExpectedScore = ... }` 루프 **앞**에 들어가야 한다 (점수는 전 케이스 일괄 계산).

- [ ] **Step 3: Go 픽스처 재생성 + 검증 + 수계산 스팟체크**

```bash
HYDRA_UPDATE_FIXTURES=1 go test ./internal/infra/ai/ -run TestSchedulerFixtures -v
go test ./internal/infra/ai/ -v
```
Expected: cases.json 23케이스로 재생성, 전체 PASS.
스팟체크(계획 검증용 수계산 — 값이 다르면 구현 버그):
- `pergpu_single_best_fit_uses_selected_util`: 선택 = idx1(20000, util 50) → gpuFree 50 → 50×0.4 + 48 + 18 + 9 = **95.0**
- `pergpu_two_of_three`: 선택 = {1,2} (util 30,10) → gpuFree (70+90)/2 = 80 → 32+48+18+9 = **107.0**
- `pergpu_no_gpu_requirement_uses_node_util`: 선택 없음 → 노드 util 20 → **107.0** (baseline과 동일)
- `pergpu_split_vram_rejected`, `pergpu_count_insufficient`, `fallback_no_pergpu_multi_rejected`: **-1**

- [ ] **Step 4: Python — models.py에 GPUFree + gpus**

`WorkerSnapshot` dataclass 위에 추가:

```python
@dataclass
class GPUFree:
    """GPU 한 장의 스케줄링 가시 상태 — 스펙 §6 per-GPU 계약."""

    index: int
    memory_free_mb: int = 0
    utilization: float = 0.0

    @classmethod
    def from_json(cls, d: dict[str, Any]) -> "GPUFree":
        return cls(
            index=d.get("index", 0),
            memory_free_mb=d.get("memoryFreeMB", 0),
            utilization=d.get("utilization", 0.0),
        )
```

`WorkerSnapshot`에 필드 + from_json 매핑 추가:

```python
    gpus: list["GPUFree"] = field(default_factory=list)
```

```python
            gpus=[GPUFree.from_json(g) for g in (d.get("gpus") or [])],
```

- [ ] **Step 5: Python — sim.py 갱신**

`pack_gpus` 추가 (Go PackGPUs와 1:1 — "확정 시맨틱" 표):

```python
def pack_gpus(task: TaskSpec, w: WorkerSnapshot) -> list[int] | None:
    """task가 w에서 점유할 GPU 인덱스. None=부적격, []=GPU 제약 없음.

    Go PackGPUs(scheduler.go)와 동일: gpuMemoryMB는 장당 요구량,
    gpuCount 0은 1로 간주, best-fit(여유 작은 순, 동률 시 인덱스 순).
    GPU별 데이터 없는 워커는 단일 GPU 요구만 합산치로 폴백 검사.
    """
    r = task.resource_reqs
    if r is None or (r.gpu_memory_mb == 0 and r.gpu_count == 0):
        return []
    count = r.gpu_count or 1
    if not w.gpus:
        if count >= 2:
            return None
        if r.gpu_memory_mb > w.gpu_memory_free_mb:
            return None
        return []
    eligible = [g for g in w.gpus if g.memory_free_mb >= r.gpu_memory_mb]
    if len(eligible) < count:
        return None
    eligible.sort(key=lambda g: (g.memory_free_mb, g.index))
    return sorted(g.index for g in eligible[:count])
```

`_reject_reason`의 GPU 하드 체크 교체 — 기존 두 줄
(`if r.gpu_memory_mb > 0 and ... return "insufficient GPU memory"`)을 삭제하고,
함수 마지막 RAM 체크 **앞**에:

```python
    if pack_gpus(task, w) is None:
        return "insufficient GPU memory/count"
```

(RAM 체크는 그대로 유지.)

`score_for_task`의 gpu_free 항 교체:

```python
    selected = pack_gpus(task, w) or []
    if selected:
        by_index = {g.index: g for g in w.gpus}
        gpu_free = sum(100.0 - by_index[i].utilization for i in selected) / len(selected)
    else:
        gpu_free = 100.0 - w.gpu_utilization
```

`explain`: `ScoreBreakdown`에 `selected_gpus: list[int] = field(default_factory=list)` 추가하고, eligible 분기에서 동일한 selected 계산으로 `gpu_free_term`을 산출·`selected_gpus=selected` 기록. (ineligible 행은 기존대로 0/INELIGIBLE.)

- [ ] **Step 6: Python — 동작 테스트 추가 + 패리티/전체 확인**

`python/tests/test_sim.py`에 추가:

```python
from hydra_client.models import GPUFree, ResourceRequirements
from hydra_client.sim import pack_gpus


def test_pack_gpus_split_vram_rejected():
    spec = TaskSpec(resource_reqs=ResourceRequirements(gpu_memory_mb=20000))
    w = _worker("a", gpus=[GPUFree(0, 10000, 20.0), GPUFree(1, 10000, 30.0)])
    assert pack_gpus(spec, w) is None
    assert score_for_task(spec, w) == INELIGIBLE


def test_pack_gpus_best_fit_and_selected_util_scoring():
    spec = TaskSpec(resource_reqs=ResourceRequirements(gpu_memory_mb=16000, gpu_count=2))
    w = _worker("a", gpus=[GPUFree(0, 8000, 90.0), GPUFree(1, 24000, 30.0), GPUFree(2, 20000, 10.0)])
    assert pack_gpus(spec, w) == [1, 2]
    rows = [r for r in explain(spec, [w]) if r.eligible]
    assert rows[0].selected_gpus == [1, 2]


def test_pack_gpus_no_constraint_empty():
    assert pack_gpus(TaskSpec(), _worker("a")) == []
```

Run: `cd python && .venv/bin/python -m pytest tests/ -v`
Expected: 패리티 23케이스 포함 전부 PASS (기존 14 + 신규 9 자동 파라미터라이즈)

- [ ] **Step 7: 전체 회귀 + 원자 커밋**

```bash
go test ./... && go vet ./...
git add internal/infra/ai/scheduler.go internal/infra/ai/scheduler_fixture_test.go \
        python/tests/fixtures/scheduler/cases.json \
        python/src/hydra_client/models.py python/src/hydra_client/sim.py python/tests/test_sim.py
git commit -m "feat(ai): per-GPU packing 적격성/점수 + Python sim 동기 갱신 (원자 패리티 커밋)

노드 합산 VRAM 체크를 PackGPUs로 대체 — 10GB×2 노드에 20GB task가
배치되던 오배치 수정. gpuFree 항은 선택된 GPU들의 평균 여유율 사용.
골든 픽스처 23케이스 재생성, Go/Python 점수 패리티 유지.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Go — Task.AssignedGPUIndexes + SQLite 영속화

**Files:**
- Modify: `internal/domain/task.go` (필드 추가)
- Modify: `internal/repository/sqlite/sqlite.go:224-261` (idempotent ALTER TABLE)
- Modify: `internal/repository/sqlite/task.go` (Save/UPSERT/scan)
- Test: `internal/repository/sqlite/task_test.go` (라운드트립 케이스 추가)

**Interfaces:**
- Consumes: 없음 (독립)
- Produces: `Task.AssignedGPUIndexes []int json:"assignedGpuIndexes,omitempty"` — Task 4의 할당 경로와 Python 1단계의 `Task.from_json`/worker가 소비. DB 컬럼 `assigned_gpu_indexes TEXT NOT NULL DEFAULT '[]'` (JSON 배열 문자열, `blocked_device_ids`와 같은 패턴)

- [ ] **Step 1: 실패하는 테스트 작성**

`task_test.go`의 기존 라운드트립 테스트 패턴을 확인하고 (기존 Save→GetByID 테스트와 동일한 헬퍼/DB 구성 사용) 케이스 추가:

```go
func TestTaskRoundTripAssignedGPUIndexes(t *testing.T) {
	repo, ctx := newTestTaskRepo(t) // 기존 테스트 파일의 셋업 헬퍼 관례를 따를 것
	task := &domain.Task{
		ID: "t-gpu", Type: "command", Status: domain.TaskStatusAssigned,
		Priority: domain.TaskPriorityNormal, CreatedAt: time.Now(),
		AssignedGPUIndexes: []int{0, 3},
	}
	if err := repo.Save(ctx, task); err != nil {
		t.Fatal(err)
	}
	got, err := repo.GetByID(ctx, "t-gpu")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got.AssignedGPUIndexes, []int{0, 3}) {
		t.Fatalf("AssignedGPUIndexes = %v, want [0 3]", got.AssignedGPUIndexes)
	}
	// 빈 값 라운드트립도 안전해야 함
	task2 := &domain.Task{ID: "t-nogpu", Type: "command",
		Status: domain.TaskStatusQueued, Priority: domain.TaskPriorityNormal, CreatedAt: time.Now()}
	if err := repo.Save(ctx, task2); err != nil {
		t.Fatal(err)
	}
	got2, _ := repo.GetByID(ctx, "t-nogpu")
	if len(got2.AssignedGPUIndexes) != 0 {
		t.Fatalf("expected empty indexes, got %v", got2.AssignedGPUIndexes)
	}
}
```

- [ ] **Step 2: 실패 확인**

Run: `go test ./internal/repository/sqlite/ -run TestTaskRoundTripAssignedGPUIndexes -v`
Expected: 컴파일 실패 — `unknown field AssignedGPUIndexes`

- [ ] **Step 3: 구현**

`internal/domain/task.go` — Task 구조체 `AssignedDeviceID` 아래에:

```go
	// AssignedGPUIndexes are the GPU indexes the scheduler reserved on the
	// assigned device (spec §6). The worker converts them to
	// CUDA_VISIBLE_DEVICES. Empty = no per-GPU pinning (whole node visible).
	AssignedGPUIndexes []int `json:"assignedGpuIndexes,omitempty"`
```

`internal/repository/sqlite/sqlite.go` — 기존 idempotent ALTER TABLE 블록(devices GPU 컬럼과 같은 패턴)에:

```go
		`ALTER TABLE tasks ADD COLUMN assigned_gpu_indexes TEXT NOT NULL DEFAULT '[]'`,
```

`internal/repository/sqlite/task.go` — Save에 직렬화 추가:

```go
	gpuIdx, _ := json.Marshal(t.AssignedGPUIndexes)
	if t.AssignedGPUIndexes == nil {
		gpuIdx = []byte("[]")
	}
```

INSERT 컬럼 목록에 `assigned_gpu_indexes` 추가(VALUES `?` 1개 추가), UPSERT의 Mutable 목록에 `assigned_gpu_indexes = excluded.assigned_gpu_indexes` 추가, Exec 인자에 `string(gpuIdx)` 추가 (위치는 `assigned_device_id` 뒤 관례대로). `taskSelectColumns`에 컬럼 추가, `scanTask`에 언마샬 추가:

```go
	if gpuIdx != "" {
		if err := json.Unmarshal([]byte(gpuIdx), &t.AssignedGPUIndexes); err != nil {
			log.Printf("[taskrepo] assigned_gpu_indexes unmarshal failed for task %s: %v", t.ID, err)
		}
	}
```

주의: ALTER TABLE은 이미 존재하는 DB에서 "duplicate column" 에러를 낼 수 있음 — sqlite.go의 기존 마이그레이션 실행부가 idempotent 에러를 어떻게 처리하는지(devices GPU 컬럼 선례) 확인하고 동일하게 따를 것.

- [ ] **Step 4: 통과 + 전체 회귀 후 커밋**

Run: `go test ./internal/repository/sqlite/ -v && go test ./... && go vet ./...`

```bash
git add internal/domain/task.go internal/repository/sqlite/sqlite.go internal/repository/sqlite/task.go internal/repository/sqlite/task_test.go
git commit -m "feat(domain): Task.assignedGpuIndexes + SQLite 영속화

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Go — supervisor 배선: 스냅샷 GPUs, 할당 시 packing, tick 내 차감

**Files:**
- Modify: `internal/usecase/task_supervisor.go:280-322` (할당 + bump + buildWorkerSnapshot)
- Modify: `internal/domain/taskqueue.go:397-416` (AssignToDevice 시그니처), `:349-377` (재큐잉 클리어)
- Test: `internal/usecase/task_supervisor_test.go`, `internal/domain/taskqueue_test.go` (기존 파일 관례 따름)

**Interfaces:**
- Consumes: Task 1 `PackGPUs`/`GPUFree`, Task 3 `Task.AssignedGPUIndexes`
- Produces:
  - `TaskQueue.AssignToDevice(taskID, deviceID string, gpuIndexes []int) *Task` — 시그니처 변경 (유일 호출처는 supervisor; 테스트 호출처는 컴파일러가 안내)
  - `buildWorkerSnapshot` — `metrics.GPU.GPUs`에서 `snap.GPUs` 채움 (Index, MemoryFree bytes→MB, UsagePercent)
  - `bumpGPUReservation(snaps, deviceID, indexes, memMB)` — 스냅샷의 선택 GPU 여유 VRAM 차감

- [ ] **Step 1: 실패하는 테스트 작성**

`taskqueue_test.go`에 (기존 AssignToDevice 테스트 관례 따라):

```go
func TestAssignToDeviceRecordsGPUIndexes(t *testing.T) {
	q := NewTaskQueue()
	task := &Task{ID: "t1", Type: "command", Status: TaskStatusPending, Priority: TaskPriorityNormal}
	q.Enqueue(task)
	got := q.AssignToDevice("t1", "gpu1", []int{0, 3})
	if got == nil {
		t.Fatal("assign returned nil")
	}
	if !reflect.DeepEqual(got.AssignedGPUIndexes, []int{0, 3}) {
		t.Fatalf("indexes = %v", got.AssignedGPUIndexes)
	}
}

func TestReassignClearsGPUIndexes(t *testing.T) {
	q := NewTaskQueue()
	task := &Task{ID: "t1", Type: "command", Status: TaskStatusPending,
		Priority: TaskPriorityNormal, MaxRetries: 3}
	q.Enqueue(task)
	q.AssignToDevice("t1", "gpu1", []int{2})
	reassigned := q.ReassignTasksFromDevice("gpu1")
	if len(reassigned) != 1 {
		t.Fatalf("reassigned = %d", len(reassigned))
	}
	if len(reassigned[0].AssignedGPUIndexes) != 0 {
		t.Fatalf("indexes not cleared: %v", reassigned[0].AssignedGPUIndexes)
	}
}
```

`task_supervisor_test.go`에 (기존 buildWorkerSnapshot 테스트 관례 따라; 없으면 신규 함수 테스트로):

```go
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
```

- [ ] **Step 2: 실패 확인**

Run: `go test ./internal/domain/ ./internal/usecase/ -run 'GPUIndexes|PerGPU|GPUReservation' -v`
Expected: 컴파일 실패 (시그니처/함수 미존재)

- [ ] **Step 3: 구현**

`taskqueue.go` — AssignToDevice 시그니처 확장 및 기록:

```go
func (q *TaskQueue) AssignToDevice(taskID, deviceID string, gpuIndexes []int) *Task {
	// ... 기존 본문 유지, task.AssignedAt = &now 다음에:
	task.AssignedGPUIndexes = gpuIndexes
```

`ReassignTasksFromDevice`의 재큐잉 분기(`task.AssignedDeviceID = ""` 옆)에:

```go
				task.AssignedGPUIndexes = nil
```

`task_supervisor.go` — `buildWorkerSnapshot`의 GPU 집계 루프에 GPU별 상태 추가:

```go
	if metrics.GPU != nil && len(metrics.GPU.GPUs) > 0 {
		var utilSum float64
		var freeBytes uint64
		for _, g := range metrics.GPU.GPUs {
			utilSum += g.UsagePercent
			freeBytes += g.MemoryFree
			snap.GPUs = append(snap.GPUs, ai.GPUFree{
				Index:        g.Index,
				MemoryFreeMB: int(g.MemoryFree / (1024 * 1024)),
				Utilization:  g.UsagePercent,
			})
		}
		snap.GPUUtilization = utilSum / float64(len(metrics.GPU.GPUs))
		snap.GPUMemoryFreeMB = int(freeBytes / (1024 * 1024))
	}
```

`scheduleQueue`의 할당 지점(현재 280행) 교체:

```go
		gpuIndexes, _ := ai.PackGPUs(task, *best)
		assigned := s.taskQueue.AssignToDevice(task.ID, best.DeviceID, gpuIndexes)
		if assigned == nil {
			continue // raced: another pass claimed it
		}
		log.Printf("[supervisor] task %s assigned to %s (gpus=%v)", task.ID, best.DeviceID, gpuIndexes)
		s.notifyDeviceOfTask(best.DeviceID, assigned)
		bumpRunningJobs(snaps, best.DeviceID)
		if r := task.ResourceReqs; r != nil && r.GPUMemoryMB > 0 && len(gpuIndexes) > 0 {
			bumpGPUReservation(snaps, best.DeviceID, gpuIndexes, r.GPUMemoryMB)
		}
```

`bumpRunningJobs` 아래에 추가:

```go
// bumpGPUReservation subtracts memMB from the selected GPUs' free VRAM in
// the local snapshot slice so later tasks in the same tick don't overcommit
// the GPUs this assignment just claimed. Cross-tick accuracy comes from
// nvidia-smi remeasurement; there is deliberately no reservation table
// (spec §6 accepted tradeoff).
func bumpGPUReservation(snaps []ai.WorkerSnapshot, deviceID string, indexes []int, memMB int) {
	for i := range snaps {
		if snaps[i].DeviceID != deviceID {
			continue
		}
		for _, idx := range indexes {
			for j := range snaps[i].GPUs {
				if snaps[i].GPUs[j].Index == idx {
					snaps[i].GPUs[j].MemoryFreeMB -= memMB
					if snaps[i].GPUs[j].MemoryFreeMB < 0 {
						snaps[i].GPUs[j].MemoryFreeMB = 0
					}
				}
			}
		}
		return
	}
}
```

기존 `AssignToDevice` 테스트 호출처들은 컴파일 에러로 드러남 — `nil` 인자 추가로 일괄 수정.

- [ ] **Step 4: 통과 + 전체 회귀 후 커밋**

Run: `go test ./... && go vet ./... && make build`

```bash
git add internal/usecase/task_supervisor.go internal/domain/taskqueue.go internal/usecase/task_supervisor_test.go internal/domain/taskqueue_test.go
git commit -m "feat(supervisor): 할당 시 GPU packing 기록·전파 + tick 내 VRAM 차감

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Python — cluster_snapshot gpus 채움 + README 갱신 + 최종 검증

**Files:**
- Modify: `python/src/hydra_client/client.py` (cluster_snapshot)
- Modify: `python/README.md` (per-GPU 노트 현행화)
- Test: `python/tests/test_monitoring.py` (gpus 검증 추가)

**Interfaces:**
- Consumes: Task 2의 `models.GPUFree`, `WorkerSnapshot.gpus`
- Produces: `cluster_snapshot()`이 각 스냅샷에 `gpus`를 채워 sim의 per-GPU 경로가 실데이터로 동작

- [ ] **Step 1: 실패하는 테스트 작성**

`test_monitoring.py`의 기존 테스트에 어서션 추가 (gpu1 디바이스의 기존 목 데이터에 `"index"` 키 추가 필요):

```python
    # 기존 gpu 목 데이터에 index 추가:
    #   {"index": 0, "usagePercent": 20.0, "memoryFree": 20000 * MB},
    #   {"index": 1, "usagePercent": 40.0, "memoryFree": 10000 * MB},
    assert [(x.index, x.memory_free_mb, x.utilization) for x in g.gpus] == [
        (0, 20000, 20.0), (1, 10000, 40.0)]
    assert c.gpus == []          # error 디바이스는 GPU별 상태도 비움
```

- [ ] **Step 2: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_monitoring.py -v`
Expected: FAIL — `g.gpus == []`

- [ ] **Step 3: 구현**

`client.py`의 `cluster_snapshot()` GPU 집계 블록에 (평균/합산 계산 옆):

```python
                if gpus:
                    snap.gpus = [
                        GPUFree(
                            index=g.get("index", 0),
                            memory_free_mb=int(g.get("memoryFree", 0) / (1024 ** 2)),
                            utilization=g.get("usagePercent", 0.0),
                        )
                        for g in gpus
                    ]
```

(models에서 `GPUFree` import 추가.)

- [ ] **Step 4: README 갱신**

`python/README.md`에서:
- per-GPU 주의 문구("현행 서버는 노드 합산 VRAM 기준")를 현행화: 서버가 per-GPU packing을 지원한다 — `gpu_count`장 × 장당 `gpu_memory_mb` 적격성, 할당 시 `assignedGpuIndexes` 수신 → 워커가 `CUDA_VISIBLE_DEVICES` 설정. 구버전 서버에 대해선 필드가 무시된다는 표는 유지.
- sim 섹션에 `pack_gpus` 한 줄 예제 추가:

```python
sim.pack_gpus(spec, worker)   # -> [1, 2] (선택 인덱스) / None (부적격) / [] (GPU 제약 없음)
```

- [ ] **Step 5: 최종 전체 검증 + 커밋**

```bash
cd python && .venv/bin/python -m pytest tests/ -v
cd .. && go test ./... && go vet ./... && make build
git add python/src/hydra_client/client.py python/tests/test_monitoring.py python/README.md
git commit -m "feat(python): cluster_snapshot GPU별 상태 + README per-GPU 현행화

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 계획 외 참고

- **e2e 스모크 (선택, 수동)**: GPU 노드 연결 상태에서 `gpu_count=1, gpu_memory_mb=<실측 여유보다 작게>` task 제출 → `task.assigned_gpu_indexes` 확인 → 워커 로그에서 `CUDA_VISIBLE_DEVICES` 확인.
- **범위 밖 (1단계 원장의 follow-up 유지)**: 서버의 `task.cancel` WS 송신, SetResult 터미널 가드, batch 경로 resourceReqs 테스트, wait_all 백오프. 이번 계획에 포함하지 않음 — per-GPU와 독립적인 별도 개선.
- **1단계 골든 픽스처와의 호환**: 기존 14케이스의 worker에는 `gpus`가 없으므로 폴백 경로를 타지만, `gpu_mem_does_not_fit`/`gpu_mem_exact_fit`/`ram_does_not_fit` 등의 기대 점수는 폴백 시맨틱이 기존 합산 체크와 동일해 변하지 않는다 (Task 2 재생성 시 자동 확인됨 — 기존 케이스 점수가 바뀌면 폴백 구현 버그).
