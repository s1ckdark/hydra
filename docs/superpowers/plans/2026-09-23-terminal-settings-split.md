# 터미널 설정 분리 + 노드별 설정 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 터미널 전용 설정(색상 테마, 폰트, 크기, 커서, 스크롤백)을 앱 외형 설정에서 분리한다. 설정 화면의 전체 설정과, 터미널 안 패널의 노드별 설정("전체 설정 따르기" 체크)을 macOS·iOS 모두에 만든다.

**Architecture:** 공유 값 타입 `TerminalSettings`와 `TerminalSettingsStore`(UserDefaults: 전체 값은 개별 키, 노드별 값은 JSON)를 `Hydra/Theme`에 둔다. 터미널 화면은 `store.effective(for: deviceId)`를 representable에 넘기고, representable은 이전에 적용한 값과 비교해 바뀐 항목만 SwiftTerm에 적용한다. SwiftUI 폼 하나(`TerminalSettingsForm`)를 설정 화면(전체)과 터미널 안 패널(노드)에서 바인딩만 바꿔 재사용한다.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftTerm(벤더링), CoreText, XCTest, XcodeGen

**Spec:** `docs/superpowers/specs/2026-09-23-terminal-settings-split-design.md`

## Global Constraints

- 모든 코드 경로는 `hydra/Hydra/` 기준이다 (git 루트는 `hydra/`). 빌드·테스트는 `hydra/Hydra`에서, git은 `hydra/`에서 실행한다.
- 공유 코드는 `Hydra/Hydra/Theme/`에 둔다. macOS SwiftPM `Hydra` 타겟과 iOS XcodeGen `HydraiOS` 타겟이 함께 컴파일한다. SwiftTerm 의존 코드는 `#if canImport(SwiftTerm)`으로 감싼다.
- UserDefaults 키: `terminalColorScheme`(기존, 유지), `terminalFontName`, `terminalFontSize`, `terminalCursor`, `terminalScrollback`, `terminalNodeOverrides`.
- 기본값: 색상 `default-dark`, 폰트 `D2Coding`, 크기 macOS 13 / iOS 14, 커서 `blinkBlock`, 스크롤백 10_000. 크기 범위 8…32. 스크롤백 선택지 `[1_000, 5_000, 10_000, 50_000]`.
- 노드별 설정은 노드(`TerminalSession.deviceId`)에만 적용된다. 다른 노드나 전체 설정을 바꾸지 않는다.
- macOS `Hydra/Views/Terminal/TerminalView.swift`에서는 SwiftUI `Button`과 `.task`를 쓰지 않는다. 파일 상단의 `TapLabel`과 `.onAppear { Task { } }`를 쓴다.
- 사용자 문구는 공유 테이블 `Hydra/Hydra/Resources/{ko,en}.lproj/Localizable.strings`에 ko·en을 모두 추가한다. 두 파일의 키 집합은 같아야 한다(`LocalizationTableTests`). 코드 리터럴은 기존 관례대로 한국어 원문을 키로 쓴다.
- macOS 창·내비게이션 제목은 `.localizedNavigationTitle("…")`를 쓴다. `.navigationTitle("…")`는 쓰지 않는다.
- `Hydra.xcodeproj`는 gitignore된 생성물이다. 파일을 추가하면 `xcodegen generate`를 실행한다.
- 시뮬레이터 destination은 `-destination 'platform=iOS Simulator,id=E72726B6-1862-456F-A01D-278DB9364E27'`(또는 빌드만 할 때 `generic/platform=iOS Simulator`)을 쓴다. 시뮬레이터를 erase하거나 삭제하지 않는다. 앱을 실행하거나 사용자 defaults(`io.hydra.Hydra`)를 건드리지 않는다.
- `rm`은 대화형 별칭일 수 있다. 파일을 지울 때는 `/bin/rm`을 쓴다.
- 커밋 메시지 끝에 빈 줄을 두고 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`를 붙인다.

## File Structure

| 파일 | 역할 |
|---|---|
| Create `Hydra/Theme/TerminalSettings.swift` | `TerminalCursor`, `TerminalSettings` 값 타입 |
| Create `Hydra/Theme/TerminalSettingsStore.swift` | 전체·노드별 저장, 조회, 변경 알림 |
| Create `Hydra/Theme/TerminalFontCatalog.swift` | 번들 폰트 등록, 폰트 목록, 이름 → 폰트 해석 |
| Create `Hydra/Resources/Fonts/D2Coding.ttf`, `Hydra/Resources/Fonts/OFL.txt` | 번들 폰트와 라이선스 |
| Create `Hydra/Theme/TerminalSettings+SwiftTerm.swift` | 바뀐 항목만 SwiftTerm 뷰에 적용 |
| Create `Hydra/Theme/TerminalSettingsForm.swift` | 공유 설정 폼, 노드별 설정 목록 섹션, iOS 설정 화면 |
| Create `Hydra/Theme/TerminalNodeSettingsPanel.swift` | 터미널 안 패널("전체 설정 따르기" + 폼) |
| Modify `Hydra/Theme/TerminalColorSchemeOptions.swift` | `@AppStorage` 대신 `Binding<String>`, `TerminalColorSchemeScreen` 삭제 |
| Modify `Hydra/Views/Terminal/SwiftTermRepresentable.swift`, `HydraiOS/Terminal/SwiftTermRepresentableiOS.swift` | `settings: TerminalSettings` |
| Modify `Hydra/Views/Terminal/TerminalView.swift`, `HydraiOS/Terminal/TerminalScreen.swift` | 스토어 연결, ⚙ 진입점 |
| Modify `Hydra/Views/Settings/SettingsView.swift`, `Hydra/Views/Settings/AppearanceSettingsTab.swift`, `HydraiOS/Screens/SettingsScreen.swift` | 설정 화면 재배치 |
| Modify `Hydra/HydraApp.swift`, `HydraiOS/App.swift` | 폰트 등록, `CommandMenu("Terminal")` |
| Modify `scripts/bundle-app.sh` | `Fonts/` 복사 |
| Tests `Tests/HydraTests/TerminalSettingsStoreTests.swift`, `TerminalFontCatalogTests.swift`, `TerminalSettingsApplyTests.swift`, `HydraiOSUITests/TerminalNodeSettingsUITests.swift` | |

---

### Task 1: TerminalSettings + TerminalSettingsStore

**Files:**
- Create: `Hydra/Theme/TerminalSettings.swift`, `Hydra/Theme/TerminalSettingsStore.swift`
- Test: `Tests/HydraTests/TerminalSettingsStoreTests.swift`

**Interfaces:**
- Consumes: `TerminalColorScheme.storageKey`, `TerminalColorScheme.find(id:)`, `TerminalColorScheme.defaultDark` (기존)
- Produces:
  - `enum TerminalCursor: String, CaseIterable, Codable, Identifiable` (`blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar`), `var label: String`
  - `struct TerminalSettings: Codable, Equatable` 필드 `colorSchemeID: String`, `fontName: String`, `fontSize: Double`, `cursor: TerminalCursor`, `scrollback: Int`, `static let scrollbackChoices: [Int]`, `static let fontSizeRange: ClosedRange<Double>`, `static let defaultFontSize: Double`, `func normalized() -> TerminalSettings`
  - `final class TerminalSettingsStore: ObservableObject` — `static let shared`, `init(defaults:)`, `var global: TerminalSettings`, `func effective(for:) -> TerminalSettings`, `func isFollowingGlobal(_:) -> Bool`, `func setFollowingGlobal(_:for:)`, `func update(_:_:)`, `var overriddenDeviceIDs: [String]`, `func resetOverride(_:)`

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/HydraTests/TerminalSettingsStoreTests.swift`

