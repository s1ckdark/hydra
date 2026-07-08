# 앱 내 파이썬 콘솔 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Naga/Hydra macOS 앱에 `client`가 사전 주입된 파이썬 스니펫을 작성·실행·저장하는 Console 탭을 추가한다 — 번들된 파이썬으로 서브프로세스 실행, stdout/stderr 스트리밍, 취소 지원.

**Architecture:** 순수 로직(프리앰블 조립·traceback 줄번호 보정)을 먼저 만들어 XCTest로 검증하고, `SavedTaskStore`를 미러한 `PySnippetStore`(JSON 영속화)와 `EmbeddedServer`를 미러한 `PYExecutor`(Process spawn·Pipe 스트리밍·terminate)를 얹은 뒤, `ConsoleViewModel`+Console 탭 UI로 잇는다. 마지막으로 `bundle-app.sh`가 python-build-standalone(arm64)과 벤더링된 hydra_client를 `.app`에 동봉한다.

**Tech Stack:** Swift 5 / SwiftUI (macOS, SwiftPM `Hydra/`), XCTest, Foundation `Process`/`Pipe`, python-build-standalone, 기존 hydra_client (`python/src/hydra_client`).

**스펙:** `docs/superpowers/specs/2026-07-08-in-app-python-console-design.md`

## Global Constraints

- 브랜치: `feature/in-app-python-console` (main에서 분기; 실행 시작 시 생성)
- 커밋 메시지: 기존 스타일 + 마지막 줄 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Swift 빌드/테스트: `cd Hydra && swift build` / `cd Hydra && swift test` (XCTest, `@testable import Hydra`)
- 앱 번들: 리포 루트에서 `make hydra-app` (→ `Hydra/scripts/bundle-app.sh release`)
- macOS 전용 컴포넌트는 `#if os(macOS)` 게이트 (기존 `TasksView`/`SettingsView`/`EmbeddedServer` 관례)
- 파이썬 런타임: **macOS arm64** (python-build-standalone), 번들 경로 `Resources/python-runtime/bin/python3`로 정규화
- hydra_client는 **벤더 복사**(`Resources/pylib/hydra_client/`) — `pip install` 아님
- nested 바이너리는 **hardened runtime 없이** 서명 (기존 `bundle-app.sh`의 `codesign --force --deep --sign`이 그대로 커버 — `--options runtime` 절대 추가 금지, 붙이면 GUI가 python3 spawn 실패)
- 신뢰 모델: 로컬 :8080만 호출, 사용자 자기 코드 실행 (워커와 동일) — UI에 "로컬 실행" 명시
- 파일 위치: 기존 앱 트리 관례 — 모델 `Hydra/Hydra/Models/`, 서비스 `Hydra/Hydra/Services/`, 뷰모델 `Hydra/Hydra/ViewModels/`, 뷰 `Hydra/Hydra/Views/Console/`, 테스트 `Hydra/Tests/HydraTests/`

## 참고 — 기존 패턴 (그대로 미러)

- `EmbeddedServer` (`Hydra/Hydra/Services/EmbeddedServer.swift`): `@MainActor final class`, `Process()` 소유, `proc.executableURL`+`try proc.run()`, `terminate()`→3s 유예→`kill(pid, SIGKILL)`, `Bundle.main.url(forResource:withExtension:)`로 nested 바이너리 탐색, 앱 종료 시 `stop()`.
- `SavedTaskStore` (`Hydra/Hydra/Services/SavedTaskStore.swift`): `@MainActor class ObservableObject`, `static let shared`, `@Published var`, `Documents/<name>.json`에 `JSONEncoder().encode` + `.write(atomic)` / `Data(contentsOf:)`+`JSONDecoder().decode`, `add/update/delete/move` CRUD.
- `ContentView` TabView: `#if os(macOS)` 블록 안에 `TasksView().tabItem{...}.tag(AppState.Tab.tasks)` — Console 탭을 같은 블록에 추가.
- `AppState.Tab` enum (`Hydra/Hydra/State/AppState.swift`): `case dashboard/devices/orchs/tasks/settings` — `.console` 추가.
- `bundle-app.sh` (`Hydra/scripts/bundle-app.sh`): `[5/7] go build hydra-server` 단계에서 `SERVER_BIN="$APP/Contents/Resources/hydra-server"` 생성, `[6/7] codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"`로 번들 전체 서명. 파이썬 동봉은 go build 뒤·codesign 앞에 삽입.

---

### Task 1: 순수 로직 — PySnippet 모델 + PreambleBuilder

**Files:**
- Create: `Hydra/Hydra/Models/PySnippet.swift`
- Create: `Hydra/Hydra/Services/PreambleBuilder.swift`
- Test: `Hydra/Tests/HydraTests/PreambleBuilderTests.swift`

**Interfaces:**
- Produces (이후 태스크가 사용):
  - `struct PySnippet: Codable, Identifiable { var id: String; var name: String; var code: String; var createdAt: Date; var lastRunAt: Date?; var lastExitCode: Int32? }`
  - `enum PreambleBuilder`:
    - `static func assemble(userCode: String) -> (script: String, preambleLineCount: Int)`
    - `static func adjustTraceback(_ stderr: String, scriptBasename: String, preambleLineCount: Int) -> String`
  - `static let preambleSource: String` (프리앰블 본문 — 테스트가 줄 수 검증에 참조)

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Hydra/Tests/HydraTests/PreambleBuilderTests.swift
import XCTest
@testable import Hydra

