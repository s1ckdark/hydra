# 터미널 색상 테마 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** terminal(IpadTerminal)의 5종 터미널 색상 프리셋을 hydra macOS·iOS 터미널에 이식하고, 설정에서 고르면 열린 세션에 즉시 반영한다.

**Architecture:** 플랫폼에 의존하지 않는 값 타입 `TerminalColorScheme`(hex `UInt32`)을 `Hydra/Theme/`에 두어 macOS(SwiftPM `Hydra` 타겟)와 iOS(XcodeGen `HydraiOS`가 `Hydra/Theme` 포함)가 함께 쓴다. SwiftTerm 적용 코드는 `canImport(SwiftTerm)` 확장으로 분리한다. 선택값은 `@AppStorage("terminalColorScheme")`에 저장하고, 터미널 화면에서 representable로 전달한다. representable의 `update*View`는 적용된 id가 바뀔 때만 팔레트를 다시 설치한다.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftTerm(로컬 벤더링 `Hydra/Packages/SwiftTerm`), XCTest, XcodeGen

**Spec:** `docs/superpowers/specs/2026-09-22-terminal-color-scheme-design.md`

## Global Constraints

- 모든 경로는 `hydra/Hydra/` 기준이다 (git 루트는 `hydra/`).
- 프리셋 5종과 id: `default-dark`, `solarized-dark`, `solarized-light`, `dracula`, `nord`. 색 값은 terminal `App/TerminalTheme.swift` 그대로 쓴다.
- 기본값과 알 수 없는 id의 폴백은 `default-dark`. Default Dark 커서는 `0x0A84FF`.
- 저장 키는 `terminalColorScheme`.
- SwiftUI와 SwiftTerm을 함께 import하는 파일에서는 반드시 `SwiftTerm.Color`로 쓴다 (SwiftUI `Color`와 이름 충돌).
- macOS 터미널 탭(`TerminalView.swift`)에서는 SwiftUI `Button`과 `.task`를 쓰지 않는다 (파일 상단의 macOS 26 크래시 완화 규칙).
- `Hydra.xcodeproj`는 gitignore된 생성물이다. 새 파일을 추가하면 `xcodegen generate`를 실행한다.
- 커밋 메시지 끝에 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`를 붙인다.

## File Structure

| 파일 | 역할 |
|---|---|
| Create `Hydra/Theme/TerminalColorScheme.swift` | 값 타입, 프리셋, `find(id:)` (Foundation만 사용) |
| Create `Hydra/Theme/TerminalColorScheme+SwiftTerm.swift` | hex → `SwiftTerm.Color`/플랫폼 색 변환, `apply(to:)` |
| Create `Hydra/Theme/TerminalColorSchemeOptions.swift` | 공유 SwiftUI 선택 목록과 미리보기 행 |
| Create `Tests/HydraTests/TerminalColorSchemeTests.swift` | 모델·변환 단위 테스트 |
| Modify `Hydra/Views/Terminal/SwiftTermRepresentable.swift` | macOS: `scheme` 파라미터, 적용 |
| Modify `Hydra/Views/Terminal/TerminalView.swift` (`TerminalSessionPane`) | macOS: `@AppStorage` 읽어서 전달 |
| Modify `HydraiOS/Terminal/SwiftTermRepresentableiOS.swift` | iOS: `scheme` 파라미터, 적용, 컨테이너 배경 |
| Modify `HydraiOS/Terminal/TerminalScreen.swift` | iOS: `@AppStorage` 읽어서 전달 |
| Modify `HydraiOS/Screens/SettingsScreen.swift` | iOS: "터미널" 섹션과 테마 화면 링크 |
| Modify `HydraiOS/Resources/{ko,en}.lproj/Localizable.strings` | 새 문자열 |
| Modify `Hydra/Views/Settings/AppearanceSettingsTab.swift` | macOS: Terminal theme 섹션 |

---

### Task 1: TerminalColorScheme 모델 + SwiftTerm 변환

**Files:**
- Create: `Hydra/Theme/TerminalColorScheme.swift`
- Create: `Hydra/Theme/TerminalColorScheme+SwiftTerm.swift`
- Test: `Tests/HydraTests/TerminalColorSchemeTests.swift`

**Interfaces:**
- Produces:
  - `struct TerminalColorScheme: Identifiable, Equatable { static let storageKey: String; let id, displayName: String; let background, foreground, cursor: UInt32; let ansi: [UInt32] }`
  - `static let presets: [TerminalColorScheme]`, `static let defaultDark`, `static func find(id: String) -> TerminalColorScheme`
  - `static func rgbComponents(_ hex: UInt32) -> (r: UInt8, g: UInt8, b: UInt8)`
  - (`canImport(SwiftTerm)`) `static func swiftTermColor(_ hex: UInt32) -> SwiftTerm.Color`, `func swiftTermPalette() -> [SwiftTerm.Color]`, `static func platformColor(_ hex: UInt32) -> UIColor/NSColor` (typealias `TerminalPlatformColor`), `func apply(to view: SwiftTerm.TerminalView)`

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/HydraTests/TerminalColorSchemeTests.swift`

