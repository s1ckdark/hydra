# B2a — iOS 빌드 기반 + 공유 계층 크로스플랫폼화 — 설계

> 상위 목표: Hydra SSH 터미널을 iPad(iOS)에서 동작(하위 B). B2 = **B2a(이 스펙): iOS 앱 타깃 도입 + 공유 서비스 계층 iOS 컴파일** → **B2b(다음 스펙): 디바이스목록·터미널 UIKit UI**.
> 선행: A(다중키), B1(Citadel 백엔드 mac 실증) 머지 완료.

**작성일:** 2026-07-09
**상태:** 설계 승인됨 (사용자 승인 2026-07-09)

---

## 1. 배경 / 문제

현재 Hydra 앱은 **macOS 전용 메뉴바 앱**이다: `@main HydraApp`이 `@NSApplicationDelegateAdaptor` + `MenuBarExtra` + 다중 `WindowGroup`을 쓰고, 터미널 뷰는 AppKit `NSViewRepresentable`. 앱은 SwiftPM executable로 빌드되어 `make hydra-app`으로 패키징된다(xcodeproj 없음).

그러나 **서비스/모델 계층 대부분은 이미 크로스플랫폼**이다(APIClient/WebSocketClient/ServerDiscovery/DeviceIdentity/ClusterSSHConfig/CredentialStore 등 — URLSession/Foundation). iOS 비호환은 UI 파일들(`SwiftTermRepresentable`, `DeviceListView`, 메뉴바 뷰)과 subprocess 기반 macOS 전용 서비스(PYExecutor/EmbeddedServer)뿐이다. `SSHKeyLocator`의 AppKit 사용은 `#if canImport(AppKit)`로 이미 가드됨. B1으로 순수 Swift `CitadelSession`(iOS 가능)도 확보됐다.

B2a는 **iOS 앱 타깃을 처음 도입**하고 공유 계층을 iOS로 컴파일되게 만들어, 최소 iOS 앱이 시뮬레이터에서 빌드·실행됨을 증명한다. 실제 UI(디바이스목록·터미널)와 실기기 서명은 B2b.

## 2. 목표 / 비목표

**목표 (B2a):**
- **xcodegen `project.yml`**로 `Hydra.xcodeproj`를 생성해 새 **iOS 앱 타깃**을 추가. macOS 빌드(`make hydra-app`, SwiftPM)는 **불변**(추가만, 대체 아님).
- 공유 서비스 계층(`TerminalSession`/`TerminalSessionStore`/`HostKeyDecision` 등)을 iOS로 컴파일되게 **un-gate**하되, libssh2(`SSHTransportMac`) 참조는 `#if os(macOS)`로 좁히고 iOS는 `CitadelSession`만 사용.
- iOS 타깃이 최소 `@main` 엔트리 + 플레이스홀더 화면으로 **iOS Simulator 빌드·부팅** 성공(B1에서 미룬 iOS 실컴파일 최초 검증).
- macOS 회귀 0: `swift test` 전체 통과, `make hydra-app` 빌드 유지.

**비목표 (B2b 또는 별도):**
- 실제 iOS UI(디바이스 목록/터미널 뷰), SwiftTerm iOS 뷰 연결 — **B2b**.
- 실기기 서명/프로비저닝/TestFlight — **B2b**(project.yml은 automatic signing + placeholder 팀만).
- macOS 앱을 xcodeproj로 이전 — 안 함(SwiftPM 유지).
- PYExecutor/EmbeddedServer(파이썬 콘솔·임베디드 서버)의 iOS 이식 — 불가(sandbox), 범위 밖.

## 3. 아키텍처

### 3.1 빌드: xcodegen iOS 타깃 (mac은 SwiftPM 유지)
- 저장소에 `Hydra/project.yml`(xcodegen) 커밋 → `xcodegen generate`로 `Hydra/Hydra.xcodeproj` 생성(생성물은 gitignore, `project.yml`이 진실원). xcodegen은 이미 설치됨.
- iOS 앱 타깃(`HydraiOS`, bundle id 예 `com.hydra.ios`, platform iOS 17):
  - **로컬 패키지 의존**: `Packages/TerminalCore`의 `SSHTransportCitadel`/`SSHTransport`/`KnownHosts` 제품 + 원격 `SwiftTerm`(iOS). **libssh2(`SSHTransportMac`)·AppKit 링크 없음.**
  - **소스 include**: `Hydra/Hydra/`의 크로스플랫폼 서비스·모델·코어(§3.2 목록). **exclude**: `Hydra/Hydra/HydraApp.swift`, `Hydra/Hydra/Views/**`(전체 — macOS UI), 그리고 iOS 불가 서비스(`PYExecutor`, `EmbeddedServer`, 및 macOS 전용 프레임워크를 무가드 사용하는 서비스).
  - iOS 전용 엔트리 `HydraiOS/App.swift`(`@main`, `WindowGroup { PlaceholderView() }` — 메뉴바/NSApplicationDelegate 없음) + `Info.plist`.
- macOS는 기존 SwiftPM `Package.swift` + `make hydra-app` 그대로. project.yml에 macOS 타깃은 넣지 않는다(이중 빌드 회피, mac 리스크 0).

