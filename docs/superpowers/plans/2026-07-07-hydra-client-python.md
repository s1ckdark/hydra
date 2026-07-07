# hydra-client 파이썬 라이브러리 구현 계획 (1단계)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** hydra Go 백엔드(:8080)의 task 스케줄링을 파이썬에서 사용하는 `hydra-client` 패키지 — REST 클라이언트 + 스케줄러 시뮬레이션(sim) + 워커 실행 루프.

**Architecture:** 모노레포 `python/` 하위에 src 레이아웃 패키지. 세 모듈이 상호 독립: `client.py`(REST), `sim.py`(순수 점수 계산, Go 골든 픽스처로 패리티 검증), `worker.py`(WS 수신 → subprocess 실행 → REST 보고). Go 쪽은 두 가지만 변경: ① `resourceReqs` 요청 바인딩 추가(현재 누락) + `gpuCount` 계약 필드, ② 점수 픽스처 덤프 테스트.

**Tech Stack:** Python 3.10+, requests, websockets(sync API), pytest, responses. Go 1.x (기존 hydra 모듈).

**스펙:** `docs/superpowers/specs/2026-07-07-python-client-design.md`

## Global Constraints

- 브랜치: `design/python-client`에서 계속 작업
- Python `>=3.10`, 런타임 의존성은 `requests>=2.31`, `websockets>=12` 두 개만
- dev 의존성: `pytest>=8`, `responses>=0.25`
- 패키지명 `hydra-client`, import명 `hydra_client`, src 레이아웃 (`python/src/hydra_client/`)
- 파이썬 테스트 실행은 항상 `cd python && python -m pytest` (venv: `python/.venv` 권장)
- Go 테스트는 리포 루트에서 `go test ./...`, 빌드 확인은 `make build`
- 커밋 메시지: 기존 스타일 (`feat:`, `fix:`, `test:`, `docs:`) + 마지막 줄 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- 서버 JSON은 camelCase, 파이썬 속성은 snake_case — 변환은 `models.py`에서만
- **단위 주의**: task 생성 요청의 `timeout`은 **초(int)**, 응답 Task의 `timeout`과 `result.durationMs`는 **나노초(int)** (Go `time.Duration` 직렬화. `durationMs`라는 이름과 달리 실제 값은 ns)

## 서버 계약 참고 (구현 시 그대로 사용)

| 동작 | 엔드포인트 | 요청/응답 요점 |
|---|---|---|
| 제출 | `POST /api/tasks` | 요청 `{type(필수), priority, requiredCapabilities, preferredDeviceId, payload, timeout(초), maxRetries, aiSchedule}` → 201 + Task JSON (즉시 `assigned`일 수 있음) |
| 배치 | `POST /api/tasks/batch` | `{name, metadata, tasks:[생성 요청과 동일 entry]}` → 201 + TaskGroupSnapshot(`{id, name, totalTasks, completed, failed, running, queued, status, tasks:[...]}`) |
| 그룹 조회 | `GET /api/groups/:id` | 기본은 카운터만, `?detail=full`이면 `tasks` 포함 |
| 조회 | `GET /api/tasks/:id`, `GET /api/tasks?status=&device_id=` | Task JSON / 배열 |
| 상태 | `PUT /api/tasks/:id/status` | `{"status": "running"\|"failed"\|"cancelled"...}` |
| 결과 | `PUT /api/tasks/:id/result` | TaskResult `{deviceId, deviceName, output{...}, durationMs(ns)}` — 서버가 자동으로 status=completed 처리 |
| 디바이스 | `GET /api/devices`, `GET /api/devices/:id` | Device JSON (`hasGpu`, `gpuCount`, `gpuModel`, `capabilities`) |
| 능력 등록 | `POST /api/devices/:id/capabilities` | `{"capabilities": ["gpu", ...]}` |
| 메트릭 | `GET /api/monitor/snapshot` | `{devices: {deviceId: DeviceMetrics}, collectedAt}` — DeviceMetrics: `cpu.usagePercent`, `memory.free`(bytes), `gpu.gpus[].usagePercent/memoryFree`(bytes), `error` |
| WS | `GET /ws?device_id=X` | envelope `{type, deviceId, taskId, payload, timestamp}`; `task.assign`의 payload = Task 전체 JSON 객체; 서버 ping 주기 54s, 최대 메시지 512KB |
| 인증 | 전 엔드포인트 | Tailscale/localhost는 무인증. 외부는 API 키 (`X-API-Key` 헤더 — `extractAPIKey` 확인 요) |

실패 보고 규약(워커): ① `PUT /result`로 output(stdout/stderr/exitCode) 보존 → ② exit≠0이면 `PUT /status` `{"status":"failed"}` 후속 호출. (SetResult가 completed로 만들기 때문에 순서 중요)

---

### Task 1: 패키지 스캐폴드 + errors.py

**Files:**
- Create: `python/pyproject.toml`
- Create: `python/src/hydra_client/__init__.py` (빈 파일로 시작)
- Create: `python/src/hydra_client/errors.py`
- Test: `python/tests/test_errors.py`

**Interfaces:**
- Produces: 예외 계층 `HydraError`, `HydraConnectionError`, `HydraAuthError`, `HydraNotFoundError`, `HydraServerError(status_code, message)`, `TaskFailedError(task)` — 이후 모든 태스크가 이 이름을 사용

- [ ] **Step 1: 디렉토리와 pyproject 생성**

```toml
# python/pyproject.toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "hydra-client"
version = "0.1.0"
description = "Python client, scheduler simulator, and worker for the hydra GPU cluster"
requires-python = ">=3.10"
dependencies = [
    "requests>=2.31",
    "websockets>=12",
]

[project.optional-dependencies]
dev = [
    "pytest>=8",
    "responses>=0.25",
]

[tool.hatch.build.targets.wheel]
packages = ["src/hydra_client"]

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = ["e2e: requires a running hydra-server (deselected by default)"]
addopts = "-m 'not e2e'"
```

```bash
mkdir -p python/src/hydra_client python/tests/fixtures/scheduler
touch python/src/hydra_client/__init__.py
cd python && python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
```

- [ ] **Step 2: 실패하는 테스트 작성**

```python
# python/tests/test_errors.py
from hydra_client.errors import (
    HydraError, HydraConnectionError, HydraAuthError,
    HydraNotFoundError, HydraServerError, TaskFailedError,
)


def test_hierarchy():
    for exc in (HydraConnectionError, HydraAuthError,
                HydraNotFoundError, HydraServerError, TaskFailedError):
        assert issubclass(exc, HydraError)


def test_server_error_carries_status():
    e = HydraServerError(503, "task queue not available")
    assert e.status_code == 503
    assert "503" in str(e)


def test_task_failed_carries_task():
    task = object()
    e = TaskFailedError(task, "task tsk-1 failed")
    assert e.task is task
```

- [ ] **Step 3: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_errors.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'hydra_client.errors'`

- [ ] **Step 4: errors.py 구현**

```python
# python/src/hydra_client/errors.py
"""hydra-client 예외 계층."""
from __future__ import annotations


class HydraError(Exception):
    """모든 hydra-client 예외의 베이스."""


class HydraConnectionError(HydraError):
    """서버 연결 실패 / 타임아웃 (wait 중에는 백오프 재시도 후 발생)."""


class HydraAuthError(HydraError):
    """401 — API 키 누락/무효."""


class HydraNotFoundError(HydraError):
    """404 — task/device/group 없음."""


class HydraServerError(HydraError):
    """5xx 서버 오류."""

    def __init__(self, status_code: int, message: str):
        self.status_code = status_code
        super().__init__(f"{status_code}: {message}")


class TaskFailedError(HydraError):
    """wait() 중 task가 failed로 종결됨. .task로 최종 Task 접근."""

    def __init__(self, task, message: str):
        self.task = task
        super().__init__(message)
```

- [ ] **Step 5: 통과 확인 후 커밋**

Run: `cd python && .venv/bin/python -m pytest tests/test_errors.py -v`
Expected: 3 passed

```bash
git add python/pyproject.toml python/src/hydra_client python/tests/test_errors.py
git commit -m "feat(python): hydra-client 패키지 스캐폴드 + 예외 계층

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: models.py — 데이터 모델과 JSON 매핑

**Files:**
- Create: `python/src/hydra_client/models.py`
- Test: `python/tests/test_models.py`

**Interfaces:**
- Produces (이후 태스크가 그대로 사용):
  - `ResourceRequirements(gpu_memory_mb=0, cpu_cores=0, memory_mb=0, gpu_utilization=0.0, gpu_count=0)` / `.to_json()` / `.from_json(d)`
  - `TaskSpec(type="command", payload={}, priority="normal", required_capabilities=[], preferred_device_id="", resource_reqs=None, timeout=0.0, max_retries=0, ai_schedule=None, blocked_device_ids=[])` / `.to_json()` / 클래스메서드 `TaskSpec.command(cmd, **kw)`
  - `Task.from_json(d)` — 속성: `id, type, status, priority, payload, assigned_device_id, result, error, group_id, retry_count, max_retries, timeout_ns, blocked_device_ids, assigned_gpu_indexes, raw`
  - `TaskResult.from_json(d)` — `device_id, device_name, output, duration_ns`
  - `Device.from_json(d)` — `id, name, hostname, os, status, has_gpu, gpu_count, gpu_model, capabilities, ssh_enabled`
  - `WorkerSnapshot(device_id, capabilities=[], gpu_utilization=0.0, memory_free_gb=0.0, cpu_usage=0.0, running_jobs=0, gpu_count=0, gpu_memory_free_mb=0)` / `.from_json(d)` (camelCase 키)
  - 상수 `TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled"})`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# python/tests/test_models.py
from hydra_client.models import (
    ResourceRequirements, TaskSpec, Task, Device, WorkerSnapshot,
    TERMINAL_STATUSES,
)


