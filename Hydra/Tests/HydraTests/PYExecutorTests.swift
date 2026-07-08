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
