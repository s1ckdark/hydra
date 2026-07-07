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