def test_resource_reqs_to_json_omits_zeros():
    r = ResourceRequirements(gpu_memory_mb=16000, gpu_count=2)
    assert r.to_json() == {"gpuMemoryMB": 16000, "gpuCount": 2}
    assert ResourceRequirements().to_json() == {}


def test_taskspec_command_helper():
    spec = TaskSpec.command("echo hi", priority="high", timeout=60)
    j = spec.to_json()
    assert j["type"] == "command"
    assert j["payload"] == {"command": "echo hi"}
    assert j["priority"] == "high"
    assert j["timeout"] == 60          # 초 단위 int
    assert "preferredDeviceId" not in j  # 빈 값은 생략
    assert "aiSchedule" not in j


def test_taskspec_resource_reqs_serialized():
    spec = TaskSpec.command(
        "train", resource_reqs=ResourceRequirements(gpu_memory_mb=8000))
    assert spec.to_json()["resourceReqs"] == {"gpuMemoryMB": 8000}


def test_task_from_json():
    d = {
        "id": "t1", "type": "command", "status": "assigned",
        "priority": "normal", "payload": {"command": "echo"},
        "assignedDeviceId": "gpu1", "timeout": 60_000_000_000,  # ns
        "retryCount": 0, "maxRetries": 3,
        "assignedGpuIndexes": [0, 3],
        "result": {"deviceId": "gpu1", "deviceName": "gpu1",
                   "output": {"stdout": "hi"}, "durationMs": 1_500_000_000},
    }
    t = Task.from_json(d)
    assert t.id == "t1"
    assert t.assigned_device_id == "gpu1"
    assert t.timeout_ns == 60_000_000_000
    assert t.assigned_gpu_indexes == [0, 3]
    assert t.result.output["stdout"] == "hi"
    assert t.result.duration_ns == 1_500_000_000
    assert t.raw is d


def test_device_from_json():
    d = Device.from_json({"id": "d1", "name": "gpu1", "hostname": "gpu1",
                          "os": "Linux", "status": "online", "hasGpu": True,
                          "gpuCount": 2, "gpuModel": "RTX 5090",
                          "capabilities": ["gpu"], "sshEnabled": True})
    assert d.has_gpu and d.gpu_count == 2


def test_worker_snapshot_from_json():
    w = WorkerSnapshot.from_json({"deviceId": "d1", "capabilities": ["gpu"],
                                  "gpuUtilization": 20.0, "memoryFreeGB": 32.0,
                                  "cpuUsage": 10.0, "runningJobs": 1,
                                  "gpuCount": 2, "gpuMemoryFreeMB": 40000})
    assert w.device_id == "d1" and w.gpu_memory_free_mb == 40000


def test_terminal_statuses():
    assert TERMINAL_STATUSES == {"completed", "failed", "cancelled"}
```

- [ ] **Step 2: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_models.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'hydra_client.models'`

- [ ] **Step 3: models.py 구현**

```python
# python/src/hydra_client/models.py
"""서버 JSON(camelCase) <-> 파이썬(snake_case) 매핑 전담 모듈.

단위 주의:
- TaskSpec.timeout 은 초 단위(float) — 생성 요청 JSON의 "timeout"(초, int)으로 변환
- Task.timeout_ns / TaskResult.duration_ns 는 나노초 — Go time.Duration 직렬화 값
  ("durationMs" 라는 필드명과 달리 실제 값은 나노초다)
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled"})


@dataclass
class ResourceRequirements:
    gpu_memory_mb: int = 0
    cpu_cores: int = 0
    memory_mb: int = 0
    gpu_utilization: float = 0.0
    gpu_count: int = 0  # per-GPU 계약(스펙 §6). 구서버는 무시

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        if self.gpu_memory_mb:
            out["gpuMemoryMB"] = self.gpu_memory_mb
        if self.cpu_cores:
            out["cpuCores"] = self.cpu_cores
        if self.memory_mb:
            out["memoryMB"] = self.memory_mb
        if self.gpu_utilization:
            out["gpuUtilization"] = self.gpu_utilization
        if self.gpu_count:
            out["gpuCount"] = self.gpu_count
        return out

    @classmethod
    def from_json(cls, d: dict[str, Any]) -> "ResourceRequirements":
        return cls(
            gpu_memory_mb=d.get("gpuMemoryMB", 0),
            cpu_cores=d.get("cpuCores", 0),
            memory_mb=d.get("memoryMB", 0),
            gpu_utilization=d.get("gpuUtilization", 0.0),
            gpu_count=d.get("gpuCount", 0),
        )


@dataclass
class TaskSpec:
    """제출용 task 명세. blocked_device_ids 는 sim 전용 — 서버로 전송하지 않음."""

    type: str = "command"
    payload: dict[str, Any] = field(default_factory=dict)
    priority: str = "normal"
    required_capabilities: list[str] = field(default_factory=list)
    preferred_device_id: str = ""
    resource_reqs: ResourceRequirements | None = None
    timeout: float = 0.0  # 초
    max_retries: int = 0
    ai_schedule: bool | None = None
    blocked_device_ids: list[str] = field(default_factory=list)

    @classmethod
    def command(cls, command: str, **kwargs: Any) -> "TaskSpec":
        return cls(type="command", payload={"command": command}, **kwargs)

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "type": self.type,
            "payload": self.payload,
            "priority": self.priority,
            "requiredCapabilities": self.required_capabilities,
            "timeout": int(self.timeout),
            "maxRetries": self.max_retries,
        }
        if self.preferred_device_id:
            out["preferredDeviceId"] = self.preferred_device_id
        if self.ai_schedule is not None:
            out["aiSchedule"] = self.ai_schedule
        if self.resource_reqs is not None:
            r = self.resource_reqs.to_json()
            if r:
                out["resourceReqs"] = r
        return out


@dataclass
class TaskResult:
    device_id: str = ""
    device_name: str = ""
    output: dict[str, Any] = field(default_factory=dict)
    duration_ns: int = 0

    @classmethod
    def from_json(cls, d: dict[str, Any]) -> "TaskResult":
        return cls(
            device_id=d.get("deviceId", ""),
            device_name=d.get("deviceName", ""),
            output=d.get("output") or {},
            duration_ns=d.get("durationMs", 0),  # 필드명과 달리 값은 ns
        )


@dataclass
class Task:
    id: str
    type: str = ""
    status: str = ""
    priority: str = "normal"
    payload: dict[str, Any] = field(default_factory=dict)
    assigned_device_id: str = ""
    result: TaskResult | None = None
    error: str = ""
    group_id: str = ""
    retry_count: int = 0
    max_retries: int = 0
    timeout_ns: int = 0
    blocked_device_ids: list[str] = field(default_factory=list)
    assigned_gpu_indexes: list[int] = field(default_factory=list)
    raw: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_json(cls, d: dict[str, Any]) -> "Task":
        result = d.get("result")
        return cls(
            id=d.get("id", ""),
            type=d.get("type", ""),
            status=d.get("status", ""),
            priority=d.get("priority", "normal"),
            payload=d.get("payload") or {},
            assigned_device_id=d.get("assignedDeviceId", ""),
            result=TaskResult.from_json(result) if result else None,
            error=d.get("error", ""),
            group_id=d.get("groupId", ""),
            retry_count=d.get("retryCount", 0),
            max_retries=d.get("maxRetries", 0),
            timeout_ns=d.get("timeout", 0),
            blocked_device_ids=d.get("blockedDeviceIds") or [],
            assigned_gpu_indexes=d.get("assignedGpuIndexes") or [],
            raw=d,
        )

    @property
    def is_terminal(self) -> bool:
        return self.status in TERMINAL_STATUSES


@dataclass
class Device:
    id: str
    name: str = ""
    hostname: str = ""
    os: str = ""
    status: str = ""
    has_gpu: bool = False
    gpu_count: int = 0
    gpu_model: str = ""
    capabilities: list[str] = field(default_factory=list)
    ssh_enabled: bool = False
    raw: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_json(cls, d: dict[str, Any]) -> "Device":
        return cls(
            id=d.get("id", ""),
            name=d.get("name", ""),
            hostname=d.get("hostname", ""),
            os=d.get("os", ""),
            status=d.get("status", ""),
            has_gpu=d.get("hasGpu", False),
            gpu_count=d.get("gpuCount", 0),
            gpu_model=d.get("gpuModel", ""),
            capabilities=d.get("capabilities") or [],
            ssh_enabled=d.get("sshEnabled", False),
            raw=d,
        )


@dataclass
class WorkerSnapshot:
    """스케줄러 점수 입력 — Go ai.WorkerSnapshot 과 1:1 (스펙 §5)."""

    device_id: str
    capabilities: list[str] = field(default_factory=list)
    gpu_utilization: float = 0.0
    memory_free_gb: float = 0.0
    cpu_usage: float = 0.0
    running_jobs: int = 0
    gpu_count: int = 0
    gpu_memory_free_mb: int = 0

    @classmethod
    def from_json(cls, d: dict[str, Any]) -> "WorkerSnapshot":
        return cls(
            device_id=d.get("deviceId", ""),
            capabilities=d.get("capabilities") or [],
            gpu_utilization=d.get("gpuUtilization", 0.0),
            memory_free_gb=d.get("memoryFreeGB", 0.0),
            cpu_usage=d.get("cpuUsage", 0.0),
            running_jobs=d.get("runningJobs", 0),
            gpu_count=d.get("gpuCount", 0),
            gpu_memory_free_mb=d.get("gpuMemoryFreeMB", 0),
        )
```

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd python && .venv/bin/python -m pytest tests/test_models.py -v`
Expected: 7 passed

```bash
git add python/src/hydra_client/models.py python/tests/test_models.py
git commit -m "feat(python): 데이터 모델과 camelCase JSON 매핑

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Go — task 생성에 resourceReqs 바인딩 + gpuCount 계약 필드

