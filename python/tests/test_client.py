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
