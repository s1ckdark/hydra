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
