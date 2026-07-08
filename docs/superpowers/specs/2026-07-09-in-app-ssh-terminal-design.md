# 앱 내 SSH 터미널 (In-App SSH Terminal) 설계

- 날짜: 2026-07-09
- 상태: 설계 승인됨 (구현 전)
- 대상: Naga/Hydra macOS 앱 (Swift GUI, `Hydra/`)
- 재사용 소스: `/Users/dave/iWorks/terminal` (TerminalCore SSH 모듈 + `s1ckdark/SwiftTerm` 포크)
- 관련: [[2026-07-08-in-app-python-console-design]] (같은 GUI의 파이썬 콘솔 — 나란히 배치)

## 1. 배경과 목표

hydra는 GPU 클러스터 매니저로 이미 노드에 SSH로 붙어 메트릭·task를 돌린다
(Go `internal/infra/ssh`, `~/.clusterctl/config.yaml`). 이 스펙은 **앱 안에서
클러스터 노드에 라이브 인터랙티브 셸**을 여는 Terminal 탭을 추가한다 — Devices
탭에서 노드를 골라 "터미널 열기" → SwiftTerm 기반 터미널에서 실 셸 세션.

터미널 앱(`iWorks/terminal`)의 재사용 가능한 두 자산을 활용한다:
- **SwiftTerm 포크**(`s1ckdark/SwiftTerm`): `Mac/MacTerminalView.swift` AppKit
  `NSView` 터미널 에뮬레이터 → SwiftUI `NSViewRepresentable`로 래핑.
- **TerminalCore**: UI 독립적(UIKit import 0개, macOS 15+ 타겟) SSH 전송 계층.

**확정된 결정 (브레인스토밍)**
1. UI 배치: **Terminal 탭 + Devices에서 진입** (Console 탭과 대칭)
2. 코드 수급: **필요 모듈만 hydra에 벤더 복사** (단방향), SwiftTerm은 git URL 의존
3. SSH 백엔드: **Citadel** (`SSHTransportCitadel`, 순수 Swift NIO — C 링크 불필요)
4. 자격: **`~/.clusterctl/config.yaml` 재사용** (Go 서버와 동일 user/key)
5. 호스트키: **TOFU + `~/.ssh/known_hosts` 영속화**

**성공 기준**: `make hydra-app` 후 Terminal 탭에서 실 GPU 노드에 "터미널 열기" →
TOFU 수락 → 라이브 셸에서 `nvidia-smi`가 정상 실행/렌더된다.

## 2. 접근안 결정 (SwiftUI에 AppKit 터미널 얹기)

| 접근 | 방식 | 판정 |
|---|---|---|
| **A. NSViewRepresentable(MacTerminalView) + Citadel** | AppKit 터미널 뷰를 SwiftUI 래핑, 순수 Swift Citadel 세션 | **채택** — C 링크 없음, SSHSession 프로토콜이 output/state/write/resize/remoteHostKey를 뷰와 1:1 노출 |
| B. libssh2(SSHTransportMac/Shout) | Go쪽과 사상 동일하나 C 라이브러리 링크·서명 추가 | 번들 복잡도 — 배제 |
| C. 로컬 PTY로 `ssh` CLI 래핑 | MacLocalTerminalView로 `/usr/bin/ssh` 실행 | 세션 상태·호스트키 제어권 상실 — 배제 |

채택 근거: Citadel은 순수 Swift라 hydra 자체완결성(빌드에 C 링크·번들 서명 추가
없음)을 지키고, `SSHSession` 프로토콜이 이미 `output` AsyncStream / `state` /
`write` / `resize` / `remoteHostKey`를 노출해 SwiftTerm 뷰에 깔끔히 붙는다.

## 3. 벤더링 & 패키지 구조

`iWorks/terminal`에서 UI 독립적인 **필요 모듈만** hydra로 단방향 복사한다:

```
Hydra/Packages/TerminalCore/            (신규 로컬 SwiftPM 패키지)
├── Package.swift                        (필요 타겟만, macOS 전용 — iOS 조건 제거)
└── Sources/
    ├── SSHTransport/                    (SSHSession 프로토콜, SSHState/SSHError/SSHAuth/HostKeyFingerprint, FakeSSHSession)
    ├── SSHTransportCitadel/             (CitadelSession: connect/openShell/write/resize/output/remoteHostKey)
    └── KnownHosts/                      (KnownHostsParser + KnownHostsStore)
```

- **제외 (YAGNI)**: `IMECore`, `FontPlumbing`, `CommandExtraction`,
  `SSHTransportMac`(libssh2), `KeyManagement`(hydra는 config.yaml 키 경로 직접 사용).