```swift
import XCTest
import Combine
@testable import Hydra

final class TerminalSettingsStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: TerminalSettingsStore!

    override func setUpWithError() throws {
        suite = "hydra.terminal-settings.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = TerminalSettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaults() {
        let s = store.global
        XCTAssertEqual(s.colorSchemeID, "default-dark")
        XCTAssertEqual(s.fontName, "D2Coding")
        XCTAssertEqual(s.fontSize, TerminalSettings.defaultFontSize)
        XCTAssertEqual(s.cursor, .blinkBlock)
        XCTAssertEqual(s.scrollback, 10_000)
    }

    func testNormalizationClampsSizeAndScrollback() {
        var s = TerminalSettings()
        s.fontSize = 4; s.scrollback = 123
        XCTAssertEqual(s.normalized().fontSize, 8)
        XCTAssertEqual(s.normalized().scrollback, 10_000)
        s.fontSize = 99
        XCTAssertEqual(s.normalized().fontSize, 32)
    }

    func testInvalidStoredGlobalValuesFallBack() {
        defaults.set("weird", forKey: "terminalCursor")
        defaults.set("nope", forKey: "terminalColorScheme")
        defaults.set(77, forKey: "terminalScrollback")
        let s = store.global
        XCTAssertEqual(s.cursor, .blinkBlock)
        XCTAssertEqual(s.colorSchemeID, "default-dark")
        XCTAssertEqual(s.scrollback, 10_000)
    }

    func testExistingColorSchemeKeyIsReadAsGlobal() {
        defaults.set("dracula", forKey: "terminalColorScheme")
        XCTAssertEqual(store.global.colorSchemeID, "dracula")
    }

    func testGlobalRoundTrip() {
        var s = TerminalSettings()
        s.colorSchemeID = "nord"; s.fontName = "Menlo-Regular"; s.fontSize = 16; s.cursor = .steadyBar; s.scrollback = 50_000
        store.global = s
        XCTAssertEqual(TerminalSettingsStore(defaults: defaults).global, s)
        XCTAssertEqual(defaults.string(forKey: "terminalColorScheme"), "nord")
    }

    func testFollowingGlobalByDefaultAndEffectiveUsesGlobal() {
        XCTAssertTrue(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.effective(for: "node-a"), store.global)
    }

    func testTurningOffFollowCopiesGlobalAndTurningOnRemoves() {
        var g = store.global; g.fontSize = 18; store.global = g
        store.setFollowingGlobal(false, for: "node-a")
        XCTAssertFalse(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 18)
        store.setFollowingGlobal(true, for: "node-a")
        XCTAssertTrue(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.overriddenDeviceIDs, [])
    }

    func testUpdateAffectsOnlyThatNode() {
        let before = store.global
        store.update("node-a") { $0.colorSchemeID = "dracula"; $0.fontSize = 20 }
        XCTAssertFalse(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.effective(for: "node-a").colorSchemeID, "dracula")
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 20)
        XCTAssertEqual(store.global, before)
        XCTAssertEqual(store.effective(for: "node-b"), before)
        XCTAssertEqual(store.overriddenDeviceIDs, ["node-a"])
    }

    func testUpdateNormalizes() {
        store.update("node-a") { $0.fontSize = 100 }
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 32)
    }

    func testResetOverride() {
        store.update("node-a") { $0.fontSize = 20 }
        store.resetOverride("node-a")
        XCTAssertTrue(store.isFollowingGlobal("node-a"))
    }

    func testCorruptOverrideEntryIsDroppedOthersKept() throws {
        var good = TerminalSettings(); good.fontSize = 15
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let raw: [String: Any] = ["good": goodJSON, "bad": ["fontName": 1]]
        defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: "terminalNodeOverrides")
        XCTAssertEqual(store.effective(for: "good").fontSize, 15)
        XCTAssertTrue(store.isFollowingGlobal("bad"))
    }

    func testChangesNotifyObservers() {
        var fired = 0
        let c = store.objectWillChange.sink { fired += 1 }
        store.update("node-a") { $0.fontSize = 20 }
        var g = store.global; g.fontSize = 9; store.global = g
        XCTAssertEqual(fired, 2)
        c.cancel()
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter TerminalSettingsStoreTests 2>&1 | tail -8`
Expected: 컴파일 실패 `cannot find 'TerminalSettingsStore' in scope`

- [ ] **Step 3: 값 타입 구현** — `Hydra/Theme/TerminalSettings.swift`

```swift
import Foundation

/// SwiftTerm `CursorStyle`과 1:1. 저장은 rawValue 문자열.
enum TerminalCursor: String, CaseIterable, Codable, Identifiable {
    case blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar

    var id: String { rawValue }

    /// 공유 번역 테이블 키 (한국어 원문).
    var label: String {
        switch self {
        case .blinkBlock: return "블록 (깜빡임)"
        case .steadyBlock: return "블록"
        case .blinkUnderline: return "밑줄 (깜빡임)"
        case .steadyUnderline: return "밑줄"
        case .blinkBar: return "세로줄 (깜빡임)"
        case .steadyBar: return "세로줄"
        }
    }
}

/// 터미널 한 개에 적용되는 설정 묶음. 전체 설정과 노드별 설정이 같은 타입을 쓴다.
struct TerminalSettings: Codable, Equatable {
    static let scrollbackChoices = [1_000, 5_000, 10_000, 50_000]
    static let fontSizeRange: ClosedRange<Double> = 8...32
    #if os(macOS)
    static let defaultFontSize: Double = 13
    #else
    static let defaultFontSize: Double = 14
    #endif

    var colorSchemeID: String = TerminalColorScheme.defaultDark.id
    var fontName: String = "D2Coding"
    var fontSize: Double = TerminalSettings.defaultFontSize
    var cursor: TerminalCursor = .blinkBlock
    var scrollback: Int = 10_000

    /// 범위를 벗어난 값을 허용 범위로 맞춘다. 저장·조회 경계에서 항상 거친다.
    func normalized() -> TerminalSettings {
        var s = self
        s.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        if !Self.scrollbackChoices.contains(scrollback) { s.scrollback = 10_000 }
        s.colorSchemeID = TerminalColorScheme.find(id: colorSchemeID).id
        if s.fontName.isEmpty { s.fontName = "D2Coding" }
        return s
    }
}
```

- [ ] **Step 4: 스토어 구현** — `Hydra/Theme/TerminalSettingsStore.swift`

