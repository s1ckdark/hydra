# iOS Feature-Parity (macOS 대시보드 이식) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS 앱(HydraiOS)을 macOS 앱 수준으로 확장 — 대시보드·Orchs·Tasks·Chat 화면을 추가해 SSH 터미널 전용에서 풀 대시보드 클라이언트로.

**Architecture:** 공유 데이터/로직 계층(APIClient, WebSocketClient, `Hydra/ViewModels/*`, `Hydra/Models/*`)은 이미 iOS 호환. macOS Views를 직접 이식하지 않고, **공유 ViewModel 위에 iOS 네이티브 SwiftUI 화면을 새로 작성**한다(HydraiOS/Screens/). macOS 전용 UI 관용구(HSplitView, openWindow, .help, NavigationSplitView 컬럼폭, 고정 frame, keyboardShortcut)는 iOS 대응물로 대체. iOS는 임베디드 서버가 없으므로 `serverURL`(설정)로 실행 중인 hydra-server에 HTTP 접속.

**Tech Stack:** SwiftUI(iOS 17), xcodegen(project.yml), 공유 SPM 패키지(TerminalCore/SwiftTerm). 백엔드는 Go hydra-server(HTTP, `/api/*`).

## Global Constraints

- iOS 타깃 소스는 `project.yml`의 `HydraiOS.sources`에만 컴파일된다. 새 화면은 `HydraiOS/Screens/`에 두고, 공유 VM은 `project.yml`에 `Hydra/ViewModels`(및 필요 시 `Hydra/Theme`) 경로를 추가해 포함시킨다.
- **Console은 이식하지 않는다** — 로컬 Python 서브프로세스(`PYExecutor`, macOS 전용, iOS 불가). `ConsoleViewModel`은 `#if os(macOS)` 자체 가드됨.
- macOS 전용 서비스(`PYExecutor`, `EmbeddedServer`, `MetricsSampler`, `CapabilityReporter`, `MetricsReporter`)는 iOS 타깃 제외 유지.
- 기존 `Hydra/Views/iOS/*`(iOSDashboardView 등)는 stale/스텁(컴파일 에러·TODO)이므로 **참고만 하고 재사용하지 않는다** — 공유 VM 기반으로 새로 작성.
- 매 태스크 게이트: **iOS 타깃이 실기기 아치(arm64)로 컴파일**되어야 한다(아래 빌드 명령). UI는 TDD 대신 컴파일+동작 확인으로 검증.
- 인증/서명은 `com.s1ckdark/hydraios`, 팀 `8KLV8Q7TNL`, `CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates`(커맨드라인 override, project.yml 기본값은 유지).

**iOS 빌드 검증 명령(각 태스크 게이트):**
```bash
cd /Users/dave/iWorks/hydra/Hydra && xcodegen generate && \
xcodebuild -project Hydra.xcodeproj -scheme HydraiOS \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath /tmp/hydra_ios_build CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
# Expected: ** BUILD SUCCEEDED **
```
(게이트는 서명 없이 `generic/platform=iOS`로 컴파일만 확인. 실기기 설치는 Task 8에서.)

**공유 ViewModel 참조(구현자는 해당 파일을 직접 읽어 정확한 시그니처 확인):**
- `Hydra/ViewModels/DashboardViewModel.swift`: `@Published devices/orchs/gpuNodes/metricsByDevice/tasks/serverStatus/serverVersion/error/activity/quickCommand/quickCommandDeviceId/agentBusy/pingResults`; `func load(force:)`, `startPolling(interval:)/stopPolling()`, `agentSubmit/directSubmit/approve/denyEntry/runPing`.
- `Hydra/ViewModels/OrchViewModel.swift`: `loadOrchs()`, `selectOrch()`, `startProcessPolling/stopProcessPolling`, `execute(command:timeout:)`, `deleteOrch()`, published `orchs/selected/health/processes`.
- `Hydra/ViewModels/ChatViewModel.swift`: `send(_:contextPreamble:)`, `runPendingPlan()/cancelPendingPlan()`, published `turns/pendingPlan/thinking/error`.
- `Hydra/Services/SavedTaskStore.swift` (`.shared`): `tasks`, `execute(_:deviceId:)`, `add/update/delete`, `runningTaskIds`, `lastResults`.
- `Hydra/Services/APIClient.swift` (`.shared`, actor): 전체 HTTP 표면(devices/orchs/tasks/gpu/metrics/chat).

---