final class PreambleBuilderTests: XCTestCase {
    func testAssemble_prependsPreambleAndReturnsLineCount() {
        let (script, n) = PreambleBuilder.assemble(userCode: "print(client)\n")
        // 프리앰블이 앞에 붙고, 사용자 코드가 그 뒤에 온다
        XCTAssertTrue(script.hasSuffix("print(client)\n"))
        XCTAssertTrue(script.contains("from hydra_client import"))
        XCTAssertTrue(script.contains("client = HydraClient("))
        // preambleLineCount == 프리앰블이 차지하는 줄 수 (사용자 코드 시작 직전까지)
        let prefix = String(script.prefix(while: { _ in true }))
        _ = prefix
        // script를 줄로 나눴을 때, 사용자 첫 줄("print(client)")은 n+1 번째(1-based)
        let lines = script.components(separatedBy: "\n")
        XCTAssertEqual(lines[n], "print(client)")
    }

    func testAdjustTraceback_shiftsUserLineNumbers() {
        // 프리앰블 6줄이라고 가정: 사용자 코드 3번째 줄에서 에러 → 스크립트 파일 line 9
        let raw = """
        Traceback (most recent call last):
          File "/tmp/hydra-snip-abc.py", line 9, in <module>
            1/0
        ZeroDivisionError: division by zero
        """
        let out = PreambleBuilder.adjustTraceback(raw, scriptBasename: "hydra-snip-abc.py", preambleLineCount: 6)
        // 스크립트 파일 프레임의 줄번호가 9-6=3 으로 보정된다
        XCTAssertTrue(out.contains("line 3, in <module>"))
        XCTAssertFalse(out.contains("line 9"))
        // 스크립트 파일이 아닌 다른 프레임(라이브러리)의 줄번호는 손대지 않는다
        XCTAssertTrue(out.contains("ZeroDivisionError: division by zero"))
    }

    func testAdjustTraceback_leavesNonScriptFramesUntouched() {
        let raw = """
          File "/app/Resources/pylib/hydra_client/client.py", line 42, in submit_task
            raise HydraConnectionError()
        """
        let out = PreambleBuilder.adjustTraceback(raw, scriptBasename: "hydra-snip-abc.py", preambleLineCount: 6)
        XCTAssertTrue(out.contains("line 42"))   // 라이브러리 프레임은 그대로
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter PreambleBuilderTests 2>&1 | tail -20`
Expected: 컴파일 실패 — `cannot find 'PreambleBuilder' in scope`

- [ ] **Step 3: 구현**

```swift
// Hydra/Hydra/Models/PySnippet.swift
import Foundation

/// A user-defined, named Python snippet run in the in-app console.
struct PySnippet: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var code: String
    var createdAt: Date = Date()
    var lastRunAt: Date?
    var lastExitCode: Int32?
}
```

```swift
// Hydra/Hydra/Services/PreambleBuilder.swift
import Foundation

/// Builds the executable script from a user snippet by prepending a preamble
/// that injects a preconfigured `client`, `sim`, `TaskSpec`, etc., and rewrites
/// tracebacks so line numbers refer to the user's code (not the preamble).
enum PreambleBuilder {
    /// The injected preamble. Its last line is the "user code below" marker so
    /// the user's first line lands immediately after. Keep this in sync with
    /// preambleLineCount semantics: assemble() counts these lines.
    static let preambleSource = """
    import os
    from hydra_client import HydraClient, TaskSpec, ResourceRequirements, Worker, sim
    from hydra_client.errors import *
    client = HydraClient(os.environ.get("HYDRA_SERVER", "http://localhost:8080"))
    # --- user code below ---
    """

    /// Returns the full script (preamble + "\n" + userCode) and the number of
    /// lines the preamble occupies (so the user's first line is line
    /// preambleLineCount+1, 1-based, in the assembled script).
    static func assemble(userCode: String) -> (script: String, preambleLineCount: Int) {
        let preambleLineCount = preambleSource.components(separatedBy: "\n").count
        let script = preambleSource + "\n" + userCode
        return (script, preambleLineCount)
    }

