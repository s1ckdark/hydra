# UI 스타일 프리셋 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Appearance 설정에서 전환 가능한 UI 스타일 프리셋 4종(클래식·라운드·모던·아방가르드)을 토큰 기반으로 도입하고, 기본값을 라운드로 한다.

**Architecture:** `Theme` 토큰 구조체(반경·그림자·보더·폰트)를 SwiftUI Environment로 전 씬에 주입하고, 뷰의 하드코딩된 `cornerRadius`/`shadow`를 토큰 참조로 치환한다. 프리셋은 `AppStyle` enum의 static 토큰 값 묶음이며 뷰에는 프리셋 분기가 없다.

**Tech Stack:** SwiftUI (macOS 15+), SwiftPM, XCTest. 스펙: `docs/superpowers/specs/2026-07-15-style-presets-design.md`

## Global Constraints

- Swift 5 언어 모드 (`Package.swift`의 `.swiftLanguageMode(.v5)`), macOS 15 / iOS 17 플랫폼.
- 테스트: XCTest, `Hydra/Tests/HydraTests/`, 실행은 `cd /Users/dave/iWorks/hydra/Hydra && swift test`. 기존 테스트 전부 통과 유지(현재 97개).
- 레이아웃(간격·배치·크기)은 바꾸지 않는다. 질감(반경·폰트·그림자·보더)만 바꾼다.
- 상태 색상(초록=온라인, 빨강=오프라인 등)과 카드 포인트 색은 손대지 않는다.
- 코드/로그/명령어 영역의 `.monospaced` 명시는 유지한다(프리셋과 무관).
- `@AppStorage` 키: 스타일 = `"appStyle"`, 폰트 = `"appFontDesign"`(기존 키 재사용, 의미는 "사용자가 명시 선택한 폰트"로 변경 — 미설정 시 프리셋 기본 폰트 사용).
- 커밋 메시지는 한국어, 기존 스타일(`feat(app): …`, `test: …`)을 따른다.

---

### Task 1: Theme 토큰 모델 + AppStyle 프리셋

**Files:**
- Create: `Hydra/Hydra/Theme/Theme.swift`
- Test: `Hydra/Tests/HydraTests/ThemeTests.swift`

**Interfaces:**
- Consumes: `AppFontDesign` (기존, `Hydra/Hydra/Views/Settings/AppearanceSettingsTab.swift` 상단 정의 — `#if os(macOS)` 바깥이라 크로스플랫폼).
- Produces:
  - `struct ShadowSpec: Equatable { var color: Color; var radius: CGFloat; var y: CGFloat }`
  - `struct Theme: Equatable` — `cardRadius/controlRadius/chipRadius: CGFloat`, `cardShadow: ShadowSpec?`, `borderWidth: CGFloat`, `borderColor: Color`, `fontDesign: Font.Design`
  - `enum AppStyle: String, CaseIterable, Identifiable` — `.classic/.round/.modern/.avantGarde`, `var label: String`, `var font: AppFontDesign`, `var theme: Theme`, `static let storageKey = "appStyle"`, `static let defaultStyle = AppStyle.round`
  - `EnvironmentValues.theme` (기본값 `AppStyle.defaultStyle.theme`)
  - `func resolvedFontDesign(stored: String?, style: AppStyle) -> Font.Design`

- [ ] **Step 1: 실패하는 테스트 작성**

`Hydra/Tests/HydraTests/ThemeTests.swift` 생성:

```swift
import XCTest
import SwiftUI
@testable import Hydra

final class ThemeTests: XCTestCase {

    // MARK: 프리셋 → 토큰 매핑 (스펙 표의 값)

    func testClassic_keepsCurrentLook() {
        let t = AppStyle.classic.theme
        XCTAssertEqual(t.cardRadius, 8)
        XCTAssertEqual(t.controlRadius, 6)
        XCTAssertEqual(t.chipRadius, 4)
        XCTAssertEqual(t.cardShadow, ShadowSpec(color: .black.opacity(0.05), radius: 2, y: 1))
        XCTAssertEqual(t.borderWidth, 0)
        XCTAssertEqual(t.fontDesign, .default)
    }

    func testRound_isSoft() {
        let t = AppStyle.round.theme
        XCTAssertEqual(t.cardRadius, 14)
        XCTAssertEqual(t.controlRadius, 10)
        XCTAssertEqual(t.chipRadius, 8)
        XCTAssertEqual(t.cardShadow, ShadowSpec(color: .black.opacity(0.06), radius: 6, y: 2))
        XCTAssertEqual(t.borderWidth, 0)
        XCTAssertEqual(t.fontDesign, .rounded)
    }

    func testModern_isFlatWithHairline() {
        let t = AppStyle.modern.theme
        XCTAssertEqual(t.cardRadius, 10)
        XCTAssertEqual(t.controlRadius, 8)
        XCTAssertEqual(t.chipRadius, 6)
        XCTAssertNil(t.cardShadow)
        XCTAssertEqual(t.borderWidth, 0.5)
        XCTAssertEqual(t.fontDesign, .default)
    }

    func testAvantGarde_isSquareMonoBordered() {
        let t = AppStyle.avantGarde.theme
        XCTAssertEqual(t.cardRadius, 0)
        XCTAssertEqual(t.controlRadius, 0)
        XCTAssertEqual(t.chipRadius, 0)
        XCTAssertNil(t.cardShadow)
        XCTAssertEqual(t.borderWidth, 1.5)
        XCTAssertEqual(t.fontDesign, .monospaced)
    }

    // MARK: 기본값·저장 키

    func testDefaultStyle_isRound() {
        XCTAssertEqual(AppStyle.defaultStyle, .round)
        XCTAssertEqual(AppStyle.storageKey, "appStyle")
    }

    func testRawValues_areStable() {
        // @AppStorage에 저장되는 문자열 — 바뀌면 사용자 설정이 유실된다.
        XCTAssertEqual(AppStyle.classic.rawValue, "classic")
        XCTAssertEqual(AppStyle.round.rawValue, "round")
        XCTAssertEqual(AppStyle.modern.rawValue, "modern")
        XCTAssertEqual(AppStyle.avantGarde.rawValue, "avantGarde")
    }

    // MARK: 프리셋 기본 폰트 (Font 피커 연동용)

    func testPresetFonts() {
        XCTAssertEqual(AppStyle.classic.font, .standard)
        XCTAssertEqual(AppStyle.round.font, .rounded)
        XCTAssertEqual(AppStyle.modern.font, .standard)
        XCTAssertEqual(AppStyle.avantGarde.font, .monospaced)
    }

    // MARK: 폰트 결정 규칙 — 저장값 있으면 저장값, 없으면 프리셋 기본

    func testResolvedFontDesign_unset_usesPresetDefault() {
        XCTAssertEqual(resolvedFontDesign(stored: nil, style: .round), .rounded)
        XCTAssertEqual(resolvedFontDesign(stored: nil, style: .classic), .default)
    }

    func testResolvedFontDesign_stored_winsOverPreset() {
        XCTAssertEqual(resolvedFontDesign(stored: "serif", style: .round), .serif)
        XCTAssertEqual(resolvedFontDesign(stored: "standard", style: .avantGarde), .default)
    }

    func testResolvedFontDesign_garbage_fallsBackToPreset() {
        XCTAssertEqual(resolvedFontDesign(stored: "comic-sans", style: .round), .rounded)
    }
}
```

- [ ] **Step 2: 테스트가 실패(컴파일 에러)하는지 확인**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift test --filter ThemeTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'AppStyle' in scope` 류의 컴파일 에러.

- [ ] **Step 3: 구현**

`Hydra/Hydra/Theme/Theme.swift` 생성:

```swift
import SwiftUI

// MARK: - 스타일 토큰
//
// 프리셋(AppStyle)은 토큰 값 묶음이다. 뷰는 @Environment(\.theme)으로 토큰만
// 읽고 프리셋 이름으로 분기하지 않는다 — 프리셋 추가 = static 값 하나 추가.
// 스펙: docs/superpowers/specs/2026-07-15-style-presets-design.md

struct ShadowSpec: Equatable {
    var color: Color
    var radius: CGFloat
    var y: CGFloat
}

struct Theme: Equatable {
    var cardRadius: CGFloat      // 카드·패널·배너
    var controlRadius: CGFloat   // 버튼·입력창·소형 패널
    var chipRadius: CGFloat      // 뱃지·태그·게이지 바
    var cardShadow: ShadowSpec?  // nil = 그림자 없음
    var borderWidth: CGFloat     // 0 = 카드 외곽선 없음
    var borderColor: Color
    var fontDesign: Font.Design  // 프리셋의 기본 폰트 디자인
}