### Task 1: iOS 타깃에 ViewModels 배선 + 루트 DI

**Files:**
- Modify: `Hydra/project.yml` (HydraiOS.sources)
- Modify: `Hydra/HydraiOS/App.swift`
- Test(gate): iOS 컴파일

**Interfaces:**
- Produces: 루트에서 주입되는 `DashboardViewModel`(@StateObject) + `AppState`를 `.environmentObject`로 하위 화면에 공급.

- [ ] **Step 1: project.yml에 ViewModels/Theme 경로 추가**

`HydraiOS.sources`에 아래를 추가(기존 excludes 유지):
```yaml
      - path: Hydra/ViewModels
      - path: Hydra/Theme        # StatCard 등이 @Environment(\.theme) 사용 시 필요
```
`Hydra/Theme`가 존재하지 않거나 iOS 비호환이면 화면에서 Theme 의존을 제거하고 이 경로는 넣지 않는다(구현자가 `Hydra/Theme` 존재/호환 확인 후 결정).

- [ ] **Step 2: 루트 DI 구성**

`App.swift`에서 `DashboardViewModel`과 `AppState`를 @StateObject로 만들고 `RootView`에 `.environmentObject`로 주입:
```swift
@main
struct HydraiOSApp: App {
    @StateObject private var dashboardVM = DashboardViewModel()
    @StateObject private var appState = AppState()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(dashboardVM)
                .environmentObject(appState)
        }
    }
}
```
`AppState`가 iOS에서 초기화 가능한지 확인(감사 결과 CLEAN). 폴링은 각 화면 `.task`/`.onAppear`에서 `dashboardVM.load()`/`startPolling`으로 구동.

- [ ] **Step 3: iOS 컴파일 게이트**

위 "iOS 빌드 검증 명령" 실행 → `** BUILD SUCCEEDED **` 확인. (RootView는 아직 2탭이어도 됨 — 이 태스크는 배선만.)

- [ ] **Step 4: Commit** — `feat(ios): iOS 타깃에 공유 ViewModels 배선 + 루트 DI`

---

### Task 2: RootView 탭 바 확장(스켈레톤)

**Files:**
- Modify: `Hydra/HydraiOS/RootView.swift`
- Create: `Hydra/HydraiOS/Screens/DashboardScreen.swift` (스텁), `OrchsScreen.swift`(스텁), `TasksScreen.swift`(스텁), `ChatScreen.swift`(스텁)

**Interfaces:**
- Consumes: Task 1의 environmentObject(DashboardVM/AppState).
- Produces: 6탭 TabView([대시보드, 디바이스, Orchs, Tasks, Chat, 설정]) + 기존 터미널 fullScreenCover 유지.

- [ ] **Step 1: 각 화면 최소 스텁 생성**

각 `*Screen`은 `NavigationStack { Text("<이름>").navigationTitle(...) }` 수준의 컴파일되는 스텁으로 생성(다음 태스크에서 채움). Console 탭은 만들지 않는다.

- [ ] **Step 2: RootView 탭 확장**

```swift
TabView {
    DashboardScreen().tabItem { Label("대시보드", systemImage: "gauge") }
    NavigationStack { DeviceListScreen(onSelect: { selected = $0 }) }
        .tabItem { Label("디바이스", systemImage: "server.rack") }
    OrchsScreen().tabItem { Label("Orchs", systemImage: "cpu") }
    TasksScreen().tabItem { Label("Tasks", systemImage: "list.bullet.clipboard") }
    ChatScreen().tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
    NavigationStack { SettingsScreen() }.tabItem { Label("설정", systemImage: "gear") }
}
.fullScreenCover(item: $selected) { device in /* 기존 TerminalScreen 유지 */ }
```

- [ ] **Step 3: iOS 컴파일 게이트** → BUILD SUCCEEDED.
- [ ] **Step 4: Commit** — `feat(ios): RootView 6탭 확장(대시보드/Orchs/Tasks/Chat 스텁)`

---

### Task 3: DashboardScreen (iOS)

**Files:**
- Modify: `Hydra/HydraiOS/Screens/DashboardScreen.swift`
- Reference: `Hydra/Views/Dashboard/DashboardView.swift`(macOS, 레이아웃 참고), `Hydra/ViewModels/DashboardViewModel.swift`

**Interfaces:**
- Consumes: `@EnvironmentObject dashboardVM: DashboardViewModel`.

