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