```swift
import XCTest
@testable import Hydra

final class TerminalColorSchemeTests: XCTestCase {
    func testPresetsHaveSixteenANSIColors() {
        for scheme in TerminalColorScheme.presets {
            XCTAssertEqual(scheme.ansi.count, 16, scheme.id)
        }
    }

    func testPresetIDsAreUnique() {
        let ids = TerminalColorScheme.presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["default-dark", "solarized-dark", "solarized-light", "dracula", "nord"])
    }

    func testFindReturnsPresetOrFallsBackToDefaultDark() {
        for scheme in TerminalColorScheme.presets {
            XCTAssertEqual(TerminalColorScheme.find(id: scheme.id), scheme)
        }
        XCTAssertEqual(TerminalColorScheme.find(id: "nope"), .defaultDark)
        XCTAssertEqual(TerminalColorScheme.find(id: ""), .defaultDark)
    }

    func testRGBComponents() {
        let c = TerminalColorScheme.rgbComponents(0x12AB7F)
        XCTAssertEqual(c.r, 0x12); XCTAssertEqual(c.g, 0xAB); XCTAssertEqual(c.b, 0x7F)
    }

    func testSwiftTermColorScalesEightBitToSixteenBit() {
        let red = TerminalColorScheme.swiftTermColor(0xFF0000)
        XCTAssertEqual(red.red, 65535); XCTAssertEqual(red.green, 0); XCTAssertEqual(red.blue, 0)
        let mid = TerminalColorScheme.swiftTermColor(0x000180)
        XCTAssertEqual(mid.green, 257); XCTAssertEqual(mid.blue, 0x80 * 257)
    }

    func testPaletteMatchesANSIOrder() {
        let scheme = TerminalColorScheme.dracula
        let palette = scheme.swiftTermPalette()
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(palette[1].red, 0xFF * 257)   // 0xFF5555
        XCTAssertEqual(palette[1].green, 0x55 * 257)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter TerminalColorSchemeTests 2>&1 | tail -20`
Expected: 컴파일 실패 `cannot find 'TerminalColorScheme' in scope`

- [ ] **Step 3: 모델 구현** — `Hydra/Theme/TerminalColorScheme.swift`

```swift
import Foundation

/// SwiftTerm 그리드 색상 프리셋. 색은 플랫폼 무관하게 `0xRRGGBB`로 보관하고,
/// UIKit/AppKit/SwiftTerm 변환은 `TerminalColorScheme+SwiftTerm.swift`에서 한다.
/// 앱 외관(`AppTheme`)과는 독립 — 터미널만 칠한다.
struct TerminalColorScheme: Identifiable, Equatable {
    static let storageKey = "terminalColorScheme"

    let id: String
    let displayName: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    /// 16개, SwiftTerm 순서: 0–7 normal(black, red, green, yellow, blue, magenta, cyan, white), 8–15 bright.
    let ansi: [UInt32]

    static let presets: [TerminalColorScheme] = [defaultDark, solarizedDark, solarizedLight, dracula, nord]

    static func find(id: String) -> TerminalColorScheme {
        presets.first { $0.id == id } ?? defaultDark
    }

    static func rgbComponents(_ hex: UInt32) -> (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }
}

// MARK: - Presets (terminal/App/TerminalTheme.swift에서 이식)

extension TerminalColorScheme {
    static let defaultDark = TerminalColorScheme(
        id: "default-dark", displayName: "Default Dark",
        background: 0x000000, foreground: 0xD7D7CF, cursor: 0x0A84FF,
        ansi: [0x2E3436, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
               0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC])

    static let solarizedDark = TerminalColorScheme(
        id: "solarized-dark", displayName: "Solarized Dark",
        background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])

    static let solarizedLight = TerminalColorScheme(
        id: "solarized-light", displayName: "Solarized Light",
        background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x586E75,
        ansi: [0xEEE8D5, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0x073642,
               0xFDF6E3, 0xCB4B16, 0x93A1A1, 0x839496, 0x657B83, 0x6C71C4, 0x586E75, 0x002B36])

    static let dracula = TerminalColorScheme(
        id: "dracula", displayName: "Dracula",
        background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xFF79C6,
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])

    static let nord = TerminalColorScheme(
        id: "nord", displayName: "Nord",
        background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0x88C0D0,
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])
}
```