**Files:**
- Modify: `internal/domain/task.go` (ResourceRequirements에 GPUCount 추가)
- Modify: `internal/web/handler/task_handler.go:57-87` (APITaskCreate 요청 바인딩)
- Modify: `internal/web/handler/task_group_handler.go:71-80,134-146` (batch entry 바인딩)
- Test: `internal/web/handler/task_handler_test.go` (신규 또는 기존 파일에 추가)

**Interfaces:**
- Consumes: 기존 `domain.ResourceRequirements`, `domain.Task`
- Produces: `POST /api/tasks`와 `POST /api/tasks/batch`가 `resourceReqs` JSON을 `Task.ResourceReqs`로 바인딩. `ResourceRequirements.GPUCount int json:"gpuCount,omitempty"` 필드 존재 (스케줄러는 2단계까지 미사용 — 계약만 고정)

**주의:** 테스트 헬퍼(Handler 구성 방식)는 `internal/web/handler/task_group_handler_test.go`의 기존 패턴을 그대로 따를 것. 스케줄링 동작 변경은 없음 — 순수 바인딩 추가.

- [ ] **Step 1: 실패하는 테스트 작성**

`task_group_handler_test.go`의 Handler/큐 구성 방식을 확인해 동일하게 구성한 뒤:

```go
// internal/web/handler/task_handler_test.go (패키지/헬퍼는 기존 테스트 파일과 동일하게)
func TestAPITaskCreateBindsResourceReqs(t *testing.T) {
	// task_group_handler_test.go 와 같은 방식으로 taskQueue 를 가진 Handler 구성
	h, q := newTestHandlerWithQueue(t) // 기존 헬퍼가 없으면 같은 파일에 사설 헬퍼로 추출

	body := `{"type":"command","payload":{"command":"echo hi"},` +
		`"resourceReqs":{"gpuMemoryMB":16000,"gpuCount":2,"cpuCores":4,"memoryMB":8192}}`
	req := httptest.NewRequest(http.MethodPost, "/api/tasks", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	if err := h.APITaskCreate(c); err != nil {
		t.Fatalf("APITaskCreate: %v", err)
	}
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}

	var got domain.Task
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	r := got.ResourceReqs
	if r == nil {
		t.Fatal("ResourceReqs not bound (nil)")
	}
	if r.GPUMemoryMB != 16000 || r.GPUCount != 2 || r.CPUCores != 4 || r.MemoryMB != 8192 {
		t.Fatalf("ResourceReqs = %+v", r)
	}
	// 큐에 들어간 task 에도 반영됐는지 확인
	if in := q.Get(got.ID); in == nil || in.ResourceReqs == nil || in.ResourceReqs.GPUCount != 2 {
		t.Fatalf("queued task ResourceReqs = %+v", in)
	}
}
```

- [ ] **Step 2: 실패 확인**

Run: `go test ./internal/web/handler/ -run TestAPITaskCreateBindsResourceReqs -v`
Expected: FAIL — `r.GPUCount undefined` (컴파일) 또는 `ResourceReqs not bound (nil)`

- [ ] **Step 3: 구현**

`internal/domain/task.go` — ResourceRequirements에 필드 추가:

```go
// ResourceRequirements specifies the hardware resources needed to run a task.
type ResourceRequirements struct {
	GPUMemoryMB    int     `json:"gpuMemoryMB,omitempty"`
	CPUCores       int     `json:"cpuCores,omitempty"`
	MemoryMB       int     `json:"memoryMB,omitempty"`
	GPUUtilization float64 `json:"gpuUtilization,omitempty"`
	// GPUCount is the number of GPUs the task needs, with GPUMemoryMB
	// interpreted per-GPU once per-GPU packing lands (spec 2026-07-07 §6).
	// 0 means "1 GPU" for schedulers that understand it; the current
	// scheduler ignores this field entirely.
	GPUCount int `json:"gpuCount,omitempty"`
}
```

`internal/web/handler/task_handler.go` — 요청 구조체와 Task 생성에 각각 한 줄:

```go
	var req struct {
		Type                 string                       `json:"type"`
		Priority             string                       `json:"priority"`
		RequiredCapabilities []string                     `json:"requiredCapabilities"`
		PreferredDeviceID    string                       `json:"preferredDeviceId"`
		Payload              map[string]interface{}       `json:"payload"`
		Timeout              int                          `json:"timeout"` // seconds
		MaxRetries           int                          `json:"maxRetries"`
		AISchedule           *bool                        `json:"aiSchedule"`
		ResourceReqs         *domain.ResourceRequirements `json:"resourceReqs"`
	}
```

```go
	task := &domain.Task{
		// ... 기존 필드 유지 ...
		ResourceReqs: req.ResourceReqs,
	}
```

`internal/web/handler/task_group_handler.go` — `taskBatchEntry`에 `ResourceReqs *domain.ResourceRequirements json:"resourceReqs"` 추가, `APITaskBatchCreate`의 Task 생성에 `ResourceReqs: e.ResourceReqs,` 추가.

- [ ] **Step 4: 통과 + 전체 회귀 확인**

Run: `go test ./internal/web/handler/ -run TestAPITaskCreate -v && go test ./... && go vet ./...`
Expected: PASS, 전체 통과

- [ ] **Step 5: 커밋**

```bash
git add internal/domain/task.go internal/web/handler/task_handler.go internal/web/handler/task_group_handler.go internal/web/handler/task_handler_test.go
git commit -m "feat(api): task 생성/배치에 resourceReqs 바인딩 + gpuCount 계약 필드

POST /api/tasks 가 resourceReqs 를 받지 않아 클라이언트의 자원 요구가
무시되던 누락을 수정. gpuCount 는 per-GPU packing(설계 스펙 §6) 계약
선반영 — 현 스케줄러는 미사용.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: client.py — HydraClient 코어 (요청/예외 매핑/CRUD)

**Files:**
- Create: `python/src/hydra_client/client.py`
- Test: `python/tests/test_client.py`

**Interfaces:**
- Consumes: `models.TaskSpec/Task/Device`, `errors.*`
- Produces:
  - `HydraClient(base_url, api_key=None, timeout=10.0)`
  - `.submit_task(command=None, *, spec=None, **spec_kwargs) -> TaskHandle`
  - `.get_task(task_id) -> Task`, `.list_tasks(status=None, device_id=None) -> list[Task]`
  - `.update_task_status(task_id, status) -> Task`, `.cancel_task(task_id) -> Task`
  - `.set_task_result(task_id, *, device_id, device_name="", output=None, duration_ns=0) -> Task`
  - `.list_devices() -> list[Device]`, `.get_device(id) -> Device`
  - `.register_capabilities(device_id, capabilities) -> None`
  - `TaskHandle` — `.id`, `.task`(마지막 조회 Task), `.status`, `.result`, `.assigned_device_id`, `.refresh() -> Task` (wait는 Task 5)

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# python/tests/test_client.py
import pytest
import responses

from hydra_client.client import HydraClient
from hydra_client.errors import (
    HydraAuthError, HydraConnectionError, HydraNotFoundError, HydraServerError,
)

BASE = "http://head:8080"


@pytest.fixture
def client():
    return HydraClient(BASE, api_key="k123", timeout=5.0)


@responses.activate
def test_submit_task_posts_contract_json(client):
    responses.post(
        f"{BASE}/api/tasks",
        json={"id": "t1", "type": "command", "status": "assigned",
              "assignedDeviceId": "gpu1"},
        status=201,
    )
    handle = client.submit_task(
        "echo hi", priority="high", gpu_memory_mb=16000, gpu_count=2,
        timeout=60,
    )
    assert handle.id == "t1"
    assert handle.status == "assigned"
    assert handle.assigned_device_id == "gpu1"

    sent = responses.calls[0].request
    assert sent.headers["X-API-Key"] == "k123"
    import json as _json
    body = _json.loads(sent.body)
    assert body["type"] == "command"
    assert body["payload"] == {"command": "echo hi"}
    assert body["priority"] == "high"
    assert body["timeout"] == 60
    assert body["resourceReqs"] == {"gpuMemoryMB": 16000, "gpuCount": 2}


@responses.activate
def test_get_task_and_list(client):
    responses.get(f"{BASE}/api/tasks/t1",
                  json={"id": "t1", "status": "running"})
    responses.get(f"{BASE}/api/tasks",
                  json=[{"id": "t1", "status": "running"}])
    assert client.get_task("t1").status == "running"
    tasks = client.list_tasks(status="running")
    assert len(tasks) == 1
    assert responses.calls[1].request.params == {"status": "running"}


@responses.activate
def test_cancel_task_puts_status(client):
    responses.put(f"{BASE}/api/tasks/t1/status",
                  json={"id": "t1", "status": "cancelled"})
    assert client.cancel_task("t1").status == "cancelled"
    import json as _json
    assert _json.loads(responses.calls[0].request.body) == {"status": "cancelled"}


@responses.activate
def test_set_task_result(client):
    responses.put(f"{BASE}/api/tasks/t1/result",
                  json={"id": "t1", "status": "completed"})
    client.set_task_result("t1", device_id="gpu1",
                           output={"stdout": "hi", "exitCode": 0},
                           duration_ns=1_000_000)
    import json as _json
    body = _json.loads(responses.calls[0].request.body)
    assert body == {"deviceId": "gpu1", "deviceName": "",
                    "output": {"stdout": "hi", "exitCode": 0},
                    "durationMs": 1_000_000}


@responses.activate
def test_error_mapping(client):
    responses.get(f"{BASE}/api/tasks/x", json={"error": "task not found"}, status=404)
    responses.get(f"{BASE}/api/tasks/y", json={"error": "nope"}, status=401)
    responses.get(f"{BASE}/api/tasks/z", json={"error": "boom"}, status=503)
    with pytest.raises(HydraNotFoundError):
        client.get_task("x")
    with pytest.raises(HydraAuthError):
        client.get_task("y")
    with pytest.raises(HydraServerError) as ei:
        client.get_task("z")
    assert ei.value.status_code == 503


@responses.activate
def test_connection_error_wrapped(client):
    # responses 는 등록 안 된 URL 에 ConnectionError 를 발생시킨다
    with pytest.raises(HydraConnectionError):
        client.get_task("unreachable")


@responses.activate
def test_devices_and_capabilities(client):
    responses.get(f"{BASE}/api/devices",
                  json=[{"id": "d1", "hasGpu": True, "gpuCount": 2}])
    responses.post(f"{BASE}/api/devices/d1/capabilities",
                   json={"deviceId": "d1", "capabilities": ["gpu"]})
    devs = client.list_devices()
    assert devs[0].gpu_count == 2
    client.register_capabilities("d1", ["gpu"])
    import json as _json
    assert _json.loads(responses.calls[1].request.body) == {"capabilities": ["gpu"]}
```

