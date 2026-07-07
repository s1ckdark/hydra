"""Go RuleBasedScheduler(internal/infra/ai/scheduler.go)의 오프라인 재현.

규칙 기반 점수만 재현한다. 서버가 AI 중재(tiebreak/always-consult)를 쓰면
실제 배치는 다를 수 있고, 스냅샷 시점 차이로도 달라질 수 있다.
패리티는 tests/fixtures/scheduler/cases.json 으로 CI 에서 강제된다.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .models import TaskSpec, WorkerSnapshot

INELIGIBLE = -1.0

_PRIORITY_MULT = {"urgent": 2.0, "high": 1.3, "low": 0.7}


def _priority_multiplier(priority: str) -> float:
    return _PRIORITY_MULT.get(priority, 1.0)


def pack_gpus(task: TaskSpec, w: WorkerSnapshot) -> list[int] | None:
    """task가 w에서 점유할 GPU 인덱스. None=부적격, []=GPU 제약 없음.

    Go PackGPUs(scheduler.go)와 동일: gpuMemoryMB는 장당 요구량,
    gpuCount 0은 1로 간주, best-fit(여유 작은 순, 동률 시 인덱스 순).
    GPU별 데이터 없는 워커는 단일 GPU 요구만 합산치로 폴백 검사.
    """
    r = task.resource_reqs
    if r is None or (r.gpu_memory_mb == 0 and r.gpu_count == 0):
        return []
    count = r.gpu_count or 1
    if not w.gpus:
        if count >= 2:
            return None
        if r.gpu_memory_mb > w.gpu_memory_free_mb:
            return None
        return []
    eligible = [g for g in w.gpus if g.memory_free_mb >= r.gpu_memory_mb]
    if len(eligible) < count:
        return None
    eligible.sort(key=lambda g: (g.memory_free_mb, g.index))
    return sorted(g.index for g in eligible[:count])


def _reject_reason(task: TaskSpec, w: WorkerSnapshot) -> str | None:
    """부적격 사유. 적격이면 None. 판정 순서는 Go ScoreForTask 와 동일."""
    if w.device_id in (task.blocked_device_ids or []):
        return "blocked (anti-affinity)"
    if task.preferred_device_id and task.preferred_device_id != w.device_id:
        return "pinned to another device"
    have = set(w.capabilities or [])
    for cap in task.required_capabilities or []:
        if cap not in have:
            return "missing capability"
    r = task.resource_reqs
    if pack_gpus(task, w) is None:
        return "insufficient GPU memory/count"
    if r is not None:
        if r.memory_mb > 0 and r.memory_mb / 1024.0 > w.memory_free_gb:
            return "insufficient RAM"
    return None


def score_for_task(task: TaskSpec, w: WorkerSnapshot) -> float:
    """Go ScoreForTask 포팅. 높을수록 좋음, INELIGIBLE(-1.0)은 부적격."""
    if task is None or _reject_reason(task, w) is not None:
        return INELIGIBLE
    selected = pack_gpus(task, w) or []
    if selected:
        by_index = {g.index: g for g in w.gpus}
        gpu_free = sum(100.0 - by_index[i].utilization for i in selected) / len(selected)
    else:
        gpu_free = 100.0 - w.gpu_utilization
    mem_score = w.memory_free_gb * 5.0
    cpu_free = 100.0 - w.cpu_usage
    queue_score = float(100 - w.running_jobs * 10)
    if queue_score < 0:
        queue_score = 0.0
    base = (gpu_free * 0.4 + mem_score * 0.3
            + cpu_free * 0.2 + queue_score * 0.1)
    return base * _priority_multiplier(task.priority)


def pick_best_worker(task: TaskSpec,
                     workers: list[WorkerSnapshot]) -> WorkerSnapshot | None:
    """Go PickBestWorker 포팅 — 적격 워커 중 최고점. 없으면 None."""
    best, best_score = None, INELIGIBLE
    for w in workers:
        s = score_for_task(task, w)
        if s <= INELIGIBLE:
            continue
        if best is None or s > best_score:
            best, best_score = w, s
    return best


@dataclass
class ScoreBreakdown:
    worker_id: str
    eligible: bool
    reject_reason: str | None
    gpu_free_term: float
    mem_term: float
    cpu_term: float
    queue_term: float
    priority_mult: float
    total: float
    selected_gpus: list[int] = field(default_factory=list)


def explain(task: TaskSpec,
            workers: list[WorkerSnapshot]) -> list[ScoreBreakdown]:
    """워커별 점수 분해 — 왜 선택/탈락했는지. total 내림차순 정렬."""
    rows: list[ScoreBreakdown] = []
    for w in workers:
        reason = _reject_reason(task, w)
        if reason is not None:
            rows.append(ScoreBreakdown(
                worker_id=w.device_id, eligible=False, reject_reason=reason,
                gpu_free_term=0.0, mem_term=0.0, cpu_term=0.0,
                queue_term=0.0, priority_mult=0.0, total=INELIGIBLE))
            continue
        selected = pack_gpus(task, w) or []
        if selected:
            by_index = {g.index: g for g in w.gpus}
            gpu_free_term = sum(100.0 - by_index[i].utilization for i in selected) / len(selected) * 0.4
        else:
            gpu_free_term = (100.0 - w.gpu_utilization) * 0.4
        queue_score = max(0.0, float(100 - w.running_jobs * 10))
        rows.append(ScoreBreakdown(
            worker_id=w.device_id, eligible=True, reject_reason=None,
            gpu_free_term=gpu_free_term,
            mem_term=w.memory_free_gb * 5.0 * 0.3,
            cpu_term=(100.0 - w.cpu_usage) * 0.2,
            queue_term=queue_score * 0.1,
            priority_mult=_priority_multiplier(task.priority),
            total=score_for_task(task, w),
            selected_gpus=selected))
    rows.sort(key=lambda r: r.total, reverse=True)
    return rows
