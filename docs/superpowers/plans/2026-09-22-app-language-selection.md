# 앱 언어 선택 (English / 한국어) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS·iOS 두 앱의 설정에서 English / 한국어 중 하나를 고르고, 앱 화면 전체를 그 언어로 보여 준다.

**Architecture:** iOS에 이미 있는 방식(`@AppStorage("appLanguage")` → `.environment(\.locale)` + `AppLocalization.string`)을 공유 폴더로 옮겨 macOS도 쓴다. 번역 테이블은 `Hydra/Hydra/Resources/{ko,en}.lproj/Localizable.strings` 하나로 통합한다. iOS는 XcodeGen 리소스로, macOS는 `bundle-app.sh`가 `.app`에 복사하는 방식으로 쓴다. "시스템 설정" 선택지는 없애고, 저장값이 없거나 옛 값이면 기기 언어로 한 번 정해 저장한다.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftPM(macOS), XcodeGen(iOS), XCTest

**Spec:** `docs/superpowers/specs/2026-09-22-app-language-selection-design.md`

## Global Constraints

- 모든 코드 경로는 `hydra/Hydra/` 기준이다 (git 루트는 `hydra/`). 빌드·테스트는 `hydra/Hydra`에서, git은 `hydra/`에서 실행한다.
- 선택지는 `korean = "ko"`, `english = "en"` 두 가지다. 저장 키는 `appLanguage`로 유지한다.
- 기본값: 저장값이 없거나 `"system"`이거나 알 수 없는 값이면 `deviceDefault()`로 정한다. 선호 언어 중 처음 나오는 ko/en을 쓰고, 둘 다 없으면 English다.
- 번역 키는 코드에 쓰인 원문 그대로다. ko·en 두 테이블의 키 집합은 항상 같아야 한다.
- 장치 이름, 호스트명, 서버 응답, 명령어·경로, 로그 원문은 번역하지 않는다.
- `Hydra.xcodeproj`는 gitignore된 생성물이다. 파일을 옮기거나 추가하면 `xcodegen generate`를 실행한다.
- 시뮬레이터를 erase하거나 삭제하지 않는다. 이름으로 지정한 destination이 모호하면 `-destination 'platform=iOS Simulator,id=E72726B6-1862-456F-A01D-278DB9364E27'`를 쓴다.
- 커밋 메시지 끝에 빈 줄을 두고 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`를 붙인다.

## File Structure

| 파일 | 역할 |
|---|---|
| Move `HydraiOS/Resources/{ko,en}.lproj` → `Hydra/Resources/{ko,en}.lproj` | 공유 번역 테이블 |
| Move `HydraiOS/Appearance/AppAppearancePreferences.swift` → `Hydra/Theme/AppAppearancePreferences.swift` | 공유 언어 모델·조회 |
| Modify `project.yml`, `Package.swift`, `scripts/bundle-app.sh`, `Info.plist` | 리소스 연결 |
| Create `Tests/HydraTests/LocalizationTableTests.swift` | 테이블 짝 맞춤 + macOS Views 리터럴 커버리지 |
| Create `Tests/HydraTests/AppLanguageTests.swift` | deviceDefault·마이그레이션 |
| Modify `HydraiOS/App.swift`, `Hydra/HydraApp.swift` | 시작 시 마이그레이션 |
| Modify `HydraiOS/Appearance/AppearanceSettingsSection.swift`, `HydraiOSInputTests/AppAppearancePreferencesTests.swift` | iOS 정리 |
| Modify `Hydra/Views/Settings/AppearanceSettingsTab.swift` | macOS locale 주입 + Language Picker |
| Modify `Hydra/Views/**/*.swift` (iOS 폴더 제외) | macOS 문자열 현지화 |

---

### Task 1: 번역 테이블 통합 + 리소스 연결

**Files:**
- Move: `HydraiOS/Resources/ko.lproj`, `HydraiOS/Resources/en.lproj` → `Hydra/Resources/`
- Modify: `project.yml` (HydraiOS 타겟 `sources`), `Package.swift` (Hydra executableTarget), `scripts/bundle-app.sh` (3/7 단계 뒤), `Info.plist`
- Test: `Tests/HydraTests/LocalizationTableTests.swift`

**Interfaces:**
- Produces: 테이블 경로 `Hydra/Resources/{ko,en}.lproj/Localizable.strings`. 테스트 헬퍼 `LocalizationTableTests.table(_ language: String) -> [String: String]`(private), 패키지 루트 기준 경로 계산은 `#filePath`에서 3단계 위.

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/HydraTests/LocalizationTableTests.swift`

```swift
import XCTest