    /// Rewrites `File "<scriptBasename>", line N` frames to `line (N - offset)`
    /// so user-facing line numbers match what they typed. Frames pointing at
    /// other files (library code) are left untouched.
    static func adjustTraceback(_ stderr: String, scriptBasename: String, preambleLineCount: Int) -> String {
        let lines = stderr.components(separatedBy: "\n")
        let adjusted = lines.map { line -> String in
            guard line.contains(scriptBasename), let range = line.range(of: #"line (\d+)"#, options: .regularExpression) else {
                return line
            }
            let matched = String(line[range])                 // "line 9"
            let numStr = matched.replacingOccurrences(of: "line ", with: "")
            guard let n = Int(numStr) else { return line }
            let userLine = max(1, n - preambleLineCount)
            return line.replacingOccurrences(of: matched, with: "line \(userLine)")
        }
        return adjusted.joined(separator: "\n")
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `cd Hydra && swift test --filter PreambleBuilderTests 2>&1 | tail -10`
Expected: 3 tests passed

- [ ] **Step 5: 커밋**

```bash
git add Hydra/Hydra/Models/PySnippet.swift Hydra/Hydra/Services/PreambleBuilder.swift Hydra/Tests/HydraTests/PreambleBuilderTests.swift
git commit -m "feat(app): PySnippet 모델 + PreambleBuilder 순수 로직 (프리앰블 조립·traceback 줄번호 보정)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: PySnippetStore (SavedTaskStore 미러) + 시드 스니펫

**Files:**
- Create: `Hydra/Hydra/Services/PySnippetStore.swift`
- Test: `Hydra/Tests/HydraTests/PySnippetStoreTests.swift`

**Interfaces:**
- Consumes: Task 1의 `PySnippet`
- Produces:
  - `@MainActor final class PySnippetStore: ObservableObject`
  - `@Published var snippets: [PySnippet]`
  - `init(fileURL: URL? = nil)` — nil이면 `Documents/py_snippets.json`; 테스트는 임시 파일 주입
  - `func add(_:)`, `func update(_:)`, `func delete(_:)`, `func move(fromOffsets:toOffset:)`, `func recordRun(id:exitCode:)`
  - `static func seedSnippets() -> [PySnippet]` (최초 실행 시드 — 파일 없을 때 주입)

주의: `SavedTaskStore`는 `static let shared` 싱글턴이지만, 테스트 가능성을 위해 여기서는 `init(fileURL:)`로 파일 경로를 주입받게 한다(shared는 앱에서 기본 경로로 생성). 이 편차는 의도적 — SavedTaskStore도 이 패턴으로 리팩터하면 좋지만 범위 밖.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Hydra/Tests/HydraTests/PySnippetStoreTests.swift
import XCTest
@testable import Hydra

@MainActor
final class PySnippetStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pysnip-test-\(UUID().uuidString).json")
    }

    func testAddPersistsAndReloads() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PySnippetStore(fileURL: url)
        let before = store.snippets.count
        store.add(PySnippet(name: "hello", code: "print(1)"))
        XCTAssertEqual(store.snippets.count, before + 1)
        // 새 스토어가 같은 파일에서 로드
        let reloaded = PySnippetStore(fileURL: url)
        XCTAssertTrue(reloaded.snippets.contains { $0.name == "hello" })
    }

    func testUpdateAndDelete() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PySnippetStore(fileURL: url)
        var s = PySnippet(name: "a", code: "x")
        store.add(s)
        s.code = "y"
        store.update(s)
        XCTAssertEqual(store.snippets.first { $0.id == s.id }?.code, "y")
        store.delete(s)
        XCTAssertFalse(store.snippets.contains { $0.id == s.id })
    }

    func testRecordRunUpdatesMetadata() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PySnippetStore(fileURL: url)
        let s = PySnippet(name: "a", code: "x")
        store.add(s)
        store.recordRun(id: s.id, exitCode: 0)
        let got = store.snippets.first { $0.id == s.id }
        XCTAssertEqual(got?.lastExitCode, 0)
        XCTAssertNotNil(got?.lastRunAt)
    }

    func testSeedSnippetsNonEmptyAndValid() {
        let seeds = PySnippetStore.seedSnippets()
        XCTAssertFalse(seeds.isEmpty)
        XCTAssertTrue(seeds.allSatisfy { !$0.name.isEmpty && !$0.code.isEmpty })
    }

    func testEmptyFileSeedsOnFirstLoad() {
        let url = tempURL()   // 존재하지 않는 파일 → 최초 실행
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PySnippetStore(fileURL: url)
        XCTAssertFalse(store.snippets.isEmpty)   // 시드가 주입됨
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter PySnippetStoreTests 2>&1 | tail -20`
Expected: 컴파일 실패 — `cannot find 'PySnippetStore' in scope`

- [ ] **Step 3: 구현**

```swift
// Hydra/Hydra/Services/PySnippetStore.swift
import Foundation

/// Named Python snippet persistence with JSON file storage. Mirrors
/// SavedTaskStore's shape but is manual-run only (no scheduler). Seeds a few
/// starter snippets on first launch (empty/missing file).
@MainActor
final class PySnippetStore: ObservableObject {
    static let shared = PySnippetStore()

    @Published var snippets: [PySnippet] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = docs.appendingPathComponent("py_snippets.json")
        }
        load()
    }

    // MARK: - CRUD
    func add(_ snippet: PySnippet) { snippets.append(snippet); save() }

    func update(_ snippet: PySnippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[idx] = snippet
        save()
    }

    func delete(_ snippet: PySnippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func recordRun(id: String, exitCode: Int32?) {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[idx].lastRunAt = Date()
        snippets[idx].lastExitCode = exitCode
        save()
    }

    // MARK: - Persistence
    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PySnippet].self, from: data),
              !decoded.isEmpty else {
            snippets = Self.seedSnippets()
            save()
            return
        }
        snippets = decoded
    }

    // MARK: - Seeds
    static func seedSnippets() -> [PySnippet] {
        [
            PySnippet(name: "제출 & 대기", code: """
            t = client.submit_task("echo hello-from-console", required_capabilities=[])
            print("submitted:", t.id, t.status)
            t.wait(timeout=30, poll_interval=0.5)
            print("final:", t.status, t.result.output if t.result else None)
            """),
            PySnippet(name: "GPU 현황", code: """
            for d in client.list_devices():
                if d.has_gpu:
                    print(d.name, d.gpu_model, "x", d.gpu_count)
            """),
            PySnippet(name: "sim: 어디 배치될까", code: """
            spec = TaskSpec.command("train.py", required_capabilities=["gpu"], priority="high")
            for row in sim.explain(spec, client.cluster_snapshot()):
                print(row.worker_id, row.eligible, row.total, row.reject_reason)
            """),
        ]
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `cd Hydra && swift test --filter PySnippetStoreTests 2>&1 | tail -10`
Expected: 5 tests passed

- [ ] **Step 5: 커밋**

```bash
git add Hydra/Hydra/Services/PySnippetStore.swift Hydra/Tests/HydraTests/PySnippetStoreTests.swift
git commit -m "feat(app): PySnippetStore — 명명 스니펫 JSON 영속화 + 시드 (SavedTaskStore 미러)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: PYExecutor (EmbeddedServer 미러) — 실행·스트리밍·취소

**Files:**
- Create: `Hydra/Hydra/Services/PYExecutor.swift`
- Test: `Hydra/Tests/HydraTests/PYExecutorTests.swift`

**Interfaces:**
- Consumes: Task 1의 `PreambleBuilder`
- Produces:
  - `struct ConsoleLine: Identifiable { let id: UUID; let text: String; let stream: ConsoleStream }`
  - `enum ConsoleStream { case stdout, stderr, system }`
  - `@MainActor final class PYExecutor: ObservableObject`
  - `@Published var output: [ConsoleLine]`, `@Published var isRunning: Bool`, `@Published var lastExitCode: Int32?`
  - `init(interpreterProvider: @escaping () -> URL? = PYExecutor.bundledInterpreter, pylibProvider: @escaping () -> URL? = PYExecutor.bundledPylib)`
  - `func run(_ userCode: String) async` (프리앰블 조립 + traceback 보정)
  - `func runRaw(_ code: String) async` (프리앰블 없이 그대로 실행 — 테스트/고급용)
  - `func cancel()`
  - `static func bundledInterpreter() -> URL?` / `static func bundledPylib() -> URL?`

주의: `Process`/`Pipe`는 macOS 전용이므로 파일 전체를 `#if os(macOS)`로 감싼다 (EmbeddedServer와 동일). 인터프리터/라이브러리 경로를 클로저로 주입받아, 테스트에서 nil(미발견) 경로를 검증 가능하게 한다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Hydra/Tests/HydraTests/PYExecutorTests.swift
#if os(macOS)
import XCTest
@testable import Hydra

@MainActor
final class PYExecutorTests: XCTestCase {
    func testRun_interpreterNotFound_reportsSystemErrorNoCrash() async {
        let exec = PYExecutor(interpreterProvider: { nil }, pylibProvider: { nil })
        await exec.run("print('hi')")
        XCTAssertFalse(exec.isRunning)
        // 시스템 스트림에 안내 메시지가 남는다 (크래시 없음)
        XCTAssertTrue(exec.output.contains { $0.stream == .system && $0.text.contains("파이썬 런타임") })
        XCTAssertNil(exec.lastExitCode)
    }

    func testRun_realInterpreter_streamsStdoutAndExitZero() async throws {
        // /usr/bin/python3 가 있으면 실제 실행 경로를 검증 (없으면 스킵).
        // 이 테스트는 hydra_client import 없이 순수 print 만 검증하므로 pylib=nil 로도 동작.
        let sys = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sys.path),
                          "system python3 없음 — 실행 경로 스킵")
        let exec = PYExecutor(interpreterProvider: { sys }, pylibProvider: { nil })
        // 프리앰블은 hydra_client import를 포함하므로 실패한다 → 대신 프리앰블 없는 raw 실행을
        // 검증하기 위해 run 이 아니라 runRaw 를 쓴다. (아래 구현 노트 참조)
        await exec.runRaw("print('stream-check')")
        XCTAssertEqual(exec.lastExitCode, 0)
        XCTAssertTrue(exec.output.contains { $0.stream == .stdout && $0.text.contains("stream-check") })
    }
}
#endif
```

구현 노트(테스트 지원): `run(_:)`는 프리앰블을 붙이고(hydra_client 필요), `runRaw(_:)`는 프리앰블 없이 사용자 코드를 그대로 실행하는 내부 헬퍼다. `run`은 `assemble` 후 `runRaw`에 조립된 스크립트+오프셋을 넘겨 실행하고 traceback을 보정한다. 두 번째 테스트는 hydra_client 없이 스트리밍/exit 경로만 검증하려고 `runRaw`를 직접 부른다.

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter PYExecutorTests 2>&1 | tail -20`
Expected: 컴파일 실패 — `cannot find 'PYExecutor' in scope`

- [ ] **Step 3: 구현**

```swift
// Hydra/Hydra/Services/PYExecutor.swift
#if os(macOS)
import Foundation

enum ConsoleStream { case stdout, stderr, system }

struct ConsoleLine: Identifiable {
    let id = UUID()
    let text: String
    let stream: ConsoleStream
}

/// Runs a Python snippet in a bundled interpreter subprocess, streaming
/// stdout/stderr into `output`. Mirrors EmbeddedServer's Process ownership and
/// terminate→grace→SIGKILL lifecycle. One run at a time (isRunning guard).
@MainActor
final class PYExecutor: ObservableObject {
    @Published var output: [ConsoleLine] = []
    @Published var isRunning = false
    @Published var lastExitCode: Int32?

    private var proc: Process?
    private let interpreterProvider: () -> URL?
    private let pylibProvider: () -> URL?

    init(interpreterProvider: @escaping () -> URL? = PYExecutor.bundledInterpreter,
         pylibProvider: @escaping () -> URL? = PYExecutor.bundledPylib) {
        self.interpreterProvider = interpreterProvider
        self.pylibProvider = pylibProvider
    }

    /// Assembles preamble + user code, runs it, and rewrites tracebacks so line
    /// numbers refer to the user's snippet.
    func run(_ userCode: String) async {
        let (script, offset) = PreambleBuilder.assemble(userCode: userCode)
        await execute(script: script, preambleLineCount: offset)
    }

    /// Runs raw code with no preamble / no traceback rewrite (test + advanced use).
    func runRaw(_ code: String) async {
        await execute(script: code, preambleLineCount: 0)
    }

    private func execute(script: String, preambleLineCount: Int) async {
        guard !isRunning else { return }
        output.removeAll()
        lastExitCode = nil

        guard let interpreter = interpreterProvider() else {
            output.append(ConsoleLine(text: "파이썬 런타임이 번들에 없습니다 — `make hydra-app`으로 빌드하세요.", stream: .system))
            return
        }

        // 임시 스크립트 파일
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hydra-snip-\(UUID().uuidString).py")
        let scriptBasename = scriptURL.lastPathComponent
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            output.append(ConsoleLine(text: "스크립트 파일 생성 실패: \(error.localizedDescription)", stream: .system))
            return
        }

        var env = ProcessInfo.processInfo.environment
        if let pylib = pylibProvider() {
            env["PYTHONPATH"] = pylib.path
        }
        env["HYDRA_SERVER"] = "http://localhost:8080"

        let proc = Process()
        proc.executableURL = interpreter
        proc.arguments = ["-u", scriptURL.path]   // -u: 버퍼링 해제 → 즉시 스트리밍
        proc.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // 스트리밍: 줄 단위로 @Published 에 append. stderr 는 traceback 보정 후 표시.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendChunk(s, stream: .stdout, basename: scriptBasename, offset: preambleLineCount) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendChunk(s, stream: .stderr, basename: scriptBasename, offset: preambleLineCount) }
        }

        self.proc = proc
        isRunning = true
        do {
            try proc.run()
        } catch {
            output.append(ConsoleLine(text: "실행 시작 실패: \(error.localizedDescription)", stream: .system))
            isRunning = false
            self.proc = nil
            try? FileManager.default.removeItem(at: scriptURL)
            return
        }

        // 종료 대기 (백그라운드), 완료 시 상태 정리
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { p in
                Task { @MainActor in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    self.lastExitCode = p.terminationStatus
                    self.isRunning = false
                    self.proc = nil
                    try? FileManager.default.removeItem(at: scriptURL)
                    cont.resume()
                }
            }
        }
    }

    private func appendChunk(_ chunk: String, stream: ConsoleStream, basename: String, offset: Int) {
        let text = stream == .stderr && offset > 0
            ? PreambleBuilder.adjustTraceback(chunk, scriptBasename: basename, preambleLineCount: offset)
            : chunk
        // 줄 단위로 쪼개 append (마지막 빈 줄 제거)
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            output.append(ConsoleLine(text: line, stream: stream))
        }
    }

    /// SIGTERM → 3s 유예 → SIGKILL (EmbeddedServer.stop 과 동일 사상).
    func cancel() {
        guard let proc = proc, proc.isRunning else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(3.0)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }

    // MARK: - Bundle lookup
    static func bundledInterpreter() -> URL? {
        // Resources/python-runtime/bin/python3
        guard let base = Bundle.main.resourceURL else { return nil }
        let url = base.appendingPathComponent("python-runtime/bin/python3")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func bundledPylib() -> URL? {
        guard let base = Bundle.main.resourceURL else { return nil }
        let url = base.appendingPathComponent("pylib")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
#endif
```

- [ ] **Step 4: 통과 확인**

Run: `cd Hydra && swift test --filter PYExecutorTests 2>&1 | tail -10`
Expected: interpreter-not-found 테스트 PASS; 실제 실행 테스트는 `/usr/bin/python3` 있으면 PASS, 없으면 skipped

- [ ] **Step 5: 커밋**

```bash
git add Hydra/Hydra/Services/PYExecutor.swift Hydra/Tests/HydraTests/PYExecutorTests.swift
git commit -m "feat(app): PYExecutor — 번들 파이썬 서브프로세스 실행·스트리밍·취소 (EmbeddedServer 미러)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Console 탭 — ViewModel + View + AppState 배선

**Files:**
- Modify: `Hydra/Hydra/State/AppState.swift` (`Tab.console` 추가)
- Modify: `Hydra/Hydra/Views/ContentView.swift` (탭 추가)
- Create: `Hydra/Hydra/ViewModels/ConsoleViewModel.swift`
- Create: `Hydra/Hydra/Views/Console/ConsoleView.swift`
- Test: `Hydra/Tests/HydraTests/ConsoleViewModelTests.swift`, 기존 `AppStateTests.swift`에 케이스 추가

**Interfaces:**
- Consumes: Task 2 `PySnippetStore`, Task 3 `PYExecutor`/`ConsoleLine`, Task 1 `PySnippet`
- Produces:
  - `@MainActor final class ConsoleViewModel: ObservableObject`
  - `@Published var selectedID: String?`, `@Published var draftCode: String`, `@Published var draftName: String`
  - `let store: PySnippetStore`, `let executor: PYExecutor`
  - `func select(_ id: String?)`, `func run() async`, `func saveDraft()`, `func newSnippet()`, `func deleteSelected()`
  - `AppState.Tab.console`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Hydra/Tests/HydraTests/ConsoleViewModelTests.swift
#if os(macOS)
import XCTest
@testable import Hydra

@MainActor
final class ConsoleViewModelTests: XCTestCase {
    private func makeVM() -> ConsoleViewModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pysnip-vm-\(UUID().uuidString).json")
        let store = PySnippetStore(fileURL: url)
        // 인터프리터 미발견 executor (테스트에서 실제 실행 안 함)
        let exec = PYExecutor(interpreterProvider: { nil }, pylibProvider: { nil })
        return ConsoleViewModel(store: store, executor: exec)
    }

    func testSelectLoadsDraft() {
        let vm = makeVM()
        let first = vm.store.snippets[0]
        vm.select(first.id)
        XCTAssertEqual(vm.draftCode, first.code)
        XCTAssertEqual(vm.draftName, first.name)
    }

    func testNewSnippetCreatesAndSelects() {
        let vm = makeVM()
        let before = vm.store.snippets.count
        vm.newSnippet()
        XCTAssertEqual(vm.store.snippets.count, before + 1)
        XCTAssertNotNil(vm.selectedID)
    }

    func testSaveDraftPersistsEdits() {
        let vm = makeVM()
        vm.newSnippet()
        vm.draftName = "edited"
        vm.draftCode = "print('edited')"
        vm.saveDraft()
        let saved = vm.store.snippets.first { $0.id == vm.selectedID }
        XCTAssertEqual(saved?.name, "edited")
        XCTAssertEqual(saved?.code, "print('edited')")
    }

    func testDeleteSelectedRemoves() {
        let vm = makeVM()
        vm.newSnippet()
        let id = vm.selectedID!
        vm.deleteSelected()
        XCTAssertFalse(vm.store.snippets.contains { $0.id == id })
    }
}
#endif
```

`AppStateTests.swift`에 추가:
```swift
    func testActiveTab_supportsConsole() {
        let s = AppState()
        s.activeTab = .console
        XCTAssertEqual(s.activeTab, .console)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter ConsoleViewModelTests 2>&1 | tail -20`
Expected: 컴파일 실패 — `cannot find 'ConsoleViewModel'`, `.console` 없음

- [ ] **Step 3: 구현**

`AppState.swift` — `Tab` enum에 케이스 추가:
```swift
    enum Tab: Hashable {
        case dashboard
        case devices
        case orchs
        case tasks
        case console
        case settings
    }
```

`ConsoleViewModel.swift`:
```swift
// Hydra/Hydra/ViewModels/ConsoleViewModel.swift
#if os(macOS)
import Foundation

@MainActor
final class ConsoleViewModel: ObservableObject {
    @Published var selectedID: String?
    @Published var draftName: String = ""
    @Published var draftCode: String = ""

    let store: PySnippetStore
    let executor: PYExecutor

    init(store: PySnippetStore = .shared, executor: PYExecutor = PYExecutor()) {
        self.store = store
        self.executor = executor
        if let first = store.snippets.first { select(first.id) }
    }

    func select(_ id: String?) {
        selectedID = id
        if let s = store.snippets.first(where: { $0.id == id }) {
            draftName = s.name
            draftCode = s.code
        } else {
            draftName = ""; draftCode = ""
        }
    }

    func newSnippet() {
        let s = PySnippet(name: "새 스니펫", code: "# client 가 이미 주입돼 있습니다\nprint(client.list_devices())\n")
        store.add(s)
        select(s.id)
    }

    func saveDraft() {
        guard let id = selectedID, var s = store.snippets.first(where: { $0.id == id }) else { return }
        s.name = draftName
        s.code = draftCode
        store.update(s)
    }

    func deleteSelected() {
        guard let id = selectedID, let s = store.snippets.first(where: { $0.id == id }) else { return }
        store.delete(s)
        select(store.snippets.first?.id)
    }

    func run() async {
        saveDraft()
        await executor.run(draftCode)
        if let id = selectedID {
            store.recordRun(id: id, exitCode: executor.lastExitCode)
        }
    }
}
#endif
```

`ConsoleView.swift` (기존 SwiftUI 관례 — 사이드바 목록 + 디테일):
```swift
// Hydra/Hydra/Views/Console/ConsoleView.swift
#if os(macOS)
import SwiftUI

struct ConsoleView: View {
    @StateObject private var vm = ConsoleViewModel()

    var body: some View {
        HSplitView {
            // 사이드바: 스니펫 목록
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding(get: { vm.selectedID }, set: { vm.select($0) })) {
                    ForEach(vm.store.snippets) { s in
                        Text(s.name).tag(s.id)
                    }
                    .onMove { vm.store.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                Button { vm.newSnippet() } label: {
                    Label("새 스니펫", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 180, maxWidth: 260)

            // 디테일: 이름 + 에디터 + 실행/취소 + 콘솔
            VStack(alignment: .leading, spacing: 8) {
                TextField("이름", text: $vm.draftName)
                    .textFieldStyle(.roundedBorder)

                TextEditor(text: $vm.draftCode)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .border(Color.gray.opacity(0.3))

                HStack {
                    Button { Task { await vm.run() } } label: {
                        Label("실행", systemImage: "play.fill")
                    }
                    .disabled(vm.executor.isRunning)

                    Button { vm.executor.cancel() } label: {
                        Label("취소", systemImage: "stop.fill")
                    }
                    .disabled(!vm.executor.isRunning)

                    Spacer()
                    Button("저장") { vm.saveDraft() }
                    Button(role: .destructive) { vm.deleteSelected() } label: { Text("삭제") }
                }

                consoleOutput

                if let code = vm.executor.lastExitCode {
                    Text("exit code: \(code)").font(.caption).foregroundColor(code == 0 ? .green : .red)
                }
                Text("로컬(:8080)에서 실행됨 — 사용자 코드가 이 머신에서 그대로 실행됩니다.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(10)
        }
    }

    private var consoleOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(vm.executor.output) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(color(for: line.stream))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(6)
            }
            .background(Color.black.opacity(0.04))
            .frame(minHeight: 120)
            .onChange(of: vm.executor.output.count) { _ in
                if let last = vm.executor.output.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(for stream: ConsoleStream) -> Color {
        switch stream {
        case .stdout: return .primary
        case .stderr: return .red
        case .system: return .orange
        }
    }
}
#endif
```

`ContentView.swift` — `#if os(macOS)` 블록의 TasksView 다음에 추가:
```swift
                ConsoleView()
                    .tabItem { Label("Console", systemImage: "terminal") }
                    .tag(AppState.Tab.console)
```

- [ ] **Step 4: 통과 확인 + 빌드**

Run: `cd Hydra && swift build 2>&1 | tail -5 && swift test --filter 'ConsoleViewModelTests|AppStateTests' 2>&1 | tail -10`
Expected: 빌드 성공, 테스트 통과

- [ ] **Step 5: 커밋**

```bash
git add Hydra/Hydra/State/AppState.swift Hydra/Hydra/Views/ContentView.swift Hydra/Hydra/ViewModels/ConsoleViewModel.swift Hydra/Hydra/Views/Console/ConsoleView.swift Hydra/Tests/HydraTests/ConsoleViewModelTests.swift Hydra/Tests/HydraTests/AppStateTests.swift
git commit -m "feat(app): Console 탭 — ViewModel + 사이드바/에디터/콘솔 UI + AppState 배선

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: bundle-app.sh — 파이썬 런타임 동봉 + hydra_client 벤더링

**Files:**
- Modify: `Hydra/scripts/bundle-app.sh` ([5/7] go build 뒤, [6/7] codesign 앞에 삽입)

**Interfaces:**
- Consumes: Task 3의 경로 규약 (`Resources/python-runtime/bin/python3`, `Resources/pylib/hydra_client/`)
- Produces: 서명된 `.app`에 파이썬 런타임 + 벤더 라이브러리 동봉

**주의 (실측 필요):** python-build-standalone 릴리스 태그·URL은 시간에 따라 바뀐다. 아래 스크립트는 `PBS_TAG`/`PBS_FILE`을 변수로 두고 **다운로드 실패 시 하드 실패**하게 한다 — 구현자는 https://github.com/astral-sh/python-build-standalone/releases 에서 현재 유효한 최신 태그의 **macOS aarch64 install_only** tarball 파일명을 확인해 `PBS_TAG`/`PBS_FILE`에 넣고, `curl -fL`로 실제 받아지는지 확인할 것. (플랜은 URL을 지어내지 않는다 — 라이브 값 확인이 이 태스크의 일부다.)

- [ ] **Step 1: 스크립트 삽입 (다운로드·캐시·전개·벤더·정규화)**

`bundle-app.sh`의 `chmod +x "$SERVER_BIN"` 줄 다음, `touch "$APP"` 앞에 삽입:

```bash
echo "[5b/7] bundle Python runtime + vendored hydra_client"
# python-build-standalone (macOS arm64, install_only). PBS_TAG/PBS_FILE 는
# releases 페이지에서 확인한 현재 유효한 값으로 설정할 것.
PBS_TAG="${PBS_TAG:-<SET-ME: e.g. 20240814>}"
PBS_FILE="${PBS_FILE:-<SET-ME: e.g. cpython-3.12.5+20240814-aarch64-apple-darwin-install_only.tar.gz>}"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"
PBS_CACHE="${PBS_CACHE:-$HOME/.cache/hydra-pbs}"
mkdir -p "$PBS_CACHE"
PBS_TARBALL="$PBS_CACHE/$PBS_FILE"

if [[ ! -f "$PBS_TARBALL" ]]; then
    echo "  downloading $PBS_URL"
    curl -fL --retry 3 -o "$PBS_TARBALL" "$PBS_URL" || { echo "PBS download failed: $PBS_URL" >&2; exit 1; }
fi

PY_DEST="$APP/Contents/Resources/python-runtime"
rm -rf "$PY_DEST"
mkdir -p "$PY_DEST"
# install_only tarball 은 최상위 'python/' 디렉터리로 전개된다 → 그 내용을 python-runtime/ 로.
tar -xzf "$PBS_TARBALL" -C "$PBS_CACHE/extract-$$" --one-top-level 2>/dev/null || {
    mkdir -p "$PBS_CACHE/extract-$$"; tar -xzf "$PBS_TARBALL" -C "$PBS_CACHE/extract-$$"; }
# 전개 결과 python/ 하위를 python-runtime 으로 이동, bin/python3 심볼릭 정규화
if [[ -d "$PBS_CACHE/extract-$$/python" ]]; then
    cp -R "$PBS_CACHE/extract-$$/python/." "$PY_DEST/"
else
    cp -R "$PBS_CACHE/extract-$$/." "$PY_DEST/"
fi
rm -rf "$PBS_CACHE/extract-$$"
# bin/python3 이 실제 실행 가능해야 한다 (install_only 는 bin/python3.x + python3 심볼릭 제공)
if [[ ! -x "$PY_DEST/bin/python3" ]]; then
    # python3.x 만 있으면 python3 심볼릭 생성
    PYBIN="$(ls "$PY_DEST"/bin/python3.* 2>/dev/null | head -1)"
    [[ -n "$PYBIN" ]] && ln -sf "$(basename "$PYBIN")" "$PY_DEST/bin/python3"
fi
[[ -x "$PY_DEST/bin/python3" ]] || { echo "python-runtime/bin/python3 not executable after extract" >&2; exit 1; }

# 벤더링: hydra_client 소스를 Resources/pylib/ 로 복사 (repo 루트 기준 ../python/src)
PYLIB_DEST="$APP/Contents/Resources/pylib"
rm -rf "$PYLIB_DEST"
mkdir -p "$PYLIB_DEST"
cp -R "../python/src/hydra_client" "$PYLIB_DEST/hydra_client"
# 벤더 라이브러리의 런타임 의존성(requests, websockets)은 번들 파이썬에 설치
"$PY_DEST/bin/python3" -m pip install --quiet --target "$PYLIB_DEST" "requests>=2.31" "websockets>=12" \
    || { echo "pip install into pylib failed" >&2; exit 1; }
```

주의: 기존 `[6/7] codesign --force --deep --sign ... "$APP"`가 **번들 전체**를 재서명하므로 새로 넣은 python3·dylib·so가 자동 커버된다. **`--options runtime`을 추가하지 말 것** (nested spawn 실패). `--deep`이 복잡한 파이썬 프레임워크 구조에서 일부 Mach-O를 놓치면, codesign 단계 앞에 명시적으로 `find "$PY_DEST" -name '*.dylib' -o -name '*.so' | xargs codesign --force --sign "$CODESIGN_IDENTITY"` 한 줄을 추가할 것 (구현 중 `codesign --verify --deep --strict "$APP"` 실패 시).

- [ ] **Step 2: 빌드 + 서명 검증**

```bash
cd /Users/dave/iWorks/hydra && make hydra-app 2>&1 | tail -15
APP="$(cd Hydra && swift build -c release --show-bin-path)/Hydra.app"
codesign --verify --deep --strict "$APP" && echo "SIGN_OK"
ls -la "$APP/Contents/Resources/python-runtime/bin/python3"
ls "$APP/Contents/Resources/pylib/hydra_client/__init__.py"
```
Expected: 빌드·서명 통과, python3 실행파일과 벤더 hydra_client 존재

- [ ] **Step 3: 번들 파이썬이 hydra_client를 import 하는지 확인**

```bash
APP="$(cd Hydra && swift build -c release --show-bin-path)/Hydra.app"
PYTHONPATH="$APP/Contents/Resources/pylib" "$APP/Contents/Resources/python-runtime/bin/python3" \
  -c "import hydra_client, requests, websockets; print('import OK', hydra_client.__file__)"
```
Expected: `import OK .../pylib/hydra_client/__init__.py`

- [ ] **Step 4: 커밋**

```bash
git add Hydra/scripts/bundle-app.sh
git commit -m "build(app): .app 번들에 파이썬 런타임(arm64) + 벤더 hydra_client 동봉

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 최종 검증 (수동 스모크 — CI 스킵)

번들 파이썬 의존이라 자동화하지 않고 수동으로 확인:

1. `make hydra-app` 후 임베디드 서버까지 새로 뜨도록 재배포 (오늘 확립한 절차 — `/Applications/Hydra.app` 교체 시 nested 서명, GUI+hydra-server 둘 다 kill 후 재시작). 개발 중이면 빌드된 `.app`을 직접 `open`.
2. 앱에서 **Console** 탭 열기 → 시드 스니펫 "제출 & 대기" 선택 → **실행**.
3. 기대: stdout에 `submitted: <id> ...` 스트리밍 → `final: completed ...` 표시, exit code 0(초록). (워커가 없으면 task가 assigned에 머무를 수 있으니, 로컬에 `python -m hydra_client.worker --server http://localhost:8080 --capabilities <매칭>`를 띄우거나 required_capabilities=[]로 아무 연결 워커에 배정.)
4. 에러 스모크: `1/0\n` 실행 → stderr 빨간색 traceback, 줄번호가 **1**로 보정되는지 확인.
5. 취소 스모크: `import time; time.sleep(30)` 실행 중 **취소** → 프로세스 종료, isRunning 해제.

## 계획 외 참고

- 실제 파이썬 실행 통합 테스트는 번들 의존이라 XCTest에서 제외 — 순수 로직(Task 1)·저장(Task 2)·미발견 경로(Task 3)·VM 조율(Task 4)이 자동 커버, 실행 왕복은 위 수동 스모크.
- 후속(YAGNI, 이번 제외): 셀 간 상태 유지, 문법 하이라이팅, 멀티 동시 실행, 원격 노드 실행, 스니펫 스케줄링.
