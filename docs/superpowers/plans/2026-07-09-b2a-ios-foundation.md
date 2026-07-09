# B2a — iOS 빌드 기반 + 공유 계층 크로스플랫폼화 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 공유 서비스 계층을 iOS로 컴파일되게 un-gate하고, xcodegen로 iOS 앱 타깃을 도입해 최소 iOS 앱이 iOS Simulator에서 빌드·부팅됨을 증명한다. macOS 빌드/테스트는 불변.

**Architecture:** `TerminalSession`/`TerminalSessionStore`/`HostKeyDecision`의 `#if os(macOS)` 전체 래핑을 제거하고 libssh2 참조만 macOS로 좁힌다(iOS는 Citadel). xcodegen `project.yml`이 iOS 앱 타깃을 정의하며, macOS 전용 UI(`Views/**`, `HydraApp.swift`)와 iOS 불가 서비스를 제외한 공유 소스를 glob한다. mac은 기존 SwiftPM(`make hydra-app`) 그대로.

**Tech Stack:** Swift 5 language mode, xcodegen(설치됨), xcodebuild(iOS Simulator), SwiftPM(mac), Citadel(iOS SSH).

## Global Constraints
- **macOS 회귀 0**: 매 관련 단계마다 `cd Hydra && swift test`(mac, 77 tests/1 skip 기대) 통과. un-gate가 mac을 깨면 안 됨.
- **불변 파일**: `Package.swift`(양쪽), `Makefile`, `Views/**`, `HydraApp.swift`, `CitadelSession`/`LibSSH2Session`/`SSHSession`, `SSHKeyLocator`(이미 AppKit 가드됨).
- iOS 타깃은 **libssh2(`SSHTransportMac`)를 링크하지 않는다**(iOS는 CitadelSession만).
- 생성된 `Hydra.xcodeproj`는 커밋하지 않는다(gitignore); `project.yml`이 진실원.
- iOS 타깃 소스에서 macOS 전용 API를 만나면 **로직을 iOS에서 지우지 말고**, 그 파일을 타깃에서 제외하거나 macOS-전용 부분만 `#if os(macOS)`로 가드한다(iOS가 필요로 하는 로직은 보존).

---

### Task 1: 공유 계층 un-gate (macOS green 유지)

**Files:**
- Modify: `Hydra/Hydra/Services/TerminalSession.swift`, `Hydra/Hydra/Services/HostKeyDecision.swift`, `Hydra/Hydra/Services/TerminalSessionStore.swift`

**Interfaces:**
- Produces: `TerminalSession`/`HostKeyGate`/`HostKeyDecision`/`TerminalSessionStore`가 iOS에서도 컴파일 가능(플랫폼 무관). `TerminalSessionStore.defaultBackend()`는 iOS에서 `CitadelSession`을, macOS에서 env 스위치(libssh2 기본)를 반환.

- [ ] **Step 1: TerminalSession.swift un-gate**

`Hydra/Hydra/Services/TerminalSession.swift`의 **첫 줄** `#if os(macOS)`와 **마지막 줄** `#endif`를 제거(그 사이 코드는 그대로). 결과 상단은:
```swift
import Foundation
import SSHTransport
import KnownHosts

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
```

- [ ] **Step 2: HostKeyDecision.swift un-gate**

`Hydra/Hydra/Services/HostKeyDecision.swift`의 첫 줄 `#if os(macOS)`와 마지막 줄 `#endif` 제거. 결과 상단:
```swift
import Foundation
import SSHTransport
import KnownHosts

enum HostKeyDecision: Equatable {
```

- [ ] **Step 3: TerminalSessionStore.swift un-gate + libssh2를 macOS로 좁히기**

(3a) 상단 래핑 제거 + `import SSHTransportMac`만 조건부로:
```swift
import Foundation
import SSHTransport
#if os(macOS)
import SSHTransportMac
#endif
import SSHTransportCitadel

@MainActor
final class TerminalSessionStore: ObservableObject {
```
(3b) 파일 **마지막 줄** `#endif`(파일 전체 래핑용) 제거.
(3c) `defaultBackend()`를 플랫폼 조건부로 교체:
```swift
    /// libssh2 by default on macOS (rsa-sha2 + every key); `HYDRA_SSH_BACKEND=citadel`
    /// selects the pure-Swift Citadel backend there. iOS has no libssh2, so it always
    /// uses Citadel.
    ///
    /// `nonisolated`: this store is `@MainActor`, but `defaultBackend()` is called from
    /// the plain (non-isolated) `sessionFactory` closure type in `init`'s default arg,
    /// and from synchronous XCTest methods. It only reads the environment and constructs
    /// a backend, touching no main-actor state — do NOT drop this annotation.
    nonisolated static func defaultBackend() -> SSHSession {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["HYDRA_SSH_BACKEND"]?.lowercased() == "citadel" {
            return CitadelSession()
        }
        return LibSSH2Session()
        #else
        return CitadelSession()
        #endif
    }
```

