# 앱 내 파이썬 콘솔 (In-App Python Console) 설계

- 날짜: 2026-07-08
- 상태: 설계 승인됨 (구현 전)
- 대상: Naga/Hydra macOS 앱 (Swift GUI, `Hydra/`)
- 관련: [[2026-07-07-python-client-design]] (hydra_client 라이브러리)

## 1. 배경과 목표

hydra_client 파이썬 라이브러리(1·2단계 완료, main 배포됨)로 task 제출·조회·sim·워커를
스크립트할 수 있게 됐다. 이 스펙은 그 코드를 **앱 안에서 바로 작성·실행**하는 콘솔을
추가한다 — 노트북 셀처럼 `client`가 미리 주입된 상태에서 몇 줄 쓰면 로컬 임베디드
서버(:8080)에 바로 제출/조회된다.

**확정된 결정 (브레인스토밍)**
1. 성격: 앱 내 파이썬 콘솔/에디터 — 직접 실행 (코드 생성기·워커 런처가 아님)
2. 파이썬 런타임: **번들** — python-build-standalone + 벤더링된 hydra_client를 .app에 동봉
3. 실행 모델: `client`/`sim`/`TaskSpec` 등을 네임스페이스에 **사전 주입** (노트북 셀 느낌)
4. 저장: **명명 저장 + 목록** — SavedTask 패턴 미러 (`PySnippetStore`)
5. 러너 하네스: **프리앰블 주입 + 서브프로세스 파일 실행** (접근 A)

**성공 기준**: `make hydra-app` 빌드 후 콘솔에서 시드 스니펫
`client.submit_task("echo hi").wait()`를 실행하면 stdout이 스트리밍되고 completed로 끝난다.

## 2. 접근안 결정 (러너 하네스)

| 접근 | 방식 | 판정 |
|---|---|---|
| **A. 프리앰블+파일 실행** | 프리앰블+사용자코드를 임시 .py로 써서 번들 python3로 실행, Pipe 스트리밍 | **채택** — EmbeddedServer 패턴 재사용, 서브프로세스 격리, cancel=terminate |
| B. JSON 프로토콜 러너 | 동봉 runner.py가 실행 후 구조화 JSON 반환 | 예외 표시 깔끔하나 프로토콜 계층 추가 — YAGNI |
| C. 임베디드 libpython C-API | 인프로세스 실행 | GIL·크래시 격리·서명 복잡도 과다 — 배제 |

채택 근거: 서브프로세스 격리로 사용자 코드가 앱을 크래시시키지 못하고, 기존
`EmbeddedServer`의 `Process()` 소유·`terminate()` 패턴을 그대로 쓴다. 예외는 파이썬
traceback이 stderr로 흘러 콘솔에 그대로 보이므로 B의 구조화 없이 충분하다.

## 3. 아키텍처 & 번들 패키징

### 번들 레이아웃

```
Hydra.app/Contents/Resources/
├── hydra-server                 (기존 Go 백엔드)
├── python-runtime/              (신규: python-build-standalone, ~40MB)
│   └── bin/python3
└── pylib/
    └── hydra_client/            (신규: python/src/hydra_client 벤더 복사)
```

### `bundle-app.sh` 추가 단계 (기존 hydra-server 서명 단계 옆)

1. python-build-standalone tarball을 받아 전개 → `Resources/python-runtime/`
   (다운로드는 캐시; 오프라인 재빌드 시 캐시 재사용). **아키텍처: macOS
   arm64**(Apple Silicon — 개발/타겟 머신 m4max 기준; universal2는 비범위).
   전개 결과의 디렉터리 구조(보통 `python/bin/python3.x`)는 스크립트가
   `Resources/python-runtime/bin/python3`로 **정규화**(심볼릭 링크 또는 이동)해,
   런타임 탐색 경로를 고정한다.
2. `python/src/hydra_client` → `Resources/pylib/hydra_client/` 복사 (벤더링 —
   앱과 라이브러리 버전이 한 번들에서 동기화).
