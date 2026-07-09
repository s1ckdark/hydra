# B2b — iOS 실 UI (디바이스목록 + 터미널) — 설계

> 상위 목표: Hydra SSH 터미널을 iPad(iOS)에서 동작(하위 B). B2 = B2a(iOS 빌드 기반, 완료) → **B2b(이 스펙): iOS 실 UI로 iPad에서 실제 SSH 셸**.
> 선행: A(다중키), B1(Citadel), B2a(iOS 타깃+공유계층) 머지 완료.

**작성일:** 2026-07-09
**상태:** 설계 승인됨 (사용자 승인 2026-07-09)

---

## 1. 배경 / 목표

B2a로 iOS 앱 타깃과 공유 서비스 계층(터미널 오케스트레이션·CitadelSession)이 iOS에서 컴파일된다(플레이스홀더 화면). B2b는 그 위에 **실 UI**를 얹어 iPad에서 서버 URL·SSH 키를 넣고 노드를 골라 **실제 SSH 셸**을 여는 MVP를 완성한다.

재사용 자산: A의 주입형/플랫폼분기 자격 해석, A의 다중키 순회, B1 `CitadelSession`(iOS SSH), B2a 크로스플랫폼 `TerminalSession`/`TerminalSessionStore`/`HostKeyGate`, iOS Keychain `CredentialStore`, `APIClient.listDevices()`, SwiftTerm iOS `TerminalView`.

**목표 (B2b MVP):**
- iOS 온보딩/설정: **서버 URL 수동 입력** + **SSH username** + **SSH 개인키 임포트(붙여넣기/Files) → Keychain**.
- iOS **디바이스 목록**(REST) → 탭 → **터미널**(SwiftTerm iOS + CitadelSession) + **호스트키 TOFU 시트**.
- `PlaceholderView`를 실제 `NavigationStack` 앱으로 교체.
- macOS 회귀 0(공유 파일 iOS 분기 추가가 mac을 안 깨뜨림).
- iOS Simulator에서 UI 빌드·부팅·흐름 검증. 실기기 서명·실 노드 SSH는 사용자 최종 단계.

**비목표 (이후):** Bonjour 디스커버리, 온디바이스 키 생성, 다중 세션 탭, 스크롤백/검색, 실기기 서명 자동화, iOS 클립보드(UIPasteboard) 완성.

## 2. 아키텍처

### 2.1 iOS 자격 공급 (기존 흐름 재사용)
- `CredentialStore`(Keychain)에 Key 추가: `sshPrivateKeyPEM`, 그리고 username·port는 `UserDefaults`(`sshUsername`, 기존 `serverURL`과 동일 방식; port 기본 22).
- `TerminalSession.defaultCredentials()`에 **iOS 분기** 추가:
  ```
  #if os(macOS)   // 기존: config.yaml + orderedKeyPairs(~/.ssh)
  #else           // iOS: Keychain PEM + 설정 username
    let pem = CredentialStore.shared.get(.sshPrivateKeyPEM)   // String(PEM)
    let user = UserDefaults.standard.string(forKey: "sshUsername") ?? "root"
    return pem.isEmpty
      ? SSHCredentials(user: user, port: 22, keys: [])
      : SSHCredentials(user: user, port: 22,
          keys: [ResolvedKey(path: "keychain", pem: Data(pem.utf8), algorithm: "imported")])
  #endif
  ```
- 이로써 iOS도 기존 `TerminalSessionStore.open(device:)` → `TerminalSession`(Citadel) → 다중키 루프(단일 임포트 키) → TOFU 흐름을 **코드 재사용**한다. 키 미임포트면 keys=[] → 기존 "키 없음" 에러 경로(사용자에게 임포트 유도).

### 2.2 iOS 터미널 뷰 (mac 미러링)
- 신규 `HydraiOS/Terminal/SwiftTermRepresentableiOS.swift`: `UIViewRepresentable`이 SwiftTerm의 iOS `TerminalView`를 래핑. mac `SwiftTermRepresentable`(NSViewRepresentable)과 동일 배선:
  - `session.onOutput = { view.feed(byteArray:) }`
  - Coordinator: `TerminalViewDelegate` — `send(source:data:)` → `session.send(Data(data))`, `sizeChanged` → `session.resize(cols:rows:)`, 나머지 델리게이트 메서드는 빈 구현(mac과 동일).
  - 입력 지연/스레딩은 mac 패턴(`MainActor.assumeIsolated`) 준용.
- `TerminalScreen`(SwiftUI): `SwiftTermRepresentableiOS(session:)` + 연결 상태/에러 표시 + `.onAppear`에서 `store.open`/`session.connect`, `.onDisappear`에서 close. 호스트키 TOFU는 `session.hostKeyPrompt` 관찰 → `.sheet`/`.alert`로 신뢰/취소(`trustPendingHostKey`/`cancelPendingHostKey`).

### 2.3 디바이스 목록 / 온보딩 / 설정 (SwiftUI)
- `DeviceListScreen`: `APIClient.listDevices()`(async) → `List`(기존 `Device` 모델). pull-to-refresh, 로딩/에러 상태, 각 행 탭 → `TerminalScreen(device:)`. SSH 가능 표시(`sshEnabled`).
- `SettingsScreen`: 서버 URL(`APIClient.setBaseURL`) + SSH username(`UserDefaults sshUsername`) + **키 임포트**(§2.4) 진입.
- `KeyImportScreen`: (a) 붙여넣기 `TextEditor`로 PEM 입력, (b) `.fileImporter`로 키 파일 선택 → 텍스트 로드. 최소 검증(PEM 헤더 `-----BEGIN ... PRIVATE KEY-----` 포함) 후 `CredentialStore.set(.sshPrivateKeyPEM,)`. 현재 로드 상태(있음/없음) 표시·삭제.

