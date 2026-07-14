# Terminal 탭 디바이스 사이드바 (macOS)

날짜: 2026-07-14
상태: 승인됨 (디바이스 통합 리스트 안 채택)

## 배경

- Terminal 탭 사이드바는 현재 "열린 세션 목록"만 보여준다. 세션이 없으면 빈 화면 안내뿐이라, 터미널을 열려면 반드시 Devices 탭을 거쳐야 한다.
- Devices 탭 → "터미널 열기" 시 Terminal 탭으로 전환하는 동작(요청 ②)은 63e472f에서 이미 구현되어 있다. 이번 작업은 요청 ①(사이드바 노드 리스트)만 다룬다.

## 설계: 디바이스 통합 리스트

사이드바를 세션 목록에서 **전체 노드 리스트**로 교체한다. 세션은 디바이스당 1개로
중복 방지되므로(`TerminalSessionStore.open()` dedupe) 디바이스 = 세션 슬롯 1:1 매핑이 성립한다.

### 행 표시 규칙

| 상태 | 표시 | 클릭 |
|---|---|---|
| 세션 연결됨 | ● 초록 점 + ✕ 닫기 | 해당 세션 포커스 |
| 세션 연결중/idle | ● 회색 점 + ✕ 닫기 | 해당 세션 포커스 |
| 세션 끊김 | ● 빨강 점 + ✕ 닫기 | 해당 세션 포커스(재연결 배너는 pane에 있음) |
| 세션 없음 + 온라인 + SSH 가능 | ○ 빈 점 | 새 세션 열기 |
| 오프라인 또는 SSH 불가 (세션 없음) | 흐리게(40%), 비활성 | 무시 |

- 정렬/숨김: `DevicePreferences.apply(to:id:)` — Devices 탭과 동일한 사용자 순서.
- 고아 세션(세션은 열려 있는데 디바이스가 목록에서 사라짐): 리스트 하단에 세션 행으로
  유지해 닫기 수단을 보존한다. id 충돌 방지를 위해 행 id는 `session:<sessionId>`.
- 활성 세션 행은 강조 배경으로 표시.
- 빈 pane 문구는 "왼쪽에서 노드를 선택하세요."로 교체.

### 구조

- `TerminalSidebarRow` (신규, `Views/Terminal/TerminalSidebarModel.swift`):
  디바이스·세션 스냅샷(`DeviceInfo`/`SessionInfo` 경량 구조체)을 받아 행 배열을 만드는
  순수 함수 `rows(devices:sessions:)`. `Device`/`TerminalSession` 실물 없이 테스트 가능.
- `TerminalTabView`: `DashboardViewModel`(EnvironmentObject) + `DevicePreferences` 구독
  추가, 사이드바 List를 행 모델 기반으로 교체. 상태 점은 라이브 갱신을 위해
  `TerminalSession`을 `@ObservedObject`로 받는 소형 서브뷰로 렌더링.

### 테스트

`TerminalSidebarModelTests` (유닛):
- 세션 ↔ 디바이스 매칭(상태·sessionId 전달)
- 세션 없는 온라인/오프라인/SSH불가 디바이스의 enabled 여부
- 세션 보유 디바이스는 오프라인이어도 enabled 유지
- 고아 세션 행이 하단에 유지되고 id가 `session:` 프리픽스를 가짐

수동 검증: 릴리즈 빌드 재설치 후 (a) Terminal 탭에서 노드 클릭으로 세션 열기,
(b) Devices 탭 "터미널 열기" → Terminal 탭 자동 전환 확인.
