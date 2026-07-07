"""Go ScoreForTask 와의 점수 패리티 — cases.json 은 Go 테스트가 생성한다.

깨졌다면 Go 스케줄러 로직이 바뀐 것: sim.py 를 맞추고
HYDRA_UPDATE_FIXTURES=1 go test ./internal/infra/ai/ 로 픽스처를 재생성할 것.
"""
import json
import pathlib

import pytest

from hydra_client.models import ResourceRequirements, TaskSpec, WorkerSnapshot
from hydra_client.sim import score_for_task

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "scheduler" / "cases.json"
CASES = json.loads(FIXTURE.read_text())


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_score_matches_go(case):
    t = case["task"]
    reqs = t.get("resourceReqs")
    spec = TaskSpec(
        priority=t.get("priority", "normal"),
        required_capabilities=t.get("requiredCapabilities") or [],
        preferred_device_id=t.get("preferredDeviceId", ""),
        blocked_device_ids=t.get("blockedDeviceIds") or [],
        resource_reqs=ResourceRequirements.from_json(reqs) if reqs else None,
    )
    worker = WorkerSnapshot.from_json(case["worker"])
    got = score_for_task(spec, worker)
    assert got == pytest.approx(case["expectedScore"], abs=1e-9), case["name"]
