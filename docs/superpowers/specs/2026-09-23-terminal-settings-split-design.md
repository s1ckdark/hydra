# 터미널 설정 분리 + 노드별 설정 — 설계

- 날짜: 2026-09-23
- 상태: 승인됨
- 범위: macOS 앱 + iOS 앱 (Android 제외)
- 상위 작업: terminal(IpadTerminal) 기능 이식 2단계(폰트) 확장. Nerd Font 다운로드는 후속 spec B에서 한다.

## 배경 / 목표

지금은 앱 전체 외형(테마, 폰트, 텍스트 크기)과 터미널 전용 설정(색상 테마)이 섞여 있다. macOS에서는 터미널 색상 테마가 Appearance 탭에 있고, 터미널 폰트와 크기는 설정할 수 없다(SwiftTerm 기본 폰트 고정).

목표는 다음 세 가지다.
1. 설정을 **외형(앱 전체)**과 **터미널(터미널 전용)**으로 나눈다.
2. 터미널 전용 설정에 색상 테마, 폰트, 폰트 크기, 커서 모양, 스크롤백을 둔다.
3. 터미널 화면 안에 설정 패널을 둔다. 패널에는 "전체 설정 따르기" 체크가 있고, 끄면 **그 노드에만** 적용되는 설정을 쓴다.

## 결정 사항

| 항목 | 결정 |
|---|---|
| 설정 계층 | 전체 설정(설정 화면 → 터미널) + 노드별 설정(터미널 안 패널) |
| 노드별 설정 범위 | 노드(`TerminalSession.deviceId`) 단위로 저장·복원. 다른 노드와 전체 설정에 영향 없음 |
| "전체 설정 따르기" | 켜면 전체 설정 사용. 끄면 노드 설정 사용. 처음 끌 때 현재 전체 설정을 복사해서 시작 |
| ⌘= / ⌘- / ⌘0 (터미널 안) | 그 노드 설정의 크기를 바꾼다. 전체 설정을 따르던 노드면 따르기를 자동으로 끄고 전체 설정을 복사한 뒤 바꾼다 |
| 폰트 | 번들 D2Coding + 시스템 고정폭 폰트. Nerd Font 다운로드는 spec B |
| 적용 시점 | 모든 항목을 열린 터미널에 즉시 반영한다(스크롤백은 `changeScrollback`) |
| 앱 외형과의 관계 | 앱 텍스트 크기·폰트는 터미널에 영향 없음. 터미널 설정은 앱 UI에 영향 없음 |

## 컴포넌트

### 1. 모델 (`Hydra/Hydra/Theme/`, macOS·iOS 공유)

`TerminalSettings` (Codable, Equatable)

| 필드 | 타입 | 기본값 | 제약 |
|---|---|---|---|
| `colorSchemeID` | String | `"default-dark"` | 알 수 없는 id → `TerminalColorScheme.find` 폴백 |
| `fontName` | String | `"D2Coding"` | PostScript 이름 또는 `"system"`(시스템 고정폭) |
| `fontSize` | Double | macOS 13, iOS 14 | 8…32로 clamp |
| `cursor` | `TerminalCursor` enum | `.blinkBlock` | `blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar` (SwiftTerm `CursorStyle`과 1:1) |
| `scrollback` | Int | 10_000 | `[1_000, 5_000, 10_000, 50_000]` 중 하나. 그 외 값 → 10_000 |

`TerminalSettingsStore` (ObservableObject, 단일 인스턴스 `shared`, 테스트용 `init(defaults:)`)
- 전체 설정: `UserDefaults` 개별 키 `terminalColorScheme`(기존 키 유지), `terminalFontName`, `terminalFontSize`, `terminalCursor`, `terminalScrollback`
- 노드별 설정: 키 `terminalNodeOverrides`에 `[String: TerminalSettings]` JSON. 딕셔너리에 없는 노드는 전체 설정을 따른다.
- API:
  - `var global: TerminalSettings` (get/set)
  - `func effective(for deviceID: String) -> TerminalSettings`
  - `func isFollowingGlobal(_ deviceID: String) -> Bool`
  - `func setFollowingGlobal(_ follow: Bool, for deviceID: String)` — false로 바꿀 때 `global`을 복사해 넣고, true로 바꿀 때 항목을 지운다
  - `func update(_ deviceID: String, _ change: (inout TerminalSettings) -> Void)` — 따르기 상태면 먼저 끈 뒤 적용
  - `var overriddenDeviceIDs: [String]`, `func resetOverride(_ deviceID: String)`
  - 디코딩에 실패한 항목은 버리고 전체 설정을 따른다.