- **SwiftTerm**: hydra `Package.swift`에 git 의존 추가
  (`url: https://github.com/s1ckdark/SwiftTerm`, `revision: 54b436a6231976fa64d7c3859d0b197a6ccfcb91`
  — terminal 레포와 동일 고정). 벤더링 불필요.
- **의존성 트리 추가**: Citadel(`orlandos-nl/Citadel` → swift-nio-ssh) + SwiftTerm.
  둘 다 순수 Swift — C 링크/번들 서명 이슈 없음.
- **벤더 출처 표기**: 복사한 각 파일 상단에
  `// vendored from iWorks/terminal @ <commit>, do not edit here` 주석. 단방향
  복사임을 명시(양방향 동기화 안 함). `FakeSSHSession`도 함께 벤더(테스트용).
- **Package.swift 수정**: 복사한 타겟의 iOS/Catalyst 조건·불필요 product를 제거하고
  `platforms: [.macOS(.v15)]`만 남긴다. Citadel 의존만 유지(Shout/libssh2 제거).

## 4. 컴포넌트

### 4.1 `ClusterSSHConfig` (Services/, 신규)
```swift
struct ClusterSSHConfig {
    struct Resolved { let user: String; let privateKeyPath: String; let port: Int }
    static func load() -> Resolved?   // ~/.clusterctl/config.yaml 파싱
    static func load(from yaml: String) -> Resolved?   // 테스트용 순수 함수
}
```
- `ssh.user` / `ssh.private_key_path` / `ssh.port` 세 키만 추출 (Go `SSHConfig`와
  동일 필드). 전체 YAML 모델링 안 함. 순수 파서라 픽스처 YAML로 유닛 테스트.
- 파일/키 없으면 nil → 호출부가 `SSHKeyLocator`(hydra 기존) 폴백으로 `~/.ssh`의
  ed25519/ecdsa/rsa 순 개인키 사용.

### 4.2 `TerminalSession` (Services/, `@MainActor ObservableObject`, `#if os(macOS)`)
```swift
final class TerminalSession: ObservableObject, Identifiable {
    let id: String
    let deviceId: String
    let deviceName: String
    let host: String
    @Published var state: SSHState = .idle
    // private session: SSHSession (Citadel or injected Fake) + terminal: SwiftTerm.Terminal
    init(device: Device, session: SSHSession)   // session 주입 → 테스트에서 Fake
    func connect() async     // creds 해석(§4.1) → session.connect → openShell(termType,cols,rows); host key 검증(§4.5)
    func send(_ data: Data)  // → session.write
    func resize(cols: Int, rows: Int)  // → session.resize
    func close()             // → session.disconnect
    // output AsyncStream 소비 → 뷰의 terminal.feed 로 흐름
}
```
- 세션 1개 = 노드 1개. `SSHError`는 `state = .disconnected(reason:)`로 노출(배너+재연결).

### 4.3 `TerminalSessionStore` (Services/, `@MainActor ObservableObject`, shared)
```swift
final class TerminalSessionStore: ObservableObject {
    static let shared = TerminalSessionStore()
    @Published var sessions: [TerminalSession] = []
    @Published var activeSessionId: String?
    func open(device: Device)   // 기존 세션 재사용(중복 생성 금지) or 새로 생성 + activeSessionId
    func close(id: String)
    func closeAll()             // applicationWillTerminate 에서 호출
    // 테스트: sessionFactory 주입 가능 (Fake 세션 생성)
}
```

### 4.4 UI (`Views/Terminal/`, `#if os(macOS)`)
- `AppState.Tab.terminal` 추가; `ContentView` macOS 블록에 탭 배선(Console 탭 옆).
- `TerminalView`: `HSplitView` — 좌: 세션 목록(노드명 + 상태 점 초록/회색/빨강, 닫기 버튼), 우: `TerminalSessionView`.
- `TerminalSessionView`: `NSViewRepresentable`로 `SwiftTerm.MacTerminalView` 래핑.
  `Coordinator`가 SwiftTerm delegate(사용자 입력→`send`, 리사이즈→`resize`) ↔
  세션을 잇고, 세션 `output`을 `terminal.feed`로 렌더. 상단 상태 배너(연결 중/끊김+재연결).
- **Devices 진입**: Device 상세/행에 "터미널 열기" 버튼 →
  `TerminalSessionStore.open(device:)` + `AppState.activeTab = .terminal`.
- **탭 exhaustiveness**: `ChatContextProvider` 등 `AppState.Tab` switch에 `.terminal`
  추가(Console 때와 동일 — nil/settings 그룹).

