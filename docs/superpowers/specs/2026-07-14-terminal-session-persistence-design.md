# 터미널 세션 저장 — 목록 복원 + tmux 지속 (macOS)

날짜: 2026-07-14
상태: 승인됨 (추천안 ①+③ 채택)

## 범위

1. **세션 목록 복원 (항상 켜짐)**: 앱 재시작 후 Terminal 탭에 들어가면 직전에 열려
   있던 노드 세션들과 활성 세션이 자동으로 복구된다. 셸 상태 자체는 새로 시작.
2. **tmux 세션 지속 (opt-in 설정)**: 켜면 셸 시작 시 원격 tmux 세션(`hydra`)에
   자동 부착해, 앱을 꺼도 원격 작업이 살아있고 재접속 시 그대로 이어진다.

스크롤백 직렬화(②)는 채택하지 않음.

## A. 세션 목록 복원

- `TerminalSessionStore`에 UserDefaults 주입(`defaults:` 파라미터, 기본 `.standard`).
- 저장 키: `terminal.openDeviceIds`([String], 열린 순서), `terminal.activeDeviceId`(String).
  세션 id == deviceId이므로 deviceId만 저장하면 충분.
- 저장 시점: `open()`, `close()`, `activeSessionId` 변경 시.
- **`closeAll()`은 저장하지 않는다** — `applicationWillTerminate`가 closeAll()을
  호출하므로, 여기서 persist하면 종료 때마다 복원 목록이 지워진다. 사용자가 명시적으로
  탭에서 ✕로 닫는 것(`close()`)만 목록에서 제거된다.
- `restoreIfNeeded(devices:)`: 런치당 1회. 저장된 deviceId 중 현재 디바이스 목록에
  존재하는 것만 `open()`으로 재생성하고, 저장된 활성 세션을 복원. 목록에 없는 id는
  버린다(디바이스 소멸). 호출 지점은 `ContentView.task`(디바이스 로드 직후) +
  `TerminalTabView.task`(폴백) — 사용자가 다른 탭에서 새 세션을 열어 저장 목록을
  덮기 전에 복원이 먼저 실행되어야 한다.
- **빈 디바이스 목록 가드 (리뷰 HIGH 반영)**: 저장 목록이 있는데 디바이스 목록이
  비어 있으면(오프라인/백엔드 미기동 런치) 진행하지 않고 래치 없이 반환 — 진행하면
  아무것도 매칭되지 않아 저장 목록이 빈 배열로 덮여 영구 소실된다. 목록이 도착한
  다음 호출에서 복원한다.
- 복원된 세션은 idle 상태로 생성되고, pane이 표시될 때(활성화 시) 기존 로직대로
  lazy 연결된다. 연결 폭주 없음.

## B. tmux 세션 지속 (opt-in)

- 설정: `@AppStorage("terminalPersistViaTmux")`, 기본 false. Settings에 "Terminal" 탭
  신설(토글 + 동작 설명 + tmux 필요 조건 + "앱에서 닫아도 원격 세션은 유지" 안내).
- 방식: **셸 부트스트랩 주입** (백엔드 무관). `exec()` 사이드채널은 Citadel에만
  구현되어 있어(libssh2는 "" 폴백) 프로브 방식은 기본 백엔드에서 동작하지 않는다.
  대신 셸이 열린 직후 아래 한 줄을 stdin으로 주입한다:

  ```
   command -v tmux >/dev/null 2>&1 && tmux new-session -A -s hydra; clear
  ```

  - tmux 있으면: 세션명 `hydra`에 attach-or-create(`-A`).
  - tmux 없거나 attach 실패(중첩 tmux, 소켓 권한 등): 부모 셸이 살아남아 일반 셸로
    폴백. `exec`는 쓰지 않는다 — 실패 시 SSH 채널까지 닫혀 터미널이 아예 열리지
    않는다 (리뷰 MEDIUM 반영).
  - 주입 줄은 순수 함수 `TerminalSession.tmuxBootstrapLine()`으로 분리(테스트 대상).
- `TerminalSession` init에 `persistenceEnabled: () -> Bool` 주입(기본: UserDefaults
  읽기). `openShellNow()` 성공 직후 참이면 부트스트랩 라인을 `write()`.
- 제약(설정 화면에 명시): 노드에 tmux 설치 필요, tmux 안에서 실행 시 중첩 주의,
  원격 세션 완전 종료는 셸에서 `exit`.

## 테스트

- 저장/복원 (`UserDefaults(suiteName:)` 격리):
  - open 2개 → 저장 목록·활성 일치 / close 1개 → 목록 갱신
  - closeAll → 저장 목록 유지 (종료 시나리오)
  - restoreIfNeeded: 순서 보존 복원, 활성 복원, 소멸 디바이스 드롭, 2회 호출 무해
- tmux 주입 (`ScriptedSSHSession`에 write 기록 추가):
  - enabled=true → openShell 후 부트스트랩 라인 write됨
  - enabled=false → write 없음
  - `tmuxBootstrapLine()` 내용(폴백 포함) 검증
- 수동: 설정 토글 on → 터미널 열기 → tmux 상태바 확인 → 앱 재시작 → 세션 목록
  복원 + tmux 재부착 확인.
