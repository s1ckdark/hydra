# Naga - Tailscale 기반 GPU 클러스터 관리 도구

Tailscale 네트워크 내의 GPU 노드를 자동으로 감지하고 관리하며, Ray 클러스터를 구성하여 분산 작업을 실행하는 종합 관리 솔루션입니다.

## 주요 특징

- **자동 GPU 감지**: Linux 노드에서 SSH를 통해 nvidia-smi 실행으로 GPU 자동 감지
- **Tailscale 네트워크 통합**: 별도 API 키 없이 Tailscale 인증만으로 접근 제어
- **분산 작업 실행**: 클러스터의 모든 GPU 워커에서 병렬로 명령 실행
- **웹 대시보드**: HTMX + Tailwind CSS로 구성된 실시간 Device/Cluster 관리 UI
- **macOS 앱**: SwiftUI 메뉴바 + 메인 윈도우로 언제든 클러스터 상태 확인
- **MCP 서버**: Claude Code 및 다른 AI 어시스턴트 통합 (TypeScript)
- **다중 역할 에이전트**: Head/Worker 노드 구분으로 분산 시스템 지원
- **클러스터 HA**: AI 기반 자동 헤드 노드 페일오버

## 현재 구성

- **GPU**: 4x RTX 5090, 2x NVIDIA A40 (총 6개 GPU 노드)
- **오케스트레이션**: Ray 클러스터 기반 분산 작업 실행
- **인증**: Tailscale CGNAT (100.64.0.0/10) 네트워크 기반

## 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                     Tailscale Network                           │
│  (자동 인증, VPN 터널, CGNAT: 100.64.0.0/10)                    │
└─────────────────────────────────────────────────────────────────┘
        │                      │                      │
        ▼                      ▼                      ▼
  ┌──────────────┐       ┌──────────────┐    ┌──────────────┐
  │ GPU Node 1   │       │ GPU Node 2   │    │ GPU Node N   │
  │ (RTX 5090)   │       │ (A40)        │    │ (Worker)     │
  │ cluster-     │       │ cluster-     │    │ cluster-     │
  │ agent        │       │ agent        │    │ agent        │
  └──────────────┘       └──────────────┘    └──────────────┘
        │                      │                      │
        └──────────────────────┼──────────────────────┘
                               │ SSH Executor
                               │ (nvidia-smi, Ray CLI)
                      ┌────────▼────────┐
                      │  Web Server     │
                      │  (Echo + SQLite)│
                      │  Port 8080      │
                      └────────┬────────┘
                               │
          ┌────────────────────┼────────────────────┐
          ▼                    ▼                    ▼
      ┌─────────┐       ┌─────────┐         ┌─────────┐
      │Dashboard│       │  API    │         │MCP Tools│
      │(Web UI) │       │(JSON)   │         │(Claude) │
      └─────────┘       └─────────┘         └─────────┘
          │                    │                    │
          └────────────────────┼────────────────────┘
                               │
                      ┌────────▼────────┐
                      │  macOS SwiftUI   │
                      │  App + Menu Bar  │
                      └─────────────────┘
