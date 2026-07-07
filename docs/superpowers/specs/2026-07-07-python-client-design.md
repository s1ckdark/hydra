# hydra-client: 파이썬 클라이언트 라이브러리 + per-GPU 할당 계약 설계

- 날짜: 2026-07-07
- 상태: 설계 승인됨 (구현 전)
- 범위: 두 프로젝트를 동시 설계, 순차 구현
  - **1단계**: 파이썬 라이브러리 `hydra-client` (제출/조회/배치/시뮬레이션/워커)
  - **2단계**: Go 스케줄러 per-GPU 할당 (packing + `CUDA_VISIBLE_DEVICES` 핀닝)

## 1. 배경과 목표

hydra의 task 스케줄링은 Go 백엔드(`:8080`)의 `TaskSupervisor` + `ScoreForTask`
(가중치 점수: GPU 40% / 메모리 30% / CPU 20% / 큐 10%, 우선순위 배수)가 수행한다.
파이썬에서 이 흐름을 그대로 사용할 수 있는 라이브러리를 만든다.

동시에, 현재 스케줄러의 알려진 한계를 고친다: VRAM을 노드 합산으로만 체크해서
10GB×2 노드에 20GB 요구 task가 잘못 배치될 수 있고, 멀티 GPU task 개념과
GPU 핀닝이 없다. 또한 워커 쪽 실행-보고 루프가 미구현이다
(`task.assign` WS 메시지를 받아 실행하는 주체가 없음 — `wstub`은 로그만 찍음).

**목표**
1. 파이썬에서 `import hydra_client`로 task 제출→대기→결과 흐름 완결
2. 스케줄러 점수 로직의 파이썬 재현(sim)과 Go↔Python 패리티 CI 강제
3. 파이썬 워커 모듈로 실행-보고 루프 완성 (`python -m hydra_client.worker`)
4. per-GPU 계약(JSON 필드)을 지금 고정해 1단계 파이썬 API가 2단계에서 깨지지 않게 함

**주 사용 시나리오**: ML 학습/실험 잡 제출, 대량 배치/자동화, 스케줄러
검증/시뮬레이션, 클러스터 모니터링/조회 (모두 지원).

## 2. 결정 사항 요약

| 결정 | 선택 | 근거 |
|---|---|---|
| 라이브러리 성격 | 하이브리드: REST SDK + 로컬 sim | 스케줄링은 Go가 수행, sim은 오프라인 검증용 |
| API 스타일 | 동기 우선 + 배치 헬퍼 | 노트북 친화, 구현 단순. asyncio는 추후 |
| 워커 실행 주체 | 파이썬 워커 모듈 포함 | 실행-보고 루프 완성, ML 노드엔 파이썬 존재 |
| per-GPU 깊이 | gpu_count + 개별 packing + 핀닝 | 멀티 GPU 학습 표준 패턴. lease 테이블은 배제 |
| 구조 | 모노레포 `python/` + 골든 픽스처 | 계약이 한 레포에서 진화, 패리티를 CI로 강제 |
| 구현 순서 | 파이썬 먼저, per-GPU는 다음 | 각 단계가 작고 검증 가능 |

## 3. 패키지 구조

```
hydra/
└── python/
    ├── pyproject.toml            # 패키지명 hydra-client, Python 3.10+
    │                             # deps: requests / websockets(워커용)
    ├── src/hydra_client/
    │   ├── __init__.py           # 공개 API 재노출
    │   ├── client.py             # HydraClient (REST)
    │   ├── models.py             # dataclass 모델 (camelCase JSON 매핑)
    │   ├── worker.py             # python -m hydra_client.worker
    │   ├── sim.py                # 점수 로직 포팅 (순수 함수)
    │   └── errors.py             # 예외 계층
    └── tests/
        ├── fixtures/scheduler/   # Go가 덤프한 골든 JSON (커밋 대상)
        ├── test_client.py        # REST 모킹 유닛
        ├── test_sim_parity.py    # 골든 픽스처 패리티
        └── test_worker.py        # 가짜 WS 서버 통합
```

세 역할(제출/실행/시뮬레이션)은 한 패키지에 있지만 상호 의존이 없다:
`client.py`는 REST만, `worker.py`는 WS+subprocess만, `sim.py`는 순수 계산만.

## 4. 클라이언트 API (client.py)

