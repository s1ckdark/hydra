# hydra-client

hydra GPU 클러스터를 위한 파이썬 클라이언트 라이브러리 — task 제출/대기/배치,
스케줄러 점수 오프라인 시뮬레이션(sim), 그리고 워커 실행 루프까지 포함한다.

설계 스펙: [docs/superpowers/specs/2026-07-07-python-client-design.md](../docs/superpowers/specs/2026-07-07-python-client-design.md)

세 역할(제출/실행/시뮬레이션)은 한 패키지에 있지만 상호 의존이 없다:
`client.py`는 REST만, `worker.py`는 WS+subprocess만, `sim.py`는 순수 계산만 다룬다.
실제 스케줄링(점수 계산, 큐잉, AI 중재)은 전부 Go 백엔드(`:8080`)가 수행하며,
이 라이브러리는 계약대로 제출·조회하거나 그 로직을 오프라인으로 재현할 뿐이다.

## 설치

`python/` 디렉터리에서:

```bash
pip install -e '.[dev]'
```

Python 3.10+ 가 필요하다. 런타임 의존성은 `requests`(REST)와 `websockets`(워커),
개발 의존성은 `pytest`/`responses`다.

## 빠른 시작 — 제출 & 대기

```python
from hydra_client import HydraClient

client = HydraClient(
    "http://head:8080",
    api_key=None,   # Tailscale 밖에서만 필요 (X-API-Key 헤더)
    timeout=10.0,   # HTTP 요청 타임아웃 — 초 단위
)

task = client.submit_task(
    command="torchrun train.py",
    priority="high",                # low / normal / high / urgent
    required_capabilities=["gpu"],
    gpu_memory_mb=16000,            # per-GPU 요구량 (아래 "gpu_count 주의" 참조)
    gpu_count=2,
    cpu_cores=4,
    memory_mb=8192,
    timeout=3600.0,                 # task 실행 제한 — 초 단위
    max_retries=3,
    ai_schedule=None,               # None=서버 기본 / True / False
)

task.wait(timeout=7200, poll_interval=2.0, raise_on_failure=True)
print(task.status, task.assigned_device_id, task.result.output)
```

`submit_task`는 서버가 `ScheduleNow`로 즉시 스케줄을 시도하므로, 반환 시점에
이미 `assigned` 상태일 수 있다.

`wait()`는 terminal 상태(`completed`/`failed`/`cancelled`)까지 폴링한다. 일시적
연결 오류는 즉시 실패시키지 않고 지수 백오프(최대 30초)로 재시도하며, `timeout`
초과 시 마지막 시도가 연결 오류였으면 `HydraConnectionError`, 아니면 `TimeoutError`를
발생시킨다. `raise_on_failure=True`(기본값)면 task가 `failed`로 종결될 때
`TaskFailedError`를 던진다 — `.task`로 최종 `Task`에 접근할 수 있다.

## 배치 제출

```python
from hydra_client import TaskSpec

specs = [TaskSpec.command(f"python run.py --seed {i}") for i in range(8)]
group = client.submit_batch(specs, name="sweep-001")

snapshot = group.wait_all(timeout=3600)
print(snapshot["status"])   # completed / failed / partial
for handle in group.tasks:
    print(handle.id, handle.status)  # wait_all()이 detail=full로 재동기화한 최종 상태
```

그룹의 terminal 상태는 Go `domain.DeriveGroupStatus` 기준으로 `completed`(전부
성공) / `failed`(전부 실패) / `partial`(혼합)이며, `running`만 비종결이다.
`wait_all()`도 `wait()`과 동일하게 일시적 연결 오류를 지수 백오프(최대 30초)로
재시도하며, `timeout` 초과 시 마지막 시도가 연결 오류였으면
`HydraConnectionError`, 아니면 `TimeoutError`를 발생시킨다.

## 조회 & 모니터링

