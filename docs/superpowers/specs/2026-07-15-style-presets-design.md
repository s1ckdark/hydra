# UI 스타일 프리셋 — 클래식·라운드·모던·아방가르드 (macOS)

날짜: 2026-07-15
상태: 승인됨 (4종 프리셋 + 기본값 라운드 채택)

## 배경

- 현재 UI는 코너 반경 2~12pt가 뷰마다 제각각 하드코딩되어 있고, 옅은 그림자 +
  시스템 기본 폰트 + 원색 포인트 조합이라 전형적인 "모니터링 대시보드" 인상이다.
  사용자는 더 둥글둥글하고 부드러운 느낌을 원한다.
- `AppearanceSettingsTab`에 테마(라이트/다크)·폰트 디자인·텍스트 크기 설정과
  `AppearanceModifier`(4개 씬 루트에 적용)가 이미 있다. 스타일 프리셋은 이 인프라에
  얹는다.
- 단일 리디자인 대신 **설정에서 전환 가능한 스타일 프리셋**으로 간다. 기존 감성도
  "클래식"으로 보존된다.

## 설계 원칙

**테마 = 토큰 값 묶음.** 뷰는 `theme.cardRadius` 같은 토큰만 읽고, 프리셋 이름으로
분기하지 않는다. 프리셋 추가 = static 값 하나 추가이며, 레이아웃(배치·구조)은 모든
프리셋에서 동일하다. 프리셋은 질감(반경·폰트·그림자·보더)만 바꾼다.

## 토큰 모델

`Hydra/Theme/Theme.swift` (신규):

```swift
struct ShadowSpec: Equatable {
    var color: Color
    var radius: CGFloat
    var y: CGFloat
}

struct Theme: Equatable {
    var cardRadius: CGFloat      // 카드·패널·배너
    var controlRadius: CGFloat   // 버튼·입력창·피커
    var chipRadius: CGFloat      // 뱃지·태그·상태 칩
    var cardShadow: ShadowSpec?  // nil = 그림자 없음
    var borderWidth: CGFloat     // 0 = 보더 없음 (카드 외곽선)
    var fontDesign: Font.Design  // 프리셋의 기본 폰트 디자인
}
```

## 프리셋 4종

`enum AppStyle: String, CaseIterable` — `@AppStorage("appStyle")`, 기본값 `.round`.

| 프리셋 | card/control/chip | 그림자 | 보더 | 폰트 | 느낌 |
|---|---|---|---|---|---|
| 클래식 `classic` | 8 / 6 / 4 | 현재값(black 5%, r2, y1) | 0 | 기본 | 지금 모습 보존 |
| 라운드 `round` | 14 / 10 / 8 | 확산(black 6%, r6, y2) | 0 | SF Rounded | 둥글둥글 — 새 기본값 |
| 모던 `modern` | 10 / 8 / 6 | 없음 | 0.5 헤어라인 | 기본 | 플랫 미니멀 |
| 아방가르드 `avantGarde` | 0 / 0 / 0 | 없음 | 1.5 | 모노스페이스 | 고대비 브루탈리즘 |

## 주입

- `AppearanceModifier`에 `@AppStorage("appStyle")` 추가 후
  `.environment(\.theme, style.theme)` 한 줄로 전 씬(메인 윈도우·메뉴바 팝오버·설정
  등 4개 루트)에 주입. 새 주입 지점을 만들지 않는다.
- **폰트 연동**: 설정에서 프리셋을 고르는 순간 `appFontDesign` 값을 프리셋 기본값으로
  1회 덮어쓴다(예: 라운드 선택 → Font가 Rounded로 바뀜). 이후 사용자가 Font 피커에서
  재변경하면 그 값이 유지된다. 프리셋 = 출발점, Font 설정 = 최종 결정권.
  `AppearanceModifier`의 폰트 적용 로직은 기존 그대로 `appFontDesign`만 읽는다.
- 최초 실행(저장값 없음) 시 `appStyle=round`이고 `appFontDesign`도 미설정이므로,
  `appFontDesign`의 코드 기본값을 계산 시 프리셋 기본으로 위임한다: 저장값이 없으면
  `style.theme.fontDesign`, 있으면 저장값. 이렇게 하면 신규 사용자는 라운드+Rounded
  폰트로 시작하고, 기존 사용자의 명시적 폰트 선택은 침범하지 않는다.

## 뷰 치환

- 반복되는 카드 패턴(`padding + background + clipShape(RoundedRectangle) + shadow`)을
  공용 모디파이어로 통합: `.cardStyle()` — `@Environment(\.theme)`을 읽어 반경·그림자·
  보더를 적용. 아방가르드/모던의 보더는 이 모디파이어가 `borderWidth > 0`일 때 그린다.
- 51개 뷰 파일의 하드코딩된 `cornerRadius`·`shadow`를 역할별 토큰으로 기계적 치환:
  카드류 → `cardRadius`(또는 `.cardStyle()`), 버튼/입력 → `controlRadius`,
  뱃지/칩 → `chipRadius`.
- 테마별 `if`/`switch` 분기를 뷰에 두지 않는다.

## 예외 규칙

- 터미널 화면, 코드/로그/명령어 표시 영역은 프리셋과 무관하게 모노스페이스를
  유지한다(기존 `.monospaced` 명시 유지).
- 상태 색상(초록=온라인, 빨강=오프라인 등)과 카드 포인트 색은 모든 프리셋에서
  동일하다. 이번 작업은 색을 바꾸지 않는다.
- 레이아웃(간격·배치·크기)은 바꾸지 않는다. 라운드의 "부드러움"은 반경·폰트·
  그림자로만 표현한다.

## 설정 UI

`AppearanceSettingsTab`에 Style 섹션 추가(Theme 섹션 위):

- 세그먼트 피커: `Classic | Round | Modern | Avant`
- 기존 Preview 섹션이 카드 스타일까지 반영하도록 `.cardStyle()` 적용 — 프리셋 전환을
  즉시 눈으로 확인 가능.
- 프리셋 변경 시 `appFontDesign`을 프리셋 기본값으로 덮어쓴다(위 폰트 연동 규칙).

## 범위

- 이번 작업: macOS 메인 앱 + 메뉴바 팝오버.
- 후속: iOS(HydraiOS) — 토큰 모델은 공유 가능하게 타깃 멤버십만 고려해 둔다.

## 테스트·검증

- 유닛: `AppStyle → Theme` 매핑 값, 폰트 연동 규칙(저장값 없음 → 프리셋 기본,
  저장값 있음 → 저장값 유지).
- 수동: 빌드 후 4종 프리셋을 전환하며 대시보드·디바이스·터미널·메뉴바 팝오버 확인.
  기존 테스트 97개 통과 유지.