- 변경은 `objectWillChange`로 알린다. `@AppStorage`를 쓰지 않는 이유는 노드별 딕셔너리와 전체 값을 한 곳에서 일관되게 알리기 위해서다.

`TerminalColorScheme` 저장 키는 그대로 두되, 앞으로 읽기·쓰기는 `TerminalSettingsStore`를 거친다. 기존 `@AppStorage(TerminalColorScheme.storageKey)` 사용처(두 터미널 화면, `TerminalColorSchemeOptions`)는 스토어로 바꾼다.

### 2. 폰트 (`TerminalFontCatalog`, 공유)

- D2Coding TTF(OFL)를 `Hydra/Hydra/Resources/Fonts/D2Coding.ttf`로 넣고 라이선스 파일(`OFL.txt`)을 같이 둔다. 출처는 `~/iWorks/terminal/App/Resources/Fonts/D2Coding.ttf`.
  - iOS는 `project.yml`의 `Hydra/Resources` 소스에 포함되어 번들에 들어간다.
  - macOS는 `bundle-app.sh`가 `Fonts/`를 `Contents/Resources/Fonts/`로 복사한다.
- `static func registerBundledFonts(bundle: Bundle = .main)`: 앱 시작 시 `CTFontManagerRegisterFontsForURL(.process)`로 등록한다. 이미 등록돼 있으면 오류를 무시한다.
- `static func availableFonts() -> [TerminalFontOption]`: 번들 폰트, 그다음 시스템 고정폭 폰트(macOS `NSFontManager.availableFontNames(with: .fixedPitchFontMask)`, iOS `UIFont.familyNames`에서 고정폭 트레이트 검사)를 PostScript 이름으로 중복 없이 반환한다. 맨 앞에 `"system"` 항목을 둔다.
- `static func resolve(_ name: String, size: CGFloat) -> PlatformFont`: 이름으로 폰트를 만들고, 없으면 `monospacedSystemFont(ofSize:weight: .regular)`로 폴백한다. 폴백했는지 여부도 돌려준다(설정 화면에 "사용할 수 없음" 표시용).

### 3. 적용

- `TerminalSettings+SwiftTerm.swift`(공유, `canImport(SwiftTerm)`): `func apply(to view: SwiftTerm.TerminalView, previous: TerminalSettings?)`
  - 바뀐 항목만 적용한다: 색상 테마(기존 `TerminalColorScheme.apply`), `view.font = resolve(...)`, `view.getTerminal().setCursorStyle(...)`, `view.changeScrollback(...)`
  - 폰트가 바뀌면 SwiftTerm이 cols/rows를 다시 계산하고 `sizeChanged` delegate로 원격 PTY를 resize한다(기존 경로).
- representable 두 개: `scheme` 파라미터를 `settings: TerminalSettings`로 바꾸고, Coordinator의 `appliedSchemeID`를 `appliedSettings: TerminalSettings?`로 넓힌다. 같으면 아무것도 하지 않는다.
- iOS `NativeTerminalInputView`는 이미 `terminal.font`를 입력 뷰에 동기화한다(`layoutSubviews`). 폰트 변경 후 `setNeedsLayout()`을 호출한다.
- 화면: macOS `TerminalSessionPane`, iOS `TerminalScreen`은 `@ObservedObject TerminalSettingsStore.shared`에서 `effective(for: session.deviceId)`를 넘긴다.

### 4. 공유 폼 `TerminalSettingsForm` (SwiftUI, 공유)

- `init(binding: Binding<TerminalSettings>)` — 전체 설정이든 노드 설정이든 같은 폼을 쓴다.
- 섹션: 색상 테마(`TerminalColorSchemeOptions`를 바인딩 기반으로 바꿔 재사용), 폰트(Picker, 사용할 수 없는 폰트는 "(사용할 수 없음)" 표시), 크기(Stepper 1pt 단위, 8…32, 미리보기 한 줄 "$ ls -la  한글 가나다" 표시), 커서(Picker 6개), 스크롤백(Picker 4개)
- 사용처
  - macOS 설정 **Terminal** 탭: `TerminalSettingsForm(binding: 전체)` + 기존 tmux 섹션 + "노드별 설정" 섹션(덮어쓴 노드 목록과 각 "초기화" 버튼). Appearance 탭의 "Terminal theme" 섹션은 **삭제**한다.
  - iOS 설정 → 터미널: 현재 "터미널 테마" 링크를 "터미널 설정" 화면(`TerminalSettingsScreen`, 같은 폼 + 노드별 설정 섹션)으로 바꾼다. 기존 `TerminalColorSchemeScreen`은 삭제한다.
  - 터미널 안 패널: 아래 5번

