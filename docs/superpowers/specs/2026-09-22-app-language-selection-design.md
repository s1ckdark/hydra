# 앱 언어 선택 (English / 한국어) — 설계

- 날짜: 2026-09-22
- 상태: 승인됨
- 범위: macOS 앱 + iOS 앱 (Android 제외)

## 배경 / 목표

iOS 앱에는 이미 앱 언어 Picker(시스템 설정 / 한국어 / English)와 ko/en `Localizable.strings`(258키)가 있다.
macOS 앱에는 현지화가 없고, 화면 문자열이 한국어와 영어로 섞여 코드에 직접 쓰여 있다.

목표는 두 앱 모두 설정에서 **English / 한국어 두 가지 중 하나**를 고르게 하고, 앱 화면 전체를 그 언어로 보여 주는 것이다.

## 결정 사항

| 항목 | 결정 |
|---|---|
| 선택지 | 한국어(`ko`), English(`en`) 두 가지. "시스템 설정" 선택지는 없앤다 |
| 기본값 | 저장값이 없거나 `"system"`이거나 알 수 없는 값이면, 기기 선호 언어로 한 번 결정해 **저장**한다 (ko 계열이면 한국어, 그 외는 English). 이후에는 사용자가 바꿀 때만 바뀐다 |
| 저장 | 기존 키 `appLanguage` 유지 |
| 번역 테이블 | 하나로 통합: `Hydra/Hydra/Resources/{ko,en}.lproj/Localizable.strings`를 iOS·macOS가 공유 |
| 키 | 코드에 쓰인 원문 그대로 (한국어 대부분, macOS 일부 영어). 모든 키에 ko·en 값을 둔다 |
| macOS 번들 | SwiftPM 타겟에서 `Resources`를 `exclude`하고, `scripts/bundle-app.sh`가 `*.lproj`를 `Hydra.app/Contents/Resources/`로 복사한다. SwiftUI `Text` 리터럴이 `Bundle.main`에서 찾아지게 하기 위함이다 |
| 적용 방식 | 기존 iOS 방식 그대로: `.environment(\.locale, …)` + 동적 문자열은 `AppLocalization.string` / `AppLocalizedText` |

## 컴포넌트

### 1. 언어 모델 (공유로 이동)

`HydraiOS/Appearance/AppAppearancePreferences.swift`를 `Hydra/Hydra/Theme/AppAppearancePreferences.swift`로 옮긴다(`git mv`).
이 파일은 `AppDisplayLanguage`, `AppAppearancePreferences`, `AppLocalization`, `AppLocalizedText`, `hydraAppearancePreferences()`를 담고 있고, macOS와 iOS가 함께 컴파일한다.

- `AppDisplayLanguage`: `case korean = "ko"`, `case english = "en"`만 둔다.
  - `static func deviceDefault(preferredLanguages:) -> AppDisplayLanguage`: 선호 언어 목록에서 처음 나오는 ko 또는 en을 고르고, 둘 다 없으면 `.english`.
  - 기존 `resolvedIdentifier(preferredLanguages:)` 호출부는 `rawValue`로 바꾼다.
- `AppAppearancePreferences.language` getter: 저장값이 유효하지 않으면 `deviceDefault()`를 돌려준다.
- `AppAppearancePreferences.migrateLanguageIfNeeded(preferredLanguages:)`: 저장값이 유효하지 않으면 `deviceDefault`를 저장한다. 유효하면 아무것도 하지 않는다.
- 호출: iOS `HydraiOSApp.init`, macOS `HydraApp.init`에서 한 번 호출한다. iOS 설정 UI 테스트 fixture 모드에서는 fixture의 UserDefaults를 대상으로 한다.

### 2. 번역 테이블 통합