```

## 프로젝트 구조

```
clusterManager/
├── cmd/                          # 실행 가능한 바이너리
│   ├── server/                   # Web/API 서버 (Echo)
│   │   └── main.go              # 엔드포인트 및 인증 설정
│   ├── naga-agent/            # GPU 노드 에이전트
│   │   └── main.go              # Heartbeat, 페일오버, 헬스체크
│   └── naga/               # CLI 도구
│       └── main.go              # Command-line interface
│
├── internal/                      # 애플리케이션 코어
│   ├── domain/                   # 비즈니스 로직 (Entity)
│   │   ├── cluster.go           # Ray 클러스터 구조
│   │   ├── device.go            # GPU 노드 정보
│   │   ├── gpu.go               # GPU 상태/메트릭
│   │   ├── heartbeat.go         # HA 헬스체크
│   │   └── metrics.go           # 성능 메트릭
│   │
│   ├── usecase/                 # 비즈니스 로직 (Use Cases)
│   │   ├── cluster_usecase.go   # 클러스터 관리
│   │   ├── device_usecase.go    # Device 자동 감지
│   │   ├── monitor_usecase.go   # 실시간 모니터링
│   │   └── failover_usecase.go  # HA 페일오버 로직
│   │
│   ├── repository/               # 데이터 접근 계층
│   │   └── sqlite/              # SQLite 구현
│   │       ├── cluster.go
│   │       ├── device.go
│   │       ├── metrics.go
│   │       └── sqlite.go        # DB 연결
│   │
│   ├── infra/                   # 외부 시스템 통합
│   │   ├── ssh/                 # SSH 실행 및 수집
│   │   │   ├── executor.go      # SSH 명령 실행
│   │   │   ├── gpu_collector.go # nvidia-smi 수집
│   │   │   └── collector.go     # 노드 정보 수집
│   │   ├── tailscale/           # Tailscale API
│   │   │   └── client.go        # Device 목록, 상태
│   │   ├── ray/                 # Ray 오케스트레이션
│   │   │   └── manager.go       # Ray 클러스터 시작/중지
│   │   └── ai/                  # AI 모델 통합
│   │       └── selector.go      # Claude API (페일오버)
│   │
│   ├── web/                     # HTTP 웹 레이어
│   │   ├── handler/             # HTTP 핸들러
│   │   │   └── handler.go       # 모든 엔드포인트
│   │   └── static/              # HTML, CSS, JS
│   │       ├── index.html
│   │       ├── devices.html
│   │       ├── clusters.html
│   │       └── styles.css
│   │
│   ├── agent/                   # 노드 에이전트 (분산)
│   │   ├── agent.go             # 메인 에이전트 루프
│   │   ├── heartbeat.go         # 하트비트 신호
│   │   ├── election.go          # HA 선출 로직
│   │   └── systemd.go           # systemd 통합
│   │
│   └── tui/                     # Terminal UI (선택사항)
│       └── monitor/             # 실시간 터미널 대시보드
│
├── mcp-server/                   # Claude Code MCP 서버 (TypeScript)
│   ├── src/
│   │   ├── index.ts             # MCP 서버 메인
│   │   ├── client.ts            # HTTP 클라이언트
│   │   └── tools/
│   │       ├── devices.ts       # Device 관련 도구
│   │       └── clusters.ts      # Cluster 관련 도구
│   ├── package.json
│   └── node_modules/
│
├── Naga/                         # macOS/iOS SwiftUI 앱
│   └── Naga/
│       ├── NagaApp.swift                # App 진입점
│       ├── Models/
│       │   ├── Device.swift
│       │   ├── Cluster.swift
│       │   └── TaskResult.swift
│       ├── Services/
│       │   └── APIClient.swift  # HTTP 클라이언트
│       ├── ViewModels/
│       │   ├── DashboardViewModel.swift
│       │   └── ClusterViewModel.swift
│       └── Views/
│           ├── ContentView.swift        # 메인 윈도우
│           ├── MenuBar/
│           │   └── MenuBarView.swift    # 메뉴바 UI
│           ├── Dashboard/
│           │   └── DashboardView.swift
│           ├── Devices/
│           │   └── DeviceListView.swift
│           └── Clusters/
│               └── ClusterListView.swift
│
├── config/                       # 설정 관리
│   ├── config.go                # Config 구조
│   └── config_test.go
│
├── scripts/
│   └── serve.sh                 # Tailscale Serve 래퍼
│
├── go.mod / go.sum              # Go 의존성
├── Makefile                     # Build targets
└── README.md                    # 이 파일
```

## 빠른 시작

### 전제 조건

- Go 1.25.6 이상
- SQLite3
- SSH 접근 가능한 Linux 노드 (GPU 감지용)
- Tailscale 클라이언트 (네트워크 접근)
- (선택) macOS 14+ (SwiftUI 앱 빌드용)
- (선택) Node.js 18+ (MCP 서버 실행용)

### 설치

1. **저장소 클론**
   ```bash
   git clone https://github.com/dave/clusterManager.git
   cd clusterManager
   ```

2. **Go 의존성 설치**
   ```bash
   make deps
   ```

3. **바이너리 빌드**
   ```bash
   make build          # CLI + 서버 모두
   # 또는 개별 빌드
   make build-cli      # naga CLI
   make build-server   # Web 서버
   ```

4. **데이터베이스 초기화** (선택)
   ```bash
   make db-init
   ```

### 웹 서버 실행

#### 방법 1: 로컬 테스트
```bash
make run-server
# 액세스: http://localhost:8080
```

#### 방법 2: Tailscale Serve (Tailnet 공유)
```bash
make serve
# 자동으로 Tailscale HTTPS URL 노출
# Tailnet 사용자만 접근 가능 (별도 인증 불필요)
```

### MCP 서버 설정 (Claude Code 통합)

1. **빌드**
   ```bash
   cd mcp-server
   npm install
   npm run build
   ```

2. **실행**
   ```bash
   npm start
   ```

3. **Claude 설정** - `~/.claude/mcp.json` 추가:
   ```json
   {
     "mcpServers": {
       "gpu-cluster": {
         "command": "node",
         "args": ["/path/to/mcp-server/dist/index.js"],
         "env": {
           "CLUSTER_API_URL": "http://localhost:8080"
         }
       }
     }
   }
   ```

### macOS 앱 빌드

```bash
cd Naga
open Package.swift
# Xcode에서 빌드 및 실행
# 또는 CLI:
xcodebuild -scheme Naga -configuration Release
```

## 기능 목록

### 오케스트레이션별 AI 에이전트 모델

macOS 앱의 **Orchs → 오케스트레이션 선택 → AI Agents → Configure Agents**에서 설정합니다.
Android에서는 **Orchs → 오케스트레이션 선택 → AI 에이전트 → 설정**으로 들어갑니다.

1. 공급자 연결을 추가하고 계정에서 사용할 수 있는 정확한 모델 ID를 등록합니다. 한 연결에 여러 모델을 등록할 수 있습니다.
2. 헤드 모델을 선택합니다. 전역 설정을 사용하면 기존 채팅 AI 설정이 헤드 역할을 맡습니다.
3. 에이전트마다 이름과 역할을 적습니다. 기본값인 **Let head decide**에서는 헤드가 작업과 역할을 보고 등록된 모델 중 하나를 선택합니다.
4. 특정 모델을 고정하려면 에이전트의 모델 설정에서 연결과 모델 ID를 지정합니다. 이 설정은 헤드의 선택보다 우선합니다.
5. **Open Agent Chat**으로 대화를 시작합니다. 응답에 사용한 모델이 표시되며, 제안된 작업은 **Run**을 눌러야 실행됩니다.

설정은 Hydra 서버의 설정 디렉터리에 있는 `agent-teams.json`에 저장됩니다. 파일 권한은 `0600`이며, 조회 API는 API 키 대신 저장 여부만 반환합니다. 저장된 키를 유지하려면 키 입력란을 비워 두세요. 공급자나 엔드포인트를 변경할 때는 키를 다시 입력해야 합니다.

앱과 연결된 Hydra 서버 모두 이 기능을 지원하는 버전이어야 합니다. 원격 서버에 연결한 경우 앱 업데이트와 서버 업데이트를 각각 적용해야 합니다.

관련 API:

- `GET /api/orchs/:id/ai-agents`: 연결·모델·에이전트 설정 조회
- `PUT /api/orchs/:id/ai-agents`: 전체 설정 저장
- `POST /api/agent/chat`: `orchestration_id`와 `agent_id`를 함께 전달하면 해당 에이전트 사용
- `POST /api/agent/execute`: 응답의 `model_selection`을 함께 전달해 같은 모델로 실행 결과 요약

설정을 변경한 뒤에는 기존 실행 대기 계획을 다시 생성해야 합니다. 서버는 계획 생성 시의 설정 버전과 현재 버전을 비교한 뒤 실행합니다.

### Agent Tree로 실행 흐름 확인

에이전트 채팅을 시작하면 **Orchs 상세의 Agent Tree**에서 현재 작업 흐름을 확인할 수 있습니다. 채팅의 **Expand Agent Tree**에서도 같은 트리를 펼칠 수 있습니다.

- 헤드의 모델 선택, 에이전트의 계획 작성, 실행 승인, 개별 작업, 결과 요약을 실제 진행 상태에 따라 표시합니다.
- 실선 화살표는 처리 순서, 점선 화살표는 위임 관계를 나타냅니다. 노드에는 단계 번호, 모델, 실행 중·대기·완료·실패·건너뜀 상태가 표시됩니다.
- 노드를 선택하면 상태와 완료된 단계의 소요 시간을 확인할 수 있습니다. 큰 트리는 가로·세로로 스크롤하며, **Current step**으로 현재 실행 단계에 바로 이동할 수 있습니다.
- 승인 대기 중인 작업은 **Run** 전까지 실행되지 않습니다. 모델을 고정한 에이전트는 헤드의 모델 선택 단계를 건너뜁니다.
- 연결이 끊기면 마지막 상태를 알 수 없다고 표시합니다. 실행 결과가 불확실한 계획을 자동으로 다시 보내지 않습니다.

진행 정보는 현재 앱 세션에 표시되며, 새 요청을 시작하면 새 트리가 만들어집니다. 진행 스트림을 지원하지 않는 서버의 일반 JSON 응답도 처리하지만, 그 경우 실시간 트리는 표시되지 않습니다.

API 클라이언트는 기존 채팅·실행 POST에 `?stream=1`을 붙여 진행 이벤트와 최종 결과를 받을 수 있습니다. 실행 요청의 `run_id`는 계획 작성 때 받은 값을 그대로 전달합니다. 스트리밍 계획은 최대 100개 작업을 지원합니다.

### Android 앱

Android에서도 공급자별 모델 등록, 헤드 자동 선택·에이전트별 모델 고정, 에이전트 채팅과 실시간 Agent Tree를 사용할 수 있습니다. 트리는 휴대폰에서 위에서 아래로 진행하며, **현재 단계**로 실행 중인 작업에 이동할 수 있습니다. 탭을 바꿔도 같은 채팅 세션과 승인 대기 계획이 유지됩니다.

새 설치의 기본 서버는 `http://100.125.85.81:8081`입니다. Tailscale 연결이 필요하며, 이미 저장한 서버 주소는 유지됩니다. 설정에서 서버를 바꾸면 이전 서버의 대기 계획과 입력 중인 키를 지우고 진행 요청을 취소합니다.