### 5. 터미널 안 패널 `TerminalNodeSettingsPanel` (공유 SwiftUI)

- 맨 위 `Toggle("전체 설정 따르기")` — `store.isFollowingGlobal(deviceID)`에 바인딩
- 켜져 있으면 전체 설정 값으로 폼을 보여 주되 `.disabled(true)`. 꺼져 있으면 노드 설정 바인딩으로 폼을 편집한다.
- 아래에 "전체 설정 열기" 링크를 둔다. macOS는 `SettingsLink`, iOS는 패널을 닫고 설정 탭으로 이동하는 대신 안내 문구만 둔다(iOS 터미널은 전체 화면 모달이라 탭 이동이 불가능).
- 진입점
  - macOS `TerminalSessionPane`: 상단 상태 바에 ⚙ 아이콘. macOS 26 크래시 완화 규칙 때문에 SwiftUI `Button` 대신 파일 상단의 `TapLabel`로 만들고 `.popover`로 패널을 연다. 단축키 ⌘= / ⌘- / ⌘0 은 터미널 뷰의 `keyDown`이 아니라 앱의 `CommandMenu("Terminal")` 항목으로 두고, 현재 선택된 세션(`TerminalSessionStore.shared.activeSessionId`, 세션 id = 노드 id)에 `store.update`를 적용한다. 선택된 세션이 없으면 메뉴 항목을 비활성화한다.
  - 위험: 이 파일에서 `.popover`가 macOS 26 격리-체크 크래시를 일으키는지는 확인되지 않았다. 문제가 생기면 `.sheet`가 아니라 AppKit `NSPopover`로 바꾼다(구현 중 판단).
  - iOS `TerminalScreen`: 툴바 ⚙ 버튼 → `.sheet`(iPad `.presentationDetents([.medium, .large])`)로 패널. 하드웨어 키보드 ⌘= / ⌘- / ⌘0 은 `.keyboardShortcut`이 달린 숨김 버튼 대신, 툴바 메뉴 항목에 `.keyboardShortcut`을 붙여 제공한다.

## 테스트

- `Tests/HydraTests/TerminalSettingsStoreTests.swift` (macOS `swift test`, 격리 suite)
  - 기본값, `fontSize` clamp(4 → 8, 99 → 32), 허용 외 스크롤백 → 10_000, 알 수 없는 커서 문자열 → 기본값
  - `setFollowingGlobal(false)`가 전체 설정을 복사, `true`가 항목 삭제
  - `update`가 따르기 상태에서 자동으로 끄고 적용, 다른 노드와 전체 설정은 그대로
  - `effective`: 덮어쓰기 없으면 전체, 있으면 노드 값
  - 깨진 JSON 항목은 버리고 전체 설정을 따름
  - 기존 `terminalColorScheme` 값이 전체 설정의 `colorSchemeID`로 읽힘(마이그레이션 없이 호환)
- `Tests/HydraTests/TerminalFontCatalogTests.swift`: `resolve("없는폰트")`가 고정폭 시스템 폰트로 폴백하고 폴백 플래그가 true, `availableFonts()` 첫 항목이 `"system"`, 중복 없음
- `Tests/HydraTests/TerminalSettingsApplyTests.swift`: macOS `SwiftTerm.TerminalView`를 만들어 `apply` 후 `font.pointSize`, `nativeBackgroundColor`, 스크롤백이 설정값과 같은지, 같은 값으로 다시 부르면 폰트 객체가 바뀌지 않는지
- iOS UI 테스트: 터미널 fixture(`--terminal-recovery-ui-test`)에서 ⚙ → 따르기 끄기 → 크기 + → 터미널 뷰의 접근성 값(폰트 크기 probe)이 바뀌는지. probe는 DEBUG에서만 `accessibilityValue`로 노출한다.
- 수동: macOS 개발 빌드에서 두 노드 세션을 열어 한쪽만 Dracula/16pt로 바꾸고 다른 쪽이 그대로인지 스크린샷으로 확인

## 범위 밖

- Nerd Font 카탈로그·다운로드·설치 UI (spec B)
- 노드별 tmux 설정
- 앱 외형(Appearance)의 기존 항목 변경
- Android