- [ ] **Step 2: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_client.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'hydra_client.client'`

- [ ] **Step 3: client.py 구현 (코어)**

```python
# python/src/hydra_client/client.py
"""hydra Go 백엔드(:8080) REST 클라이언트.

스케줄링(점수 계산, 큐잉, AI 중재)은 전부 서버가 수행한다 — 이 모듈은
계약대로 제출하고 조회만 한다. 점수의 오프라인 재현은 sim.py 참조.
"""
from __future__ import annotations

import time
from typing import Any

import requests

from .errors import (
    HydraAuthError, HydraConnectionError, HydraError,
    HydraNotFoundError, HydraServerError, TaskFailedError,
)
from .models import Device, ResourceRequirements, Task, TaskSpec, WorkerSnapshot


class HydraClient:
    def __init__(self, base_url: str, api_key: str | None = None,
                 timeout: float = 10.0):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._session = requests.Session()
        if api_key:
            self._session.headers["X-API-Key"] = api_key

    # ── 내부 공통 ────────────────────────────────────────────────
    def _request(self, method: str, path: str, *,
                 json_body: Any = None, params: dict | None = None) -> Any:
        url = f"{self.base_url}{path}"
        try:
            resp = self._session.request(
                method, url, json=json_body, params=params,
                timeout=self.timeout)
        except requests.RequestException as e:
            raise HydraConnectionError(f"{method} {url}: {e}") from e

        if resp.status_code == 401:
            raise HydraAuthError(_error_message(resp))
        if resp.status_code == 404:
            raise HydraNotFoundError(_error_message(resp))
        if resp.status_code >= 500:
            raise HydraServerError(resp.status_code, _error_message(resp))
        if resp.status_code >= 400:
            raise HydraError(f"{resp.status_code}: {_error_message(resp)}")
        return resp.json()

    # ── task ────────────────────────────────────────────────────
    def submit_task(self, command: str | None = None, *,
                    spec: TaskSpec | None = None,
                    type: str = "command",
                    payload: dict | None = None,
                    priority: str = "normal",
                    required_capabilities: list[str] | None = None,
                    preferred_device_id: str = "",
                    gpu_memory_mb: int = 0, gpu_count: int = 0,
                    cpu_cores: int = 0, memory_mb: int = 0,
                    timeout: float = 0.0, max_retries: int = 0,
                    ai_schedule: bool | None = None) -> "TaskHandle":
        if spec is None:
            reqs = ResourceRequirements(
                gpu_memory_mb=gpu_memory_mb, gpu_count=gpu_count,
                cpu_cores=cpu_cores, memory_mb=memory_mb)
            spec = TaskSpec(
                type=type,
                payload=payload if payload is not None
                        else ({"command": command} if command else {}),
                priority=priority,
                required_capabilities=required_capabilities or [],
                preferred_device_id=preferred_device_id,
                resource_reqs=reqs if reqs.to_json() else None,
                timeout=timeout, max_retries=max_retries,
                ai_schedule=ai_schedule)
        data = self._request("POST", "/api/tasks", json_body=spec.to_json())
        return TaskHandle(self, Task.from_json(data))

    def get_task(self, task_id: str) -> Task:
        return Task.from_json(self._request("GET", f"/api/tasks/{task_id}"))

    def list_tasks(self, status: str | None = None,
                   device_id: str | None = None) -> list[Task]:
        params = {}
        if status:
            params["status"] = status
        if device_id:
            params["device_id"] = device_id
        data = self._request("GET", "/api/tasks", params=params or None)
        return [Task.from_json(d) for d in data]

    def update_task_status(self, task_id: str, status: str) -> Task:
        data = self._request("PUT", f"/api/tasks/{task_id}/status",
                             json_body={"status": status})
        return Task.from_json(data)

    def cancel_task(self, task_id: str) -> Task:
        return self.update_task_status(task_id, "cancelled")

    def set_task_result(self, task_id: str, *, device_id: str,
                        device_name: str = "",
                        output: dict | None = None,
                        duration_ns: int = 0) -> Task:
        body = {"deviceId": device_id, "deviceName": device_name,
                "output": output or {}, "durationMs": duration_ns}
        data = self._request("PUT", f"/api/tasks/{task_id}/result",
                             json_body=body)
        return Task.from_json(data)

    # ── device ──────────────────────────────────────────────────
    def list_devices(self) -> list[Device]:
        data = self._request("GET", "/api/devices")
        return [Device.from_json(d) for d in data]

    def get_device(self, device_id: str) -> Device:
        return Device.from_json(
            self._request("GET", f"/api/devices/{device_id}"))

    def register_capabilities(self, device_id: str,
                              capabilities: list[str]) -> None:
        self._request("POST", f"/api/devices/{device_id}/capabilities",
                      json_body={"capabilities": capabilities})


def _error_message(resp) -> str:
    try:
        return resp.json().get("error", resp.text)
    except ValueError:
        return resp.text


class TaskHandle:
    """제출된 task 의 추적 핸들. wait() 는 Task 5 에서 추가."""

    def __init__(self, client: HydraClient, task: Task):
        self._client = client
        self.task = task

    @property
    def id(self) -> str:
        return self.task.id

    @property
    def status(self) -> str:
        return self.task.status

    @property
    def result(self):
        return self.task.result

    @property
    def assigned_device_id(self) -> str:
        return self.task.assigned_device_id

    def refresh(self) -> Task:
        self.task = self._client.get_task(self.task.id)
        return self.task
```

`GET /api/devices`는 Device 객체의 순수 JSON 배열을 반환한다(래핑 없음 — `handler.go` APIDeviceList 확인 완료). 기본 응답은 모바일/좀비 디바이스를 필터링한 목록이다.

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd python && .venv/bin/python -m pytest tests/test_client.py tests/ -v`
Expected: 전부 passed

```bash
git add python/src/hydra_client/client.py python/tests/test_client.py
git commit -m "feat(python): HydraClient REST 코어 (제출/조회/상태/결과/디바이스)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: TaskHandle.wait + 배치(submit_batch / TaskGroupHandle)

**Files:**
- Modify: `python/src/hydra_client/client.py`
- Test: `python/tests/test_wait_and_batch.py`

**Interfaces:**
- Consumes: Task 4의 `HydraClient`, `TaskHandle`
- Produces:
  - `TaskHandle.wait(timeout=None, poll_interval=2.0, raise_on_failure=True) -> Task`
  - `HydraClient.submit_batch(specs: list[TaskSpec], name="", metadata=None) -> TaskGroupHandle`
  - `HydraClient.get_group(group_id, detail=False) -> dict` (TaskGroupSnapshot raw)
  - `TaskGroupHandle` — `.group_id`, `.tasks: list[TaskHandle]`, `.refresh() -> dict`, `.wait_all(timeout=None, poll_interval=2.0) -> dict`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# python/tests/test_wait_and_batch.py
import pytest
import responses

from hydra_client.client import HydraClient
from hydra_client.errors import HydraConnectionError, TaskFailedError
from hydra_client.models import TaskSpec

BASE = "http://head:8080"


@pytest.fixture
def client():
    return HydraClient(BASE)


@responses.activate
def test_wait_polls_until_completed(client):
    responses.post(f"{BASE}/api/tasks", json={"id": "t1", "status": "queued"},
                   status=201)
    responses.get(f"{BASE}/api/tasks/t1", json={"id": "t1", "status": "running"})
    responses.get(f"{BASE}/api/tasks/t1",
                  json={"id": "t1", "status": "completed",
                        "result": {"deviceId": "g1", "output": {"stdout": "hi"},
                                   "durationMs": 5}})
    h = client.submit_task("echo hi")
    task = h.wait(poll_interval=0.01)
    assert task.status == "completed"
    assert task.result.output["stdout"] == "hi"


@responses.activate
def test_wait_raises_on_failed(client):
    responses.post(f"{BASE}/api/tasks", json={"id": "t1", "status": "queued"},
                   status=201)
    responses.get(f"{BASE}/api/tasks/t1", json={"id": "t1", "status": "failed"})
    h = client.submit_task("boom")
    with pytest.raises(TaskFailedError):
        h.wait(poll_interval=0.01)


@responses.activate
def test_wait_failed_without_raise(client):
    responses.post(f"{BASE}/api/tasks", json={"id": "t1", "status": "queued"},
                   status=201)
    responses.get(f"{BASE}/api/tasks/t1", json={"id": "t1", "status": "failed"})
    h = client.submit_task("boom")
    assert h.wait(poll_interval=0.01, raise_on_failure=False).status == "failed"


@responses.activate
def test_wait_timeout_raises(client):
    responses.post(f"{BASE}/api/tasks", json={"id": "t1", "status": "queued"},
                   status=201)
    responses.get(f"{BASE}/api/tasks/t1", json={"id": "t1", "status": "running"})
    responses.get(f"{BASE}/api/tasks/t1", json={"id": "t1", "status": "running"})
    h = client.submit_task("slow")
    with pytest.raises(TimeoutError):
        h.wait(timeout=0.05, poll_interval=0.01)


@responses.activate
def test_wait_retries_connection_blips(client):
    import requests as _requests
    responses.post(f"{BASE}/api/tasks", json={"id": "t1", "status": "queued"},
                   status=201)
    responses.get(f"{BASE}/api/tasks/t1",
                  body=_requests.ConnectionError("blip"))
    responses.get(f"{BASE}/api/tasks/t1", json={"id": "t1", "status": "completed"})
    h = client.submit_task("echo")
    assert h.wait(poll_interval=0.01).status == "completed"


@responses.activate
def test_submit_batch_and_wait_all(client):
    responses.post(
        f"{BASE}/api/tasks/batch",
        json={"id": "g1", "totalTasks": 2, "queued": 2, "status": "running",
              "tasks": [{"id": "t1", "status": "queued"},
                        {"id": "t2", "status": "queued"}]},
        status=201)
    responses.get(f"{BASE}/api/groups/g1",
                  json={"id": "g1", "totalTasks": 2, "completed": 2,
                        "failed": 0, "running": 0, "queued": 0,
                        "status": "completed"})
    group = client.submit_batch(
        [TaskSpec.command("a"), TaskSpec.command("b")], name="exp-1")
    assert group.group_id == "g1"
    assert [t.id for t in group.tasks] == ["t1", "t2"]
    snap = group.wait_all(poll_interval=0.01)
    assert snap["status"] == "completed"

    import json as _json
    body = _json.loads(responses.calls[0].request.body)
    assert body["name"] == "exp-1"
    assert len(body["tasks"]) == 2
    assert body["tasks"][0]["payload"] == {"command": "a"}
```

