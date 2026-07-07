import json
import os
import subprocess
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


@responses.activate
def test_execute_task_popen_failure_reports_worker_exception(monkeypatch):
    # Popen 자체가 실패해도 (running → result → failed) 를 반드시 보고해야 한다.
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/result", json={"id": "t1"})
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})

    def raise_spawn_fail(*args, **kwargs):
        raise OSError("spawn fail")

    monkeypatch.setattr(subprocess, "Popen", raise_spawn_fail)
    w = make_worker()
    w.execute_task({"id": "t1", "payload": {"command": "echo hi"}})

    assert len(responses.calls) == 3
    assert json.loads(responses.calls[0].request.body) == {"status": "running"}
    body = json.loads(responses.calls[1].request.body)
    assert body["output"]["exitCode"] == -1
    assert "spawn fail" in body["output"]["stderr"]
    assert json.loads(responses.calls[2].request.body) == {"status": "failed"}


@responses.activate
def test_execute_task_report_failure_does_not_flip_success_to_failed(monkeypatch):
    # Fix 3: 성공 경로(_report)에서 non-HydraError 가 나도, 그건 실행 가드
    # 밖에서 일어나야 한다 — 안에서 잡히면 완료된 task 가 두 번째 실패
    # _report(failed=True) 호출로 덮여버린다.
    responses.put(f"{BASE}/api/tasks/t1/status", json={"id": "t1"})

    calls = []
    original_report = None

    def boom_report(self, task_id, output, *, failed, duration_ns):
        calls.append((output, failed))
        if len(calls) == 1:
            raise ValueError("malformed 2xx JSON")

    monkeypatch.setattr(Worker, "_report", boom_report)
    w = make_worker()
    with pytest.raises(ValueError):
        w.execute_task({"id": "t1", "payload": {"command": "echo hello"}})

    # _report 는 정확히 한 번만 호출된다 — 성공 경로에서 던진 예외가
    # exception-path 의 두 번째 failed 보고를 유발하지 않아야 한다.
    assert len(calls) == 1
    output, failed = calls[0]
    assert output["exitCode"] == 0
    assert failed is False


def test_worker_rejects_schemeless_server_url():
    with pytest.raises(ValueError, match="http://|https://"):
        Worker("head:8080", device_id="gpu1")


def test_kill_tolerates_process_already_reaped(monkeypatch):
    # poll() 확인 시점과 getpgid/killpg 사이에 프로세스가 이미 회수된 경합(TOCTOU)을 재현.
    w = make_worker()
    proc = subprocess.Popen("true", shell=True, start_new_session=True)
    proc.wait()  # 이미 종료·회수됨
    # poll() 이 여전히 "실행 중"으로 보이게 해 _kill 이 getpgid 까지 진행하도록 유도
    monkeypatch.setattr(proc, "poll", lambda: None)
    with w._procs_lock:
        w._procs["t1"] = proc

    def raise_lookup(pid):
        raise ProcessLookupError()

    monkeypatch.setattr(os, "getpgid", raise_lookup)
    w._kill("t1")  # 예외가 발생하면 안 된다