```python
client.get_task(task_id)                 # GET /api/tasks/:id
client.list_tasks(status="running")      # GET /api/tasks
client.cancel_task(task_id)              # PUT /api/tasks/:id/status → cancelled
client.list_devices() / client.get_device(device_id)
client.gpu_metrics()                     # GET /api/monitor/gpu
client.cluster_snapshot()                # 디바이스/메트릭/실행중 task를 집계해 sim 입력 생성
```

## 스케줄러 시뮬레이션 (sim)

`sim` 모듈은 Go `internal/infra/ai/scheduler.go`의 규칙 기반 점수 로직(GPU 40% /
메모리 30% / CPU 20% / 큐 10%, 우선순위 배수)을 1:1 포팅한 것으로, 실제 서버에
제출하지 않고 배치 결과를 미리 살펴보거나 디버깅할 때 쓴다.

```python
from hydra_client import TaskSpec, sim

spec = TaskSpec.command("train.py", required_capabilities=["gpu"], priority="high")
workers = client.cluster_snapshot()   # WorkerSnapshot 목록

best = sim.pick_best_worker(spec, workers)
if best is None:
    print("적합한 워커 없음")
else:
    score = sim.score_for_task(spec, best)
    print(best.device_id, score)

for row in sim.explain(spec, workers):
    print(row.worker_id, row.eligible, row.reject_reason, row.total)

sim.pack_gpus(spec, workers[0])   # -> [1, 2] (선택 인덱스) / None (부적격) / [] (GPU 제약 없음)
```

`explain()`은 워커별 점수 분해(`gpu_free_term`/`mem_term`/`cpu_term`/`queue_term`
/`priority_mult`/`total`)를 `total` 내림차순으로 반환해 왜 특정 워커가
선택되거나 탈락했는지 보여준다. `pack_gpus(spec, worker)`는 per-GPU packing
로직을 재현해 할당 가능한 GPU 인덱스 목록을 반환한다.

### sim 한계

`sim`은 **규칙 기반 점수만** 재현한다. 서버가 AI tiebreak/always-consult 모드로
동작할 경우 실제 배치는 AI 중재 결과에 따라 sim의 결과와 달라질 수 있으며,
`cluster_snapshot()`을 호출한 시점과 실제 스케줄링 시점 사이의 상태 차이로도
결과가 달라질 수 있다. `sim`은 오프라인 검증/디버깅 도구이지, 실제 배치를
보장하는 예측기가 아니다.

### gpu_count / gpu_memory_mb 주의

`ResourceRequirements.gpu_count`와 `gpu_memory_mb`는 per-GPU 할당(GPU 한 장당
요구량 + 개수)을 위한 필드다. 서버가 per-GPU packing을 지원하므로,
`gpu_count=2, gpu_memory_mb=16000`으로 제출하면 "각 GPU당 여유 VRAM ≥ 16000MB인
2개 GPU 확보"를 의미한다. 배치 시 서버가 `Task.assignedGpuIndexes`로 할당된 GPU
인덱스를 전달하면, 워커가 환경변수 `CUDA_VISIBLE_DEVICES`를 그에 맞게 설정한다.
구버전 서버에 대한 하위호환:

| 클라이언트 | 서버 | 동작 |
|---|---|---|
| `gpu_count` 전송 | 구버전(이전) | 필드 무시 → 기존 노드 단위 배치 |
| `gpu_count` 없음 | 신버전 | 1로 간주, 단일 GPU fit 체크 |
| `assignedGpuIndexes` 없음 | — | 워커가 `CUDA_VISIBLE_DEVICES` 미설정 (전 GPU 노출) |

## 워커 실행

파이썬 워커는 `task.assign` WS 메시지를 받아 subprocess로 실행하고 결과를
REST로 보고하는 실행 루프다 (서버에 `task.result` WS 수신 처리가 없어, 기존
REST 엔드포인트를 그대로 사용한다).

```bash
# --device-id 생략 시 hostname 사용
python -m hydra_client.worker \
    --server http://head:8080 \
    --device-id yeolmae-local-gpu1 \
    --capabilities gpu,cuda \
    --max-concurrent 1
```

`--server`는 스킴을 포함해야 한다(`http://` 또는 `https://`) — 없으면
`ValueError`를 즉시 던진다.

