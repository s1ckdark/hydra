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
def test_wait_timeout_zero_raises_promptly(client):
    # timeout=0 은 "즉시 만료" 여야 한다 — falsy 취급하면 deadline 이 None 이
    # 되어 status="running" 인 task 를 영원히 폴링하게 된다.
    responses.post(f"{BASE}/api/tasks", json={"id": "t1", "status": "queued"},
                   status=201)
    responses.get(f"{BASE}/api/tasks/t1", json={"id": "t1", "status": "running"})
    h = client.submit_task("slow")
    with pytest.raises(TimeoutError):
        h.wait(timeout=0, poll_interval=0.01)


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
    # wait_all() 의 refresh() 폴링 (detail 파라미터 없음)
    responses.get(f"{BASE}/api/groups/g1",
                  json={"id": "g1", "totalTasks": 2, "completed": 2,
                        "failed": 0, "running": 0, "queued": 0,
                        "status": "completed"})
    # terminal 도달 후 detail=full 재조회 — 멤버 task 최신 상태 동기화용
    responses.get(f"{BASE}/api/groups/g1",
                  json={"id": "g1", "totalTasks": 2, "completed": 2,
                        "failed": 0, "running": 0, "queued": 0,
                        "status": "completed",
                        "tasks": [{"id": "t1", "status": "completed",
                                   "result": {"deviceId": "gpu1",
                                              "output": {"stdout": "a-out"},
                                              "durationMs": 5}},
                                  {"id": "t2", "status": "completed",
                                   "result": {"deviceId": "gpu1",
                                              "output": {"stdout": "b-out"},
                                              "durationMs": 6}}]})
    group = client.submit_batch(
        [TaskSpec.command("a"), TaskSpec.command("b")], name="exp-1")
    assert group.group_id == "g1"
    assert [t.id for t in group.tasks] == ["t1", "t2"]
    assert [t.status for t in group.tasks] == ["queued", "queued"]
    snap = group.wait_all(poll_interval=0.01)
    assert snap["status"] == "completed"

    # Fix 2: wait_all 은 terminal 도달 시 detail=full 로 멤버 핸들을 재동기화한다
    assert [t.status for t in group.tasks] == ["completed", "completed"]
    assert group.tasks[0].result.output["stdout"] == "a-out"
    assert group.tasks[1].result.output["stdout"] == "b-out"
    detail_call = responses.calls[-1].request
    assert detail_call.params == {"detail": "full"}

    import json as _json
    body = _json.loads(responses.calls[0].request.body)
    assert body["name"] == "exp-1"
    assert len(body["tasks"]) == 2
    assert body["tasks"][0]["payload"] == {"command": "a"}


@responses.activate
def test_wait_all_retries_connection_blips(client):
    import requests as _requests
    responses.post(
        f"{BASE}/api/tasks/batch",
        json={"id": "g1", "totalTasks": 1, "queued": 1, "status": "running",
              "tasks": [{"id": "t1", "status": "queued"}]},
        status=201)
    responses.get(f"{BASE}/api/groups/g1", body=_requests.ConnectionError("blip"))
    responses.get(f"{BASE}/api/groups/g1",
                  json={"id": "g1", "totalTasks": 1, "completed": 1,
                        "failed": 0, "running": 0, "queued": 0,
                        "status": "completed"})
    responses.get(f"{BASE}/api/groups/g1",
                  json={"id": "g1", "totalTasks": 1, "completed": 1,
                        "failed": 0, "running": 0, "queued": 0,
                        "status": "completed",
                        "tasks": [{"id": "t1", "status": "completed"}]})
    group = client.submit_batch([TaskSpec.command("a")], name="exp-3")
    snap = group.wait_all(poll_interval=0.01)
    assert snap["status"] == "completed"


@responses.activate
def test_wait_all_timeout_zero_raises_promptly(client):
    responses.post(
        f"{BASE}/api/tasks/batch",
        json={"id": "g1", "totalTasks": 1, "queued": 1, "status": "running",
              "tasks": [{"id": "t1", "status": "queued"}]},
        status=201)
    responses.get(f"{BASE}/api/groups/g1",
                  json={"id": "g1", "totalTasks": 1, "completed": 0,
                        "failed": 0, "running": 1, "queued": 0,
                        "status": "running"})
    group = client.submit_batch([TaskSpec.command("a")], name="exp-2")
    with pytest.raises(TimeoutError):
        group.wait_all(timeout=0, poll_interval=0.01)
