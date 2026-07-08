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