- [ ] **Step 2: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_wait_and_batch.py -v`
Expected: FAIL — `AttributeError: ... no attribute 'wait'` 류

- [ ] **Step 3: 구현**

`client.py`의 `TaskHandle`에 wait 추가, `HydraClient`에 batch 추가:

```python
# TaskHandle 에 추가
    def wait(self, timeout: float | None = None, poll_interval: float = 2.0,
             raise_on_failure: bool = True) -> Task:
        """terminal 상태(completed/failed/cancelled)까지 폴링.

        일시적 연결 오류는 지수 백오프(최대 30s)로 재시도한다. timeout 초과 시:
        마지막 시도가 연결 오류였으면 HydraConnectionError, 아니면 TimeoutError.
        """
        deadline = time.monotonic() + timeout if timeout else None
        backoff = poll_interval
        last_conn_error: Exception | None = None
        while True:
            try:
                self.refresh()
                last_conn_error = None
                backoff = poll_interval
                if self.task.is_terminal:
                    if self.task.status == "failed" and raise_on_failure:
                        raise TaskFailedError(
                            self.task, f"task {self.task.id} failed")
                    return self.task
            except HydraConnectionError as e:
                last_conn_error = e
                backoff = min(backoff * 2, 30.0)
            if deadline is not None and time.monotonic() >= deadline:
                if last_conn_error is not None:
                    raise HydraConnectionError(
                        f"wait({self.task.id}): server unreachable"
                    ) from last_conn_error
                raise TimeoutError(
                    f"task {self.task.id} not terminal after {timeout}s "
                    f"(status={self.task.status})")
            time.sleep(min(backoff,
                           max(0.0, deadline - time.monotonic())
                           if deadline is not None else backoff))
```

```python
# HydraClient 에 추가
    def submit_batch(self, specs: list[TaskSpec], name: str = "",
                     metadata: dict | None = None) -> "TaskGroupHandle":
        body = {"name": name, "metadata": metadata or {},
                "tasks": [s.to_json() for s in specs]}
        snap = self._request("POST", "/api/tasks/batch", json_body=body)
        return TaskGroupHandle(self, snap)

    def get_group(self, group_id: str, detail: bool = False) -> dict:
        params = {"detail": "full"} if detail else None
        return self._request("GET", f"/api/groups/{group_id}", params=params)
```

```python
class TaskGroupHandle:
    """배치 제출 결과 핸들. snapshot 은 TaskGroupSnapshot raw dict."""

    def __init__(self, client: HydraClient, snapshot: dict):
        self._client = client
        self.snapshot = snapshot
        self.tasks = [TaskHandle(client, Task.from_json(t))
                      for t in (snapshot.get("tasks") or [])]

    @property
    def group_id(self) -> str:
        return self.snapshot.get("id", "")

    def refresh(self) -> dict:
        self.snapshot = self._client.get_group(self.group_id)
        return self.snapshot

    # 그룹 terminal 상태는 domain.DeriveGroupStatus 기준:
    # completed(전부 성공) / failed(전부 실패) / partial(혼합). running 만 비종결.
    GROUP_TERMINAL = ("completed", "failed", "partial")

    def wait_all(self, timeout: float | None = None,
                 poll_interval: float = 2.0) -> dict:
        """그룹 status 가 terminal 이 될 때까지 폴링."""
        deadline = time.monotonic() + timeout if timeout else None
        while True:
            snap = self.refresh()
            if snap.get("status") in self.GROUP_TERMINAL:
                return snap
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError(
                    f"group {self.group_id} not terminal after {timeout}s")
            time.sleep(poll_interval)
```

스펙과 다른 확정 사항: 그룹 상태에 "cancelled"는 없다 — `domain.DeriveGroupStatus`(task_group.go:43)는 running/completed/failed/partial 네 값만 반환한다.

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd python && .venv/bin/python -m pytest tests/ -v`
Expected: 전부 passed

```bash
git add python/src/hydra_client/client.py python/tests/test_wait_and_batch.py
git commit -m "feat(python): TaskHandle.wait 폴링 + 배치 제출(TaskGroupHandle)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: 모니터링 조회 + cluster_snapshot (sim 입력 재구성)

**Files:**
- Modify: `python/src/hydra_client/client.py`
- Test: `python/tests/test_monitoring.py`

**Interfaces:**
- Consumes: `models.WorkerSnapshot`, Task 4의 `_request`
- Produces:
  - `HydraClient.gpu_metrics() -> dict` (GET /api/monitor/gpu raw)
  - `HydraClient.metrics_snapshot() -> dict` (GET /api/monitor/snapshot raw)
  - `HydraClient.cluster_snapshot() -> list[WorkerSnapshot]` — Go `buildWorkerSnapshot`(task_supervisor.go:290)과 동일 집계: GPU 사용률 평균, GPU 여유 VRAM 합산(MB), memory.free bytes→GB, running_jobs = 해당 디바이스의 assigned+running task 수. metrics에 `error`가 있으면 CPU/메모리/GPU 항은 0 유지

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# python/tests/test_monitoring.py
import responses

from hydra_client.client import HydraClient

BASE = "http://head:8080"
GB = 1024 ** 3
MB = 1024 ** 2


@responses.activate
def test_cluster_snapshot_mirrors_go_aggregation():
    client = HydraClient(BASE)
    responses.get(f"{BASE}/api/devices", json=[
        {"id": "gpu1", "capabilities": ["gpu"], "gpuCount": 2},
        {"id": "cpu1", "capabilities": ["compute"], "gpuCount": 0},
    ])
    responses.get(f"{BASE}/api/monitor/snapshot", json={
        "devices": {
            "gpu1": {"deviceId": "gpu1",
                     "cpu": {"usagePercent": 10.0},
                     "memory": {"free": 32 * GB},
                     "gpu": {"gpus": [
                         {"usagePercent": 20.0, "memoryFree": 20000 * MB},
                         {"usagePercent": 40.0, "memoryFree": 10000 * MB}]}},
            "cpu1": {"deviceId": "cpu1",
                     "cpu": {"usagePercent": 50.0},
                     "memory": {"free": 8 * GB},
                     "error": "ssh: dial timeout"},   # error → 자원 항 0 유지
        },
        "collectedAt": "2026-07-07T00:00:00Z",
    })
    responses.get(f"{BASE}/api/tasks", json=[
        {"id": "t1", "status": "running", "assignedDeviceId": "gpu1"},
        {"id": "t2", "status": "assigned", "assignedDeviceId": "gpu1"},
        {"id": "t3", "status": "completed", "assignedDeviceId": "gpu1"},
    ])

    snaps = {s.device_id: s for s in client.cluster_snapshot()}
    g = snaps["gpu1"]
    assert g.gpu_utilization == 30.0            # (20+40)/2
    assert g.gpu_memory_free_mb == 30000        # 합산
    assert g.memory_free_gb == 32.0
    assert g.cpu_usage == 10.0
    assert g.running_jobs == 2                  # running + assigned
    assert g.gpu_count == 2
    c = snaps["cpu1"]
    assert c.cpu_usage == 0.0 and c.memory_free_gb == 0.0  # error 디바이스
```

