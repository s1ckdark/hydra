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