- [ ] **Step 4: SwiftTerm 변환 구현** — `Hydra/Theme/TerminalColorScheme+SwiftTerm.swift`

```swift
#if canImport(SwiftTerm)
import SwiftTerm
#if canImport(UIKit)
import UIKit
typealias TerminalPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias TerminalPlatformColor = NSColor
#endif

extension TerminalColorScheme {
    /// SwiftTerm 채널은 16비트 — 8비트 값에 257을 곱해 0xFF → 0xFFFF로 맞춘다.
    static func swiftTermColor(_ hex: UInt32) -> SwiftTerm.Color {
        let c = rgbComponents(hex)
        return SwiftTerm.Color(red: UInt16(c.r) * 257, green: UInt16(c.g) * 257, blue: UInt16(c.b) * 257)
    }

    func swiftTermPalette() -> [SwiftTerm.Color] { ansi.map(Self.swiftTermColor) }

    static func platformColor(_ hex: UInt32) -> TerminalPlatformColor {
        let c = rgbComponents(hex)
        return TerminalPlatformColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                     blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// ANSI 팔레트 + 기본 전경/배경 + 커서. 이미 출력된 셀도 SwiftTerm이 다시 그린다.
    func apply(to view: SwiftTerm.TerminalView) {
        view.installColors(swiftTermPalette())
        view.nativeForegroundColor = Self.platformColor(foreground)
        view.nativeBackgroundColor = Self.platformColor(background)
        view.caretColor = Self.platformColor(cursor)
    }
}
#endif
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `cd Hydra && swift test --filter TerminalColorSchemeTests 2>&1 | tail -20`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Hydra/Hydra/Theme/TerminalColorScheme.swift Hydra/Hydra/Theme/TerminalColorScheme+SwiftTerm.swift Hydra/Tests/HydraTests/TerminalColorSchemeTests.swift
git commit -m "feat(terminal): TerminalColorScheme 프리셋 5종 + SwiftTerm 변환"
```

---

### Task 2: 터미널 뷰에 테마 적용 (macOS + iOS)

**Files:**
- Modify: `Hydra/Views/Terminal/SwiftTermRepresentable.swift`
- Modify: `Hydra/Views/Terminal/TerminalView.swift` (`TerminalSessionPane`, 172행 근처)
- Modify: `HydraiOS/Terminal/SwiftTermRepresentableiOS.swift`
- Modify: `HydraiOS/Terminal/TerminalScreen.swift` (31행 근처)

**Interfaces:**
- Consumes: `TerminalColorScheme.find(id:)`, `.storageKey`, `.apply(to:)`, `.platformColor(_:)`
- Produces: `SwiftTermRepresentable(session:scheme:)`, `SwiftTermRepresentableiOS(session:scheme:)`. `scheme`은 기본값이 `.defaultDark`라 기존 호출도 컴파일된다.

- [ ] **Step 1: macOS representable** — `SwiftTermRepresentable`에 다음을 추가한다.

```swift
    let session: TerminalSession
    var scheme: TerminalColorScheme = .defaultDark
```
`makeNSView`에서 `return view` 직전에 추가:
```swift
        applyScheme(to: view, coordinator: context.coordinator)
```
`updateNSView` 본문:
```swift
    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        applyScheme(to: nsView, coordinator: context.coordinator)
    }

    /// SwiftUI는 update를 자주 부른다 — id가 바뀔 때만 팔레트를 다시 설치한다.
    private func applyScheme(to view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        guard coordinator.appliedSchemeID != scheme.id else { return }
        scheme.apply(to: view)
        coordinator.appliedSchemeID = scheme.id
    }
```
`Coordinator`에 `var appliedSchemeID: String?`를 추가한다.

