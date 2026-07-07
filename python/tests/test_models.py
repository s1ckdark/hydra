from hydra_client.models import (
    ResourceRequirements, TaskSpec, Task, Device, WorkerSnapshot,
    TERMINAL_STATUSES,
)


def test_resource_reqs_to_json_omits_zeros():
    r = ResourceRequirements(gpu_memory_mb=16000, gpu_count=2)
    assert r.to_json() == {"gpuMemoryMB": 16000, "gpuCount": 2}
    assert ResourceRequirements().to_json() == {}


def test_taskspec_command_helper():
    spec = TaskSpec.command("echo hi", priority="high", timeout=60)
    j = spec.to_json()
    assert j["type"] == "command"
    assert j["payload"] == {"command": "echo hi"}
    assert j["priority"] == "high"
    assert j["timeout"] == 60          # 초 단위 int
    assert "preferredDeviceId" not in j  # 빈 값은 생략
    assert "aiSchedule" not in j


def test_taskspec_resource_reqs_serialized():
    spec = TaskSpec.command(
        "train", resource_reqs=ResourceRequirements(gpu_memory_mb=8000))
    assert spec.to_json()["resourceReqs"] == {"gpuMemoryMB": 8000}


def test_task_from_json():
    d = {
        "id": "t1", "type": "command", "status": "assigned",
        "priority": "normal", "payload": {"command": "echo"},
        "assignedDeviceId": "gpu1", "timeout": 60_000_000_000,  # ns
        "retryCount": 0, "maxRetries": 3,
        "assignedGpuIndexes": [0, 3],
        "result": {"deviceId": "gpu1", "deviceName": "gpu1",
                   "output": {"stdout": "hi"}, "durationMs": 1_500_000_000},
    }
    t = Task.from_json(d)
    assert t.id == "t1"
    assert t.assigned_device_id == "gpu1"
    assert t.timeout_ns == 60_000_000_000
    assert t.assigned_gpu_indexes == [0, 3]
    assert t.result.output["stdout"] == "hi"
    assert t.result.duration_ns == 1_500_000_000
    assert t.raw is d


def test_device_from_json():
    d = Device.from_json({"id": "d1", "name": "gpu1", "hostname": "gpu1",
                          "os": "Linux", "status": "online", "hasGpu": True,
                          "gpuCount": 2, "gpuModel": "RTX 5090",
                          "capabilities": ["gpu"], "sshEnabled": True})
    assert d.has_gpu and d.gpu_count == 2


def test_worker_snapshot_from_json():
    w = WorkerSnapshot.from_json({"deviceId": "d1", "capabilities": ["gpu"],
                                  "gpuUtilization": 20.0, "memoryFreeGB": 32.0,
                                  "cpuUsage": 10.0, "runningJobs": 1,
                                  "gpuCount": 2, "gpuMemoryFreeMB": 40000})
    assert w.device_id == "d1" and w.gpu_memory_free_mb == 40000


def test_terminal_statuses():
    assert TERMINAL_STATUSES == {"completed", "failed", "cancelled"}
