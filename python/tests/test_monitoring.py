import responses

from hydra_client.client import HydraClient

BASE = "http://head:8080"
GB = 1024 ** 3
MB = 1024 ** 2


@responses.activate
def test_cluster_snapshot_mirrors_go_aggregation():
    client = HydraClient(BASE)
    responses.get(f"{BASE}/api/devices", json=[
        {"id": "gpu1", "capabilities": ["gpu"], "gpuCount": 2, "status": "online"},
        {"id": "cpu1", "capabilities": ["compute"], "gpuCount": 0, "status": "online"},
        {"id": "gpu2-offline", "capabilities": ["gpu"], "gpuCount": 1,
         "status": "offline"},
    ])
    responses.get(f"{BASE}/api/monitor/snapshot", json={
        "devices": {
            "gpu1": {"deviceId": "gpu1",
                     "cpu": {"usagePercent": 10.0},
                     "memory": {"free": 32 * GB},
                     "gpu": {"gpus": [
                         {"index": 0, "usagePercent": 20.0, "memoryFree": 20000 * MB},
                         {"index": 1, "usagePercent": 40.0, "memoryFree": 10000 * MB}]}},
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
    # Fix 4: offline 디바이스는 Go 스케줄러가 점수화하지 않는 워커이므로 제외된다
    assert "gpu2-offline" not in snaps
    g = snaps["gpu1"]
    assert g.gpu_utilization == 30.0            # (20+40)/2
    assert g.gpu_memory_free_mb == 30000        # 합산
    assert g.memory_free_gb == 32.0
    assert g.cpu_usage == 10.0
    assert g.running_jobs == 2                  # running + assigned
    assert g.gpu_count == 2
    # per-GPU 상태 검증
    assert [(x.index, x.memory_free_mb, x.utilization) for x in g.gpus] == [
        (0, 20000, 20.0), (1, 10000, 40.0)]
    c = snaps["cpu1"]
    assert c.cpu_usage == 0.0 and c.memory_free_gb == 0.0  # error 디바이스
    assert c.gpus == []          # error 디바이스는 GPU별 상태도 비움