루프: `/ws` 접속(지수 백오프 재접속) → `POST /api/devices/:id/capabilities` 등록
(재접속마다 재등록) → `task.assign` 수신 → `payload["command"]`를 subprocess로
실행(`assignedGpuIndexes` 수신 시 `CUDA_VISIBLE_DEVICES` 설정) → stdout/stderr/exit
code를 `PUT /api/tasks/:id/result`로 보고. task `timeout` 초과나 `task.cancel`
수신 시 프로세스 그룹에 SIGTERM → 5초 유예 → SIGKILL 순으로 종료한다.

### 취소

REST `cancel_task()`/`update_task_status(..., "cancelled")`는 서버 쪽 task
상태를 `cancelled`로 바꾸는 동시에, 해당 task 를 실행 중인 워커에게
`task.cancel` WS 메시지를 보낸다 — 워커는 이를 받아 실행 중인 프로세스
그룹에 SIGTERM(유예 후 SIGKILL)을 보내 실제로 중단시킨다. 또한 서버는
이미 `cancelled`/`failed`로 종결된 task 에 대한 뒤늦은 결과 보고를
거부하므로, 취소 이후 워커가 뒤늦게 보고하는 결과가 `cancelled` 상태를
`completed`/`failed`로 덮어쓰는 일은 없다.

### 워커 신뢰 모델

파이썬 워커는 오퍼레이터가 제출한 명령을 셸로 그대로 실행한다 — task
제출 권한이 있는 누구나 워커 프로세스 권한으로 임의 명령을 실행할 수
있다는 뜻이다. `/ws` 접속은 이제 Tailscale 네트워크 또는 API 키 인증을
요구하지만, 인증된 접속 주체를 접속 시 넘기는 `device_id` 쿼리 파라미터에
바인딩하지는 않는다 — 인증된 누구나 임의의 `device_id`를 자칭해 접속할 수
있다는 점은 알려진 갭으로 남아 있다.

## 단위 주의

숫자 단위가 요청/응답 방향에 따라 다르므로 주의한다:

- **요청 시 `timeout`** (`TaskSpec.timeout`, `submit_task(timeout=...)`): **초** 단위
  (`float`). 서버로 보낼 때 정수 초로 변환되며, 초 미만 소수(예: `0.5`)는
  올림된다(`1`) — 내림하면 `0`이 되어 "타임아웃 없음"으로 오해석될 수 있기
  때문이다. `0`은 그대로 "타임아웃 없음"을 의미한다.
- **응답의 `Task.timeout_ns`, `TaskResult.duration_ns`**: 필드명(JSON의
  `timeout`, `durationMs`)과 달리 실제 값은 **나노초**다. 특히 `durationMs`라는
  JSON 필드명에도 불구하고 값은 ms가 아니라 ns이므로, 초 단위로 쓰려면
  `/ 1e9`가 필요하다.

## 예외 계층

```
HydraError
├── HydraConnectionError      # 연결 실패/타임아웃 (wait 중에는 백오프 재시도 후)
├── HydraAuthError            # 401
├── HydraNotFoundError        # 404
├── HydraServerError          # 5xx (status_code 속성 포함)
└── TaskFailedError           # wait() 중 failed 종결 (raise_on_failure=False로 억제 가능, .task로 최종 Task 접근)
```

## 테스트

```bash
cd python
.venv/bin/python -m pytest tests/ -v
```

`tests/test_sim_parity.py`는 Go가 덤프한 골든 픽스처(`tests/fixtures/scheduler/`)와
`sim.py` 재계산 결과를 `1e-9` 이내로 비교해 Go↔Python 점수 로직 패리티를 강제한다.

e2e 스모크(선택, 수동 — CI 기본 제외):

```bash
# 한 셸에서
make build && ./bin/hydra-server

# 다른 셸에서
python -m hydra_client.worker --server http://localhost:8080 --capabilities compute
```

```python
from hydra_client import HydraClient
HydraClient("http://localhost:8080").submit_task("echo e2e").wait()
```
