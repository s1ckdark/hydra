import pytest

from hydra_client.models import GPUFree, ResourceRequirements, TaskSpec, WorkerSnapshot
from hydra_client.sim import INELIGIBLE, explain, pack_gpus, pick_best_worker, score_for_task


def _worker(device_id, **kw):
    defaults = dict(capabilities=["gpu"], gpu_utilization=20.0,
                    memory_free_gb=32.0, cpu_usage=10.0, running_jobs=1,
                    gpu_memory_free_mb=40000)
    defaults.update(kw)
    return WorkerSnapshot(device_id=device_id, **defaults)


def test_pick_best_prefers_less_loaded():
    spec = TaskSpec()
    idle = _worker("idle", gpu_utilization=5.0, running_jobs=0)
    busy = _worker("busy", gpu_utilization=90.0, running_jobs=5)
    assert pick_best_worker(spec, [busy, idle]).device_id == "idle"


def test_pick_best_returns_none_when_all_ineligible():
    spec = TaskSpec(required_capabilities=["quantum"])
    assert pick_best_worker(spec, [_worker("a"), _worker("b")]) is None


def test_explain_reports_reject_reason_and_terms():
    spec = TaskSpec(required_capabilities=["gpu"], priority="high")
    ok = _worker("ok")
    no_cap = _worker("no-cap", capabilities=["compute"])
    rows = {r.worker_id: r for r in explain(spec, [ok, no_cap])}
    assert rows["ok"].eligible
    assert rows["ok"].priority_mult == 1.3
    assert rows["ok"].total == score_for_task(spec, ok)
    assert not rows["no-cap"].eligible
    assert rows["no-cap"].reject_reason == "missing capability"
    assert rows["no-cap"].total == INELIGIBLE


def test_explain_sorted_by_total_desc():
    spec = TaskSpec()
    rows = explain(spec, [_worker("busy", running_jobs=8), _worker("idle", running_jobs=0)])
    assert [r.worker_id for r in rows] == ["idle", "busy"]


def test_explain_terms_reconstruct_total():
    """Invariant: decomposed terms from explain() reconstruct score_for_task() total."""
    spec = TaskSpec(priority="high")
    rows = [r for r in explain(spec, [_worker("a", running_jobs=0), _worker("b", running_jobs=8)]) if r.eligible]
    assert rows, "expected eligible rows"
    for r in rows:
        reconstructed = (r.gpu_free_term + r.mem_term + r.cpu_term + r.queue_term) * r.priority_mult
        assert reconstructed == pytest.approx(r.total, abs=1e-9)


def test_pack_gpus_split_vram_rejected():
    spec = TaskSpec(resource_reqs=ResourceRequirements(gpu_memory_mb=20000))
    w = _worker("a", gpus=[GPUFree(0, 10000, 20.0), GPUFree(1, 10000, 30.0)])
    assert pack_gpus(spec, w) is None
    assert score_for_task(spec, w) == INELIGIBLE


def test_pack_gpus_best_fit_and_selected_util_scoring():
    spec = TaskSpec(resource_reqs=ResourceRequirements(gpu_memory_mb=16000, gpu_count=2))
    w = _worker("a", gpus=[GPUFree(0, 8000, 90.0), GPUFree(1, 24000, 30.0), GPUFree(2, 20000, 10.0)])
    assert pack_gpus(spec, w) == [1, 2]
    rows = [r for r in explain(spec, [w]) if r.eligible]
    assert rows[0].selected_gpus == [1, 2]


def test_pack_gpus_no_constraint_empty():
    assert pack_gpus(TaskSpec(), _worker("a")) == []


def test_pack_gpus_negative_count_clamped_to_one():
    spec = TaskSpec(resource_reqs=ResourceRequirements(gpu_memory_mb=16000, gpu_count=-1))
    w = _worker("a", gpus=[GPUFree(0, 24000, 10.0), GPUFree(1, 20000, 50.0)])
    assert pack_gpus(spec, w) == [1]
