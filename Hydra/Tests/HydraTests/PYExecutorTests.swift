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

    func testRun_multibyteUTF8AcrossChunkBoundaries_noDropNoMojibake() async throws {
        let sys = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sys.path),
                          "system python3 없음 — 실행 경로 스킵")
        let exec = PYExecutor(interpreterProvider: { sys }, pylibProvider: { nil })
        // 한글+이모지를 1000줄 출력 — 청크 경계가 멀티바이트 시퀀스 중간에 걸릴 가능성이 높다.
        await exec.runRaw("""
        for i in range(1000):
            print("한글출력-\\U0001F600-" + str(i))
        """)
        XCTAssertEqual(exec.lastExitCode, 0)
        let stdoutLines = exec.output.filter { $0.stream == .stdout && !$0.text.isEmpty }
        XCTAssertEqual(stdoutLines.count, 1000, "1000줄이 정확히 스트리밍되어야 함 (드롭/병합 없이)")
        XCTAssertTrue(stdoutLines.allSatisfy { $0.text.contains("한글출력-😀-") },
                      "모든 줄이 mojibake 없이 온전한 멀티바이트 문자열을 포함해야 함")
        XCTAssertTrue(stdoutLines.contains { $0.text == "한글출력-😀-0" })
        XCTAssertTrue(stdoutLines.contains { $0.text == "한글출력-😀-999" })
    }

    func testRun_noTrailingNewline_flushedOnTermination() async throws {
        let sys = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sys.path),
                          "system python3 없음 — 실행 경로 스킵")
        let exec = PYExecutor(interpreterProvider: { sys }, pylibProvider: { nil })
        await exec.runRaw("import sys; sys.stdout.write('no-newline-tail')")
        XCTAssertEqual(exec.lastExitCode, 0)
        XCTAssertTrue(exec.output.contains { $0.stream == .stdout && $0.text.contains("no-newline-tail") },
                      "개행 없이 끝난 출력도 종료 시 플러시되어야 함")
    }
}
#endif