```bash
make android-build
make android-test
```

APK는 `android/app/build/outputs/apk/debug/app-debug.apk`에 생성됩니다. 에뮬레이터·기기 UI 검증은 `make android-instrumented-test`로 실행합니다. 에이전트 관련 UI 테스트는 모의 저장소를 사용하므로 실제 서버 설정을 바꾸거나 유료 모델을 호출하지 않습니다.

### 웹 대시보드 (HTMX + Tailwind)

| 기능 | 설명 |
|------|------|
| **Dashboard** | 실시간 클러스터 상태, GPU 사용률, 오류 알림 |
| **Device List** | 모든 Tailscale 노드, OS, SSH 상태, GPU 모델/개수 |
| **Device Detail** | 상세 정보, GPU 메트릭, 마지막 SSH 실행 결과 |
| **Cluster List** | 모든 Ray 클러스터, 상태, Head/Worker 구성 |
| **Cluster Detail** | 클러스터 구성, Ray Dashboard URL, 헬스 체크 |
| **Execute Task** | 선택된 Device 또는 Cluster의 모든 Worker에서 명령 병렬 실행 |

### REST API (JSON)

**읽기 전용 (인증 불필요):**
- `GET /api/devices` - 모든 Device 목록
- `GET /api/devices/:id` - Device 상세
- `GET /api/devices/:id/metrics` - GPU 메트릭
- `GET /api/clusters` - 모든 Cluster 목록
- `GET /api/clusters/:id` - Cluster 상세
- `GET /api/clusters/:id/health` - 헬스 체크

