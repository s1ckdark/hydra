# 터미널 색상 테마 — 설계

- 날짜: 2026-09-22
- 상태: 승인됨
- 범위: macOS 앱 + iOS 앱 (Android 제외)
- 상위 작업: terminal(IpadTerminal) 기능 이식 1/4 — 테마 → 폰트 → SSH 키 관리 보강 → AI Dock

## 배경 / 목표

terminal(IpadTerminal) 앱은 SwiftTerm 그리드에 5종 색상 프리셋을 제공한다
(`terminal/App/TerminalTheme.swift`). hydra의 터미널은 SwiftTerm 기본 색만 쓴다.
프리셋 중 하나를 골라 macOS·iOS 터미널 모두에 적용하고, 설정을 바꾸면 열려 있는
터미널 세션에도 즉시 반영되게 한다.

앱 전체 외관(`AppTheme`: system/light/dark)과는 독립된 설정이다.

## 결정 사항

| 항목 | 결정 |
|---|---|
| 선택 방식 | 프리셋 1개 고정 (앱 라이트/다크와 무관) |
| 프리셋 | Default Dark, Solarized Dark, Solarized Light, Dracula, Nord — terminal 값 그대로 |
| 기본값 | Default Dark (알 수 없는 저장값도 Default Dark로 폴백) |
| 저장 | `UserDefaults` 키 `terminalColorScheme` (프리셋 id 문자열), `@AppStorage`로 접근 |
| 변경 전파 | SwiftUI 상태 → representable `update*View` (NotificationCenter 미사용) |
| 코드 위치 | `Hydra/Theme/` — macOS(SwiftPM `Hydra` 타겟)와 iOS(XcodeGen이 `Hydra/Theme` 포함) 공유 |
| AI Dock 색 | 이번 범위 제외 — AI Dock 이식(4/4) 때 모델에 추가 |

## 컴포넌트

### 1. `TerminalColorScheme` (신규, `Hydra/Theme/TerminalColorScheme.swift`)

플랫폼 무관 값 타입. 색은 `UInt32` `0xRRGGBB`로 보관한다.

```swift
struct TerminalColorScheme: Identifiable, Equatable {
    static let storageKey = "terminalColorScheme"
    let id: String
    let displayName: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let ansi: [UInt32]          // 16개, SwiftTerm 순서 (0–7 normal, 8–15 bright)

    static let presets: [TerminalColorScheme]
    static let defaultDark: TerminalColorScheme
    static func find(id: String) -> TerminalColorScheme   // 미존재 → defaultDark
}
```

- Default Dark의 커서는 terminal에서 `.systemBlue`였다. 공유 모델은 hex만 쓰므로
  `0x0A84FF`(다크 모드 systemBlue)로 고정한다.

### 2. SwiftTerm 적용 확장 (신규, `Hydra/Theme/TerminalColorScheme+SwiftTerm.swift`)

- `canImport(SwiftTerm)`로 감싼다. iOS 타겟은 SwiftTerm을 링크하고, macOS에서는 SwiftTerm이
  macOS 조건부 의존성이다.
- `func swiftTermPalette() -> [SwiftTerm.Color]`: 8비트 채널을 16비트로 변환한다 (`c * 257`, 0xFF → 65535).
- `func apply(to view: SwiftTerm.TerminalView)`: 다음을 설정한다.
  - `nativeBackgroundColor`, `nativeForegroundColor`, `caretColor`, `installColors(swiftTermPalette())`
  - `#if canImport(UIKit)` / `AppKit`로 `UIColor`/`NSColor`를 만든다.

### 3. representable 연결

- `SwiftTermRepresentable`(macOS)과 `SwiftTermRepresentableiOS`에 `let scheme: TerminalColorScheme`를 추가한다.
- `make*View`에서 적용하고 `coordinator.appliedSchemeID`를 기록한다.
- `update*View`에서는 id가 다를 때만 다시 적용한다. SwiftUI가 자주 호출해도 팔레트를 재설치하지 않게 하기 위해서다.
- iOS `NativeTerminalInputView` 컨테이너의 `backgroundColor`도 테마 배경으로 맞춘다.
  SwiftTerm iOS 뷰가 non-opaque라서 컨테이너 배경이 비쳐 보이기 때문이다.
- 이 representable을 쓰는 화면(`TerminalScreen`, macOS `TerminalTabView`)은
  `@AppStorage(TerminalColorScheme.storageKey)`로 id를 읽고 `find(id:)` 결과를 넘긴다.

### 4. 설정 UI

- 공유 뷰 `TerminalColorSchemeRow` (`Hydra/Theme/`): 테마 배경 위에 foreground 글자 "Aa"와
  ANSI 0–7 칩을 보여 주고, 이름과 선택 체크 표시를 둔다.
- 공유 뷰 `TerminalColorSchemePicker`: `List`/`ForEach`로 프리셋을 나열하고 탭하면 저장한다.
- iOS: `SettingsScreen`에 `Section("터미널")`을 추가하고
  `NavigationLink("터미널 테마") { TerminalColorSchemePicker() }`를 둔다.
- macOS: `AppearanceSettingsTab`에 `Section`과 `Picker("Terminal theme")`를 추가한다. 선택지 라벨은 `TerminalColorSchemeRow`다.
- 새 문자열은 iOS의 `HydraiOS/Resources/{ko,en}.lproj/Localizable.strings`에 추가한다. macOS 설정 탭은 기존처럼 영문 리터럴을 쓴다. 프리셋 이름(Dracula 등)은 고유명사라 번역하지 않는다.

## 테스트

- `Tests/HydraTests/TerminalColorSchemeTests.swift` (macOS `swift test`)
  - 모든 프리셋의 `ansi.count == 16`
  - 프리셋 id가 서로 겹치지 않음
  - `find(id: "nope") == .defaultDark`, 각 프리셋 id로 찾으면 그 프리셋이 나옴
  - `swiftTermPalette()`: `0xFF0000` → (65535, 0, 0), `0x000000` → (0, 0, 0)
- 빌드: macOS `swift build`, iOS `xcodebuild -scheme HydraiOS` (시뮬레이터)
- 수동 확인: iOS 시뮬레이터에서 테마를 바꾼 뒤 열린 터미널의 배경과 ANSI 색 반영을 스크린샷으로 확인
  (`--terminal-recovery-ui-test` fixture 또는 입력 harness 화면 사용)

## 범위 밖

- 사용자 정의 테마 편집·가져오기
- 앱 라이트/다크 연동 자동 전환
- AI Dock 크롬 색 (4/4에서)
- Android 터미널

## 구현 계획 반영 메모

- 공유 UI는 `TerminalColorSchemeOptions`(Form 안에 넣는 행 목록)와 `TerminalColorSchemeScreen`(iOS 전체 화면)으로 나눈다.
  macOS는 `Picker` 대신 같은 행 목록을 Appearance 탭의 `Section`에 넣는다. Picker 메뉴에서는 색 칩이 제대로 그려지지 않기 때문이다.
- 계획: `docs/superpowers/plans/2026-09-22-terminal-color-scheme.md`