```swift
import Foundation
import Combine

/// 터미널 설정 저장소. 전체 설정은 개별 키(기존 terminalColorScheme 키와 호환),
/// 노드별 설정은 `terminalNodeOverrides`에 [deviceID: TerminalSettings] JSON으로 둔다.
/// 딕셔너리에 없는 노드는 전체 설정을 따른다.
final class TerminalSettingsStore: ObservableObject {
    static let shared = TerminalSettingsStore()

    enum Key {
        static let colorScheme = TerminalColorScheme.storageKey
        static let fontName = "terminalFontName"
        static let fontSize = "terminalFontSize"
        static let cursor = "terminalCursor"
        static let scrollback = "terminalScrollback"
        static let overrides = "terminalNodeOverrides"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var global: TerminalSettings {
        get {
            var s = TerminalSettings()
            if let v = defaults.string(forKey: Key.colorScheme) { s.colorSchemeID = v }
            if let v = defaults.string(forKey: Key.fontName) { s.fontName = v }
            if defaults.object(forKey: Key.fontSize) != nil { s.fontSize = defaults.double(forKey: Key.fontSize) }
            if let v = defaults.string(forKey: Key.cursor), let c = TerminalCursor(rawValue: v) { s.cursor = c }
            if defaults.object(forKey: Key.scrollback) != nil { s.scrollback = defaults.integer(forKey: Key.scrollback) }
            return s.normalized()
        }
        set {
            objectWillChange.send()
            let s = newValue.normalized()
            defaults.set(s.colorSchemeID, forKey: Key.colorScheme)
            defaults.set(s.fontName, forKey: Key.fontName)
            defaults.set(s.fontSize, forKey: Key.fontSize)
            defaults.set(s.cursor.rawValue, forKey: Key.cursor)
            defaults.set(s.scrollback, forKey: Key.scrollback)
        }
    }

    func effective(for deviceID: String) -> TerminalSettings {
        overrides[deviceID] ?? global
    }

    func isFollowingGlobal(_ deviceID: String) -> Bool {
        overrides[deviceID] == nil
    }

    /// false: 현재 전체 설정을 복사해 노드 설정을 만든다. true: 노드 설정을 지운다.
    func setFollowingGlobal(_ follow: Bool, for deviceID: String) {
        var o = overrides
        if follow {
            o[deviceID] = nil
        } else if o[deviceID] == nil {
            o[deviceID] = global
        }
        overrides = o
    }

    /// 노드 설정만 바꾼다. 전체 설정을 따르던 노드면 전체 설정을 복사한 뒤 바꾼다.
    func update(_ deviceID: String, _ change: (inout TerminalSettings) -> Void) {
        var o = overrides
        var s = o[deviceID] ?? global
        change(&s)
        o[deviceID] = s.normalized()
        overrides = o
    }

    var overriddenDeviceIDs: [String] { overrides.keys.sorted() }

    func resetOverride(_ deviceID: String) {
        setFollowingGlobal(true, for: deviceID)
    }

    /// 항목 단위로 디코딩한다. 깨진 항목만 버리고 나머지는 살린다.
    private var overrides: [String: TerminalSettings] {
        get {
            guard let data = defaults.data(forKey: Key.overrides),
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
            var result: [String: TerminalSettings] = [:]
            for (id, value) in raw {
                guard JSONSerialization.isValidJSONObject(value),
                      let entry = try? JSONSerialization.data(withJSONObject: value),
                      let s = try? JSONDecoder().decode(TerminalSettings.self, from: entry) else { continue }
                result[id] = s.normalized()
            }
            return result
        }
        set {
            objectWillChange.send()
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.overrides)
        }
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter TerminalSettingsStoreTests 2>&1 | tail -5`
Expected: `Executed 12 tests, with 0 failures`

- [ ] **Step 6: 테이블에 커서 라벨 추가** — 두 테이블 끝에 `/* MARK: terminal settings */` 블록을 만들고 추가한다(ko 값 = 원문).
- en: `"블록 (깜빡임)" = "Block (blinking)";`, `"블록" = "Block";`, `"밑줄 (깜빡임)" = "Underline (blinking)";`, `"밑줄" = "Underline";`, `"세로줄 (깜빡임)" = "Bar (blinking)";`, `"세로줄" = "Bar";`

Run: `swift test --filter LocalizationTableTests 2>&1 | tail -3` → 0 failures

- [ ] **Step 7: Commit**

```bash
git add Hydra/Hydra/Theme/TerminalSettings.swift Hydra/Hydra/Theme/TerminalSettingsStore.swift Hydra/Tests/HydraTests/TerminalSettingsStoreTests.swift Hydra/Hydra/Resources
git commit -m "feat(terminal): TerminalSettings 모델 + 전체/노드별 설정 저장소"
```

---

### Task 2: 폰트 카탈로그 + D2Coding 번들

**Files:**
- Create: `Hydra/Theme/TerminalFontCatalog.swift`, `Hydra/Resources/Fonts/D2Coding.ttf`(복사), `Hydra/Resources/Fonts/OFL.txt`
- Modify: `scripts/bundle-app.sh`, `Hydra/HydraApp.swift`, `HydraiOS/App.swift`
- Test: `Tests/HydraTests/TerminalFontCatalogTests.swift`

**Interfaces:**
- Consumes: `LocalizationTableTests.packageRoot` (기존 테스트 헬퍼, 패키지 루트 URL)
- Produces:
  - `typealias TerminalPlatformFont` (UIFont / NSFont)
  - `struct TerminalFontOption: Identifiable, Hashable { let id: String; let displayName: String }`
  - `enum TerminalFontCatalog` — `static let systemID = "system"`, `static func registerBundledFonts(bundle: Bundle = .main)`, `static func registerFont(at url: URL)`, `static func availableFonts() -> [TerminalFontOption]`, `static func resolve(_ name: String, size: CGFloat) -> TerminalFontCatalog.Resolved` (`font: TerminalPlatformFont`, `isFallback: Bool`)

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/HydraTests/TerminalFontCatalogTests.swift`

```swift
import XCTest
@testable import Hydra

final class TerminalFontCatalogTests: XCTestCase {
    private var bundledD2Coding: URL {
        LocalizationTableTests.packageRoot.appendingPathComponent("Hydra/Resources/Fonts/D2Coding.ttf")
    }