- `git mv HydraiOS/Resources/{ko,en}.lproj Hydra/Resources/`
- iOS `project.yml`: `HydraiOS` 타겟 `sources`에 `- path: Hydra/Resources`를 추가한다. XcodeGen은 `.lproj`를 리소스로 처리한다.
- macOS `Package.swift`: `Hydra` executableTarget에 `exclude: ["Resources"]`를 추가한다.
- `scripts/bundle-app.sh`: 앱을 조립할 때 `Hydra/Resources/*.lproj`를 `$APP/Contents/Resources/`로 복사한다.
- `Info.plist`(macOS): `CFBundleLocalizations` = `[ko, en]`을 추가한다.

### 3. macOS 적용

- `AppearanceModifier`(`Hydra/Views/Settings/AppearanceSettingsTab.swift`)에 `@AppStorage(AppAppearancePreferences.languageKey)`를 추가하고 `.environment(\.locale, Locale(identifier: language.rawValue))`를 준다. 모든 macOS 씬(메인 창, Chat 확장 창, Settings, MenuBarExtra)이 `.appAppearance()`를 거치므로 한 곳이면 된다.
- macOS `Hydra/Views/**`(iOS 폴더 제외) 문자열을 정리한다.
  - `Text("…")`, `Button("…")`, `Label("…")`, `Section("…")`, `Picker("…")`, `.help("…")`, `.navigationTitle("…")` 등 `LocalizedStringKey`를 받는 리터럴은 코드를 그대로 두고 테이블에만 키를 추가한다.
  - `String` 타입으로 흘러가는 문구(변수, 삼항식, 문자열 보간, `Text(verbatim:)`, `Text(someString)`)는 `AppLocalization.string(…)`이나 `AppLocalizedText(…)`로 감싼다.
  - 장치 이름, 호스트명, 서버 응답, 명령어·경로, 로그 원문은 번역하지 않는다.
- 설정 UI: Appearance 탭 맨 위에 `Section { Picker("Language", selection:) { 한국어 | English } .pickerStyle(.segmented) } header: { Text("Language") }`를 넣는다.

### 4. iOS 정리

- `AppearanceSettingsSection`: Picker 선택지가 자동으로 두 개가 된다. `?? .system` 폴백은 `deviceDefault()`로 바꾼다. footer 문구는 "선택하면 바로 적용됩니다."로 줄인다(ko·en 테이블 모두 갱신).
- `HydraAppearancePreferencesModifier`: `rawValue`로 locale을 만든다.

## 테스트

- macOS `Tests/HydraTests/AppLanguageTests.swift`
  - `deviceDefault`: `["ko-KR","en-US"]` → ko, `["fr-FR","en-GB"]` → en, `["ja-JP","ko_KR"]` → ko, `["ja-JP"]` → en, `[]` → en
  - `migrateLanguageIfNeeded`: 저장값 없음 + ko 기기 → `"ko"` 저장, `"system"` + fr 기기 → `"en"` 저장, `"en"` + ko 기기 → `"en"` 유지
  - 테이블 짝 맞춤: ko·en `Localizable.strings`의 키 집합이 같고 비어 있지 않다 (`#filePath` 기준으로 소스 경로에서 읽음)
- iOS `HydraiOSInputTests/AppAppearancePreferencesTests.swift`: `.system` 관련 assert를 `deviceDefault` 기준으로 고친다. 번역 조회 테스트(Bundle.main)는 파일을 옮긴 뒤에도 통과해야 한다.
- iOS `HydraiOSUITests/SettingsPreferencesUITests.swift`: 선택지가 두 개로 바뀐 것 외에 흐름은 같으므로 통과해야 한다.
- 수동: `./scripts/bundle-app.sh debug`로 만든 macOS 앱을 실행해 English로 바꾸고, 터미널 탭과 설정 창을 스크린샷으로 확인한다.

## 범위 밖

- macOS 메뉴 막대의 AppKit 시스템 메뉴와 `CommandMenu` 항목 (시스템 언어를 따르거나 영어 유지)
- 3번째 언어, String Catalog(`.xcstrings`) 전환
- `swift run`으로 번들 없이 실행할 때의 번역 (키 원문이 그대로 보임)
- Android