/// 공유 번역 테이블(Hydra/Resources)의 ko·en 키가 어긋나지 않는지 소스 파일에서 직접 확인한다.
final class LocalizationTableTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // HydraTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root (hydra/Hydra)

    static func table(_ language: String) throws -> [String: String] {
        let url = packageRoot.appendingPathComponent("Hydra/Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(text.propertyListFromStringsFileFormat(), url.path)
    }

    func testKoreanAndEnglishTablesHaveTheSameKeys() throws {
        let ko = try Self.table("ko"), en = try Self.table("en")
        XCTAssertFalse(ko.isEmpty)
        XCTAssertEqual(Set(ko.keys).subtracting(en.keys).sorted(), [], "ko에만 있는 키")
        XCTAssertEqual(Set(en.keys).subtracting(ko.keys).sorted(), [], "en에만 있는 키")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter LocalizationTableTests 2>&1 | tail -8`
Expected: FAIL. 파일이 아직 옮겨지지 않았으므로 `String(contentsOf:)`가 파일 없음 오류를 던진다.

- [ ] **Step 3: 테이블 이동** (git 루트 `hydra/`에서)

```bash
mkdir -p Hydra/Hydra/Resources
git mv Hydra/HydraiOS/Resources/ko.lproj Hydra/Hydra/Resources/ko.lproj
git mv Hydra/HydraiOS/Resources/en.lproj Hydra/Hydra/Resources/en.lproj
```
`Hydra/HydraiOS/Resources/`에 다른 파일이 남아 있으면 그대로 둔다.

- [ ] **Step 4: SwiftPM에서 제외** — `Package.swift`의 Hydra `executableTarget`에서 `path: "Hydra",` 다음 줄에 추가:

```swift
            // 번역 테이블은 scripts/bundle-app.sh가 .app/Contents/Resources로 직접 복사한다
            // (SwiftUI Text 리터럴이 Bundle.main에서 찾도록). SwiftPM 리소스로 넣으면 Bundle.module로 가고
            // defaultLocalization도 요구하므로 제외한다.
            exclude: ["Resources"],
```

- [ ] **Step 5: iOS 타겟에 추가** — `project.yml`의 `HydraiOS` 타겟 `sources:` 목록에서 `- path: Hydra/Theme` 다음 줄에 추가:

```yaml
      - path: Hydra/Resources     # 공유 번역 테이블 (ko/en .lproj)
```

- [ ] **Step 6: macOS 번들에 복사** — `scripts/bundle-app.sh`의 `[3/7]` 블록(`cp -R "$RESOURCE_BUNDLE" ...` 의 `fi`) 바로 다음에 추가:

```bash
# 공유 번역 테이블 — SwiftUI Text 리터럴은 Bundle.main에서 .lproj를 찾는다.
cp -R Hydra/Resources/*.lproj "$APP/Contents/Resources/"
```

그리고 macOS `Info.plist`의 `CFBundleDevelopmentRegion` 항목 다음에 추가:

```xml
    <key>CFBundleLocalizations</key>
    <array>
        <string>ko</string>
        <string>en</string>
    </array>
```

- [ ] **Step 7: 테스트·빌드 확인**

Run: `swift test --filter LocalizationTableTests 2>&1 | tail -5 && swift build 2>&1 | tail -2`
Expected: `Executed 1 test, with 0 failures`, `Build complete!`

Run: `xcodegen generate && xcodebuild -project Hydra.xcodeproj -scheme TerminalInputTests -destination 'platform=iOS Simulator,id=E72726B6-1862-456F-A01D-278DB9364E27' test -only-testing:TerminalInputTests/AppAppearancePreferencesTests 2>&1 | grep -E "Executed|SUCCEEDED|FAILED" | tail -3`
Expected: `** TEST SUCCEEDED **`. 이 테스트는 옮긴 테이블을 iOS `Bundle.main`에서 조회한다.

- [ ] **Step 8: Commit**

```bash
git add -A Hydra/Hydra/Resources Hydra/HydraiOS/Resources Hydra/Package.swift Hydra/project.yml Hydra/scripts/bundle-app.sh Hydra/Info.plist Hydra/Tests/HydraTests/LocalizationTableTests.swift
git commit -m "build(i18n): ko/en 번역 테이블을 iOS·macOS 공유로 이동"
```

---

### Task 2: 언어 모델 공유화 + "시스템 설정" 제거 + 마이그레이션

**Files:**
- Move: `HydraiOS/Appearance/AppAppearancePreferences.swift` → `Hydra/Theme/AppAppearancePreferences.swift`
- Modify: 옮긴 파일, `HydraiOS/App.swift`, `Hydra/HydraApp.swift`, `HydraiOS/Appearance/AppearanceSettingsSection.swift`, `Hydra/Resources/{ko,en}.lproj/Localizable.strings`, `HydraiOSInputTests/AppAppearancePreferencesTests.swift`
- Test: `Tests/HydraTests/AppLanguageTests.swift`

**Interfaces:**
- Consumes: Task 1의 테이블 경로
- Produces:
  - `enum AppDisplayLanguage: String, CaseIterable, Identifiable { case korean = "ko", english = "en"; var label: String; static func deviceDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> AppDisplayLanguage }`
  - `AppAppearancePreferences.languageKey`(= `"appLanguage"`), `.language`, `func migrateLanguageIfNeeded(preferredLanguages: [String] = Locale.preferredLanguages)`
  - `AppLocalization.string(_:language:defaults:bundle:)`, `AppLocalizedText(_:)` (시그니처 유지)
  - `resolvedIdentifier(...)`는 삭제한다. 호출부는 `rawValue`로 바꾼다.

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/HydraTests/AppLanguageTests.swift`

```swift
import XCTest
@testable import Hydra

final class AppLanguageTests: XCTestCase {
    func testDeviceDefaultPicksFirstSupportedPreferredLanguage() {
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ko-KR", "en-US"]), .korean)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["fr-FR", "en-GB"]), .english)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ja-JP", "ko_KR"]), .korean)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: []), .english)
    }

    func testOnlyKoreanAndEnglishAreSelectable() {
        XCTAssertEqual(AppDisplayLanguage.allCases.map(\.rawValue), ["ko", "en"])
    }

    func testMigrationStoresDeviceLanguageWhenMissingOrLegacy() throws {
        try withDefaults { defaults in
            AppAppearancePreferences(defaults: defaults).migrateLanguageIfNeeded(preferredLanguages: ["ko-KR"])
            XCTAssertEqual(defaults.string(forKey: "appLanguage"), "ko")
        }
        try withDefaults { defaults in
            defaults.set("system", forKey: "appLanguage")
            AppAppearancePreferences(defaults: defaults).migrateLanguageIfNeeded(preferredLanguages: ["fr-FR"])
            XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        }
    }

    func testMigrationKeepsExplicitChoice() throws {
        try withDefaults { defaults in
            defaults.set("en", forKey: "appLanguage")
            AppAppearancePreferences(defaults: defaults).migrateLanguageIfNeeded(preferredLanguages: ["ko-KR"])
            XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "hydra.language.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppLanguageTests 2>&1 | tail -8`
Expected: 컴파일 실패 `cannot find 'AppDisplayLanguage' in scope` (아직 iOS 전용 폴더에 있음)

- [ ] **Step 3: 파일 이동** (git 루트에서)

```bash
git mv Hydra/HydraiOS/Appearance/AppAppearancePreferences.swift Hydra/Hydra/Theme/AppAppearancePreferences.swift
```

- [ ] **Step 4: `AppDisplayLanguage` 교체** — 옮긴 파일에서 `enum AppDisplayLanguage ... { ... }` 전체를 다음으로 바꾼다.

```swift
enum AppDisplayLanguage: String, CaseIterable, Identifiable {
    case korean = "ko"
    case english = "en"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .korean: return "한국어"
        case .english: return "English"
        }
    }

    /// 기기 선호 언어 중 처음 나오는 ko/en. 둘 다 없으면 English.
    static func deviceDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> AppDisplayLanguage {
        for identifier in preferredLanguages {
            let code = identifier.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first?.lowercased()
            if code == "ko" { return .korean }
            if code == "en" { return .english }
        }
        return .english
    }
}
```

- [ ] **Step 5: 설정·조회 코드 수정** (같은 파일)

`AppAppearancePreferences.language` getter:
```swift
        get { AppDisplayLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .deviceDefault() }
```
`theme` 프로퍼티 다음에 추가:
```swift
    /// 저장값이 없거나 예전 "system"·알 수 없는 값이면 기기 언어로 한 번 정해 저장한다.
    func migrateLanguageIfNeeded(preferredLanguages: [String] = Locale.preferredLanguages) {
        guard AppDisplayLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") == nil else { return }
        language = .deviceDefault(preferredLanguages: preferredLanguages)
    }
```
나머지 호출부 (`grep -n "resolvedIdentifier\|\.system" Hydra/Theme/AppAppearancePreferences.swift`로 찾기):
- `AppLocalization.string`: `let identifier = (language ?? AppAppearancePreferences(defaults: defaults).language).rawValue`
- `AppLocalization.format`: `locale: Locale(identifier: language.rawValue),`
- `AppLocalizedText.body`: `let language = AppDisplayLanguage(rawValue: locale.language.languageCode?.identifier ?? "") ?? AppAppearancePreferences().language`
- `HydraAppearancePreferencesModifier`: `@AppStorage(AppAppearancePreferences.languageKey) private var languageRaw = AppDisplayLanguage.deviceDefault().rawValue`, `let language = AppDisplayLanguage(rawValue: languageRaw) ?? .deviceDefault()`, `.environment(\.locale, Locale(identifier: language.rawValue))`
- `AppTheme` 쪽 `.system`은 건드리지 않는다.

- [ ] **Step 6: 앱 시작 시 마이그레이션**

`HydraiOS/App.swift`: `appearanceDefaults`를 `private static var appearanceDefaults: UserDefaults`로 바꾸고, `.defaultAppStorage(Self.appearanceDefaults)`로 쓰고, 다음을 추가:
```swift
    init() {
        AppAppearancePreferences(defaults: Self.appearanceDefaults).migrateLanguageIfNeeded()
    }
```
`Hydra/HydraApp.swift`: `@StateObject` 선언들 다음에 추가:
```swift
    init() {
        AppAppearancePreferences().migrateLanguageIfNeeded()
    }
```

- [ ] **Step 7: iOS 설정 섹션** — `HydraiOS/Appearance/AppearanceSettingsSection.swift`
- `languageRaw` 기본값: `AppDisplayLanguage.deviceDefault().rawValue`
- getter 폴백: `AppDisplayLanguage(rawValue: languageRaw) ?? .deviceDefault()`
- footer: `Text("선택하면 바로 적용됩니다.")`
- Picker 선택지 라벨은 `Text(verbatim: choice.label)`로 바꾼다. 언어 이름은 번역하지 않고 각 언어 표기로 보여 준다.

두 테이블에서 옛 footer 키 줄 `"선택하면 바로 적용됩니다. 시스템 설정을 선택하면 기기 설정을 따릅니다." = ...;`를 삭제하고 추가한다. 삭제하기 전에 `grep -rn "시스템 설정을 선택하면" Hydra HydraiOS`로 다른 사용처가 없는지 확인한다.
- ko: `"선택하면 바로 적용됩니다." = "선택하면 바로 적용됩니다.";`
- en: `"선택하면 바로 적용됩니다." = "Changes apply immediately.";`

`"System"` 키는 `AppTheme` 라벨에서도 쓰므로 남긴다.

- [ ] **Step 8: iOS 단위 테스트 갱신** — `HydraiOSInputTests/AppAppearancePreferencesTests.swift`
- `testInvalidStoredValuesFallBackToSystem`: `XCTAssertEqual(preferences.language, .system)`를 `XCTAssertEqual(preferences.language, .deviceDefault())`로 바꾼다 (theme assert는 그대로).
- `testLanguageSelectionResolvesSupportedPreferredLanguages` 본문을 교체:
```swift
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ko-KR", "en-US"]), .korean)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["fr-FR", "en-GB"]), .english)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ja-JP", "ko_KR"]), .korean)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(AppDisplayLanguage.english.rawValue, "en")
        XCTAssertEqual(AppDisplayLanguage.korean.rawValue, "ko")
```

- [ ] **Step 9: 확인**

Run: `swift test --filter "AppLanguageTests|LocalizationTableTests" 2>&1 | tail -5 && swift build 2>&1 | tail -2`
Expected: 5 tests 0 failures, `Build complete!`

Run: `xcodegen generate && xcodebuild -project Hydra.xcodeproj -scheme TerminalInputTests -destination 'platform=iOS Simulator,id=E72726B6-1862-456F-A01D-278DB9364E27' test -only-testing:TerminalInputTests/AppAppearancePreferencesTests 2>&1 | grep -E "Executed|SUCCEEDED|FAILED" | tail -3`
Expected: `** TEST SUCCEEDED **`

Run: `xcodebuild -project Hydra.xcodeproj -scheme TerminalInputUITests -destination 'platform=iOS Simulator,id=E72726B6-1862-456F-A01D-278DB9364E27' test -only-testing:TerminalInputUITests/SettingsPreferencesUITests 2>&1 | grep -E "Executed|SUCCEEDED|FAILED" | tail -3`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 10: Commit**

```bash
git add -A Hydra/Hydra/Theme/AppAppearancePreferences.swift Hydra/HydraiOS/Appearance Hydra/HydraiOS/App.swift Hydra/Hydra/HydraApp.swift Hydra/Hydra/Resources Hydra/HydraiOSInputTests/AppAppearancePreferencesTests.swift Hydra/Tests/HydraTests/AppLanguageTests.swift
git commit -m "feat(i18n): 언어 선택을 한국어/English 둘로 — 기기 언어로 1회 마이그레이션, 모델 공유화"
```

---

### Task 3: macOS locale 주입 + Language Picker

**Files:**
- Modify: `Hydra/Views/Settings/AppearanceSettingsTab.swift` (`AppearanceModifier`, `AppearanceSettingsTab`)
- Modify: `Hydra/Resources/{ko,en}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `AppAppearancePreferences.languageKey`, `AppDisplayLanguage.deviceDefault()`, `.allCases`, `.label`
- Produces: 모든 macOS 씬이 `.appAppearance()`를 통해 `\.locale`을 받는다 (Task 4가 여기에 의존).

- [ ] **Step 1: locale 주입** — `AppearanceModifier`에 추가:

```swift
    @AppStorage(AppAppearancePreferences.languageKey) private var language = AppDisplayLanguage.deviceDefault().rawValue
```
`body`의 modifier 체인 끝에 추가:
```swift
            .environment(\.locale, Locale(identifier: (AppDisplayLanguage(rawValue: language) ?? .deviceDefault()).rawValue))
```

- [ ] **Step 2: Language Picker** — `AppearanceSettingsTab`에 다음 프로퍼티를 추가한다.
```swift
    @AppStorage(AppAppearancePreferences.languageKey) private var language = AppDisplayLanguage.deviceDefault().rawValue
```
`Form {` 바로 다음(맨 위 섹션)에 추가:
```swift
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppDisplayLanguage.allCases) { Text(verbatim: $0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Language")
            }
```

- [ ] **Step 3: 테이블** — 두 파일 끝에 추가 (이미 있으면 건너뜀):
- ko: `"Language" = "언어";`
- en: `"Language" = "Language";`

- [ ] **Step 4: 확인**

Run: `swift build 2>&1 | tail -2 && swift test --filter LocalizationTableTests 2>&1 | tail -3`
Expected: `Build complete!`, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Hydra/Hydra/Views/Settings/AppearanceSettingsTab.swift Hydra/Hydra/Resources
git commit -m "feat(i18n): macOS 앱 locale 주입 + Appearance 탭 Language 선택"
```

---

### Task 4: macOS 화면 문자열 현지화

**Files:**
- Modify: `Hydra/Views/**/*.swift` 중 `Hydra/Views/iOS/` 제외 (ContentView, ConnectionView, Settings/*, Terminal/*, Devices/*, Console/*, Dashboard/*, Chat/*, MenuBar/*, Orchs/*, Tasks/*)
- Modify: `Hydra/Resources/{ko,en}.lproj/Localizable.strings`
- Test: `Tests/HydraTests/LocalizationTableTests.swift`에 커버리지 테스트 추가

**Interfaces:**
- Consumes: Task 1 `LocalizationTableTests.table(_:)`, `packageRoot`. Task 2 `AppLocalization.string(_:)`, `AppLocalizedText(_:)`. Task 3의 locale 주입.

- [ ] **Step 1: 실패하는 커버리지 테스트 추가** — `LocalizationTableTests`에 메서드 추가:

```swift
    /// macOS 화면의 LocalizedStringKey 리터럴(보간 없는 것)은 모두 테이블에 키가 있어야 한다.
    func testMacViewLiteralsHaveTranslations() throws {
        let en = try Self.table("en")
        let views = Self.packageRoot.appendingPathComponent("Hydra/Views")
        let pattern = try NSRegularExpression(pattern:
            #"(?:Text|Button|Label|Section|Toggle|Picker|TextField|SecureField|Menu|LabeledContent|navigationTitle|help|alert|confirmationDialog)\(\s*"((?:[^"\\]|\\.)+)""#)
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Views/iOS/") && !$0.path.contains("/.omc/") }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                let key = String(source[Range(match.range(at: 1), in: source)!])
                if key.contains("\\(") { continue }        // 보간 리터럴은 포맷 키로 따로 관리
                if en[key] == nil { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        XCTAssertEqual(missing.sorted(), [], "번역 키 누락")
    }
```

- [ ] **Step 2: 실패 확인 + 누락 목록 확보**

Run: `swift test --filter testMacViewLiteralsHaveTranslations 2>&1 | grep -A200 "번역 키 누락" | head -200`
Expected: FAIL과 함께 누락된 키 목록이 출력된다. 이 목록이 작업 대상이다.

- [ ] **Step 3: 테이블 채우기** — 누락된 키마다 두 테이블 끝에 추가한다. 파일 단위로 `// MARK: macOS <파일명>` 주석 블록을 만든다.
- 한국어 원문 키: ko 값 = 원문, en 값 = 자연스러운 영어
- 영어 원문 키: en 값 = 원문, ko 값 = 자연스러운 한국어
- 번역하면 안 되는 고유명사·기술 용어(GPU, SSH, Tailscale, API, JSON 등)만 있는 키: 양쪽 값 모두 원문
- 기존 iOS 번역에 같은 뜻의 문구가 있으면 그 표현을 그대로 쓴다 (예: "설정" = "Settings")

- [ ] **Step 4: 동적 문자열 감싸기** — 테스트가 잡지 못하는, `String`으로 흘러가는 사용자 노출 문구를 찾는다.

Run: `grep -rn '"[^"]*[가-힣][^"]*"' Hydra/Views --include=*.swift | grep -v "/Views/iOS/"` 그리고 `grep -rnE '(\?\s*"|:\s*"|= "|return ")[A-Z][a-z]+' Hydra/Views --include=*.swift | grep -v "/Views/iOS/"`
- 삼항식, `let label = "..."`, `return "..."`, `Text(someString)`, `?? "연결 끊김"`처럼 `String` 타입으로 쓰이는 사용자 문구는 다음처럼 감싼다.
  - `Text` 위치에서 쓰이면: `AppLocalizedText("…")`
  - 값으로 쓰이면: `AppLocalization.string("…")`
  - 그리고 키를 두 테이블에 추가한다.
- 보간이 있는 `Text("\(n)개 연결")` 형태는 SwiftUI가 `%lld`/`%@` 포맷 키로 조회한다. 포맷 키로 테이블에 추가한다 (예: `"%lld개 연결" = "%lld connected";`).
- 번역 금지 대상(장치 이름, 호스트명, 서버 응답, 명령어·경로, 로그 원문, `Text(verbatim:)`)은 건드리지 않는다.
- macOS 26 크래시 완화 규칙이 있는 `Terminal/TerminalView.swift`에서는 `Button`과 `.task`를 새로 넣지 않는다. 문자열 교체만 한다.

- [ ] **Step 5: 확인**

Run: `swift test --filter LocalizationTableTests 2>&1 | tail -3 && swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: LocalizationTableTests 2 tests 0 failures, `Build complete!`, 전체 0 failures

Run: `xcodegen generate && xcodebuild -project Hydra.xcodeproj -scheme HydraiOS -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -2`
Expected: `** BUILD SUCCEEDED **` (공유 테이블이 바뀌었으므로 iOS도 확인)

- [ ] **Step 6: Commit**

```bash
git add Hydra/Hydra/Views Hydra/Hydra/Resources Hydra/Tests/HydraTests/LocalizationTableTests.swift
git commit -m "feat(i18n): macOS 화면 문자열 ko/en 현지화 + 리터럴 커버리지 테스트"
```

---

### Task 5: 통합 확인 (controller)

- [ ] **Step 1:** macOS `swift test` 전체 — 0 failures
- [ ] **Step 2:** iOS `TerminalInputTests` 전체와 `SettingsPreferencesUITests` — SUCCEEDED
- [ ] **Step 3:** `./scripts/bundle-app.sh debug`를 실행한 뒤 `open "$(swift build -c debug --show-bin-path)/Hydra.app" --args -appLanguage en`로 띄운다. 메인 창을 `screencapture -x`로 캡처해 영어로 나오는지 확인하고, `-appLanguage ko`로 다시 띄워 한국어도 확인한다.