    func testBundledFontFileAndLicenseExist() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledD2Coding.path))
        let license = LocalizationTableTests.packageRoot.appendingPathComponent("Hydra/Resources/Fonts/OFL.txt")
        let text = (try? String(contentsOf: license, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(text.contains("NHN Corporation"))
    }

    func testRegisteredD2CodingResolvesWithoutFallback() {
        TerminalFontCatalog.registerFont(at: bundledD2Coding)
        let r = TerminalFontCatalog.resolve("D2Coding", size: 15)
        XCTAssertFalse(r.isFallback)
        XCTAssertEqual(r.font.pointSize, 15)
    }

    func testUnknownFontFallsBackToMonospacedSystemFont() {
        let r = TerminalFontCatalog.resolve("No-Such-Font-XYZ", size: 12)
        XCTAssertTrue(r.isFallback)
        XCTAssertEqual(r.font.pointSize, 12)
        XCTAssertTrue(r.font.isFixedPitch)
    }

    func testSystemIDIsNotAFallback() {
        let r = TerminalFontCatalog.resolve(TerminalFontCatalog.systemID, size: 12)
        XCTAssertFalse(r.isFallback)
    }

    func testAvailableFontsStartWithSystemAndHaveNoDuplicates() {
        TerminalFontCatalog.registerFont(at: bundledD2Coding)
        let fonts = TerminalFontCatalog.availableFonts()
        XCTAssertEqual(fonts.first?.id, TerminalFontCatalog.systemID)
        XCTAssertEqual(Set(fonts.map(\.id)).count, fonts.count)
        XCTAssertTrue(fonts.contains { $0.id == "D2Coding" })
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter TerminalFontCatalogTests 2>&1 | tail -8`
Expected: 컴파일 실패 `cannot find 'TerminalFontCatalog' in scope`

- [ ] **Step 3: 폰트 파일과 라이선스 추가** (git 루트에서)

```bash
mkdir -p Hydra/Hydra/Resources/Fonts
cp /Users/dave/iWorks/terminal/App/Resources/Fonts/D2Coding.ttf Hydra/Hydra/Resources/Fonts/D2Coding.ttf
```
`Hydra/Hydra/Resources/Fonts/OFL.txt`를 다음 내용으로 만든다. 첫 줄은 폰트에 들어 있는 저작권 표기이고, 그 아래는 SIL Open Font License 1.1 **원문 전체**(PREAMBLE, DEFINITIONS, PERMISSION & CONDITIONS 1–5, TERMINATION, DISCLAIMER)다. 원문은 https://openfontlicense.org/open-font-license-official-text/ 와 한 글자도 다르지 않게 옮긴다.
```
Copyright (c) 2015-2016 NHN Corporation. All rights reserved. Font designed by FONTRIX Inc.

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org

-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------
(원문 계속)
```

- [ ] **Step 4: 카탈로그 구현** — `Hydra/Theme/TerminalFontCatalog.swift`

```swift
import Foundation
import CoreText
#if canImport(UIKit)
import UIKit
typealias TerminalPlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias TerminalPlatformFont = NSFont
#endif

struct TerminalFontOption: Identifiable, Hashable {
    let id: String          // PostScript 이름, 또는 TerminalFontCatalog.systemID
    let displayName: String
}

/// 터미널 폰트 목록과 해석. 번들 폰트(D2Coding)는 앱 시작 시 process 범위로 등록한다.
enum TerminalFontCatalog {
    static let systemID = "system"
    static let bundledFonts = ["D2Coding"]

    struct Resolved {
        let font: TerminalPlatformFont
        let isFallback: Bool
    }

    static func registerBundledFonts(bundle: Bundle = .main) {
        for name in bundledFonts {
            // iOS(XcodeGen)는 번들 루트, macOS(bundle-app.sh)는 Resources/Fonts에 들어간다.
            if let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? bundle.url(forResource: name, withExtension: "ttf") {
                registerFont(at: url)
            }
        }
    }

    /// 이미 등록된 폰트면 CoreText가 오류를 돌려주는데, 결과는 같으므로 무시한다.
    static func registerFont(at url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func availableFonts() -> [TerminalFontOption] {
        var result = [TerminalFontOption(id: systemID, displayName: "System Monospaced")]
        var seen: Set<String> = [systemID]
        func add(_ postscriptName: String) {
            guard !seen.contains(postscriptName),
                  let font = TerminalPlatformFont(name: postscriptName, size: 12) else { return }
            seen.insert(postscriptName)
            result.append(TerminalFontOption(id: postscriptName, displayName: displayName(of: font)))
        }
        bundledFonts.forEach(add)
        #if canImport(UIKit)
        for family in UIFont.familyNames.sorted() {
            for name in UIFont.fontNames(forFamilyName: family) {
                if let f = UIFont(name: name, size: 12), f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) { add(name) }
            }
        }
        #else
        (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []).sorted().forEach(add)
        #endif
        return result
    }

    static func resolve(_ name: String, size: CGFloat) -> Resolved {
        if name != systemID, let font = TerminalPlatformFont(name: name, size: size) {
            return Resolved(font: font, isFallback: false)
        }
        return Resolved(font: .monospacedSystemFont(ofSize: size, weight: .regular), isFallback: name != systemID)
    }

    private static func displayName(of font: TerminalPlatformFont) -> String {
        #if canImport(UIKit)
        return font.fontName
        #else
        return font.displayName ?? font.fontName
        #endif
    }
}

#if canImport(UIKit)
extension UIFont {
    /// NSFont.isFixedPitch와 같은 이름으로 테스트·UI에서 쓴다.
    var isFixedPitch: Bool { fontDescriptor.symbolicTraits.contains(.traitMonoSpace) }
}
#endif
```

- [ ] **Step 5: 앱 시작 시 등록** — `Hydra/HydraApp.swift`의 기존 `init()` 본문 첫 줄과 `HydraiOS/App.swift`의 기존 `init()` 본문 첫 줄에 `TerminalFontCatalog.registerBundledFonts()`를 추가한다.

- [ ] **Step 6: macOS 번들에 폰트 복사** — `scripts/bundle-app.sh`에서 `cp -R Hydra/Resources/*.lproj "$APP/Contents/Resources/"` 줄 바로 다음에 추가:

```bash
# 번들 터미널 폰트 (TerminalFontCatalog.registerBundledFonts가 Resources/Fonts에서 찾는다)
cp -R Hydra/Resources/Fonts "$APP/Contents/Resources/"
```

- [ ] **Step 7: 확인**

Run: `swift test --filter TerminalFontCatalogTests 2>&1 | tail -5 && swift build 2>&1 | tail -2`
Expected: 5 tests 0 failures, `Build complete!`

Run: `xcodegen generate >/dev/null && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`. 그다음 `find ~/Library/Developer/Xcode/DerivedData -path "*Debug-iphonesimulator/HydraiOS.app/D2Coding.ttf" -newer Hydra/Theme/TerminalFontCatalog.swift | head -1`로 폰트가 iOS 앱 번들에 들어갔는지 확인한다. 이 결과가 비어 있으면 DerivedData 대신 `xcodebuild ... -showBuildSettings | grep " BUILT_PRODUCTS_DIR"` 경로에서 찾는다.

- [ ] **Step 8: Commit**

```bash
git add Hydra/Hydra/Theme/TerminalFontCatalog.swift Hydra/Hydra/Resources/Fonts Hydra/scripts/bundle-app.sh Hydra/Hydra/HydraApp.swift Hydra/HydraiOS/App.swift Hydra/Tests/HydraTests/TerminalFontCatalogTests.swift
git commit -m "feat(terminal): D2Coding 번들 + 터미널 폰트 카탈로그"
```

---

### Task 3: 설정을 터미널 뷰에 적용

**Files:**
- Create: `Hydra/Theme/TerminalSettings+SwiftTerm.swift`
- Modify: `Hydra/Views/Terminal/SwiftTermRepresentable.swift`, `HydraiOS/Terminal/SwiftTermRepresentableiOS.swift`, `Hydra/Views/Terminal/TerminalView.swift` (`TerminalSessionPane`), `HydraiOS/Terminal/TerminalScreen.swift`
- Test: `Tests/HydraTests/TerminalSettingsApplyTests.swift`

**Interfaces:**
- Consumes: Task 1 `TerminalSettings`, `TerminalSettingsStore.shared`, `effective(for:)`. Task 2 `TerminalFontCatalog.resolve`. 기존 `TerminalColorScheme.find(id:)`, `.apply(to:)`, `.platformColor(_:)`
- Produces:
  - `extension TerminalSettings { var swiftTermCursor: CursorStyle; func apply(to view: SwiftTerm.TerminalView, previous: TerminalSettings?) }`
  - `SwiftTermRepresentable(session:settings:)`, `SwiftTermRepresentableiOS(session:settings:)` — `settings: TerminalSettings` (기본값 `TerminalSettings()`)

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/HydraTests/TerminalSettingsApplyTests.swift`

```swift
import XCTest
import AppKit
import SwiftTerm
@testable import Hydra

final class TerminalSettingsApplyTests: XCTestCase {
    private func makeView() -> SwiftTerm.TerminalView {
        SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), font: nil)
    }

    private func settings() -> TerminalSettings {
        var s = TerminalSettings()
        s.colorSchemeID = "dracula"
        s.fontName = TerminalFontCatalog.systemID
        s.fontSize = 17
        s.cursor = .steadyBar
        s.scrollback = 5_000
        return s
    }

    func testApplySetsFontColorsCursorAndScrollback() throws {
        let view = makeView()
        let s = settings()
        s.apply(to: view, previous: nil)
        XCTAssertEqual(view.font.pointSize, 17)
        let bg = try XCTUnwrap(view.nativeBackgroundColor.usingColorSpace(.sRGB))
        XCTAssertEqual(bg.redComponent, CGFloat(0x28) / 255, accuracy: 0.01)
        XCTAssertEqual(bg.blueComponent, CGFloat(0x36) / 255, accuracy: 0.01)
        XCTAssertEqual(view.getTerminal().options.scrollback, 5_000)
    }

    func testReapplyingSameSettingsKeepsFontObject() {
        let view = makeView()
        let s = settings()
        s.apply(to: view, previous: nil)
        let font = view.font
        s.apply(to: view, previous: s)
        XCTAssertTrue(view.font === font)
    }

    func testOnlyChangedFieldIsApplied() {
        let view = makeView()
        var s = settings()
        s.apply(to: view, previous: nil)
        let font = view.font
        var next = s
        next.scrollback = 50_000
        next.apply(to: view, previous: s)
        XCTAssertTrue(view.font === font)
        XCTAssertEqual(view.getTerminal().options.scrollback, 50_000)
        s = next
        next.fontSize = 20
        next.apply(to: view, previous: s)
        XCTAssertEqual(view.font.pointSize, 20)
    }

    func testCursorMapping() {
        XCTAssertEqual(TerminalCursor.allCases.count, 6)
        var s = TerminalSettings()
        s.cursor = .blinkUnderline
        if case .blinkUnderline = s.swiftTermCursor {} else { XCTFail("mapping") }
        s.cursor = .steadyBlock
        if case .steadyBlock = s.swiftTermCursor {} else { XCTFail("mapping") }
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter TerminalSettingsApplyTests 2>&1 | tail -8`
Expected: 컴파일 실패 `value of type 'TerminalSettings' has no member 'apply'`

- [ ] **Step 3: 적용 확장 구현** — `Hydra/Theme/TerminalSettings+SwiftTerm.swift`

```swift
#if canImport(SwiftTerm)
import SwiftTerm

extension TerminalSettings {
    var swiftTermCursor: CursorStyle {
        switch cursor {
        case .blinkBlock: return .blinkBlock
        case .steadyBlock: return .steadyBlock
        case .blinkUnderline: return .blinkUnderline
        case .steadyUnderline: return .steadyUnderline
        case .blinkBar: return .blinkBar
        case .steadyBar: return .steadyBar
        }
    }

    /// `previous`와 비교해 바뀐 항목만 적용한다. 폰트 교체는 SwiftTerm의 cols/rows 재계산과
    /// sizeChanged(→ 원격 PTY resize)를 일으키므로 같은 값이면 건드리지 않는다.
    func apply(to view: SwiftTerm.TerminalView, previous: TerminalSettings?) {
        if previous?.colorSchemeID != colorSchemeID {
            TerminalColorScheme.find(id: colorSchemeID).apply(to: view)
        }
        if previous?.fontName != fontName || previous?.fontSize != fontSize {
            view.font = TerminalFontCatalog.resolve(fontName, size: CGFloat(fontSize)).font
        }
        if previous?.cursor != cursor {
            view.getTerminal().setCursorStyle(swiftTermCursor)
        }
        if previous?.scrollback != scrollback {
            view.changeScrollback(scrollback)
        }
    }
}
#endif
```

- [ ] **Step 4: macOS representable** — `Hydra/Views/Terminal/SwiftTermRepresentable.swift`
- `var scheme: TerminalColorScheme = .defaultDark` → `var settings: TerminalSettings = TerminalSettings()`
- `applyScheme(to:coordinator:)`를 다음으로 바꾸고, `makeNSView`/`updateNSView`의 호출도 `applySettings`로 바꾼다.
```swift
    /// SwiftUI는 update를 자주 부른다 — 이전에 적용한 값과 다른 항목만 반영한다.
    private func applySettings(to view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        guard coordinator.appliedSettings != settings else { return }
        settings.apply(to: view, previous: coordinator.appliedSettings)
        coordinator.appliedSettings = settings
    }
```
- `Coordinator`의 `var appliedSchemeID: String?`를 `var appliedSettings: TerminalSettings?`로 바꾼다.

- [ ] **Step 5: iOS representable** — `HydraiOS/Terminal/SwiftTermRepresentableiOS.swift`
- `var scheme: TerminalColorScheme = .defaultDark` → `var settings: TerminalSettings = TerminalSettings()`
- `applyScheme`를 다음으로 바꾸고 호출부도 바꾼다.
```swift
    /// SwiftUI는 update를 자주 부른다 — 이전에 적용한 값과 다른 항목만 반영한다.
    /// SwiftTerm iOS 뷰는 non-opaque라 컨테이너 배경이 비치므로 같이 칠하고,
    /// 입력 뷰가 터미널 폰트를 따라가도록 레이아웃을 다시 요청한다.
    private func applySettings(to container: NativeTerminalInputView, coordinator: Coordinator) {
        guard coordinator.appliedSettings != settings else { return }
        settings.apply(to: container.terminal, previous: coordinator.appliedSettings)
        container.backgroundColor = TerminalColorScheme.platformColor(TerminalColorScheme.find(id: settings.colorSchemeID).background)
        container.setNeedsLayout()
        coordinator.appliedSettings = settings
    }
```
- `Coordinator`의 `appliedSchemeID`를 `var appliedSettings: TerminalSettings?`로 바꾼다.

- [ ] **Step 6: 화면 연결**
- `TerminalSessionPane`(`Hydra/Views/Terminal/TerminalView.swift`): `@AppStorage(TerminalColorScheme.storageKey) private var schemeID = …` 줄을 `@ObservedObject private var settingsStore = TerminalSettingsStore.shared`로 바꾸고, 호출부를 `SwiftTermRepresentable(session: session, settings: settingsStore.effective(for: session.deviceId))`로 바꾼다.
- `TerminalScreen`(`HydraiOS/Terminal/TerminalScreen.swift`): 같은 방식으로 `@ObservedObject private var settingsStore = TerminalSettingsStore.shared`와 `SwiftTermRepresentableiOS(session: session, settings: settingsStore.effective(for: session.deviceId))`.
- 확인: `grep -rn "scheme:" Hydra/Hydra/Views/Terminal Hydra/HydraiOS/Terminal`이 representable 호출에서 아무것도 찾지 않아야 한다.

- [ ] **Step 7: 확인**

Run: `swift test --filter "TerminalSettingsApplyTests|TerminalColorSchemeTests" 2>&1 | tail -4 && swift build 2>&1 | tail -2`
Expected: 0 failures, `Build complete!`

Run: `xcodegen generate >/dev/null && xcodebuild -project Hydra.xcodeproj -scheme TerminalInputTests -destination 'platform=iOS Simulator,id=E72726B6-1862-456F-A01D-278DB9364E27' test 2>&1 | grep -E "Executed [0-9]+ tests|SUCCEEDED|FAILED" | tail -3`
Expected: `** TEST SUCCEEDED **` (입력·렌더링 회귀 없음)

- [ ] **Step 8: Commit**

```bash
git add Hydra/Hydra/Theme/TerminalSettings+SwiftTerm.swift Hydra/Hydra/Views/Terminal Hydra/HydraiOS/Terminal Hydra/Tests/HydraTests/TerminalSettingsApplyTests.swift
git commit -m "feat(terminal): 폰트·크기·커서·스크롤백·테마를 노드별 유효 설정으로 적용"
```

---

### Task 4: 공유 설정 폼 + 설정 화면 재배치

**Files:**
- Create: `Hydra/Theme/TerminalSettingsForm.swift`
- Modify: `Hydra/Theme/TerminalColorSchemeOptions.swift`, `Hydra/Views/Settings/SettingsView.swift` (`TerminalSettingsTab`), `Hydra/Views/Settings/AppearanceSettingsTab.swift` (Terminal theme 섹션 삭제), `HydraiOS/Screens/SettingsScreen.swift` (터미널 섹션), 두 번역 테이블

**Interfaces:**
- Consumes: Task 1 스토어 API, Task 2 `TerminalFontCatalog.availableFonts()` / `resolve`, `LocalizedNavigationTitle`(`.localizedNavigationTitle`)
- Produces:
  - `TerminalColorSchemeOptions(selectedID: Binding<String>)`
  - `struct TerminalSettingsForm: View { init(settings: Binding<TerminalSettings>) }` — `Section`들만 내놓는다(바깥 `Form`은 호출하는 쪽에서)
  - `struct TerminalNodeOverridesSection: View` — `init(store: TerminalSettingsStore = .shared, nodeName: (String) -> String = { $0 })`
  - `struct TerminalSettingsScreen: View` (iOS 설정에서 여는 화면)
  - `extension TerminalSettingsStore { var globalBinding: Binding<TerminalSettings>; func binding(for deviceID: String) -> Binding<TerminalSettings> }`

- [ ] **Step 1: `TerminalColorSchemeOptions`를 바인딩 기반으로** — `@AppStorage` 프로퍼티를 `@Binding var selectedID: String`으로 바꾼다. 행 버튼 동작(`selectedID = scheme.id`)과 체크 표시 로직은 그대로 둔다. `TerminalColorSchemeScreen` 구조체는 **삭제**한다.

- [ ] **Step 2: 폼 작성** — `Hydra/Theme/TerminalSettingsForm.swift`

```swift
import SwiftUI

extension TerminalSettingsStore {
    var globalBinding: Binding<TerminalSettings> {
        Binding(get: { self.global }, set: { self.global = $0 })
    }

    /// 노드 설정 바인딩. 쓰면 그 노드만 바뀐다(따르기 상태였으면 자동으로 끈다).
    func binding(for deviceID: String) -> Binding<TerminalSettings> {
        Binding(get: { self.effective(for: deviceID) },
                set: { newValue in self.update(deviceID) { $0 = newValue } })
    }
}

/// 터미널 설정 섹션 묶음. 전체 설정과 노드 설정이 바인딩만 바꿔 같은 폼을 쓴다.
struct TerminalSettingsForm: View {
    @Binding var settings: TerminalSettings
    private let fonts = TerminalFontCatalog.availableFonts()

    init(settings: Binding<TerminalSettings>) { _settings = settings }

    var body: some View {
        Section {
            TerminalColorSchemeOptions(selectedID: $settings.colorSchemeID)
        } header: { Text("색상 테마") }

        Section {
            Picker("폰트", selection: $settings.fontName) {
                ForEach(fontChoices) { option in
                    Text(verbatim: option.displayName).tag(option.id)
                }
            }
            .accessibilityIdentifier("terminal-settings-font")
            Stepper(value: $settings.fontSize, in: TerminalSettings.fontSizeRange, step: 1) {
                Text(AppLocalization.format("크기 %lld pt", Int(settings.fontSize)))
            }
            .accessibilityIdentifier("terminal-settings-size")
            preview
        } header: { Text("폰트") }

        Section {
            Picker("커서", selection: $settings.cursor) {
                ForEach(TerminalCursor.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            Picker("스크롤백", selection: $settings.scrollback) {
                ForEach(TerminalSettings.scrollbackChoices, id: \.self) {
                    Text(AppLocalization.format("%lld줄", $0)).tag($0)
                }
            }
        } header: { Text("동작") }
    }

    /// 저장된 폰트가 목록에 없으면(삭제된 폰트 등) "(사용할 수 없음)"을 붙여 맨 뒤에 둔다.
    private var fontChoices: [TerminalFontOption] {
        guard !fonts.contains(where: { $0.id == settings.fontName }) else { return fonts }
        let missing = TerminalFontOption(id: settings.fontName,
            displayName: "\(settings.fontName) \(AppLocalization.string("(사용할 수 없음)"))")
        return fonts + [missing]
    }

    private var preview: some View {
        let resolved = TerminalFontCatalog.resolve(settings.fontName, size: CGFloat(settings.fontSize))
        let scheme = TerminalColorScheme.find(id: settings.colorSchemeID)
        return Text(verbatim: "$ ls -la  한글 가나다 0O1lI")
            .font(Font(resolved.font))
            .foregroundStyle(Self.color(scheme.foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Self.color(scheme.background), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("terminal-settings-preview")
    }

    private static func color(_ hex: UInt32) -> Color {
        let c = TerminalColorScheme.rgbComponents(hex)
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

/// 노드별 설정을 가진 노드 목록 + 개별 초기화. 전체 설정 화면에서 쓴다.
struct TerminalNodeOverridesSection: View {
    @ObservedObject var store: TerminalSettingsStore
    let nodeName: (String) -> String

    init(store: TerminalSettingsStore = .shared, nodeName: @escaping (String) -> String = { $0 }) {
        self.store = store
        self.nodeName = nodeName
    }

    var body: some View {
        Section {
            if store.overriddenDeviceIDs.isEmpty {
                Text("노드별 설정이 없습니다.").foregroundStyle(.secondary)
            } else {
                ForEach(store.overriddenDeviceIDs, id: \.self) { id in
                    HStack {
                        Text(verbatim: nodeName(id))
                        Spacer()
                        Button("초기화") { store.resetOverride(id) }
                            .accessibilityIdentifier("terminal-override-reset-\(id)")
                    }
                }
            }
        } header: {
            Text("노드별 설정")
        } footer: {
            Text("터미널 화면의 ⚙에서 '전체 설정 따르기'를 끄면 그 노드만의 설정을 쓸 수 있습니다.")
        }
    }
}

/// iOS 설정 → 터미널 설정 화면.
struct TerminalSettingsScreen: View {
    @ObservedObject private var store = TerminalSettingsStore.shared
    var nodeName: (String) -> String = { $0 }

    var body: some View {
        Form {
            TerminalSettingsForm(settings: store.globalBinding)
            TerminalNodeOverridesSection(store: store, nodeName: nodeName)
        }
        .localizedNavigationTitle("터미널 설정")
    }
}
```

`Font(resolved.font)`는 `Font(UIFont)`/`Font(NSFont)` 이니셜라이저(CTFont 브리지)다. 컴파일되지 않으면 `Font(resolved.font as CTFont)`를 쓴다.

- [ ] **Step 3: macOS 설정 재배치**
- `SettingsView.swift`의 `TerminalSettingsTab.body`를 다음 구조로 바꾼다. 기존 tmux `Section`은 내용 그대로 두고, 위치를 폼 뒤로 옮긴다.
```swift
        Form {
            TerminalSettingsForm(settings: settingsStore.globalBinding)
            /* 기존 tmux Section 그대로 */
            TerminalNodeOverridesSection(store: settingsStore)
        }
        .formStyle(.grouped)
```
그리고 `@ObservedObject private var settingsStore = TerminalSettingsStore.shared`를 추가한다. 노드 이름은 이 탭에서 알 수 없으므로 id를 그대로 보여 준다(기본 `nodeName`).
- `AppearanceSettingsTab.swift`에서 `Section { TerminalColorSchemeOptions() } header: { Text("Terminal theme") }` 블록을 **삭제**한다.

- [ ] **Step 4: iOS 설정** — `SettingsScreen.swift`의 `NavigationLink("터미널 테마") { TerminalColorSchemeScreen() }`를 다음으로 바꾼다.
```swift
                NavigationLink("터미널 설정") {
                    TerminalSettingsScreen(nodeName: { id in dashboardVM.devices.first { $0.id == id }?.displayName ?? id })
                }
                .accessibilityIdentifier("settings-terminal-scheme")
```
(기존 identifier는 테스트 호환을 위해 유지한다.) `dashboardVM.devices`와 `displayName`이 실제 이름과 다르면 `grep -n "var devices\|displayName" Hydra/Hydra/ViewModels/DashboardViewModel.swift Hydra/Hydra/Models/Device.swift`로 확인해 맞춘다.

- [ ] **Step 5: 번역 테이블** — 두 테이블의 `/* MARK: terminal settings */` 블록에 추가한다(ko 값 = 원문). 이미 있는 키는 건너뛴다(`grep -n '"키"'`로 확인).
- `"색상 테마" = "Color theme"`, `"폰트" = "Font"`, `"크기 %lld pt" = "Size %lld pt"`, `"동작" = "Behavior"`, `"커서" = "Cursor"`, `"스크롤백" = "Scrollback"`, `"%lld줄" = "%lld lines"`, `"(사용할 수 없음)" = "(unavailable)"`, `"노드별 설정이 없습니다." = "No per-node settings."`, `"초기화" = "Reset"`, `"노드별 설정" = "Per-node settings"`, `"터미널 화면의 ⚙에서 '전체 설정 따르기'를 끄면 그 노드만의 설정을 쓸 수 있습니다." = "Turn off 'Use global settings' from ⚙ in a terminal to give that node its own settings."`, `"터미널 설정" = "Terminal settings"`
- 더 이상 쓰이지 않는 `"터미널 테마"`, `"Terminal theme"` 키는 두 테이블에서 지운다. 지우기 전에 `grep -rn '"터미널 테마"\|"Terminal theme"' Hydra/Hydra Hydra/HydraiOS --include=*.swift`로 사용처가 없는지 확인한다.

- [ ] **Step 6: 확인**

Run: `swift test 2>&1 | grep -E "Executed .* tests|error:" | tail -2 && swift build 2>&1 | tail -2`
Expected: 0 failures (LocalizationTableTests 포함), `Build complete!`

Run: `xcodegen generate >/dev/null && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Hydra/Hydra/Theme Hydra/Hydra/Views/Settings Hydra/HydraiOS/Screens/SettingsScreen.swift Hydra/Hydra/Resources
git commit -m "feat(settings): 터미널 설정을 외형에서 분리 — 공유 폼 + 노드별 설정 목록"
```

---

### Task 5: 터미널 안 설정 패널 + 단축키

**Files:**
- Create: `Hydra/Theme/TerminalNodeSettingsPanel.swift`, `HydraiOSUITests/TerminalNodeSettingsUITests.swift`
- Modify: `Hydra/Views/Terminal/TerminalView.swift` (`TerminalSessionPane`), `HydraiOS/Terminal/TerminalScreen.swift`, `Hydra/HydraApp.swift` (`CommandMenu("Terminal")`), 두 번역 테이블

**Interfaces:**
- Consumes: Task 1 스토어, Task 4 `TerminalSettingsForm(settings:)`, `store.binding(for:)`, `store.globalBinding`, `TerminalSessionStore.shared.activeSessionId`
- Produces:
  - `struct TerminalNodeSettingsPanel: View { init(deviceID: String, nodeName: String, store: TerminalSettingsStore = .shared) }`
  - `extension TerminalSettingsStore { func adjustFontSize(_ deviceID: String, by delta: Double); func resetFontSize(_ deviceID: String) }`

- [ ] **Step 1: 크기 조절 테스트 추가** — `Tests/HydraTests/TerminalSettingsStoreTests.swift`에 추가:

```swift
    func testAdjustFontSizeTurnsOffFollowAndClamps() {
        var g = store.global; g.fontSize = 13; store.global = g
        store.adjustFontSize("node-a", by: 1)
        XCTAssertFalse(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 14)
        XCTAssertEqual(store.global.fontSize, 13)
        for _ in 0..<40 { store.adjustFontSize("node-a", by: 1) }
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 32)
        store.resetFontSize("node-a")
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 13)
    }