**쓰기 (Tailscale 네트워크 인증):**
- `POST /api/clusters` - Cluster 생성
- `DELETE /api/clusters/:id` - Cluster 삭제
- `POST /api/clusters/:id/workers` - Worker 추가
- `DELETE /api/clusters/:id/workers/:deviceId` - Worker 제거
- `PUT /api/clusters/:id/head` - Head 노드 변경
- `POST /api/clusters/:id/failover` - 수동 페일오버
- `POST /api/clusters/:id/execute` - 모든 Worker에서 명령 실행
- `POST /api/devices/:id/execute` - 특정 Device에서 명령 실행

### CLI 도구 (naga)

```bash
# Device 관리
./naga device list              # 모든 Device 출력
./naga device detail <id>       # Device 상세
./naga device gpu-status        # GPU 메트릭 조회

# Cluster 관리
./naga cluster list             # 모든 Cluster 출력
./naga cluster create <name> <head-id> [workers...]
./naga cluster delete <id>
./naga cluster health <id>

# Task 실행
./naga execute device <id> <command>
./naga execute cluster <id> <command>

# 모니터링
./naga monitor                  # 실시간 TUI 대시보드
```

## MCP 도구 목록

### Device 도구

| 도구 | 파라미터 | 설명 |
|------|---------|------|
| `list_devices` | `refresh?`, `gpu_only?` | Tailscale 내 모든 Device 나열 |
| `get_device` | `id` (Device ID/이름) | 특정 Device 상세 조회 |
| `get_gpu_status` | `device_id?` | nvidia-smi 실시간 GPU 상태 조회 |
| `execute_on_device` | `device_id`, `command`, `timeout_seconds?` | SSH로 명령 실행 |