3. **nested 바이너리 ad-hoc 서명**: `python-runtime/bin/python3`(및 전개된
   `.dylib`/`.so`)를 ad-hoc(`codesign -s -`)으로 서명 — hardened runtime을
   붙이면 부모 GUI가 spawn하지 못한다(hydra-server와 동일 제약, 검증된 gotcha).
   그 뒤 번들 전체를 dev cert로 재봉인.

### 런타임 인터프리터 탐색

`PYExecutor`가 `Bundle.main.url(forResource:"python-runtime/bin/python3", withExtension:nil)`로
인터프리터를 찾는다. 실행 env에 `PYTHONPATH=<Resources/pylib 절대경로>`와
`HYDRA_SERVER=http://localhost:8080`을 주입해 `hydra_client` import를 가능하게 한다.
인터프리터 미발견(예: `bundle-app.sh` 안 거친 `swift run`)은 크래시가 아니라 콘솔
안내 메시지로 처리.

## 4. 컴포넌트

### 4.1 `Models/PySnippet.swift`
```swift
struct PySnippet: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var code: String
    var createdAt: Date = Date()
    var lastRunAt: Date?
    var lastExitCode: Int32?
}
```

### 4.2 `Services/PySnippetStore.swift`
`SavedTaskStore`와 동일 구조를 미러: `@MainActor ObservableObject`,
`@Published var snippets: [PySnippet]`, `Documents/py_snippets.json` JSON 영속화,
`add/update/delete/move` CRUD. **스케줄러 없음**(스니펫은 수동 실행만 — SavedTask와
다른 점, YAGNI). 최초 실행 시 시드 스니펫 2~3개 주입(제출+wait, GPU 조회, sim explain).

### 4.3 `Services/PYExecutor.swift` (`@MainActor ObservableObject`)
```swift
@Published var output: [OutputLine] = []   // OutputLine{ text: String, stream: .stdout|.stderr }
@Published var isRunning = false
@Published var lastExitCode: Int32?
private var proc: Process?

func run(_ userCode: String) async     // 프리앰블+userCode 조립 → 임시 .py → python3 -u 실행
func cancel()                          // proc.terminate() → 유예 후 SIGKILL
```
- 실행: `assemblePreamble(userCode)` 결과를 스크래치 `.py`에 기록,
  `python3 -u script.py`를 `Process`로 실행(`-u`=버퍼링 해제 즉시 스트리밍),
  `PYTHONPATH`/`HYDRA_SERVER` env 주입.
- 스트리밍: stdout·stderr 각각 `Pipe`, `readabilityHandler`에서 줄 단위로 append
  (stderr는 `.stderr` 태그 → 뷰에서 빨간색).
- 동시 실행 1개 제한(`isRunning` 가드) — 노트북처럼 순차.
- 취소: `terminate()`(SIGTERM) → 유예 후 SIGKILL(워커 kill 시퀀스와 동일 사상).
- 종료: `lastExitCode` 세팅, `isRunning=false`, 임시 파일 정리. 앱 종료 시 살아있는 proc terminate.

### 4.4 프리앰블 조립 (순수 함수 — 테스트 최우선)
`assemblePreamble(_ userCode: String) -> (script: String, preambleLineCount: Int)`:
```python
import os
from hydra_client import HydraClient, TaskSpec, ResourceRequirements, Worker, sim
from hydra_client.errors import *
client = HydraClient(os.environ.get("HYDRA_SERVER", "http://localhost:8080"))
# --- user code below ---
<userCode>
```
`preambleLineCount`를 반환해, stderr traceback의 `line N`을 **사용자 코드 기준으로
보정**(N - preambleLineCount)해 표시한다 — 안 하면 에러 줄이 어긋난다. 보정 로직도
순수 함수(`adjustTraceback(_ stderr: String, offset: Int) -> String`)로 분리.

### 4.5 `ViewModels/ConsoleViewModel.swift`
선택된 `PySnippet` + `PYExecutor`를 소유, 실행/저장/삭제 액션 조율. `PySnippetStore`와
`PYExecutor`를 주입받아 뷰와 서비스 사이를 잇는다.

