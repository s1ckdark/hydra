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