```python
client = HydraClient(
    "http://head:8080",
    api_key=None,        # Tailscale 밖에서만 필요 (X-API-Key 헤더)
    timeout=10.0,        # HTTP 요청 타임아웃 (초)
)

task = client.submit_task(
    command="torchrun train.py",   # 편의 → type="command", payload={"command": ...}
    # 원형 지정도 가능: type=..., payload={...}
    priority="high",               # low / normal / high / urgent
    required_capabilities=["gpu"],
    gpu_memory_mb=16000,           # per-GPU 요구량 (계약 §6 참조)
    gpu_count=2,                   # 신규 계약 필드 (서버 미구현 시 무시됨)
    cpu_cores=4,
    memory_mb=8192,
    preferred_device_id=None,
    timeout=3600.0,                # task 실행 제한 (Task.Timeout)
    max_retries=3,
    ai_schedule=None,              # None=서버 기본 / True / False
)  # -> TaskHandle

task.wait(timeout=7200, poll_interval=2.0, raise_on_failure=True)
task.status / task.assigned_device_id / task.result.output

group = client.submit_batch([TaskSpec(...), ...])   # POST /api/tasks/batch
group.wait_all(timeout=...)                          # GET /api/groups/:id 폴링

client.get_task(id) -> Task                # GET /api/tasks/:id
client.list_tasks(status=None) -> list     # GET /api/tasks
client.cancel_task(id)                     # PUT /api/tasks/:id/status → cancelled
client.list_devices() / client.get_device(id)
client.gpu_metrics()                       # GET /api/monitor/gpu
client.cluster_snapshot()                  # GET /api/monitor/snapshot (sim 입력)
```

- 필드명 매핑: 파이썬 snake_case ↔ 서버 JSON camelCase는 `models.py`에서 일괄 처리.
- `submit_task`는 서버가 `ScheduleNow`로 즉시 스케줄을 시도하므로 반환 시점에
  이미 `assigned`일 수 있다.

## 5. 시뮬레이션 (sim.py)

Go `internal/infra/ai/scheduler.go`의 규칙 기반 점수를 1:1 포팅한다.

```python
score_for_task(spec, worker) -> float        # -1.0 = ineligible
pick_best_worker(spec, workers) -> WorkerSnapshot | None
explain(spec, workers) -> list[ScoreBreakdown]
# ScoreBreakdown: worker_id, eligible, reject_reason,
#   gpu_free_term, mem_term, cpu_term, queue_term, priority_mult, total
```

- **재현 범위**: 규칙 기반 점수만. AI tiebreak/always-consult 모드는 외부 AI
  호출이라 재현 불가 — 문서와 `explain()` 출력에 "AI 중재 시 실제 배치는 다를 수
  있음"을 명시한다.
- **패리티 장치**: Go에 `scheduler_fixture_test.go`를 추가해 대표 케이스의
  입력/기대점수를 `python/tests/fixtures/scheduler/*.json`으로 덤프.
  파이썬 `test_sim_parity.py`가 같은 파일을 재계산해 `1e-9` 이내 일치 검증.
  Go 로직이 바뀌면 픽스처 재생성 → 파이썬 테스트 실패 → sim 갱신 강제.
- 픽스처 케이스: 하드 필터 4종(anti-affinity, 핀닝, capability, 자원 부족),
  가중치 경계(RunningJobs≥10 큐 클램프 등), 우선순위 배수 4종, 빈 워커 목록,
  (2단계 후) per-GPU packing 케이스.

## 6. per-GPU 할당 계약 (지금 고정, 2단계 구현)

### JSON 계약

```jsonc
// ResourceRequirements
{
  "gpuMemoryMB": 16000,   // 의미 재정의: 노드 합산 → "GPU 한 장당" 요구량
  "gpuCount": 2           // 신규. 0 또는 생략 = 1 (하위호환)
}

// Task — 서버가 할당 시 기록, task.assign WS payload에도 포함
{ "assignedGpuIndexes": [0, 3] }   // 워커가 CUDA_VISIBLE_DEVICES=0,3 으로 변환

// WorkerSnapshot — 스케줄러 입력에 GPU별 상태 추가
{ "gpus": [
    {"index": 0, "memoryFreeMB": 22000, "utilization": 15.0},
    {"index": 1, "memoryFreeMB": 4000,  "utilization": 90.0}
] }
```

### 스케줄러 로직 (Go)

- **적격성**: 여유 VRAM ≥ `gpuMemoryMB`인 GPU가 `gpuCount`장 이상 → 통과.
  기존 "노드 합산 VRAM 체크"를 대체 (오배치 버그 수정).
- **packing**: 적격 GPU 중 여유 VRAM 작은 순으로 `gpuCount`장 선택 (best-fit —
  큰 여유 GPU를 이후의 큰 task용으로 보존).
- **소프트 점수**: 산식(40/30/20/10 + 우선순위 배수)은 유지, `gpuFree` 항만
  노드 평균 → 선택된 GPU들의 평균 여유율로 교체.