```
Run: `swift test --filter testAdjustFontSizeTurnsOffFollowAndClamps 2>&1 | tail -5` → 컴파일 실패(`adjustFontSize` 없음)

- [ ] **Step 2: 패널과 크기 조절 구현** — `Hydra/Theme/TerminalNodeSettingsPanel.swift`

```swift
import SwiftUI

extension TerminalSettingsStore {
    /// ⌘= / ⌘- — 그 노드만 바꾼다(전체 설정을 따르던 노드는 자동으로 노드 설정이 된다).
    func adjustFontSize(_ deviceID: String, by delta: Double) {
        update(deviceID) { $0.fontSize += delta }
    }

    /// ⌘0 — 노드 크기를 전체 설정의 크기로 되돌린다.
    func resetFontSize(_ deviceID: String) {
        let size = global.fontSize
        update(deviceID) { $0.fontSize = size }
    }
}

/// 터미널 화면 안 설정 패널. 끄면 이 노드만의 설정을 편집하고, 켜면 전체 설정을 보여 주기만 한다.
struct TerminalNodeSettingsPanel: View {
    let deviceID: String
    let nodeName: String
    @ObservedObject var store: TerminalSettingsStore

    init(deviceID: String, nodeName: String, store: TerminalSettingsStore = .shared) {
        self.deviceID = deviceID
        self.nodeName = nodeName
        self.store = store
    }

