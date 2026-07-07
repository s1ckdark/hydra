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