### 4.5 호스트키 TOFU (`KnownHosts` 벤더 재사용)
- connect 중 `session.remoteHostKey`(HostKeyFingerprint)를 `KnownHostsStore`와 대조.
- **신규**: SwiftUI `.sheet`로 sha256 fingerprint 표시 → "신뢰" 시
  `~/.ssh/known_hosts`에 기록·연결 계속, "취소" 시 세션 종료.
- **불일치**(기존과 다른 키): 빨간 경고 시트 + 연결 차단(MITM 가능성).
- **일치**: 조용히 진행.

## 5. 데이터 흐름

1. Devices 탭에서 노드 "터미널 열기" → `TerminalSessionStore.open(device)` → `activeTab = .terminal`
2. `TerminalSession.connect()`: `ClusterSSHConfig.load()`(+`SSHKeyLocator` 폴백)로 user/key 해석 → `session.connect(host: device.tailscaleIp, port, user, auth: .privateKey(...))`
3. 핸드셰이크 후 `remoteHostKey` → KnownHosts 대조 → (신규면 TOFU 시트)
4. `session.openShell(termType:"xterm-256color", cols, rows)` → 라이브 셸
5. 셸 stdout → `session.output` AsyncStream → `terminal.feed` → MacTerminalView 렌더
6. 사용자 키입력 → SwiftTerm delegate → `session.write`; 뷰 리사이즈 → `session.resize`
7. 앱 종료 → `TerminalSessionStore.closeAll()` → 각 `session.disconnect()`

## 6. 에러 처리

- `SSHError.unreachable/handshakeFailed/authFailed/channelFailed` → `state = .disconnected(reason:)` → 뷰 배너 + "재연결". 크래시 없음.
- 키 암호화(passphrase 필요) → `authFailed` → 연결 시트에서 passphrase 1회 입력 후 재시도(Keychain 저장은 비범위).
- config.yaml 없음/키 없음 → `SSHKeyLocator` 폴백; 그래도 없으면 "~/.ssh 키 없음" 안내.
- 호스트키 불일치 → 연결 차단 + 경고(자동 수락 안 함).

## 7. 보안 / 신뢰 모델

사용자 자기 머신에서 자기 SSH 키로 자기 클러스터 노드에 접속 — 기존 hydra SSH
사상과 동일. 호스트키는 TOFU + known_hosts 영속화로 표준 SSH 보안 관행을 따른다
(불일치 차단). 앱은 리스너를 열지 않음; Tailscale 네트워크 경계 위에서 동작.

## 8. 테스트 전략

1. **Swift 유닛** (`Hydra/Tests/HydraTests/`):
   - `ClusterSSHConfig.load(from:)` — 픽스처 YAML → user/key/port 추출(순수 함수, 최고 가치)
   - `KnownHostsStore` — 신규/일치/불일치 판정(벤더 KnownHosts)
   - `TerminalSessionStore.open` — 같은 노드 재사용(중복 생성 금지)·`closeAll`
   - `TerminalSession` connect→openShell→output 흐름·에러 표면: `FakeSSHSession`(벤더) 주입으로 실 SSH 없이 검증
2. **수동 스모크** (CI 스킵 — 실 노드/SSH 의존):
   `make hydra-app` → Terminal 탭 → 실 GPU 노드(y-gpu-1 등) "터미널 열기" → TOFU 수락
   → 라이브 셸 `nvidia-smi` 실행/렌더 확인. 리사이즈·재연결·다중 세션.

## 9. 구현 순서 (계획 단계에서 태스크화)

1. 벤더링: TerminalCore 3모듈(+Fake) 복사 + Package.swift(macOS 전용) + hydra Package.swift에 SwiftTerm/Citadel 의존 추가 → `swift build` 통과
2. `ClusterSSHConfig` 순수 파서 + 유닛
3. `TerminalSession` + `TerminalSessionStore`(Fake 주입) + 유닛
4. 호스트키 TOFU 로직(KnownHosts 대조) + 유닛
5. Terminal 탭 UI(NSViewRepresentable + 세션 목록) + Devices 진입 버튼 + AppState/ChatContextProvider 배선
6. 수동 스모크

## 10. 비범위 (YAGNI)

- 세션 스크롤백 영속화, 탭 분할/멀티페인
- 파일 전송(scp/sftp)
- 폰트/테마 커스터마이즈
- passphrase Keychain 저장
- iOS/Catalyst 지원 (macOS 앱 전용)
- 앱 자체 서버/키 관리 UI (config.yaml + ~/.ssh 단일 소스)
- libssh2 백엔드 (Citadel 단일)