- **tick 내 경합**: 기존 `bumpRunningJobs`처럼 스냅샷의 선택 GPU VRAM을 차감
  (`bumpGPUReservation`). tick 간에는 nvidia-smi 실측 반영.
- **수용한 트레이드오프**: lease 테이블 없음 — 실행 직후 VRAM이 실측에 아직
  안 잡힌 짧은 창에서 과할당 가능. 정확성보다 상태 관리 단순성을 택함.

### 하위호환

| 클라이언트 | 서버 | 동작 |
|---|---|---|
| `gpuCount` 전송 | 구버전 | 필드 무시 → 기존 노드 단위 배치 |
| `gpuCount` 없음 | 신버전 | 1로 간주, 단일 GPU fit 체크 |
| `assignedGpuIndexes` 없음 | — | 워커가 CUDA_VISIBLE_DEVICES 미설정 (전 GPU 노출) |

주의: `gpuMemoryMB`의 "장당" 의미는 2단계 서버부터 유효하다. 1단계 기간에는
서버가 여전히 노드 합산으로 체크하므로, 파이썬 문서에 "현행 서버는 노드 합산
기준" 임을 명시한다 (docstring + README).

## 7. 워커 (worker.py)

```bash
python -m hydra_client.worker \
    --server http://head:8080 \
    --device-id yeolmae-local-gpu1 \   # 생략 시 hostname
    --capabilities gpu,cuda \
    --max-concurrent 1
```

루프: `/ws` 접속(지수 백오프 재접속) → `POST /api/devices/:id/capabilities` 등록
(재접속마다 재등록) → `task.assign` 수신 → `payload["command"]` subprocess 실행
(`assignedGpuIndexes` 수신 시 `CUDA_VISIBLE_DEVICES` 설정) → stdout/stderr/exit
code를 `PUT /api/tasks/:id/result`로 보고.

- 결과 보고를 WS가 아닌 REST로 하는 이유: 서버의 `task.result` WS 수신 처리가
  미구현이므로, 이미 존재·테스트된 REST 엔드포인트가 Go 변경 없이 완결되는 경로.
- task `Timeout` 초과: 프로세스 그룹에 SIGTERM → 5초 → SIGKILL, 실패 보고.
- `task.cancel` WS 메시지 수신: 위와 동일한 kill 시퀀스.
- 실행 중 서버 재시작: subprocess는 유지, 보고 실패 시 백오프 재시도.
  보고 시 404/중복이면 경고 로그 후 폐기 (서버가 재할당했을 수 있음).

## 8. 예외 계층 (errors.py)

```
HydraError
├── HydraConnectionError      # 연결 실패/타임아웃 (wait 중에는 백오프 재시도 후)
├── HydraAuthError            # 401
├── HydraNotFoundError        # 404
├── HydraServerError          # 5xx
└── TaskFailedError           # wait() 중 failed 종결 (raise_on_failure=False로 억제)
```

`wait()` 폴링 중 일시적 연결 오류는 즉시 raise하지 않고 지수 백오프 재시도,
`wait(timeout=)` 초과 시 `HydraConnectionError`.

## 9. 테스트 전략

1. **유닛**: `responses`로 REST 모킹 — 직렬화, 예외 매핑, wait 폴링/타임아웃.
2. **sim 패리티**: 골든 픽스처 재계산, `1e-9` 이내 일치 (핵심 게이트).
3. **워커 통합**: 테스트 내 가짜 WS 서버 — assign→실행→보고 왕복, timeout kill,
   재접속, `CUDA_VISIBLE_DEVICES` 주입 검증.
4. **e2e (선택)**: `pytest -m e2e`, 실제 로컬 hydra-server 대상. CI 기본 제외.

## 10. 구현 순서

1. **1단계 — 파이썬 라이브러리** (이 스펙의 §3~5, §7~9)
   - models/errors → client → sim(+Go 픽스처 덤프 테스트) → worker → 테스트
   - 이 단계에서 Go 변경은 픽스처 덤프 테스트 추가뿐 (동작 변경 없음)
2. **2단계 — per-GPU 할당** (별도 계획으로 진행, §6 계약 준수)
   - Go: WorkerSnapshot GPU별 상태 → 적격성/packing → assignedGpuIndexes 전파
   - Python: sim per-GPU 갱신 + 새 픽스처, 같은 커밋으로

## 11. 비범위 (이번에 안 함)

- asyncio 클라이언트 (필요 시 후속)
- GPU lease/예약 테이블
- AI tiebreak의 로컬 재현
- 로그 스트리밍 (결과는 완료 후 일괄 보고)
- PyPI 배포 파이프라인 (로컬 `pip install -e python/` 우선)
