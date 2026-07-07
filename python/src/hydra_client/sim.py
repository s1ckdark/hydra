"""Go RuleBasedScheduler(internal/infra/ai/scheduler.go)의 오프라인 재현.

규칙 기반 점수만 재현한다. 서버가 AI 중재(tiebreak/always-consult)를 쓰면
실제 배치는 다를 수 있고, 스냅샷 시점 차이로도 달라질 수 있다.
패리티는 tests/fixtures/scheduler/cases.json 으로 CI 에서 강제된다.
"""
from __future__ import annotations

from dataclasses import dataclass

from .models import TaskSpec, WorkerSnapshot

INELIGIBLE = -1.0

_PRIORITY_MULT = {"urgent": 2.0, "high": 1.3, "low": 0.7}


def _priority_multiplier(priority: str) -> float:
    return _PRIORITY_MULT.get(priority, 1.0)


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
    if r is not None:
        if r.gpu_memory_mb > 0 and r.gpu_memory_mb > w.gpu_memory_free_mb:
            return "insufficient GPU memory"
        if r.memory_mb > 0 and r.memory_mb / 1024.0 > w.memory_free_gb:
            return "insufficient RAM"
    return None


def score_for_task(task: TaskSpec, w: WorkerSnapshot) -> float:
    """Go ScoreForTask 포팅. 높을수록 좋음, INELIGIBLE(-1.0)은 부적격."""
    if task is None or _reject_reason(task, w) is not None:
        return INELIGIBLE
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
        queue_score = max(0.0, float(100 - w.running_jobs * 10))
        rows.append(ScoreBreakdown(
            worker_id=w.device_id, eligible=True, reject_reason=None,
            gpu_free_term=(100.0 - w.gpu_utilization) * 0.4,
            mem_term=w.memory_free_gb * 5.0 * 0.3,
            cpu_term=(100.0 - w.cpu_usage) * 0.2,
            queue_term=queue_score * 0.1,
            priority_mult=_priority_multiplier(task.priority),
            total=score_for_task(task, w)))
    rows.sort(key=lambda r: r.total, reverse=True)
    return rows
