# AI Auth Settings — Design

Hydra의 Settings에 AI 프로바이더 인증(auth)을 추가해 멀티태스크 오케스트레이션의 3역할(HeadSelection / TaskScheduling / CapacityEstimation)을 구성 가능하게 한다.

## Goals

- 사용자가 UI에서 AI auth(API key 또는 로컬 API endpoint)를 입력·저장·테스트할 수 있다.
- 현재 단일 프로바이더 파이프(`cmd/server/ai.go`의 `buildAITaskScheduler`)를 역할별 라우팅 파이프로 전환한다.
- 기존 `AgentConfig`의 레거시 필드(`ai_provider`, `anthropic_api_key`, `ollama_*`, `lmstudio_*`)로 동작하던 배포를 깨지 않는다.

## Non-Goals

- OAuth(Claude·ChatGPT 구독 기반 브라우저 로그인): 써드파티 앱에 클라이언트 발급이 닫혀있어 불가.
- Claude/Codex CLI subprocess 위임: 이번 범위 밖.
- iOS Settings UI: 관리자 성격의 설정이라 macOS 우선. iOS는 후속 범위.
- `NAGA_` → `HYDRA_` viper 접두사 마이그레이션: 별도 cleanup 작업.

## Provider Auth Model

UI는 **단일 Provider 드롭다운**으로 통합한다 (별도의 "Auth Method" 토글 없음). Provider 선택값에 따라 입력 필드만 달라진다.

| Provider | 그룹 | 필요 입력 |
|---|---|---|
| `claude` | Cloud | `api_key` (시크릿), 선택적 `model` |
| `openai` | Cloud | `api_key`, 선택적 `model` |
| `zai` | Cloud | `api_key`, 선택적 `model` |
| `ollama` | Local | `endpoint` (URL), 선택적 `model` |
| `lmstudio` | Local | `endpoint`, 선택적 `model` |
| `openai_compatible` | Local | `endpoint`, 선택적 `model` |

드롭다운 라벨은 그룹 힌트를 표기한다 (예: "Claude (cloud)", "Ollama (local)") — 사용자가 어떤 입력이 필요할지 미리 예상할 수 있게.

OAuth 스타일(브라우저 로그인) 인증은 써드파티 앱에 클라이언트 발급이 닫혀있어 Non-Goal로 명시 (Claude/Codex CLI subprocess 위임도 별도 범위).

## Config Schema

### 변경 — `config/config.go`

`AgentConfig`에 `AI` 필드 추가. Role-override + default 구조:

```go
type AgentConfig struct {
    // ... 기존 필드 유지
    AI AIConfig `mapstructure:"ai"`
}

type AIConfig struct {
    Default            ProviderConfig  `mapstructure:"default"`
    HeadSelection      *ProviderConfig `mapstructure:"head_selection,omitempty"`
    TaskScheduling     *ProviderConfig `mapstructure:"task_scheduling,omitempty"`
    CapacityEstimation *ProviderConfig `mapstructure:"capacity_estimation,omitempty"`
}

type ProviderConfig struct {
    Provider string `mapstructure:"provider"`
    APIKey   string `mapstructure:"api_key"`
    Endpoint string `mapstructure:"endpoint"`
    Model    string `mapstructure:"model"`
}
```

`Provider` 값이 discriminator 역할을 한다 — `claude`/`openai`/`zai`는 `APIKey` 요구, `ollama`/`lmstudio`/`openai_compatible`은 `Endpoint` 요구. Validation은 `AIConfig.Resolve(role)` 호출 시점에 수행.

### 레거시 호환 레이어

`config.Load()`의 마지막 단계에서 레거시 필드를 새 구조로 승격:

```go
// 레거시 → 새 구조. Default가 이미 세팅돼 있으면 skip.
if cfg.Agent.AI.Default.Provider == "" {
    migrateLegacyAgentAI(&cfg.Agent)
}
```