### Cluster 도구

| 도구 | 파라미터 | 설명 |
|------|---------|------|
| `list_clusters` | 없음 | 모든 Ray Cluster 나열 |
| `get_cluster` | `id` (Cluster ID/이름) | 특정 Cluster 상세 조회 |
| `create_cluster` | `name`, `head_id`, `worker_ids?` | 새 Ray Cluster 생성 |
| `delete_cluster` | `id`, `force?` | Cluster 삭제 |
| `execute_on_cluster` | `cluster_id`, `command`, `timeout_seconds?` | 모든 Worker에서 병렬 실행 |
| `get_cluster_health` | `id` | 클러스터 헬스 체크 |

**사용 예시** (Claude Code 내):
```
안녕, GPU 클러스터 상태를 보여줄래?

→ list_clusters 도구 호출 → Cluster 목록 반환
→ get_cluster_health 도구로 각 클러스터 헬스 확인
```

## macOS 앱 스크린샷 설명

### 메뉴바 아이콘
- **상태 표시**: 🟢 Online / 🔴 Offline
- **빠른 액션**: Cluster 상태, 최근 Task 결과
- **메인 윈도우 열기**: 상단 메뉴 클릭

### Dashboard 탭
- **요약 카드**: 총 Device 수, Online 노드, 활성 Cluster, 에러 알림
- **GPU 실시간 그래프**: 전체 클러스터 GPU 사용률, 온도
- **최근 Task**: 마지막 10개 작업의 결과 (Device/명령/소요시간)