- [ ] **Step 1: 화면 구성** — `ScrollView` 세로 스택(iPhone 폭 대응, macOS의 2열/4열 HStack → 세로/adaptive grid):
  - 서버 상태 배너(`serverStatus`/`serverVersion`)
  - 요약 카드 4종(Devices/GPU Nodes/Orchs/Tasks 카운트) — `LazyVGrid(columns: 2)`
  - 디바이스 개요: `dashboardVM.devices` + `metricsByDevice`로 CPU/RAM/GPU 바 + uptime 카드 리스트
  - GPU 섹션(`gpuNodes`: util/temp 바), 실행 중 Orchs(`orchs`), 최근 Tasks(`tasks`)
  - 빠른 명령: 대상 디바이스 Picker + 명령 TextField + ▶실행(`directSubmit`)/✨에이전트(`agentSubmit`), 결과는 `activity`
- [ ] **Step 2: 데이터 구동** — `.task { await dashboardVM.load(); dashboardVM.startPolling(interval: 5) }`, `.refreshable { await dashboardVM.load(force: true) }`, `.onDisappear { dashboardVM.stopPolling() }`.
- [ ] **Step 3: macOS 관용구 제거** — `.help()` 제거, `ToolbarItem`에 iOS placement 지정, 고정 폭 제거.
- [ ] **Step 4: iOS 컴파일 게이트** → BUILD SUCCEEDED.
- [ ] **Step 5: Commit** — `feat(ios): DashboardScreen — 공유 DashboardViewModel 재사용`

---

### Task 4: OrchsScreen + 상세 + 생성 (iOS)

**Files:**
- Modify: `Hydra/HydraiOS/Screens/OrchsScreen.swift`
- Create: `Hydra/HydraiOS/Screens/OrchDetailScreen.swift`, `CreateOrchScreen.swift`
- Reference: `Hydra/Views/Orchs/{OrchListView,CreateOrchView}.swift`, `Hydra/ViewModels/OrchViewModel.swift`

**Interfaces:**
- Consumes: `@StateObject vm = OrchViewModel()` (화면 로컬), `APIClient.shared`.

- [ ] **Step 1: 목록** — `NavigationStack { List(vm.orchs) { OrchRow → NavigationLink(OrchDetailScreen) } }`, `.task { await vm.loadOrchs() }`, `.refreshable`, 툴바 `+`(생성 시트), 행 스와이프/컨텍스트 삭제(`vm.deleteOrch`).
- [ ] **Step 2: 상세** — `OrchDetailScreen(orch:)`: 정보 그리드, Node Health(`vm.health`), 분산 실행(명령 TextField + `vm.execute`), 워커 프로세스(`vm.processes`, `startProcessPolling`/`stopProcessPolling`). NavigationSplitView 대신 push 네비.
- [ ] **Step 3: 생성** — `CreateOrchScreen`: `NavigationStack`+`Form`(Name, Coordinator Picker, Workers Toggle 리스트) + 툴바 Cancel/Create → `APIClient.shared.createOrch`. 고정 frame 제거.
- [ ] **Step 4: iOS 컴파일 게이트** → BUILD SUCCEEDED.
- [ ] **Step 5: Commit** — `feat(ios): OrchsScreen 목록/상세/생성 — OrchViewModel 재사용`

---

### Task 5: TasksScreen (iOS)

**Files:**
- Modify: `Hydra/HydraiOS/Screens/TasksScreen.swift`
- Create: `Hydra/HydraiOS/Screens/TaskEditorScreen.swift`
- Reference: `Hydra/Views/Tasks/TasksView.swift`(macOS, `#if os(macOS)`라 참고만), `Hydra/Services/SavedTaskStore.swift`

**Interfaces:**
- Consumes: `@ObservedObject store = SavedTaskStore.shared`, `@EnvironmentObject dashboardVM`(대상 디바이스 목록).

- [ ] **Step 1: 목록** — `List(store.tasks)` 행(이름/명령/대상), 실행 상태(`runningTaskIds`)·결과(`lastResults`). 툴바 `+`(에디터 시트), 스와이프 Edit/Delete, run-now(`store.execute(task, deviceId:)`).
- [ ] **Step 2: 에디터** — `TaskEditorScreen`: `NavigationStack`+`Form`(name, command, target device Picker(`dashboardVM.devices`), timeout, priority, capabilities). macOS의 `FlowLayout`은 재사용 가능(플랫폼 무관)하면 가져오고, 아니면 단순 리스트. 고정 frame/keyboardShortcut 제거.
- [ ] **Step 3: iOS 컴파일 게이트** → BUILD SUCCEEDED.
- [ ] **Step 4: Commit** — `feat(ios): TasksScreen — SavedTaskStore 재사용, 실행/편집`