- [ ] **Step 2: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_monitoring.py -v`
Expected: FAIL — `AttributeError: ... 'cluster_snapshot'`

- [ ] **Step 3: 구현**

```python
# HydraClient 에 추가
    def gpu_metrics(self) -> dict:
        return self._request("GET", "/api/monitor/gpu")

    def metrics_snapshot(self) -> dict:
        return self._request("GET", "/api/monitor/snapshot")

    def cluster_snapshot(self) -> list[WorkerSnapshot]:
        """sim 입력용 WorkerSnapshot 목록.

        Go buildWorkerSnapshot(task_supervisor.go)과 같은 집계:
        GPU 사용률 평균 / 여유 VRAM 합산 / bytes→GB, running_jobs 는
        assigned+running task 수. 시점 차이와 AI 중재 때문에 실제 배치와
        다를 수 있다 — sim.explain() 문서 참조.
        """
        devices = self.list_devices()
        metrics = (self.metrics_snapshot().get("devices") or {})
        running: dict[str, int] = {}
        for status in ("assigned", "running"):
            for t in self.list_tasks(status=status):
                if t.assigned_device_id:
                    running[t.assigned_device_id] = (
                        running.get(t.assigned_device_id, 0) + 1)

        snaps: list[WorkerSnapshot] = []
        for dev in devices:
            snap = WorkerSnapshot(
                device_id=dev.id, capabilities=dev.capabilities,
                running_jobs=running.get(dev.id, 0), gpu_count=dev.gpu_count)
            m = metrics.get(dev.id)
            if m and not m.get("error"):
                snap.cpu_usage = (m.get("cpu") or {}).get("usagePercent", 0.0)
                snap.memory_free_gb = (
                    (m.get("memory") or {}).get("free", 0) / (1024 ** 3))
                gpus = ((m.get("gpu") or {}).get("gpus") or [])
                if gpus:
                    snap.gpu_utilization = (
                        sum(g.get("usagePercent", 0.0) for g in gpus)
                        / len(gpus))
                    snap.gpu_memory_free_mb = int(
                        sum(g.get("memoryFree", 0) for g in gpus)
                        / (1024 ** 2))
            snaps.append(snap)
        return snaps
```

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd python && .venv/bin/python -m pytest tests/ -v`
Expected: 전부 passed

```bash
git add python/src/hydra_client/client.py python/tests/test_monitoring.py
git commit -m "feat(python): 모니터링 조회 + cluster_snapshot 집계 (Go buildWorkerSnapshot 미러)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Go — 스케줄러 골든 픽스처 덤프/검증 테스트

**Files:**
- Create: `internal/infra/ai/scheduler_fixture_test.go`
- Create(생성물): `python/tests/fixtures/scheduler/cases.json` (커밋 대상)

**Interfaces:**
- Consumes: `ScoreForTask`, `domain.Task`, `domain.ResourceRequirements`, `WorkerSnapshot`
- Produces: `cases.json` — `[{name, task{priority, requiredCapabilities?, preferredDeviceId?, blockedDeviceIds?, resourceReqs?}, worker{deviceId, capabilities, gpuUtilization, memoryFreeGB, cpuUsage, runningJobs, gpuCount, gpuMemoryFreeMB}, expectedScore}]`. Task 8의 파이썬 패리티 테스트가 이 파일을 소비

- [ ] **Step 1: 픽스처 테스트 작성 (동작: env `HYDRA_UPDATE_FIXTURES=1`이면 파일 재생성, 아니면 커밋본과 현행 로직 비교)**

```go
// internal/infra/ai/scheduler_fixture_test.go
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

type fixtureWorker struct {
	DeviceID        string   `json:"deviceId"`
	Capabilities    []string `json:"capabilities"`
	GPUUtilization  float64  `json:"gpuUtilization"`
	MemoryFreeGB    float64  `json:"memoryFreeGB"`
	CPUUsage        float64  `json:"cpuUsage"`
	RunningJobs     int      `json:"runningJobs"`
	GPUCount        int      `json:"gpuCount"`
	GPUMemoryFreeMB int      `json:"gpuMemoryFreeMB"`
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
	return WorkerSnapshot{
		DeviceID: f.DeviceID, Capabilities: f.Capabilities,
		GPUUtilization: f.GPUUtilization, MemoryFreeGB: f.MemoryFreeGB,
		CPUUsage: f.CPUUsage, RunningJobs: f.RunningJobs,
		GPUCount: f.GPUCount, GPUMemoryFreeMB: f.GPUMemoryFreeMB,
	}
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
```

- [ ] **Step 2: 픽스처 생성 후 검증 모드 통과 확인**

```bash
HYDRA_UPDATE_FIXTURES=1 go test ./internal/infra/ai/ -run TestSchedulerFixtures -v
go test ./internal/infra/ai/ -run TestSchedulerFixtures -v
```
Expected: 첫 실행이 `python/tests/fixtures/scheduler/cases.json` 생성(14 cases), 두 번째 실행 PASS

- [ ] **Step 3: 전체 Go 회귀 후 커밋**

Run: `go test ./... && go vet ./...`
Expected: 전체 통과

```bash
git add internal/infra/ai/scheduler_fixture_test.go python/tests/fixtures/scheduler/cases.json
git commit -m "test(ai): 스케줄러 점수 골든 픽스처 — Python sim 패리티 계약

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: sim.py — 점수 로직 포팅 + 패리티 테스트

**Files:**
- Create: `python/src/hydra_client/sim.py`
- Test: `python/tests/test_sim_parity.py`, `python/tests/test_sim.py`

**Interfaces:**
- Consumes: `models.TaskSpec`, `models.ResourceRequirements`, `models.WorkerSnapshot`, Task 7의 `cases.json`
- Produces:
  - `INELIGIBLE = -1.0`
  - `score_for_task(task: TaskSpec, worker: WorkerSnapshot) -> float`
  - `pick_best_worker(task, workers) -> WorkerSnapshot | None`
  - `ScoreBreakdown` dataclass — `worker_id, eligible, reject_reason, gpu_free_term, mem_term, cpu_term, queue_term, priority_mult, total`
  - `explain(task, workers) -> list[ScoreBreakdown]` (total 내림차순, ineligible 뒤쪽)

- [ ] **Step 1: 실패하는 패리티 테스트 작성**

```python
# python/tests/test_sim_parity.py
"""Go ScoreForTask 와의 점수 패리티 — cases.json 은 Go 테스트가 생성한다.

깨졌다면 Go 스케줄러 로직이 바뀐 것: sim.py 를 맞추고
HYDRA_UPDATE_FIXTURES=1 go test ./internal/infra/ai/ 로 픽스처를 재생성할 것.
"""
import json
import pathlib

import pytest

from hydra_client.models import ResourceRequirements, TaskSpec, WorkerSnapshot
from hydra_client.sim import score_for_task

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "scheduler" / "cases.json"
CASES = json.loads(FIXTURE.read_text())


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_score_matches_go(case):
    t = case["task"]
    reqs = t.get("resourceReqs")
    spec = TaskSpec(
        priority=t.get("priority", "normal"),
        required_capabilities=t.get("requiredCapabilities") or [],
        preferred_device_id=t.get("preferredDeviceId", ""),
        blocked_device_ids=t.get("blockedDeviceIds") or [],
        resource_reqs=ResourceRequirements.from_json(reqs) if reqs else None,
    )
    worker = WorkerSnapshot.from_json(case["worker"])
    got = score_for_task(spec, worker)
    assert got == pytest.approx(case["expectedScore"], abs=1e-9), case["name"]
```

```python
# python/tests/test_sim.py
from hydra_client.models import TaskSpec, WorkerSnapshot
from hydra_client.sim import INELIGIBLE, explain, pick_best_worker, score_for_task


def _worker(device_id, **kw):
    defaults = dict(capabilities=["gpu"], gpu_utilization=20.0,
                    memory_free_gb=32.0, cpu_usage=10.0, running_jobs=1,
                    gpu_memory_free_mb=40000)
    defaults.update(kw)
    return WorkerSnapshot(device_id=device_id, **defaults)


def test_pick_best_prefers_less_loaded():
    spec = TaskSpec()
    idle = _worker("idle", gpu_utilization=5.0, running_jobs=0)
    busy = _worker("busy", gpu_utilization=90.0, running_jobs=5)
    assert pick_best_worker(spec, [busy, idle]).device_id == "idle"


def test_pick_best_returns_none_when_all_ineligible():
    spec = TaskSpec(required_capabilities=["quantum"])
    assert pick_best_worker(spec, [_worker("a"), _worker("b")]) is None


def test_explain_reports_reject_reason_and_terms():
    spec = TaskSpec(required_capabilities=["gpu"], priority="high")
    ok = _worker("ok")
    no_cap = _worker("no-cap", capabilities=["compute"])
    rows = {r.worker_id: r for r in explain(spec, [ok, no_cap])}
    assert rows["ok"].eligible
    assert rows["ok"].priority_mult == 1.3
    assert rows["ok"].total == score_for_task(spec, ok)
    assert not rows["no-cap"].eligible
    assert rows["no-cap"].reject_reason == "missing capability"
    assert rows["no-cap"].total == INELIGIBLE


def test_explain_sorted_by_total_desc():
    spec = TaskSpec()
    rows = explain(spec, [_worker("busy", running_jobs=8), _worker("idle", running_jobs=0)])
    assert [r.worker_id for r in rows] == ["idle", "busy"]
```

- [ ] **Step 2: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_sim_parity.py tests/test_sim.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'hydra_client.sim'`

- [ ] **Step 3: sim.py 구현 (Go scheduler.go:69-122 의 1:1 포팅)**

```python
# python/src/hydra_client/sim.py
"""Go RuleBasedScheduler(internal/infra/ai/scheduler.go)의 오프라인 재현.

규칙 기반 점수만 재현한다. 서버가 AI 중재(tiebreak/always-consult)를 쓰면
실제 배치는 다를 수 있고, 스냅샷 시점 차이로도 달라질 수 있다.
패리티는 tests/fixtures/scheduler/cases.json 으로 CI 에서 강제된다.
"""
from __future__ import annotations

from dataclasses import dataclass

from .models import TaskSpec, WorkerSnapshot

INELIGIBLE = -1.0

_PRIORITY_MULT = {"urgent": 2.0, "high": 1.3, "low": 0.7}


def _priority_multiplier(priority: str) -> float:
    return _PRIORITY_MULT.get(priority, 1.0)


def _reject_reason(task: TaskSpec, w: WorkerSnapshot) -> str | None:
    """부적격 사유. 적격이면 None. 판정 순서는 Go ScoreForTask 와 동일."""
    if w.device_id in (task.blocked_device_ids or []):
        return "blocked (anti-affinity)"
    if task.preferred_device_id and task.preferred_device_id != w.device_id:
        return "pinned to another device"
    have = set(w.capabilities or [])
    for cap in task.required_capabilities or []:
        if cap not in have:
            return "missing capability"
    r = task.resource_reqs
    if r is not None:
        if r.gpu_memory_mb > 0 and r.gpu_memory_mb > w.gpu_memory_free_mb:
            return "insufficient GPU memory"
        if r.memory_mb > 0 and r.memory_mb / 1024.0 > w.memory_free_gb:
            return "insufficient RAM"
    return None


def score_for_task(task: TaskSpec, w: WorkerSnapshot) -> float:
    """Go ScoreForTask 포팅. 높을수록 좋음, INELIGIBLE(-1.0)은 부적격."""
    if task is None or _reject_reason(task, w) is not None:
        return INELIGIBLE
    gpu_free = 100.0 - w.gpu_utilization
    mem_score = w.memory_free_gb * 5.0
    cpu_free = 100.0 - w.cpu_usage
    queue_score = float(100 - w.running_jobs * 10)
    if queue_score < 0:
        queue_score = 0.0
    base = (gpu_free * 0.4 + mem_score * 0.3
            + cpu_free * 0.2 + queue_score * 0.1)
    return base * _priority_multiplier(task.priority)


def pick_best_worker(task: TaskSpec,
                     workers: list[WorkerSnapshot]) -> WorkerSnapshot | None:
    """Go PickBestWorker 포팅 — 적격 워커 중 최고점. 없으면 None."""
    best, best_score = None, INELIGIBLE
    for w in workers:
        s = score_for_task(task, w)
        if s <= INELIGIBLE:
            continue
        if best is None or s > best_score:
            best, best_score = w, s
    return best


@dataclass
class ScoreBreakdown:
    worker_id: str
    eligible: bool
    reject_reason: str | None
    gpu_free_term: float
    mem_term: float
    cpu_term: float
    queue_term: float
    priority_mult: float
    total: float


def explain(task: TaskSpec,
            workers: list[WorkerSnapshot]) -> list[ScoreBreakdown]:
    """워커별 점수 분해 — 왜 선택/탈락했는지. total 내림차순 정렬."""
    rows: list[ScoreBreakdown] = []
    for w in workers:
        reason = _reject_reason(task, w)
        if reason is not None:
            rows.append(ScoreBreakdown(
                worker_id=w.device_id, eligible=False, reject_reason=reason,
                gpu_free_term=0.0, mem_term=0.0, cpu_term=0.0,
                queue_term=0.0, priority_mult=0.0, total=INELIGIBLE))
            continue
        queue_score = max(0.0, float(100 - w.running_jobs * 10))
        rows.append(ScoreBreakdown(
            worker_id=w.device_id, eligible=True, reject_reason=None,
            gpu_free_term=(100.0 - w.gpu_utilization) * 0.4,
            mem_term=w.memory_free_gb * 5.0 * 0.3,
            cpu_term=(100.0 - w.cpu_usage) * 0.2,
            queue_term=queue_score * 0.1,
            priority_mult=_priority_multiplier(task.priority),
            total=score_for_task(task, w)))
    rows.sort(key=lambda r: r.total, reverse=True)
    return rows
```

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd python && .venv/bin/python -m pytest tests/ -v`
Expected: 전부 passed (패리티 14케이스 포함)

```bash
git add python/src/hydra_client/sim.py python/tests/test_sim_parity.py python/tests/test_sim.py
git commit -m "feat(python): 스케줄러 점수 sim 포팅 + Go 골든 픽스처 패리티 테스트

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: worker.py — WS 실행 루프

**Files:**
- Create: `python/src/hydra_client/worker.py`
- Create: `python/src/hydra_client/__main__.py` 는 만들지 않음 — 실행은 `python -m hydra_client.worker` (worker.py 안의 `if __name__ == "__main__":`)
- Test: `python/tests/test_worker.py`

**Interfaces:**
- Consumes: `HydraClient.update_task_status/set_task_result/register_capabilities`, `errors.HydraNotFoundError`
- Produces:
  - `Worker(server, device_id=None, capabilities=None, max_concurrent=1, reconnect_max_backoff=30.0)`
  - `.run()` (블로킹 루프), `.stop()`, `.handle_message(msg: dict)` (테스트 훅), `.execute_task(task: dict)` (동기 실행 — 테스트에서 직접 호출)
  - CLI: `python -m hydra_client.worker --server URL [--device-id ID] [--capabilities a,b] [--max-concurrent N] [--api-key KEY]`

- [ ] **Step 1: 실패하는 테스트 작성 (실행 로직은 execute_task 를 직접 호출해 검증 — WS 루프는 handle_message 단위로)**

```python
# python/tests/test_worker.py
import json
import sys

import pytest
import responses

from hydra_client.worker import Worker

BASE = "http://head:8080"


def make_worker(**kw):
    return Worker(BASE, device_id="gpu1", capabilities=["gpu"], **kw)


@responses.activate
def test_execute_task_reports_success():
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/result",
                  json={"id": "t1", "status": "completed"})
    w = make_worker()
    w.execute_task({"id": "t1", "payload": {"command": "echo hello"}})

    # running 전이 → result 보고 (failed 후속 호출 없음)
    assert responses.calls[0].request.url.endswith("/api/tasks/t1/status")
    assert json.loads(responses.calls[0].request.body) == {"status": "running"}
    body = json.loads(responses.calls[1].request.body)
    assert body["deviceId"] == "gpu1"
    assert body["output"]["exitCode"] == 0
    assert "hello" in body["output"]["stdout"]
    assert body["durationMs"] > 0
    assert len(responses.calls) == 2