`migrateLegacyAgentAI`는:
- `ai_provider=claude` + `anthropic_api_key` → `Default = {Provider: "claude", APIKey: ...}`
- `ai_provider=openai` + `anthropic_api_key` → `Default = {Provider: "openai", APIKey: ...}` (현 `cmd/server/ai.go:29`의 재사용 로직 보존)
- `ai_provider=ollama` + `ollama_endpoint`/`ollama_model` → `Default = {Provider: "ollama", Endpoint: ..., Model: ...}`
- `ai_provider=lmstudio` + `lmstudio_*` → 동일 패턴

레거시 필드는 deprecated 주석만 남기고 read-only로 유지한다. `config.Save()`는 새 구조만 쓴다.

### Resolve 로직

```go
func (a *AIConfig) Resolve(role string) ProviderConfig {
    var override *ProviderConfig
    switch role {
    case "head": override = a.HeadSelection
    case "schedule": override = a.TaskScheduling
    case "capacity": override = a.CapacityEstimation
    }
    if override != nil && override.Provider != "" {
        return *override
    }
    return a.Default
}
```

## Server (Go Backend)

### `cmd/server/ai.go`

`buildAITaskScheduler(cfg.Agent)` → `buildAIRegistry(cfg.Agent.AI)` 로 리팩터.

```go
func buildAIRegistry(aicfg config.AIConfig) *ai.Registry {
    reg := ai.NewRegistry(ai.Config{}) // Config arg currently unused; may be dropped later
    if hs := buildHeadSelector(aicfg.Resolve("head")); hs != nil {
        reg.SetHeadSelector(hs)
    }
    if ts := buildTaskScheduler(aicfg.Resolve("schedule")); ts != nil {
        reg.SetTaskScheduler(ts)
    }
    if ce := buildCapacityEstimator(aicfg.Resolve("capacity")); ce != nil {
        reg.SetCapacityEstimator(ce)
    }
    return reg
}
```

Note: `internal/infra/ai/registry.go`의 `NewRegistry(cfg Config)` 인자는 현재 미사용. 유지 여부는 implementation 단계에서 판단.

각 `build*` 함수는 `provider.go` 매트릭스(Claude/OpenAI/Z.AI/Ollama/LM Studio/OpenAI-compat)를 참조해 지원 role만 인스턴스화. 미지원 조합은 nil 반환 → Registry는 rule-based fallback을 쓴다(현 동작 유지).

### 새 Handler — `internal/web/handler/ai_config_handler.go`

Tailscale 핸들러와 동일 패턴:

- `GET /api/config/ai` — 현재 구성 반환, `APIKey`는 `has_api_key: bool`로 마스킹
- `PUT /api/config/ai` — in-memory cfg 업데이트 + `config.Save`

Request shape:
```json
{
  "default":            { "provider": "claude", "api_key": "sk-ant-...", "model": "claude-sonnet-4-6" },
  "head_selection":     null,
  "task_scheduling":    { "provider": "ollama", "endpoint": "http://localhost:11434", "model": "llama3" },
  "capacity_estimation": null
}
```

Validation: provider=api_key 그룹인데 `api_key` 빈 값, provider=local_api 그룹인데 `endpoint` 빈 값이면 400.

라우팅은 `internal/web/middleware/apikey.go` 보호 아래 등록 (Tailscale 핸들러와 동일).

### Resolve 호출 지점 교체

- `cmd/cluster-agent/main.go`: 현재 `resolveAISelector`는 `HeadSelector`만 세팅. `buildAIRegistry`의 `head` role resolve로 대체.

## Swift macOS Settings UI

### 구조

`Hydra/Hydra/Views/Settings/SettingsView.swift`에 **"AI" 탭** 추가 (Server, Tailscale 탭과 동급).

```swift
TabView {
    ServerSettingsTab().tabItem { Label("Server", systemImage: "server.rack") }
    TailscaleSettingsTab().tabItem { Label("Tailscale", systemImage: "network") }
    AISettingsTab().tabItem { Label("AI", systemImage: "brain") }
}
```