- [ ] **Step 4: macOS 빌드 + 전체 테스트 회귀 확인**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -6`
Expected: 빌드 성공 + `Executed 77 tests, with 1 test skipped and 0 failures`. un-gate가 mac을 안 깨뜨림.

- [ ] **Step 5: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Hydra/Services/TerminalSession.swift Hydra/Hydra/Services/HostKeyDecision.swift Hydra/Hydra/Services/TerminalSessionStore.swift
git commit -m "refactor(terminal): un-gate session orchestration for iOS (Citadel-only backend)

Remove the file-wide #if os(macOS) from TerminalSession/HostKeyDecision/
TerminalSessionStore so they compile on iOS; keep libssh2 (SSHTransportMac)
macOS-gated and have iOS fall back to CitadelSession in defaultBackend().
No macOS behavior change — full suite still green."
```

---

### Task 2: xcodegen iOS 타깃 + iOS Simulator 빌드 green

**Files:**
- Create: `Hydra/project.yml`, `Hydra/HydraiOS/App.swift`, `Hydra/HydraiOS/PlaceholderView.swift`
- Modify: `.gitignore` (add `Hydra/Hydra.xcodeproj`)

**Interfaces:**
- Consumes: un-gated services (Task 1), `SSHTransportCitadel` (B1).
- Produces: `Hydra.xcodeproj`(생성물) with scheme `HydraiOS`가 iOS Simulator로 빌드됨.

- [ ] **Step 1: iOS 엔트리 파일 작성**

`Hydra/HydraiOS/App.swift`:
```swift
import SwiftUI

@main
struct HydraiOSApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}
```

`Hydra/HydraiOS/PlaceholderView.swift`:
```swift
import SwiftUI

/// B2a placeholder. The shared service layer (networking, terminal orchestration,
/// Citadel SSH) is linked and compiled into this target; the real device-list and
/// terminal UI arrive in sub-project B2b.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
            Text("Hydra iOS")
                .font(.title.bold())
            Text("UI arrives in B2b")
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: `.gitignore`에 생성물 추가**

`.gitignore`에 한 줄 추가(중첩 build 무시 라인 근처):
```
# xcodegen output — project.yml is the source of truth
Hydra/Hydra.xcodeproj/
```

- [ ] **Step 3: `Hydra/project.yml` 작성 (초기 include/exclude)**

```yaml
name: Hydra
options:
  bundleIdPrefix: com.hydra
  deploymentTarget:
    iOS: "17.0"
packages:
  TerminalCore:
    path: Packages/TerminalCore
  SwiftTerm:
    url: https://github.com/s1ckdark/SwiftTerm
    revision: 54b436a6231976fa64d7c3859d0b197a6ccfcb91
targets:
  HydraiOS:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: HydraiOS
      - path: Hydra/Models
      - path: Hydra/State
      - path: Hydra/Services
        excludes:
          - "PYExecutor.swift"        # subprocess — macOS only
          - "EmbeddedServer.swift"    # embedded hydra-server — macOS only
          - "MetricsSampler.swift"    # host metric sampling — macOS only
          - "CapabilityReporter.swift" # host GPU capability — macOS only
    dependencies:
      - package: TerminalCore
        product: SSHTransportCitadel
      - package: TerminalCore
        product: SSHTransport
      - package: TerminalCore
        product: KnownHosts
      - package: SwiftTerm
        product: SwiftTerm
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.hydra.ios
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2"
        CODE_SIGNING_ALLOWED: NO
```

> `ViewModels/`·`Views/`·`HydraApp.swift`·`Assets.xcassets`는 의도적으로 미포함(UI 계층 = B2b). 위 exclude는 **초기값**이며 Step 5에서 컴파일 에러에 따라 조정한다.

- [ ] **Step 4: 프로젝트 생성**

Run: `cd /Users/dave/iWorks/hydra/Hydra && xcodegen generate 2>&1 | tail -5`
Expected: `Created project at .../Hydra.xcodeproj`.

- [ ] **Step 5: iOS Simulator 빌드 (컴파일 구동 반복)**

Run: `cd /Users/dave/iWorks/hydra/Hydra && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40`
Expected 최종: `** BUILD SUCCEEDED **`.
- 컴파일 에러가 나면 원인별로:
  - 특정 서비스가 macOS 전용 프레임워크(IOKit/AppKit/Cocoa/Process 등)를 **무가드 사용** → 그 파일을 `project.yml`의 `excludes`에 추가(iOS 불필요 기능이면) 또는 해당 API만 `#if os(macOS)`로 가드(iOS도 필요한 파일이면). **iOS가 쓰는 로직은 지우지 말 것.**
  - 어떤 서비스가 `Views/ViewModels` 타입을 참조 → 그 서비스도 exclude(B2b에서 iOS판 결합).
  - `project.yml` 수정 후 `xcodegen generate` 다시 → 빌드 재시도.
  - 조정한 exclude/가드 목록과 이유를 리포트에 기록.