// MARK: - 프리셋

enum AppStyle: String, CaseIterable, Identifiable {
    case classic, round, modern, avantGarde

    static let storageKey = "appStyle"
    static let defaultStyle = AppStyle.round

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic:    return "Classic"
        case .round:      return "Round"
        case .modern:     return "Modern"
        case .avantGarde: return "Avant"
        }
    }

    /// 프리셋의 기본 폰트. 스타일 선택 시 Font 설정의 출발점이 된다.
    var font: AppFontDesign {
        switch self {
        case .classic, .modern: return .standard
        case .round:            return .rounded
        case .avantGarde:       return .monospaced
        }
    }

    var theme: Theme {
        switch self {
        case .classic:
            return Theme(cardRadius: 8, controlRadius: 6, chipRadius: 4,
                         cardShadow: ShadowSpec(color: .black.opacity(0.05), radius: 2, y: 1),
                         borderWidth: 0, borderColor: .clear,
                         fontDesign: font.design)
        case .round:
            return Theme(cardRadius: 14, controlRadius: 10, chipRadius: 8,
                         cardShadow: ShadowSpec(color: .black.opacity(0.06), radius: 6, y: 2),
                         borderWidth: 0, borderColor: .clear,
                         fontDesign: font.design)
        case .modern:
            return Theme(cardRadius: 10, controlRadius: 8, chipRadius: 6,
                         cardShadow: nil,
                         borderWidth: 0.5, borderColor: .primary.opacity(0.12),
                         fontDesign: font.design)
        case .avantGarde:
            return Theme(cardRadius: 0, controlRadius: 0, chipRadius: 0,
                         cardShadow: nil,
                         borderWidth: 1.5, borderColor: .primary,
                         fontDesign: font.design)
        }
    }
}

// MARK: - 폰트 결정 규칙
//
// 사용자가 Font를 명시 선택했으면(저장값 존재) 그 값, 아니면 프리셋 기본.
// 프리셋 = 출발점, Font 설정 = 최종 결정권.

func resolvedFontDesign(stored: String?, style: AppStyle) -> Font.Design {
    guard let stored, let explicit = AppFontDesign(rawValue: stored) else {
        return style.theme.fontDesign
    }
    return explicit.design
}

// MARK: - Environment 주입

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppStyle.defaultStyle.theme
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift test --filter ThemeTests 2>&1 | tail -5`
Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Hydra/Theme/Theme.swift Hydra/Tests/HydraTests/ThemeTests.swift
git commit -m "feat(app): 스타일 프리셋 토큰 모델 — Theme + AppStyle 4종"
```

---

### Task 2: AppearanceModifier에 테마 주입 + 폰트 연동

**Files:**
- Modify: `Hydra/Hydra/Views/Settings/AppearanceSettingsTab.swift:69-81` (`AppearanceModifier`)

**Interfaces:**
- Consumes: Task 1의 `AppStyle`, `resolvedFontDesign(stored:style:)`, `EnvironmentValues.theme`.
- Produces: 모든 씬 루트(`HydraApp.swift`의 `.appAppearance()` 4곳)에 `\.theme` 주입 + 프리셋 연동 폰트 적용. `HydraApp.swift`는 수정하지 않는다.

- [ ] **Step 1: AppearanceModifier 수정**

`AppearanceSettingsTab.swift`의 `AppearanceModifier`를 다음으로 교체
(변경점: `appStyle` 추가, `fontDesign`을 옵셔널로, `.fontDesign`/`.environment` 계산):

```swift
struct AppearanceModifier: ViewModifier {
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage(AppStyle.storageKey) private var style = AppStyle.defaultStyle.rawValue
    // 옵셔널: nil = 사용자가 Font를 명시 선택한 적 없음 → 프리셋 기본 폰트 사용.
    @AppStorage("appFontDesign") private var fontDesign: String?
    @AppStorage("appFontScale") private var fontScale = appFontScaleDefault

    private var appStyle: AppStyle { AppStyle(rawValue: style) ?? .defaultStyle }

    func body(content: Content) -> some View {
        content
            .environment(\.theme, appStyle.theme)
            .fontDesign(resolvedFontDesign(stored: fontDesign, style: appStyle))
            .dynamicTypeSize(appDynamicTypeSize(forScalePercent: fontScale))
            .preferredColorScheme((AppTheme(rawValue: theme) ?? .system).colorScheme)
    }
}
```