### 3.2 공유 계층 un-gate
- `Hydra/Hydra/Services/TerminalSession.swift`, `TerminalSessionStore.swift`, `HostKeyDecision.swift`의 파일 전체 `#if os(macOS)` 래핑을 제거해 iOS에서도 컴파일.
- `TerminalSessionStore`: `import SSHTransportMac`와 `LibSSH2Session()` 참조를 `#if os(macOS)`로 좁힌다. `defaultBackend()`:
  ```
  #if os(macOS)
    env==citadel ? CitadelSession() : LibSSH2Session()
  #else
    CitadelSession()          // iOS: 순수 Swift만
  #endif
  ```
- `TerminalSession`/`HostKeyDecision`은 `SSHTransport`/`KnownHosts`(크로스플랫폼)만 쓰므로 un-gate로 충분. `NSUserName()`(Foundation, iOS 가능)·`SSHKeyLocator`(AppKit 가드됨)·`ClusterSSHConfig`(크로스) 모두 iOS 안전.
- un-gate 후 **macOS 빌드/테스트가 여전히 green**이어야 한다(게이팅 변경이 mac을 깨지 않음). 이게 이 작업의 주 회귀 리스크.

### 3.3 iOS 타깃 소스 선정 원칙
iOS 타깃은 **디바이스목록+터미널에 필요한 크로스플랫폼 소스만** 포함한다(컴파일 구동 방식으로 확정): 포함 후보 = 네트워킹/모델(APIClient, WebSocketClient, ServerDiscovery, DeviceIdentity, DevicePreferences, ClusterSSHConfig, CredentialStore, SSHKeyLocator, ChatContextProvider, SavedTaskStore, OfflineQueue, MetricsReporter, PreambleBuilder, 모델 타입들) + 터미널 오케스트레이션(TerminalSession/Store/HostKeyDecision). **제외** = 모든 `Views/**`, `HydraApp.swift`/`AppDelegate`, `PYExecutor`, `EmbeddedServer`, 그리고 컴파일 시 macOS 전용 API를 무가드 사용해 실패하는 서비스(그런 파일은 제외하거나 필요한 최소만 `#if os` 가드). 최종 목록은 플랜에서 컴파일을 돌려 확정한다.

## 4. 데이터 흐름 (B2a 한정)
```
iOS 앱 부팅 → HydraiOS/App.swift @main → WindowGroup → PlaceholderView("Hydra iOS — B2b에서 UI")
  (공유 서비스 계층은 링크·컴파일되지만 B2a에선 화면에 안 씀 — 컴파일 가능성 증명이 목적)
```

## 5. 검증
- **iOS Simulator 빌드**: `cd Hydra && xcodegen generate && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'generic/platform=iOS Simulator' build` → **BUILD SUCCEEDED**. 이게 B1에서 미룬 iOS 실컴파일의 최초 실증.
- **부팅 스모크(선택)**: 시뮬레이터에 설치·실행해 플레이스홀더 화면 뜸(가능하면 자동, 어려우면 수동 문서화).
- **macOS 회귀**: `cd Hydra && swift test` 전체 통과(77+), `make hydra-app` 빌드 성공 — un-gate가 mac을 안 깨뜨림.
- 신규 유닛 테스트: un-gate된 `defaultBackend()`의 iOS 분기는 `#if !os(macOS)` 경로라 mac 테스트에선 직접 못 탄다 — 대신 mac에서 `#if os(macOS)` 분기 불변을 기존 계약 테스트로 확인하고, iOS 분기는 컴파일+빌드로 검증(별 유닛 불필요, YAGNI).

## 6. 파일 영향
- **신규**: `Hydra/project.yml`(xcodegen), `Hydra/HydraiOS/App.swift`, `Hydra/HydraiOS/PlaceholderView.swift`, `Hydra/HydraiOS/Info.plist`, `.gitignore`에 `Hydra/Hydra.xcodeproj` 추가.
- **수정**: `Hydra/Hydra/Services/TerminalSession.swift`(un-gate), `TerminalSessionStore.swift`(un-gate + libssh2 `#if os(macOS)`), `HostKeyDecision.swift`(un-gate).
- **불변**: `Package.swift`(양쪽 — SwiftPM mac 빌드 유지), `Makefile`, 모든 `Views/**`, `LibSSH2Session`/`CitadelSession`/`SSHSession`, `SSHKeyLocator`(이미 가드).

## 7. 리스크 / 완화
- **un-gate가 macOS 빌드를 깨뜨림**: 주 리스크. `#if os(macOS)`를 제거하되 libssh2 참조만 좁히는 최소 변경 + 매 단계 `swift test`(mac)로 즉시 검증.
- **xcodegen 소스 include/exclude 표류**: iOS 컴파일을 반복 구동해 실패 파일을 제외/가드로 확정(플랜이 컴파일 구동 방식으로 진행). 무가드 macOS-API 서비스는 iOS 타깃에서 제외.
- **xcodeproj 생성물 관리**: `.xcodeproj`는 gitignore, `project.yml`만 커밋 → 재현 가능·머지 충돌 없음.
- **SwiftTerm iOS 제품**: 원격 SwiftTerm 패키지가 iOS 라이브러리를 제공하는지 확인(iOS/SwiftUITerminalView 존재 확인됨). B2a는 링크만; 실제 뷰 연결은 B2b.
- **이중 빌드 시스템(SwiftPM mac + xcodeproj iOS)**: 의도적 트레이드오프 — mac 앱 무리팩터가 우선. 향후 통합은 별도 결정.