### Devices 탭
- **테이블**: ID, 호스트명, OS, SSH 상태, GPU 모델, 개수
- **필터**: GPU 있는 것만, Online만, OS 필터
- **상세 보기**: GPU 메트릭, 마지막 SSH 결과

### Clusters 탭
- **테이블**: 이름, 상태, Head/Worker 수, 생성일
- **액션**: 시작, 중지, Worker 추가/제거, 삭제
- **Dashboard 링크**: Ray Dashboard로 직접 이동

## 주요 설정

환경 변수:
```bash
# Web 서버
export CLUSTER_SERVER_HOST=0.0.0.0
export CLUSTER_SERVER_PORT=8080
export CLUSTER_TAILSCALE_APIKEY=xxx  # Tailscale API 키 (선택)
export CLUSTER_TAILSCALE_TAILNET=mynet.com

# SSH
export CLUSTER_SSH_USER=ubuntu
export CLUSTER_SSH_PRIVATE_KEY_PATH=~/.ssh/id_rsa
export CLUSTER_SSH_PORT=22
export CLUSTER_SSH_TIMEOUT=30
export CLUSTER_SSH_USE_TAILSCALE_SSH=true  # Tailscale SSH 사용

# 데이터베이스
export CLUSTER_DATABASE_DSN=$HOME/.naga/naga.db

# MCP (TypeScript)
export CLUSTER_API_URL=http://localhost:8080
```

## 개발

### 테스트 실행
```bash
make test              # 모든 테스트
make test-coverage     # 커버리지 리포트
```

### 코드 품질 검사
```bash
make lint              # golangci-lint
make fmt               # gofmt 포맷팅
make vet               # go vet 정적 분석
make check             # fmt + vet + lint + test 전부
```

### 빌드 정보
- **버전**: Git 태그 또는 "dev"
- **빌드 시간**: 빌드 타임스탐프 자동 삽입 (LDFLAGS)
- 바이너리 위치: `./build/naga`, `./build/naga-server`

## 보안

### Tailscale 네트워크 인증
- 모든 쓰기 API는 Tailscale CGNAT (100.64.0.0/10) 또는 localhost에서만 허용
- `RemoteAddr` 직접 검사 (X-Forwarded-For 헤더 무시)
- 세션 토큰/API 키 불필요 → Tailscale 인증서로 대체

### SSH 보안
- Private key 기반 인증 (password 미사용)
- Timeout 설정으로 행(hang) 방지
- (선택) Tailscale SSH 터널 사용 가능

### 데이터 저장
- SQLite 로컬 저장 (기밀 데이터는 저장하지 않음)
- Device/Cluster 메타데이터만 유지
- 민감한 자격증명은 환경변수로 관리

## 트러블슈팅

### GPU 감지 안됨
1. Linux 노드 확인: `uname -s` == "Linux"
2. SSH 접근 가능 확인: `ssh <user>@<tailscale-ip> nvidia-smi`
3. nvidia-smi 설치 확인: `which nvidia-smi`
4. GPU 감지 재시작:
   ```bash
   curl -X POST http://localhost:8080/api/devices?refresh=true
   ```

### Tailscale 인증 실패
1. Tailnet 내 접근 확인: `tailscale status`
2. IP 확인: `curl http://localhost:8080/health`의 RemoteAddr 확인
3. 서버 로그: `grep "access denied" logs/`

### Ray Cluster 시작 실패
1. Head 노드 Ray 설치: `ssh <user>@<head-ip> "ray start --head"`
2. Worker 노드: `ssh <user>@<worker-ip> "ray start --address=<head-ip>:6379"`
3. 포트 열기: Ray 포트 (6379, 8265) Tailscale에서 열혀있는지 확인

## 라이선스

MIT License

## 기여

Bug report 및 Pull Request는 환영합니다.

---

**최종 업데이트**: 2026년 3월