@responses.activate
def test_execute_task_failure_reports_result_then_failed():
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/result", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    w = make_worker()
    w.execute_task({"id": "t1",
                    "payload": {"command": f"{sys.executable} -c 'raise SystemExit(3)'"}})

    body = json.loads(responses.calls[1].request.body)
    assert body["output"]["exitCode"] == 3
    # 결과 보존 후 failed 전이 (순서 중요: SetResult 는 completed 로 만들므로)
    assert json.loads(responses.calls[2].request.body) == {"status": "failed"}


@responses.activate
def test_execute_task_timeout_kills_and_fails():
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/result", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    w = make_worker(term_grace=0.2)
    w.execute_task({"id": "t1", "payload": {"command": "sleep 30"},
                    "timeout": int(0.2 * 1e9)})  # ns

    body = json.loads(responses.calls[1].request.body)
    assert body["output"]["timedOut"] is True
    assert json.loads(responses.calls[2].request.body) == {"status": "failed"}


@responses.activate
def test_execute_task_sets_cuda_visible_devices():
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/result", json={"id": "t1"})
    w = make_worker()
    w.execute_task({"id": "t1",
                    "payload": {"command": "echo dev=$CUDA_VISIBLE_DEVICES"},
                    "assignedGpuIndexes": [0, 3]})
    body = json.loads(responses.calls[1].request.body)
    assert "dev=0,3" in body["output"]["stdout"]


@responses.activate
def test_execute_task_missing_command_reports_failure():
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/result", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    w = make_worker()
    w.execute_task({"id": "t1", "payload": {}})
    body = json.loads(responses.calls[1].request.body)
    assert body["output"]["exitCode"] != 0
    assert json.loads(responses.calls[2].request.body) == {"status": "failed"}


def test_handle_message_dispatches_assign(monkeypatch):
    w = make_worker()
    seen = []
    monkeypatch.setattr(w, "execute_task", lambda task: seen.append(task["id"]))
    w.handle_message({"type": "task.assign", "taskId": "t9",
                      "payload": {"id": "t9", "payload": {"command": "true"}}})
    w._pool.shutdown(wait=True)
    assert seen == ["t9"]


def test_handle_message_ignores_unknown_types():
    w = make_worker()
    w.handle_message({"type": "ping"})       # 예외 없이 무시
    w.handle_message({"type": "task.cancel", "taskId": "none"})
```

- [ ] **Step 2: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_worker.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'hydra_client.worker'`

- [ ] **Step 3: worker.py 구현**

