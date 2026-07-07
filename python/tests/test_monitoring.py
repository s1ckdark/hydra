import responses

from hydra_client.client import HydraClient

BASE = "http://head:8080"
GB = 1024 ** 3
MB = 1024 ** 2


@responses.activate
def test_cluster_snapshot_mirrors_go_aggregation():
    client = HydraClient(BASE)
    responses.get(f"{BASE}/api/devices", json=[
        {"id": "gpu1", "capabilities": ["gpu"], "gpuCount": 2},
        {"id": "cpu1", "capabilities": ["compute"], "gpuCount": 0},
    ])
    responses.get(f"{BASE}/api/monitor/snapshot", json={
        "devices": {
            "gpu1": {"deviceId": "gpu1",
                     "cpu": {"usagePercent": 10.0},
                     "memory": {"free": 32 * GB},
                     "gpu": {"gpus": [
                         {"usagePercent": 20.0, "memoryFree": 20000 * MB},
                         {"usagePercent": 40.0, "memoryFree": 10000 * MB}]}},
            "cpu1": {"deviceId": "cpu1",
                     "cpu": {"usagePercent": 50.0},
                     "memory": {"free": 8 * GB},
                     "error": "ssh: dial timeout"},   # error → 자원 항 0 유지
        },
        "collectedAt": "2026-07-07T00:00:00Z",
    })
    responses.get(f"{BASE}/api/tasks", json=[
        {"id": "t1", "status": "running", "assignedDeviceId": "gpu1"},
        {"id": "t2", "status": "assigned", "assignedDeviceId": "gpu1"},
        {"id": "t3", "status": "completed", "assignedDeviceId": "gpu1"},
    ])

    snaps = {s.device_id: s for s in client.cluster_snapshot()}
    g = snaps["gpu1"]
    assert g.gpu_utilization == 30.0            # (20+40)/2
    assert g.gpu_memory_free_mb == 30000        # 합산
    assert g.memory_free_gb == 32.0
    assert g.cpu_usage == 10.0
    assert g.running_jobs == 2                  # running + assigned
    assert g.gpu_count == 2
    c = snaps["cpu1"]
    assert c.cpu_usage == 0.0 and c.memory_free_gb == 0.0  # error 디바이스
