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