```python
# python/src/hydra_client/worker.py
"""hydra 워커 — task.assign 을 받아 실행하고 결과를 보고하는 실행 루프.

서버의 실행-보고 루프가 비어 있던 부분(설계 스펙 §7)을 채운다:
  /ws 접속 → capability 등록 → task.assign 수신 → subprocess 실행
  → PUT /result 보고 (exit≠0 이면 이어서 PUT /status failed).
결과를 WS 가 아니라 REST 로 보고하는 이유: 서버에 task.result WS 수신
처리가 없어, 기존 REST 엔드포인트가 Go 변경 없이 완결되는 경로라서다.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import socket
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from .client import HydraClient
from .errors import HydraError, HydraNotFoundError

log = logging.getLogger("hydra_client.worker")

_REPORT_RETRIES = 3


class Worker:
    def __init__(self, server: str, device_id: str | None = None,
                 capabilities: list[str] | None = None,
                 max_concurrent: int = 1,
                 reconnect_max_backoff: float = 30.0,
                 api_key: str | None = None,
                 term_grace: float = 5.0):
        self.server = server.rstrip("/")
        self.device_id = device_id or socket.gethostname()
        self.capabilities = capabilities or ["compute"]
        self.client = HydraClient(self.server, api_key=api_key)
        self.reconnect_max_backoff = reconnect_max_backoff
        self.term_grace = term_grace  # SIGTERM 후 SIGKILL 까지 유예(초)
        self._pool = ThreadPoolExecutor(max_workers=max_concurrent)
        self._procs: dict[str, subprocess.Popen] = {}
        self._procs_lock = threading.Lock()
        self._stop = threading.Event()

    # ── 수신 루프 ────────────────────────────────────────────────
    def run(self) -> None:
        """WS 접속·수신 블로킹 루프. 끊기면 지수 백오프로 재접속."""
        from websockets.sync.client import connect as ws_connect

        scheme = "wss" if self.server.startswith("https") else "ws"
        host = self.server.split("://", 1)[1]
        url = f"{scheme}://{host}/ws?device_id={self.device_id}"
        backoff = 1.0
        while not self._stop.is_set():
            try:
                with ws_connect(url, max_size=512 * 1024) as conn:
                    log.info("connected to %s as %s", url, self.device_id)
                    backoff = 1.0
                    # 재접속마다 재등록 — 서버 재시작에도 능력 정보 유지
                    self.client.register_capabilities(
                        self.device_id, self.capabilities)
                    for raw in conn:
                        self.handle_message(json.loads(raw))
            except Exception as e:  # noqa: BLE001 — 루프는 죽지 않는다
                if self._stop.is_set():
                    break
                log.warning("ws error: %s (reconnect in %.0fs)", e, backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, self.reconnect_max_backoff)
        self._pool.shutdown(wait=True)

    def stop(self) -> None:
        self._stop.set()

    def handle_message(self, msg: dict) -> None:
        mtype = msg.get("type")
        if mtype == "task.assign":
            task = msg.get("payload") or {}
            if isinstance(task, str):  # 방어: RawMessage 가 문자열로 올 경우
                task = json.loads(task)
            self._pool.submit(self.execute_task, task)
        elif mtype == "task.cancel":
            self._kill(msg.get("taskId", ""))
        # ping/pong 등은 websockets 가 처리, 나머지는 무시

    # ── 실행 ────────────────────────────────────────────────────
    def execute_task(self, task: dict) -> None:
        task_id = task.get("id", "")
        command = (task.get("payload") or {}).get("command")
        self._try_report_status(task_id, "running")
        if not command:
            self._report(task_id, {"stdout": "", "stderr": "no command in payload",
                                   "exitCode": 1, "timedOut": False},
                         failed=True, duration_ns=0)
            return

        env = os.environ.copy()
        gpu_indexes = task.get("assignedGpuIndexes")
        if gpu_indexes:
            env["CUDA_VISIBLE_DEVICES"] = ",".join(str(i) for i in gpu_indexes)

        timeout_ns = task.get("timeout") or 0
        timeout_s = timeout_ns / 1e9 if timeout_ns else None

        start = time.monotonic()
        proc = subprocess.Popen(
            command, shell=True, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=env)
        with self._procs_lock:
            self._procs[task_id] = proc
        timed_out = False
        try:
            stdout, stderr = proc.communicate(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            self._kill(task_id)
            stdout, stderr = proc.communicate()
        finally:
            with self._procs_lock:
                self._procs.pop(task_id, None)

        duration_ns = int((time.monotonic() - start) * 1e9)
        exit_code = proc.returncode
        failed = timed_out or exit_code != 0
        self._report(task_id,
                     {"stdout": stdout, "stderr": stderr,
                      "exitCode": exit_code, "timedOut": timed_out},
                     failed=failed, duration_ns=duration_ns)

    def _kill(self, task_id: str) -> None:
        with self._procs_lock:
            proc = self._procs.get(task_id)
        if proc is None or proc.poll() is not None:
            return
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, signal.SIGTERM)
        deadline = time.monotonic() + self.term_grace
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return
            time.sleep(0.1)
        os.killpg(pgid, signal.SIGKILL)

    # ── 보고 ────────────────────────────────────────────────────
    def _report(self, task_id: str, output: dict, *, failed: bool,
                duration_ns: int) -> None:
        # 순서 중요: 결과(output) 먼저 보존 — SetResult 가 completed 로
        # 만들기 때문에, 실패면 이어서 status=failed 로 덮는다.
        self._retry(lambda: self.client.set_task_result(
            task_id, device_id=self.device_id, device_name=self.device_id,
            output=output, duration_ns=duration_ns))
        if failed:
            self._try_report_status(task_id, "failed")

    def _try_report_status(self, task_id: str, status: str) -> None:
        self._retry(lambda: self.client.update_task_status(task_id, status))

    def _retry(self, fn) -> None:
        backoff = 1.0
        for attempt in range(_REPORT_RETRIES):
            try:
                fn()
                return
            except HydraNotFoundError:
                # 서버가 재할당/삭제했을 수 있음 — 폐기
                log.warning("report dropped: task gone from server")
                return
            except HydraError as e:
                if attempt == _REPORT_RETRIES - 1:
                    log.error("report failed after %d attempts: %s",
                              _REPORT_RETRIES, e)
                    return
                time.sleep(backoff)
                backoff = min(backoff * 2, 10.0)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="python -m hydra_client.worker",
        description="hydra task 실행 워커")
    parser.add_argument("--server", required=True, help="예: http://head:8080")
    parser.add_argument("--device-id", default=None)
    parser.add_argument("--capabilities", default="compute",
                        help="쉼표 구분, 예: gpu,cuda")
    parser.add_argument("--max-concurrent", type=int, default=1)
    parser.add_argument("--api-key", default=None)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    worker = Worker(args.server, device_id=args.device_id,
                    capabilities=args.capabilities.split(","),
                    max_concurrent=args.max_concurrent,
                    api_key=args.api_key)
    try:
        worker.run()
    except KeyboardInterrupt:
        worker.stop()


if __name__ == "__main__":
    main()
```

`test_execute_task_reports_success`에서 running 상태 보고가 command 검사보다 먼저다 — 구현도 그 순서(위 코드처럼 `_try_report_status`를 command 검사 앞에)로 할 것. no-command 케이스의 호출 수(3개: running/result/failed)와 테스트가 일치하는지 확인.

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd python && .venv/bin/python -m pytest tests/ -v`
Expected: 전부 passed (timeout 테스트 포함 — 수 초 소요 정상)

```bash
git add python/src/hydra_client/worker.py python/tests/test_worker.py
git commit -m "feat(python): 워커 실행 루프 — task.assign 수신, subprocess 실행, 결과 보고

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: 공개 API 정리 + README + 최종 검증

**Files:**
- Modify: `python/src/hydra_client/__init__.py`
- Create: `python/README.md`
- Test: `python/tests/test_public_api.py`

**Interfaces:**
- Produces: `from hydra_client import HydraClient, TaskSpec, ResourceRequirements, WorkerSnapshot, Worker` + `from hydra_client import sim`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# python/tests/test_public_api.py
def test_top_level_exports():
    import hydra_client
    for name in ("HydraClient", "TaskSpec", "ResourceRequirements",
                 "Task", "Device", "WorkerSnapshot", "Worker",
                 "HydraError", "TaskFailedError"):
        assert hasattr(hydra_client, name), name
    from hydra_client import sim
    assert callable(sim.score_for_task)
```

- [ ] **Step 2: 실패 확인**

Run: `cd python && .venv/bin/python -m pytest tests/test_public_api.py -v`
Expected: FAIL — `AssertionError: HydraClient`

- [ ] **Step 3: __init__.py + README 작성**

```python
# python/src/hydra_client/__init__.py
"""hydra GPU 클러스터 파이썬 클라이언트.

설계 스펙: docs/superpowers/specs/2026-07-07-python-client-design.md
"""
from . import sim
from .client import HydraClient, TaskGroupHandle, TaskHandle
from .errors import (
    HydraAuthError, HydraConnectionError, HydraError,
    HydraNotFoundError, HydraServerError, TaskFailedError,
)
from .models import (
    Device, ResourceRequirements, Task, TaskResult, TaskSpec, WorkerSnapshot,
)
from .worker import Worker

__all__ = [
    "HydraClient", "TaskHandle", "TaskGroupHandle",
    "TaskSpec", "Task", "TaskResult", "ResourceRequirements",
    "Device", "WorkerSnapshot", "Worker", "sim",
    "HydraError", "HydraConnectionError", "HydraAuthError",
    "HydraNotFoundError", "HydraServerError", "TaskFailedError",
]
```

README(`python/README.md`)에는 다음을 담는다 — 설치(`pip install -e '.[dev]'`), 제출/wait 예제, 배치 예제, sim/explain 예제, 워커 실행 예제(스펙 §4~§7의 코드 예제 재사용), 그리고 **단위 주의**(생성 timeout=초, 응답 timeout/durationMs=ns)와 **sim 한계**(AI 중재·시점 차이) 명시. `gpu_count`/`gpu_memory_mb`는 per-GPU packing이 서버에 구현되기 전까지는 "현행 서버는 노드 합산 VRAM 기준"임을 명시(스펙 §6 주의 문구 그대로).

- [ ] **Step 4: 최종 전체 검증**

```bash
cd python && .venv/bin/python -m pytest tests/ -v     # 파이썬 전체
cd .. && go test ./... && go vet ./... && make build  # Go 회귀 + 빌드
```
Expected: 전부 통과

- [ ] **Step 5: 커밋**

```bash
git add python/src/hydra_client/__init__.py python/README.md python/tests/test_public_api.py
git commit -m "feat(python): 공개 API 정리 + README

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 계획 외 참고

- **e2e 스모크 (선택, 수동)**: 로컬에서 `make build && ./bin/hydra-server` 후
  `python -m hydra_client.worker --server http://localhost:8080 --capabilities compute` 실행,
  다른 셸에서 `HydraClient("http://localhost:8080").submit_task("echo e2e").wait()` 가 completed 로 끝나는지 확인.
  자동화는 `pytest -m e2e`로 추후 추가 가능 (스펙 §9-4).
- **2단계 (per-GPU packing)** 는 별도 계획으로: 스펙 §6 계약 준수, Go 구현 + sim/픽스처 갱신을 같은 커밋으로.