### 4.6 UI — 새 탭 "Console"
`AppState.Tab`에 `.console` 케이스 추가, `ContentView` TabView에 뷰 하나 추가
(기존 Tasks 탭의 사이드바+디테일 패턴 미러). 레이아웃:
```
┌─ 스니펫 목록 ──┬─ 에디터 + 콘솔 ─────────────┐
│ 목록/+새 스니펫 │ [monospace 코드 에디터]      │
│                │ [▶ 실행][■ 취소]  저장/삭제   │
│                │ [출력 콘솔: 자동스크롤, stderr 빨강] │
│                │ exit code: N                 │
└────────────────┴──────────────────────────────┘
```
콘솔 하단에 "로컬에서 실행됨" 한 줄(신뢰 모델 명시).

## 5. 데이터 흐름

1. 사용자가 스니펫 선택/작성 → **실행** 클릭
2. `ConsoleViewModel` → `PYExecutor.run(code)`
3. `assemblePreamble(code)` → 임시 `.py` 기록
4. 번들 `python3 -u`로 실행, env 주입 (`PYTHONPATH`, `HYDRA_SERVER`)
5. 스크립트가 `hydra_client`로 로컬 :8080에 REST 호출 → 서버가 스케줄링/응답
6. stdout/stderr가 Pipe로 스트리밍 → `@Published output` → 콘솔 뷰 자동 갱신
7. 종료 시 exit code 표시, 스니펫의 `lastRunAt`/`lastExitCode` 갱신·저장

## 6. 에러 처리

- 인터프리터 미발견/spawn 실패: 콘솔에 명시 안내("파이썬 런타임이 번들에 없습니다 —
  make hydra-app으로 빌드하세요"). 크래시 없음.
- 사용자 코드 예외: 파이썬 traceback이 stderr로 흐름 → 줄번호 보정 후 빨간색 표시.
- 서버 미기동(:8080 없음): 스크립트의 `HydraConnectionError`가 traceback으로 표시됨.
- 무한 루프/장시간: **취소** 버튼으로 terminate. 동시 실행 1개 제한이 폭주 방지.

## 7. 보안 / 신뢰 모델

사용자 자신의 머신에서 자신이 쓴 파이썬을 실행 — 워커 신뢰 모델과 동일(임의 코드
실행 허용). 네트워크 노출 없음(로컬 :8080만 호출). 콘솔에 "로컬 실행" 명시.

## 8. 테스트 전략

1. **Swift 유닛** (`Hydra/Tests/HydraTests/`):
   - `PySnippetStore` CRUD + JSON 라운드트립 (SavedTaskStore 테스트 관례 미러)
   - `assemblePreamble` 조립 결과·`preambleLineCount` 정확성 (순수 함수)
   - `adjustTraceback` 줄번호 보정 (순수 함수 — 파이썬 불필요, 가장 가치 높음)
   - `PYExecutor` 인터프리터-미발견 경로 (주입 가능한 URL provider로 테스트)
2. **수동 스모크** (CI 스킵 — 번들 파이썬 의존):
   `make hydra-app` → 콘솔에서 시드 스니펫 `client.submit_task("echo hi").wait()`가
   stdout 스트리밍 + completed로 종결되는지 확인. (2026-07-07 라이브러리 스모크와 동일 사상.)

## 9. 구현 순서 (계획 단계에서 태스크화)

1. 순수 로직 먼저: `PySnippet` 모델 + `assemblePreamble`/`adjustTraceback` + 유닛
2. `PySnippetStore` (SavedTaskStore 미러) + 유닛
3. `PYExecutor` (EmbeddedServer 미러) + 미발견-경로 유닛
4. `ConsoleViewModel` + Console 탭 뷰 + `AppState.Tab.console` 배선
5. `bundle-app.sh` 파이썬 런타임 동봉·벤더링·서명 단계
6. 수동 스모크

## 10. 비범위 (YAGNI)

- 셀 간 상태 유지(변수 persistence), REPL 스타일
- 문법 하이라이팅, 자동완성
- 멀티 동시 실행, 스니펫 스케줄링
- 원격 노드 실행(로컬 :8080만)
- 파이썬 패키지 추가 설치(번들된 hydra_client + 표준 라이브러리만)