### Basic 뷰 (기본 노출)

- Section "① AI Provider (Default)":
  - Provider 드롭다운 (6개 항목, 그룹 힌트 라벨 — "Claude (cloud)", "OpenAI (cloud)", "Z.AI (cloud)", "Ollama (local)", "LM Studio (local)", "OpenAI-compatible (local)")
  - Provider가 cloud 그룹이면 `SecureField` API Key 표시
  - Provider가 local 그룹이면 `TextField` Endpoint 표시
  - 공통: `TextField` Model (optional)
- Section "② Verify": Test 버튼 → provider별 ping (Claude `/v1/models`, OpenAI `/v1/models`, Ollama `/api/tags`, LM Studio `/v1/models`)
- Section "③ Advanced": disclosure(`DisclosureGroup`). 기본 접힘
- Section "④ Save": Save & Push to Server (verify 성공 후 활성)

### Advanced 섹션 (disclosure 펼침)

3개 하위 섹션 (Head Selection / Task Scheduling / Capacity Estimation). 각 섹션은:

- Toggle "Use Default" (기본 ON)
- Toggle OFF 시 → 해당 role의 provider 블록이 그 섹션 내부에 펼쳐짐 (Basic 뷰와 동일 필드)

이 역할 섹션들은 외부 disclosure 안에 있으므로, Basic 사용자는 "Advanced" 자체를 펼치지 않으면 스크롤 부담이 없다.

### CredentialStore

`CredentialStore.swift`에 key 추가:
- `aiDefaultAPIKey`
- `aiHeadAPIKey`, `aiScheduleAPIKey`, `aiCapacityAPIKey`

Endpoint·Model·Provider는 non-secret이므로 `@AppStorage` 또는 서버 PUT 응답으로 관리. API Key만 Keychain.

### Save & Push

Tailscale 탭 패턴 재사용:
1. Test Connection 성공 (`connectionVerified = true`)
2. Save Locally (Keychain + AppStorage)
3. Save & Push to Server → `PUT /api/config/ai` (server API key가 있으면 Bearer 헤더)

## Testing

- Go: `config.Load` 레거시 필드 승격 유닛 테스트 (`config/config_test.go`에 케이스 추가)
- Go: `AIConfig.Resolve` role fallback 테스트
- Go: `ai_config_handler` GET 마스킹 / PUT validation 테스트
- Swift: UI 테스트는 범위 밖 (기존 SettingsView와 동일 수준)

## Files Touched

### Modified
- `config/config.go` — AIConfig, ProviderConfig 타입 + Load 마이그레이션 훅
- `config/config_test.go` — 레거시 승격·resolve 테스트
- `cmd/server/ai.go` — `buildAIRegistry` 리팩터
- `cmd/server/main.go` — 새 핸들러 등록
- `cmd/cluster-agent/main.go` — `resolveAISelector` 제거, Registry 사용
- `internal/infra/ai/registry.go` — (이미 3역할 지원, 변경 없음 확인)
- `Hydra/Hydra/Views/Settings/SettingsView.swift` — AI 탭 추가
- `Hydra/Hydra/Services/CredentialStore.swift` — 신규 key

### New
- `internal/web/handler/ai_config_handler.go`
- `Hydra/Hydra/Views/Settings/AISettingsTab.swift` (SettingsView에서 분리)

## Migration / Rollout

- 기존 `~/.hydra/config.yaml`이 레거시 필드만 가진 상태로 서버 기동 → `Load`가 `AI.Default`로 승격 → 기존 동작 그대로.
- 사용자가 Settings UI에서 Save → 새 구조로 파일에 기록됨. 레거시 필드는 덮어쓰지 않고 남겨두되 `config.Save`는 더이상 쓰지 않음 (다음 save 사이클에서 자연 소멸하려면 별도 cleanup. 이번 범위는 남겨둠).