주의: 같은 파일 아래 `AppearanceSettingsTab`(#if os(macOS) 블록)의
`@AppStorage("appFontDesign") private var fontDesign = AppFontDesign.standard.rawValue`는
이 시점엔 그대로 둔다(Task 3에서 피커와 함께 수정). 두 선언의 타입이 달라도
키만 같으면 UserDefaults 동작엔 문제없다.

- [ ] **Step 2: 전체 테스트 + 빌드 확인**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: 빌드 성공, 기존+신규 테스트 전부 PASS.

- [ ] **Step 3: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Hydra/Views/Settings/AppearanceSettingsTab.swift
git commit -m "feat(app): 씬 루트에 테마 주입 — 프리셋 기본 폰트 연동"
```

---

### Task 3: 설정 UI — Style 피커 + Font 피커 연동 + 프리뷰

**Files:**
- Modify: `Hydra/Hydra/Views/Settings/AppearanceSettingsTab.swift:89-140` (`AppearanceSettingsTab`)

**Interfaces:**
- Consumes: `AppStyle`(Task 1), `\.theme` 주입(Task 2 — 설정 씬도 `.appAppearance()` 적용됨).
- Produces: 사용자 노출 UI. 스타일 변경 시 `appFontDesign`을 프리셋 기본으로 1회 덮어씀.

- [ ] **Step 1: AppearanceSettingsTab 수정**

struct 전체를 다음으로 교체:

```swift
struct AppearanceSettingsTab: View {
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage(AppStyle.storageKey) private var style = AppStyle.defaultStyle.rawValue
    @AppStorage("appFontDesign") private var fontDesign: String?
    @AppStorage("appFontScale") private var fontScale = appFontScaleDefault
    @Environment(\.theme) private var themeTokens

    private var appStyle: AppStyle { AppStyle(rawValue: style) ?? .defaultStyle }

    var body: some View {
        Form {
            Section {
                Picker("Style", selection: $style) {
                    ForEach(AppStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                // 프리셋 = 폰트의 출발점: 스타일을 고르면 Font 설정을 프리셋
                // 기본값으로 덮어쓴다. 이후 Font 피커에서 자유롭게 재변경.
                .onChange(of: style) { _, new in
                    fontDesign = (AppStyle(rawValue: new) ?? .defaultStyle).font.rawValue
                }
            } header: {
                Text("Style")
            }

            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            }

            Section {
                Picker("Font", selection: Binding(
                    get: { fontDesign ?? appStyle.font.rawValue },
                    set: { fontDesign = $0 }
                )) {
                    ForEach(AppFontDesign.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Text size", selection: $fontScale) {
                    ForEach(appFontScaleOptions, id: \.self) { Text("\($0)%").tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Font")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The quick brown fox jumps over the lazy dog")
                        .font(.headline)
                    Text("Devices 12/12 online · 6 GPUs")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("$ nvidia-smi --query-gpu=utilization.gpu --format=csv")
                        .font(.system(.caption, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: themeTokens.controlRadius))
                .overlay {
                    if themeTokens.borderWidth > 0 {
                        RoundedRectangle(cornerRadius: themeTokens.controlRadius)
                            .strokeBorder(themeTokens.borderColor,
                                          lineWidth: themeTokens.borderWidth)
                    }
                }
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: 빌드 + 전체 테스트**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: 빌드 성공, 전부 PASS.

- [ ] **Step 3: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Hydra/Views/Settings/AppearanceSettingsTab.swift
git commit -m "feat(app): Appearance에 Style 피커 — 4종 프리셋 전환 + 프리뷰 반영"
```

---

### Task 4: cardStyle 공용 모디파이어 + SummaryCard 적용

**Files:**
- Create: `Hydra/Hydra/Theme/CardStyle.swift`
- Modify: `Hydra/Hydra/Views/Dashboard/DashboardView.swift:733-737` (`SummaryCard.body` 말미)

**Interfaces:**
- Consumes: `\.theme`.
- Produces: `View.cardStyle()` — 카드 패턴(배경+클립+그림자+보더)을 토큰 기반으로 적용. Task 5에서 다른 카드에도 사용.

- [ ] **Step 1: CardStyle.swift 생성**

```swift
import SwiftUI

/// 카드 패턴 공용 모디파이어: 배경 + 코너 클립 + (프리셋에 따라) 그림자·보더.
/// 반복되던 `background + clipShape + shadow` 조합을 토큰 기반으로 통합한다.
/// 패딩은 카드마다 달라 호출부에 남긴다.
struct CardStyleModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius)
        content
            .background(.background)
            .clipShape(shape)
            .overlay {
                if theme.borderWidth > 0 {
                    shape.strokeBorder(theme.borderColor, lineWidth: theme.borderWidth)
                }
            }
            .shadow(color: theme.cardShadow?.color ?? .clear,
                    radius: theme.cardShadow?.radius ?? 0,
                    y: theme.cardShadow?.y ?? 0)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyleModifier()) }
}
```

- [ ] **Step 2: SummaryCard에 적용**

`DashboardView.swift`의 `SummaryCard.body` 말미(733-737행)를:

```swift
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
```

다음으로 교체:

```swift
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .cardStyle()
```

- [ ] **Step 3: 빌드 + 전체 테스트**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: 빌드 성공, 전부 PASS.

- [ ] **Step 4: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Hydra/Theme/CardStyle.swift Hydra/Hydra/Views/Dashboard/DashboardView.swift
git commit -m "feat(app): cardStyle 공용 모디파이어 — SummaryCard 토큰화"
```

---

### Task 5: 하드코딩 반경 치환 스위프

**Files (Modify only):**
- `Hydra/Hydra/Views/Dashboard/DashboardView.swift` (157, 198, 704, 850-853행)
- `Hydra/Hydra/Views/Devices/DeviceListView.swift` (673, 1161, 1230, 1238행)
- `Hydra/Hydra/Views/MenuBar/MenuBarView.swift` (51, 53행)
- `Hydra/Hydra/Views/MenuBar/PlanCardView.swift` (58행)
- `Hydra/Hydra/Views/Orchs/OrchListView.swift` (188행)
- `Hydra/Hydra/Views/Tasks/TasksView.swift` (233행)
- `Hydra/Hydra/Views/ConnectionView.swift` (54행)
- `Hydra/Hydra/Views/iOS/iOSDashboardView.swift` (98행)

**Interfaces:**
- Consumes: `\.theme`(Task 1·2), `cardStyle()`(Task 4).
- Produces: 없음 — 앱 전 화면이 프리셋을 따르게 되는 마지막 조각.

공통 규칙: 각 치환 지점을 감싸는 View struct에 `@Environment(\.theme) private var theme`가
없으면 추가한다. 행 번호는 Task 4 이후 몇 행씩 밀릴 수 있으니 코드 내용으로 찾는다.

- [ ] **Step 1: 역할별 토큰 치환**

아래 표대로 `cornerRadius: N`을 토큰으로 바꾼다. **표에 없는 반경은 건드리지 않는다.**

| 파일:행 | 현재 | 역할 | 치환 |
|---|---|---|---|
| DashboardView.swift:157 | `RoundedRectangle(cornerRadius: 6)` | 서버 상태 배너 | `theme.cardRadius` |
| DashboardView.swift:198 | `RoundedRectangle(cornerRadius: 6)` | 오프라인 알림 배너 | `theme.cardRadius` |
| DashboardView.swift:704 | `RoundedRectangle(cornerRadius: 6)` | 퀵커맨드 출력 패널(모노) | `theme.controlRadius` |
| DashboardView.swift:850 | `.clipShape(RoundedRectangle(cornerRadius: 8))` | 디바이스 요약 카드 | `theme.cardRadius` |
| DashboardView.swift:852 | `RoundedRectangle(cornerRadius: 8)` (stroke overlay) | 같은 카드의 외곽선 | `theme.cardRadius` (stroke 자체는 유지) |
| DeviceListView.swift:673 | `RoundedRectangle(cornerRadius: 6)` | SSH 키 복사 패널 | `theme.controlRadius` |
| DeviceListView.swift:1161 | `RoundedRectangle(cornerRadius: 8)` | 주소 목록 패널 | `theme.controlRadius` |
| DeviceListView.swift:1230 | `RoundedRectangle(cornerRadius: 8)` (dashed strokeBorder) | Taildrop 드롭존 | `theme.controlRadius` |
| DeviceListView.swift:1238 | `RoundedRectangle(cornerRadius: 8)` | Taildrop 드롭존 클립 | `theme.controlRadius` |
| MenuBarView.swift:51 | `RoundedRectangle(cornerRadius: 2)` | GPU 게이지 바 배경 | `theme.chipRadius` |
| MenuBarView.swift:53 | `RoundedRectangle(cornerRadius: 2)` | GPU 게이지 바 채움 | `theme.chipRadius` |
| PlanCardView.swift:58 | `RoundedRectangle(cornerRadius: 4)` | 액션 타입 태그 칩 | `theme.chipRadius` |
| OrchListView.swift:188 | `RoundedRectangle(cornerRadius: 4)` | 실행 결과 출력 패널(모노) | `theme.controlRadius` |
| TasksView.swift:233 | `RoundedRectangle(cornerRadius: 4)` | 태스크 결과 출력 패널(모노) | `theme.controlRadius` |
| ConnectionView.swift:54 | `RoundedRectangle(cornerRadius: 8)` | 서버 선택 버튼 배경 | `theme.controlRadius` |
| iOSDashboardView.swift:98 | `RoundedRectangle(cornerRadius: 12)` | iOS 요약 카드 | `theme.cardRadius` |

치환 예 (DashboardView.swift:157):

```swift
// before
        .background(statusColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
// after
        .background(statusColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
```

게이지 바 참고: 라운드 프리셋에서 `chipRadius: 8`은 바 높이의 절반을 넘어
캡슐처럼 렌더링된다 — 의도된 동작(둥글둥글). 아방가르드에선 0으로 각진 바.

모노스페이스 출력 패널(704, 188, 233행)의 `.font(.system(.caption, design: .monospaced))`는
그대로 둔다(Global Constraints).

- [ ] **Step 2: 남은 하드코딩이 없는지 확인**

Run: `grep -rn "cornerRadius: [0-9]" /Users/dave/iWorks/hydra/Hydra/Hydra/Views/ --include="*.swift"`
Expected: 출력 없음 (전부 토큰 참조로 치환됨).

- [ ] **Step 3: 빌드 + 전체 테스트**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: 빌드 성공, 전부 PASS.

- [ ] **Step 4: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Hydra/Views/
git commit -m "feat(app): 뷰 반경 토큰화 — 전 화면 스타일 프리셋 적용"
```

---

### Task 6: 앱 빌드 + 수동 검증

**Files:** 없음 (검증 전용)

- [ ] **Step 1: 전체 테스트 최종 확인**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift test 2>&1 | tail -5`
Expected: 기존 97개 + ThemeTests 10개 = 107개 전부 PASS.

- [ ] **Step 2: 앱 빌드**

Run: `cd /Users/dave/iWorks/hydra && make hydra-app 2>&1 | tail -5`
Expected: 빌드 성공, `.app` 번들 생성.

- [ ] **Step 3: 수동 검증 (실행 중인 앱이 있으면 임베디드 서버까지 종료 후 재실행)**

주의: GUI만 pkill 하면 임베디드 `hydra-server`가 :8080을 잡고 있어 구버전이
남는다 — `Resources/hydra-server` 프로세스도 함께 종료할 것.

체크리스트 (Settings → Appearance에서 프리셋 전환하며):
1. 기본값이 Round인가 (첫 실행 시 둥근 카드 + SF Rounded 폰트).
2. 4종 전환 시 대시보드 카드·배너·설정 프리뷰가 즉시 바뀌는가.
3. Round 선택 후 Font를 Serif로 바꾸면 유지되는가; 다시 스타일을 바꾸면 폰트가 프리셋 기본으로 리셋되는가.
4. 메뉴바 팝오버의 GPU 게이지·플랜 카드가 프리셋을 따르는가.
5. 아방가르드에서 카드가 각지고 보더가 생기며 모노 폰트가 되는가.
6. 터미널 탭·코드 출력 영역은 어떤 프리셋에서도 모노스페이스 유지되는가.
7. 상태 색(초록/빨강)이 모든 프리셋에서 동일한가.