---

### Task 6: ChatScreen (iOS)

**Files:**
- Modify: `Hydra/HydraiOS/Screens/ChatScreen.swift`
- Reference: `Hydra/Views/Chat/ChatDrawerView.swift`, `Hydra/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `@StateObject vm = ChatViewModel()` 또는 루트 주입. `contextPreamble`은 iOS에선 `nil` 또는 경량 문자열.

- [ ] **Step 1: 화면** — `NavigationStack` 메시지 리스트(`vm.turns`) + 대기 플랜 카드(`vm.pendingPlan` → 승인/취소 `runPendingPlan`/`cancelPendingPlan`) + 에러 + 입력 바(멀티라인 TextField + 전송 `vm.send`) + `vm.thinking` 스피너. `@Environment(\.openWindow)`·드로어 패러다임 제거(전용 탭이므로 불필요).
- [ ] **Step 2: iOS 컨텍스트(선택)** — `ChatContextProvider`(macOS 전용, 제외)를 쓰지 않고, 현재 선택 컨텍스트가 필요하면 iOS용 경량 프리앰블을 화면에서 직접 조립하거나 `nil` 전달.
- [ ] **Step 3: iOS 컴파일 게이트** → BUILD SUCCEEDED.
- [ ] **Step 4: Commit** — `feat(ios): ChatScreen — ChatViewModel 재사용(서버 기반)`

---

### Task 7: Settings 확장 (API 키 + AI instruction)

**Files:**
- Modify: `Hydra/HydraiOS/Screens/SettingsScreen.swift`
- Reference: `Hydra/Services/{APIClient,CredentialStore}.swift`

- [ ] **Step 1: 서버 API 키 필드** — `serverAPIKey`(CredentialStore, `APIClient.applyAuth`가 사용) 입력 UI 추가(SecureField). 저장 시 CredentialStore에 반영.
- [ ] **Step 2: AI instruction 필드** — `@AppStorage("aiInstruction")` TextField 추가(ChatViewModel이 읽음).
- [ ] **Step 3: iOS 컴파일 게이트** → BUILD SUCCEEDED.
- [ ] **Step 4: Commit** — `feat(ios): 설정에 서버 API 키 + AI instruction 추가`

---

### Task 8: 실기기 빌드·설치·검증

**Files:** 없음(빌드/배포)

- [ ] **Step 1: 실기기 서명 빌드**
```bash
cd /Users/dave/iWorks/hydra/Hydra && xcodegen generate && rm -rf /tmp/hydra_ios_build && \
xcodebuild -project Hydra.xcodeproj -scheme HydraiOS \
  -destination 'platform=iOS,id=449857D7-CB0F-5121-A62D-D6B23A853F1D' -configuration Release \
  -derivedDataPath /tmp/hydra_ios_build CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=8KLV8Q7TNL PRODUCT_BUNDLE_IDENTIFIER=com.s1ckdark.hydraios \
  -allowProvisioningUpdates build 2>&1 | tail -5
```
- [ ] **Step 2: 설치** — `xcrun devicectl device install app --device 449857D7-CB0F-5121-A62D-D6B23A853F1D <HydraiOS.app>`.
- [ ] **Step 3: 사용자 검증 요청** — 아이패드에서 6탭 표시, serverURL 지정 후 대시보드 로드, Orchs/Tasks/Chat 동작 확인(사용자가 실기 확인).
- [ ] **Step 4: 최종 커밋/푸시**

---

## Self-Review 메모
- 스펙 커버리지: Dashboard/Orchs/Tasks/Chat = macOS 주요 화면 커버. Console은 iOS 불가로 의도적 제외(Global Constraints). Settings 확장으로 Chat/authed 엔드포인트 UX 갭 해소.
- 타입 일관성: 화면은 macOS Views가 아니라 공유 ViewModel의 실제 @Published/메서드에 바인딩 — 구현자는 각 VM 파일을 읽어 정확한 이름 사용.
- 위험: `Hydra/Theme` iOS 호환 여부(Task 1에서 결정), `AppState` iOS 초기화(감사 CLEAN), NavigationSplitView→iPhone 축약 동작 차이(Orchs는 push 네비로 우회).