- [ ] **Step 2: macOS 화면 연결** — `TerminalSessionPane`에 추가:

```swift
    @AppStorage(TerminalColorScheme.storageKey) private var schemeID = TerminalColorScheme.defaultDark.id
```
호출부를 `SwiftTermRepresentable(session: session, scheme: TerminalColorScheme.find(id: schemeID))`로 바꾼다.

- [ ] **Step 3: macOS 빌드**

Run: `cd Hydra && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: iOS representable** — `SwiftTermRepresentableiOS`:

```swift
    let session: TerminalSession
    var scheme: TerminalColorScheme = .defaultDark
```
`makeUIView`에서 `return container` 직전에 `applyScheme(to: container, coordinator: context.coordinator)`를 넣고, `updateUIView`와 헬퍼를 추가한다.
```swift
    func updateUIView(_ uiView: NativeTerminalInputView, context: Context) {
        applyScheme(to: uiView, coordinator: context.coordinator)
    }

    /// SwiftUI는 update를 자주 부른다 — id가 바뀔 때만 팔레트를 다시 설치한다.
    /// SwiftTerm iOS 뷰는 non-opaque라 컨테이너 배경이 비치므로 같이 칠한다.
    private func applyScheme(to container: NativeTerminalInputView, coordinator: Coordinator) {
        guard coordinator.appliedSchemeID != scheme.id else { return }
        scheme.apply(to: container.terminal)
        container.backgroundColor = TerminalColorScheme.platformColor(scheme.background)
        coordinator.appliedSchemeID = scheme.id
    }
```
`Coordinator`에 `var appliedSchemeID: String?`를 추가한다.

- [ ] **Step 5: iOS 화면 연결** — `TerminalScreen`에 다음을 추가한다.
```swift
    @AppStorage(TerminalColorScheme.storageKey) private var schemeID = TerminalColorScheme.defaultDark.id
```
그리고 `SwiftTermRepresentableiOS(session: session, scheme: TerminalColorScheme.find(id: schemeID))`로 바꾼다.

- [ ] **Step 6: iOS 빌드**

Run: `cd Hydra && xcodegen generate && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 기존 iOS 입력·렌더링 테스트 회귀 확인**

Run: `cd Hydra && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' test -only-testing:TerminalInputTests 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **`. 스킴에 테스트가 포함되지 않았다면 `-scheme TerminalInputTests`로 다시 실행한다.

- [ ] **Step 8: Commit**

```bash
git add Hydra/Hydra/Views/Terminal Hydra/HydraiOS/Terminal
git commit -m "feat(terminal): macOS·iOS 터미널에 선택한 색상 테마 적용"
```

---

### Task 3: 설정 UI (공유 목록 + iOS/macOS 진입점)

**Files:**
- Create: `Hydra/Theme/TerminalColorSchemeOptions.swift`
- Modify: `HydraiOS/Screens/SettingsScreen.swift` (`Section("SSH")` 바로 위)
- Modify: `HydraiOS/Resources/ko.lproj/Localizable.strings`, `HydraiOS/Resources/en.lproj/Localizable.strings`
- Modify: `Hydra/Views/Settings/AppearanceSettingsTab.swift` (`Section { ... } header: { Text("Font") }` 다음)

**Interfaces:**
- Consumes: `TerminalColorScheme.presets`, `.storageKey`, `.rgbComponents(_:)`
- Produces: `struct TerminalColorSchemeOptions: View` (`Form`/`Section` 안에 넣는 행 목록), `struct TerminalColorSchemeScreen: View` (iOS용 전체 화면)

- [ ] **Step 1: 공유 뷰 작성** — `Hydra/Theme/TerminalColorSchemeOptions.swift`