- [ ] **Step 6: macOS 회귀 재확인 (un-gate/가드가 mac 안 깨뜨림)**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -4`
Expected: 빌드 성공 + 77 tests/1 skip/0 fail.

- [ ] **Step 7: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/project.yml Hydra/HydraiOS/App.swift Hydra/HydraiOS/PlaceholderView.swift .gitignore
# 컴파일 구동에서 소스 파일에 #if os(macOS) 가드를 추가했다면 그 파일들도 add
git add -A Hydra/Hydra/Services 2>/dev/null || true
git commit -m "build(ios): xcodegen iOS app target — shared service layer compiles for iOS

Add project.yml (source of truth; generated .xcodeproj gitignored), a minimal
HydraiOS @main entry + placeholder, and link Citadel/SSHTransport/KnownHosts/
SwiftTerm. iOS Simulator build succeeds — the first real iOS compilation of the
shared layer. macOS-only UI (Views/**, HydraApp) and subprocess services
excluded. Device-list/terminal UI + signing are B2b."
```

---

### Task 3: macOS 회귀 최종 + iOS 부팅 스모크 + 워크플로 문서

**Files:**
- Create/Modify: `Hydra/HydraiOS/README.md` (create)

**Interfaces:** 없음(검증·문서 태스크).

- [ ] **Step 1: macOS 앱 빌드 회귀**

Run: `cd /Users/dave/iWorks/hydra && make hydra-app 2>&1 | tail -6`
Expected: macOS `.app` 빌드 성공(un-gate·xcodegen 도입이 mac 패키징 안 깨뜨림).

- [ ] **Step 2: iOS 시뮬레이터 부팅 스모크**

```bash
cd /Users/dave/iWorks/hydra/Hydra
SIM=$(xcrun simctl list devices available | grep -m1 "iPad" | grep -oE "[0-9A-F-]{36}") || true
xcodebuild -project Hydra.xcodeproj -scheme HydraiOS \
  -destination "platform=iOS Simulator,name=iPad (10th generation)" \
  -derivedDataPath build/ios build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8
APP=$(find build/ios -name "HydraiOS.app" -type d | head -1)
xcrun simctl boot "iPad (10th generation)" 2>/dev/null || true
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.hydra.ios && echo "LAUNCH OK"
```
Expected: 앱이 설치·실행되어 플레이스홀더가 뜸(`LAUNCH OK`). 시뮬레이터 이름은 `xcrun simctl list devices available`로 확인해 존재하는 iPad로 맞춘다. 부팅이 환경상 불가하면 그 사실을 리포트에 남기고 Step 1의 빌드 성공을 근거로 대체(컨트롤러 에스컬레이션).

- [ ] **Step 3: 워크플로 문서** — `Hydra/HydraiOS/README.md`:

```markdown
# Hydra iOS (B2a)

Minimal iOS app target introduced in sub-project B2a. Shares the cross-platform
service layer with the macOS app; the device-list and terminal UI arrive in B2b.

## Build (simulator)
    cd Hydra
    xcodegen generate            # regenerate Hydra.xcodeproj from project.yml
    xcodebuild -project Hydra.xcodeproj -scheme HydraiOS \
      -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

## Notes
- `project.yml` is the source of truth; `Hydra.xcodeproj` is generated (gitignored).
- iOS uses the pure-Swift Citadel SSH backend (libssh2 is macOS-only).
- macOS build is unchanged: `make hydra-app` (SwiftPM).
- Device install / code signing: B2b.
```

- [ ] **Step 4: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/HydraiOS/README.md
git commit -m "docs(ios): B2a build/boot workflow + confirm macOS regression clean"
```

---

## Self-Review 체크
- **스펙 커버리지**: un-gate(T1) / xcodegen iOS 타깃 + iOS Simulator 빌드(T2) / mac 회귀 + 부팅 스모크 + 문서(T3) — 스펙 §3~§5 전부 커버. iOS defaultBackend 분기는 컴파일+빌드로 검증(스펙 §5, 별 유닛 불필요).
- **Placeholder**: 없음. project.yml/엔트리/명령 전부 구체. Task2 Step5의 exclude 조정은 "컴파일 구동" 명시적 절차(iOS 포팅 본질).
- **타입 일관성**: `defaultBackend()`(T1) ↔ B1 계약 테스트 동일 시그니처. `SSHTransportCitadel`/`SwiftTerm` 제품명 B1/Package.swift와 일치.
- **리스크**: T1의 un-gate가 유일한 mac 회귀 리스크 → T1 Step4·T2 Step6·T3 Step1에서 삼중 확인.

## Execution Handoff
계획 저장 완료. 사용자 글로벌 기본값([[plan-execution-default]])에 따라 **subagent-driven-development**로 바로 실행한다.
