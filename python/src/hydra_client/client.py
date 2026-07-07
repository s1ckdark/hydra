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

    # ── batch ───────────────────────────────────────────────────
    def submit_batch(self, specs: list[TaskSpec], name: str = "",
                     metadata: dict | None = None) -> "TaskGroupHandle":
        body = {"name": name, "metadata": metadata or {},
                "tasks": [s.to_json() for s in specs]}
        snap = self._request("POST", "/api/tasks/batch", json_body=body)
        return TaskGroupHandle(self, snap)

    def get_group(self, group_id: str, detail: bool = False) -> dict:
        params = {"detail": "full"} if detail else None
        return self._request("GET", f"/api/groups/{group_id}", params=params)

    # ── monitoring ──────────────────────────────────────────────
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
        for t in self.list_tasks():
            if t.status in ("assigned", "running") and t.assigned_device_id:
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


class TaskGroupHandle:
    """배치 제출 결과 핸들. snapshot 은 TaskGroupSnapshot raw dict."""

    # 그룹 terminal 상태는 domain.DeriveGroupStatus 기준:
    # completed(전부 성공) / failed(전부 실패) / partial(혼합). running 만 비종결.
    GROUP_TERMINAL = ("completed", "failed", "partial")

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