    private var follow: Binding<Bool> {
        Binding(get: { store.isFollowingGlobal(deviceID) },
                set: { store.setFollowingGlobal($0, for: deviceID) })
    }

    var body: some View {
        Form {
            Section {
                Toggle("전체 설정 따르기", isOn: follow)
                    .accessibilityIdentifier("terminal-node-follow-global")
            } header: {
                Text(verbatim: nodeName)
            } footer: {
                Text(follow.wrappedValue
                     ? "설정 화면의 터미널 설정을 그대로 씁니다."
                     : "여기서 바꾼 값은 이 노드에만 적용됩니다.")
            }
            Group {
                if follow.wrappedValue {
                    TerminalSettingsForm(settings: .constant(store.global)).disabled(true)
                } else {
                    TerminalSettingsForm(settings: store.binding(for: deviceID))
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

`Text(follow.wrappedValue ? "…" : "…")`는 삼항식이라 `String`으로 추론될 수 있다. 번역이 적용되도록 `Text(LocalizedStringKey(follow.wrappedValue ? "…" : "…"))`로 쓴다.

Run: `swift test --filter TerminalSettingsStoreTests 2>&1 | tail -3` → 0 failures

- [ ] **Step 3: macOS 진입점** — `TerminalSessionPane`(`Hydra/Views/Terminal/TerminalView.swift`)
- `@State private var showingSettings = false`를 추가한다.
- `VStack(spacing: 0) {`의 첫 자식으로 상단 바를 넣는다(연결 끊김 배너보다 위). **SwiftUI `Button`을 쓰지 않는다.**
```swift
            HStack {
                Spacer()
                // Button 대신 TapLabel — _ButtonGesture 크래시 회피(파일 상단 주석).
                TapLabel(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .help(AppLocalization.string("터미널 설정"))
                }
                .accessibilityIdentifier("terminal-node-settings")
                .popover(isPresented: $showingSettings, arrowEdge: .top) {
                    TerminalNodeSettingsPanel(deviceID: session.deviceId, nodeName: session.deviceName)
                        .frame(width: 420, height: 560)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.bar)
```

- [ ] **Step 4: macOS 단축키** — `Hydra/HydraApp.swift`의 `.commands { … }` 안, `CommandMenu("Chat")` 앞에 추가한다. `TerminalSessionStore`가 `@MainActor`이면 이 블록에서 그대로 접근할 수 있다(Scene body는 메인 액터).
```swift
            CommandMenu("Terminal") {
                Button("Increase Font Size") { adjustActiveTerminalFont(1) }
                    .keyboardShortcut("=")
                Button("Decrease Font Size") { adjustActiveTerminalFont(-1) }
                    .keyboardShortcut("-")
                Button("Reset Font Size") { resetActiveTerminalFont() }
                    .keyboardShortcut("0")
            }
```
그리고 `HydraApp`에 다음 메서드를 추가한다.
```swift
    #if os(macOS)
    /// 활성 터미널 세션(세션 id = 노드 id)의 노드 설정만 바꾼다. 세션이 없으면 아무것도 하지 않는다.
    private func adjustActiveTerminalFont(_ delta: Double) {
        guard let id = TerminalSessionStore.shared.activeSessionId else { return }
        TerminalSettingsStore.shared.adjustFontSize(id, by: delta)
    }

    private func resetActiveTerminalFont() {
        guard let id = TerminalSessionStore.shared.activeSessionId else { return }
        TerminalSettingsStore.shared.resetFontSize(id)
    }
    #endif
```
기존 메뉴(`Edit` 등)에 이미 ⌘=, ⌘-, ⌘0 이 있는지 `grep -n 'keyboardShortcut("="\|keyboardShortcut("-"\|keyboardShortcut("0"' Hydra/Hydra`로 확인하고, 있으면 충돌을 보고서에 적는다. 번역 테이블에는 `"Increase Font Size"`, `"Decrease Font Size"`, `"Reset Font Size"`, `"Terminal"`이 필요하면 추가한다(`CommandMenu`는 locale 주입 밖이라 시스템 언어를 따르며, 스펙상 번역 범위 밖이다. 키가 커버리지 테스트에 걸리지 않으면 추가하지 않는다).

- [ ] **Step 5: iOS 진입점** — `TerminalScreen`(`HydraiOS/Terminal/TerminalScreen.swift`)
- `@State private var showingSettings = false`를 추가한다.
- 기존 modifier 체인(`.navigationBarTitleDisplayMode(.inline)` 다음)에 추가:
```swift
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("터미널 설정") { showingSettings = true }
                        Divider()
                        Button("글자 크게") { settingsStore.adjustFontSize(session.deviceId, by: 1) }
                            .keyboardShortcut("=", modifiers: .command)
                        Button("글자 작게") { settingsStore.adjustFontSize(session.deviceId, by: -1) }
                            .keyboardShortcut("-", modifiers: .command)
                        Button("기본 크기") { settingsStore.resetFontSize(session.deviceId) }
                            .keyboardShortcut("0", modifiers: .command)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("terminal-node-settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    TerminalNodeSettingsPanel(deviceID: session.deviceId, nodeName: device.displayName)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("완료") { showingSettings = false }
                                    .accessibilityIdentifier("terminal-node-settings-done")
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
```
기존 `.toolbar`가 이미 있으면(등록 시트 안의 `.toolbar`는 다른 뷰라 무관) 새 `ToolbarItem`을 그 블록에 합친다.
- DEBUG 전용 probe: `SwiftTermRepresentableiOS(...)` 바로 뒤에 다음 overlay를 붙인다. UI 테스트가 유효 설정을 읽는 데만 쓴다.
```swift
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--terminal-recovery-ui-test") {
                    let s = settingsStore.effective(for: session.deviceId)
                    Text(verbatim: "\(Int(s.fontSize))|\(s.colorSchemeID)")
                        .font(.caption2).opacity(0.01)
                        .accessibilityIdentifier("terminal-settings-probe")
                }
            }
            #endif
```

- [ ] **Step 6: 번역 테이블** — 두 테이블의 terminal settings 블록에 추가한다(ko 값 = 원문).
- `"전체 설정 따르기" = "Use global settings"`, `"설정 화면의 터미널 설정을 그대로 씁니다." = "Uses the terminal settings from Settings."`, `"여기서 바꾼 값은 이 노드에만 적용됩니다." = "Changes here apply only to this node."`, `"글자 크게" = "Bigger text"`, `"글자 작게" = "Smaller text"`, `"기본 크기" = "Default size"`, `"완료" = "Done"`(이미 있으면 건너뜀)

- [ ] **Step 7: iOS UI 테스트** — `HydraiOSUITests/TerminalNodeSettingsUITests.swift`

recovery fixture는 `.standard` defaults를 쓴다. launch argument로 노드 설정을 넣으면 argument domain이 앱이 쓴 값을 가리므로 쓰지 않는다. 대신 테스트가 시작할 때 "따르기"를 켜서 이전 실행이 남긴 값을 지우고, 끝날 때 다시 켜서 되돌린다.

```swift
import XCTest

final class TerminalNodeSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--terminal-recovery-ui-test", "-appLanguage", "ko"]
        app.launch()
        let device = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "fixture-machine")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        device.tap()
        XCTAssertTrue(app.staticTexts["terminal-settings-probe"].waitForExistence(timeout: 10))
    }

    override func tearDown() {
        // 다음 실행을 위해 노드 설정을 지운다.
        openPanel()
        setFollow(true)
        closePanel()
        app.terminate()
    }

    private func openPanel() {
        app.buttons["terminal-node-settings"].firstMatch.tap()
        app.buttons["터미널 설정"].firstMatch.tap()
        XCTAssertTrue(app.switches["terminal-node-follow-global"].firstMatch.waitForExistence(timeout: 5))
    }

    private func closePanel() {
        app.buttons["terminal-node-settings-done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["terminal-settings-probe"].waitForExistence(timeout: 5))
    }

    private func setFollow(_ on: Bool) {
        let follow = app.switches["terminal-node-follow-global"].firstMatch
        if (follow.value as? String == "1") != on { follow.tap() }
        XCTAssertEqual(follow.value as? String, on ? "1" : "0")
    }

    private var probeSize: Int {
        Int(app.staticTexts["terminal-settings-probe"].label.split(separator: "|")[0])!
    }

    func testNodeOverrideChangesOnlyThisTerminal() {
        openPanel()
        setFollow(true)
        closePanel()
        let globalSize = probeSize

        openPanel()
        setFollow(false)
        let stepper = app.steppers["terminal-settings-size"].firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        stepper.buttons.element(boundBy: 1).tap()   // 증가
        closePanel()
        XCTAssertEqual(probeSize, globalSize + 1)

        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "terminal-node-override"
        capture.lifetime = .keepAlways
        add(capture)

        openPanel()
        setFollow(true)
        closePanel()
        XCTAssertEqual(probeSize, globalSize, "따르기를 다시 켜면 전체 설정 크기로 돌아와야 한다")
    }
}
```

- [ ] **Step 8: 확인**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1 && swift build 2>&1 | tail -2`
Expected: 0 failures, `Build complete!`

Run: `xcodegen generate >/dev/null && D='platform=iOS Simulator,id=E72726B6-1862-456F-A01D-278DB9364E27'; xcodebuild -project Hydra.xcodeproj -scheme TerminalInputUITests -destination "$D" test -only-testing:TerminalInputUITests/TerminalNodeSettingsUITests 2>&1 | grep -E "Executed|SUCCEEDED|FAILED|error" | tail -4`
Expected: `** TEST SUCCEEDED **` — 같은 명령을 두 번 실행해 두 번 모두 통과해야 한다.

Run: `xcodebuild -project Hydra.xcodeproj -scheme TerminalInputUITests -destination "$D" test -only-testing:TerminalInputUITests/TerminalKeyRecoveryUITests -only-testing:TerminalInputUITests/SettingsPreferencesUITests 2>&1 | grep -E "SUCCEEDED|FAILED" | tail -2`
Expected: `** TEST SUCCEEDED **` (기존 UI 테스트 회귀 없음)

- [ ] **Step 9: Commit**

```bash
git add Hydra/Hydra/Theme/TerminalNodeSettingsPanel.swift Hydra/Hydra/Views/Terminal/TerminalView.swift Hydra/HydraiOS/Terminal/TerminalScreen.swift Hydra/Hydra/HydraApp.swift Hydra/Hydra/Resources Hydra/HydraiOSUITests/TerminalNodeSettingsUITests.swift Hydra/Tests/HydraTests/TerminalSettingsStoreTests.swift
git commit -m "feat(terminal): 터미널 안 노드별 설정 패널 + ⌘=/⌘-/⌘0"
```

---

### Task 6: 통합 확인 (controller)

- [ ] **Step 1:** macOS `swift test` 전체 — 0 failures
- [ ] **Step 2:** iOS `TerminalInputTests` 전체와 `TerminalInputUITests` 전체 — SUCCEEDED
- [ ] **Step 3:** 사용자 동의 하에 설치된 `/Applications/Hydra.app`을 종료하고 `./scripts/bundle-app.sh debug`로 만든 앱을 띄운다. 두 노드 세션을 연 뒤, 한쪽에서 ⚙ popover로 따르기를 끄고 Dracula와 16pt로 바꾼다. 다른 쪽이 그대로인지, 설정 창 Terminal 탭의 노드별 설정 목록에 그 노드가 보이는지 스크린샷으로 확인한다. 끝나면 개발 빌드를 종료하고 설치된 앱을 다시 실행한다. 이 과정에서 생긴 `terminal*` defaults 값은 확인 전 상태로 되돌린다.