```swift
import SwiftUI

/// 터미널 색상 프리셋 선택 행 목록. Form/Section 안에 넣어 쓴다 (macOS 설정 탭, iOS 테마 화면 공용).
struct TerminalColorSchemeOptions: View {
    @AppStorage(TerminalColorScheme.storageKey) private var selectedID = TerminalColorScheme.defaultDark.id

    var body: some View {
        ForEach(TerminalColorScheme.presets) { scheme in
            Button { selectedID = scheme.id } label: {
                TerminalColorSchemeRow(scheme: scheme,
                                       isSelected: TerminalColorScheme.find(id: selectedID) == scheme)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("terminal-scheme-\(scheme.id)")
        }
    }
}

/// iOS 설정에서 NavigationLink로 여는 전체 화면.
struct TerminalColorSchemeScreen: View {
    var body: some View {
        Form { Section { TerminalColorSchemeOptions() } }
            .navigationTitle("터미널 테마")
    }
}

private struct TerminalColorSchemeRow: View {
    let scheme: TerminalColorScheme
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            preview
            Text(scheme.displayName)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    /// 테마 배경 위에 전경색 "Aa" + ANSI normal 8색 칩.
    private var preview: some View {
        HStack(spacing: 3) {
            Text("Aa")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(Self.color(scheme.foreground))
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.color(scheme.ansi[i]))
                    .frame(width: 8, height: 12)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Self.color(scheme.background), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
    }

    private static func color(_ hex: UInt32) -> Color {
        let c = TerminalColorScheme.rgbComponents(hex)
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}
```

- [ ] **Step 2: iOS 설정 진입점** — `SettingsScreen`에서 `Section("SSH") {` 바로 위에 추가:

```swift
            Section("터미널") {
                NavigationLink("터미널 테마") { TerminalColorSchemeScreen() }
                    .accessibilityIdentifier("settings-terminal-scheme")
            }
```

- [ ] **Step 3: 현지화** — `ko.lproj/Localizable.strings`와 `en.lproj/Localizable.strings` 끝에 각각 추가한다. 추가하기 전에 `grep -n '"터미널"' HydraiOS/Resources/*/Localizable.strings`로 이미 있는 키인지 확인하고, 있으면 그 줄은 건너뛴다.

ko:
```
"터미널" = "터미널";
"터미널 테마" = "터미널 테마";
```
en:
```
"터미널" = "Terminal";
"터미널 테마" = "Terminal theme";
```

- [ ] **Step 4: macOS 설정 탭** — `AppearanceSettingsTab`에서 Font 섹션(`} header: { Text("Font") }`) 바로 다음에 추가:

```swift
            Section {
                TerminalColorSchemeOptions()
            } header: {
                Text("Terminal theme")
            }
```

- [ ] **Step 5: 빌드 (양쪽)**

Run: `cd Hydra && swift build 2>&1 | tail -3 && xcodegen generate && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' build 2>&1 | tail -3`
Expected: `Build complete!` 그리고 `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Hydra/Hydra/Theme/TerminalColorSchemeOptions.swift Hydra/HydraiOS/Screens/SettingsScreen.swift Hydra/HydraiOS/Resources Hydra/Hydra/Views/Settings/AppearanceSettingsTab.swift
git commit -m "feat(settings): 터미널 테마 선택 화면 (iOS 설정 + macOS Appearance 탭)"
```

---

### Task 4: 통합 확인

- [ ] **Step 1: 전체 macOS 테스트**

Run: `cd Hydra && swift test 2>&1 | tail -8`
Expected: 새 실패가 없어야 한다. 기존 실패가 있으면 `git stash`한 main 기준 결과와 비교해 이 작업과 무관함을 기록한다. Docker가 필요한 smoke 테스트는 환경에 따라 건너뛴다.

- [ ] **Step 2: iOS 시뮬레이터 수동 확인**

앱을 설치하고 실행한 뒤 설정 → 터미널 테마로 이동해 Dracula를 고르고 스크린샷을 찍는다. 체크 표시와 미리보기 칩이 보여야 한다.

```bash
cd Hydra && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' -derivedDataPath build/dd build
xcrun simctl boot "iPad Pro 11-inch (M4)" || true
xcrun simctl install booted build/dd/Build/Products/Debug-iphonesimulator/HydraiOS.app
xcrun simctl launch booted com.s1ckdark.hydraios
xcrun simctl io booted screenshot /tmp/terminal-scheme.png
```

실제 SSH 세션에 색이 반영되는지는 연결할 노드가 있을 때만 확인할 수 있다. 확인하지 못했으면 보고서에 그렇게 적는다.