### 2.4 iOS 엔트리
- `HydraiOS/App.swift`의 `WindowGroup { PlaceholderView() }`를 `WindowGroup { RootView() }`로 교체. `RootView` = `NavigationStack`(또는 `TabView`)로 디바이스목록 + 설정. `PlaceholderView.swift` 제거 또는 대체.
- iOS 앱은 `TerminalSessionStore`(공유, @MainActor)를 `@StateObject`로 보유.

## 3. 데이터 흐름
```
iPad 앱 → RootView(NavigationStack)
  ├─ SettingsScreen: 서버URL→APIClient, username→UserDefaults, 키 임포트→Keychain
  └─ DeviceListScreen: APIClient.listDevices() → List
        └─ 탭 → TerminalScreen(device)
              → store.open(device) → TerminalSession(defaultCredentials iOS분기=Keychain 키)
              → CitadelSession.connect(다중키 단일) → HostKeyGate → (needsTrust? TOFU 시트)
              → openShell → SwiftTermRepresentableiOS(feed/send/resize)
```

## 4. 에러 처리
- 키 미임포트: TerminalSession가 keys=[] → `.disconnected("SSH 개인키를 찾을 수 없습니다…")`. UI가 이 상태에서 "키 임포트" CTA 노출.
- 서버 URL 미설정/도달불가: `listDevices()` throw → 목록 화면 에러 + 설정 유도.
- 호스트키 unknown/mismatch: A/B2a의 `HostKeyGate` 그대로 — TOFU 시트(신뢰) 또는 차단 메시지.
- iOS known_hosts: 샌드박스 `NSHomeDirectory()/.ssh/known_hosts`(B2a 폴백) — 앱 전용 TOFU 저장소로 정상 동작(사용자 홈 아님, 앱 샌드박스).

## 5. 검증
- **iOS Simulator UI 빌드·부팅**: `xcodegen generate && xcodebuild -scheme HydraiOS -destination 'generic/platform=iOS Simulator' build` 성공 + 시뮬레이터에서 RootView/설정/디바이스목록 화면 렌더(디바이스목록은 mac의 로컬 서버 `http://<LAN-IP>:8080`를 서버URL로 넣으면 실제 조회 가능; 안 되면 화면 흐름·에러상태만 확인).
- **터미널 뷰 계약**: 가능하면 Fake/Scripted 세션으로 `onOutput`/`send`/`resize` 배선 유닛(뷰 로직) 또는 코드 검사. SwiftUI 뷰는 주로 수동/스냅샷 검증.
- **macOS 회귀 0**: `swift test`(77+) + `make hydra-app` green — `defaultCredentials` iOS 분기·CredentialStore 키 추가가 mac을 안 깨뜨림.
- **실 노드 SSH(사용자 최종, 1회)**: 사용자가 실기기에 automatic signing으로 설치 → 서버URL·username·id_ed25519 임포트 → 실제 노드 셸(ed25519 authorized 노드). B1 실노드 스모크와 동급의 사용자 실행 검증.

## 6. 파일 영향
- **신규**: `HydraiOS/RootView.swift`, `HydraiOS/Screens/DeviceListScreen.swift`, `SettingsScreen.swift`, `KeyImportScreen.swift`, `HydraiOS/Terminal/{SwiftTermRepresentableiOS.swift, TerminalScreen.swift}`.
- **수정**: `HydraiOS/App.swift`(RootView), `CredentialStore.swift`(`sshPrivateKeyPEM` Key), `Hydra/Hydra/Services/TerminalSession.swift`(`defaultCredentials` iOS 분기), `Hydra/project.yml`(HydraiOS 소스에 새 iOS 파일 포함 — glob이면 자동), `PlaceholderView.swift` 제거/대체.
- **불변**: mac `Views/**`, `SwiftTermRepresentable`(mac), `Package.swift`, `Makefile`, `CitadelSession`/`SSHSession`, A의 다중키 루프.

## 7. 리스크 / 완화
- **SwiftTerm iOS TerminalView 세부(입력/포커스/키보드)**: mac 배선을 미러링하되 iOS 키보드·`UIScrollView` 특성으로 조정 필요할 수 있음 → 시뮬레이터로 입출력 왕복 확인. (SwiftTerm iOS `TerminalView`는 `feed(byteArray:)`·`terminalDelegate` 동일 제공 확인됨.)
- **`defaultCredentials` iOS 분기가 mac 회귀**: `#if os(macOS)` 분기 불변 유지 + `swift test`로 즉시 확인.
- **키 저장 보안**: PEM을 Keychain(`kSecClassGenericPassword`)에 저장(기존 CredentialStore). 무암호 키 전제(패스프레이즈 프롬프트는 이후).
- **실기기 미검증(시뮬레이터만)**: iOS Simulator는 실 노드 SSH를 LAN으로 테스트 가능하나, 최종 iPad 설치는 서명 필요 → 사용자 단계로 문서화(B2b는 시뮬레이터 빌드·흐름까지 보증).
- **범위 팽창**: MVP 밖(Bonjour/키생성/탭/스크롤백)은 명시적으로 이후. 각 화면은 최소 기능만.
