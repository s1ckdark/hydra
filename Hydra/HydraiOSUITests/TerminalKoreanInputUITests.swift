import XCTest

final class TerminalKoreanInputUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--terminal-input-ui-test"]
        app.launch()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("INITIAL_HIERARCHY:\n\(app.debugDescription)")
        let surface = app.descendants(matching: .any)["terminalInputSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    }

    func testKoreanSoftwareKeyboardComposition() throws {
        try selectKoreanKeyboard()

        // 한글 테스트
        tap(["ㅎ", "ㅏ", "ㄴ", "ㄱ", "ㅡ", "ㄹ", "space",
             "ㅌ", "ㅔ", "ㅅ", "ㅡ", "ㅌ", "ㅡ", "space"])
        assertResult("한글 테스트 ")

        // Compound final, compound medial, compound final + linkage.
        tap(["ㅇ", "ㅏ", "ㄴ", "ㅎ", "ㄷ", "ㅗ", "ㅣ", "space",
             "ㄱ", "ㅏ", "ㅂ", "ㅅ", "ㅇ", "ㅣ", "space"])
        assertResult("한글 테스트 않되 값이 ")

        // Repeated leading consonants previously triggered replace/drop logic.
        tap(["ㄱ", "ㅏ", "ㄱ", "ㅏ", "space", "ㅎ", "ㅏ", "ㅎ", "ㅏ", "space"])
        let prefix = "한글 테스트 않되 값이 가가 하하 "
        assertResult(prefix)

        tap(["ㅎ", "ㅏ", "ㄴ"])
        assertResult(prefix) // No provisional jamo or backspaces reach the PTY.
        app.keys["delete"].tap()
        tap(["ㅁ"])
        app.buttons["commitTerminalDraft"].tap()
        assertResult(prefix + "함")

        for _ in 0..<4 {
            if app.keys["a"].exists { break }
            app.buttons["Next keyboard"].tap()
        }
        tap(["a", "b", "c"])
        app.buttons["Return"].tap()
        assertResult(prefix + "함abc\r")
    }

    func testLiveKoreanDraftBeforeWhitespace() throws {
        try selectKoreanKeyboard()
        tap(["ㅎ", "ㅏ", "ㄴ", "ㄱ", "ㅡ", "ㄹ"])
        let editor = app.textViews["terminalInputSurface"]
        assertDraft("한글", outgoing: "", screenshotName: "live-korean-draft-before-space")
        tap(["space"])
        assertResult("한글 ")
        XCTAssertEqual(editor.value as? String, "")
    }

    func testLiveKoreanDraftSurvivesDeletionAndRotation() throws {
        try selectKoreanKeyboard()
        defer { XCUIDevice.shared.orientation = .portrait }

        tap(["ㅎ", "ㅏ", "ㄴ"])
        assertDraft("한", outgoing: "", screenshotName: "live-han-before-delete")
        tap(["delete"])
        assertDraft("하", outgoing: "", screenshotName: "live-ha-after-delete")
        tap(["ㅁ"])
        assertDraft("함", outgoing: "", screenshotName: "live-ham-after-edit")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(landscape: true)
        assertDraft("함", outgoing: "", screenshotName: "live-ham-landscape-uncommitted")
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(landscape: false)
        assertDraft("함", outgoing: "", screenshotName: "live-ham-portrait-uncommitted")

        let commit = app.buttons["commitTerminalDraft"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: commit)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        commit.tap()
        assertDraft("", outgoing: "함", screenshotName: "live-ham-committed-once")
    }

    private func selectKoreanKeyboard() throws {
        if app.keys["ㅎ"].exists { return }
        let candidates = ["Next keyboard", "다음 키보드", "next keyboard"]
        for _ in 0..<8 {
            guard let globe = candidates.lazy.map({ self.app.buttons[$0] }).first(where: { $0.exists }) else {
                XCTFail("Keyboard switch button not found. Keyboard hierarchy: \(app.keyboards.firstMatch.debugDescription)")
                return
            }
            globe.tap()
            if app.keys["ㅎ"].waitForExistence(timeout: 1) { return }
        }
        XCTFail("Korean keyboard is not enabled on the iPad")
    }

    func testShiftedKoreanQuestion() throws {
        try selectKoreanKeyboard()
        tap(["ㅇ", "ㅓ"])
        app.buttons["shift"].tap()
        tap(["ㄸ", "ㅓ", "ㄹ"])
        app.buttons["shift"].tap()
        tap(["ㄲ", "ㅏ"])
        app.keys["more"].firstMatch.tap()
        app.buttons["shift"].tap()
        tap(["?"])
        assertResult("어떨까?")
    }

    func testCompoundVowels() throws {
        try selectKoreanKeyboard()
        tap(["ㄷ", "ㅗ", "ㅐ", "space", "ㅇ", "ㅗ", "ㅐ", "space", "ㅇ", "ㅡ", "ㅣ", "space"])
        assertResult("돼 왜 의 ")
    }

    private func tap(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        for label in labels {
            if label == "space" {
                // Hybrid test: Korean composition still uses actual software
                // key taps. Inject only this ASCII commit boundary because
                // iPadOS can expose a stale Space accessibility element after
                // a language switch despite the key remaining visible. This
                // does not validate Space touch hit-testing or hardware IME.
                app.textViews["terminalInputSurface"].typeKey(" ", modifierFlags: [])
                continue
            }
            let key = app.keys[label]
            if !key.exists {
                XCTAssertTrue(key.waitForExistence(timeout: 3), "Missing key: \(label)", file: file, line: line)
            }
            if !key.isHittable {
                let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: key)
                XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 3), .completed,
                               "Software key not visible: \(label), frame: \(key.frame), keyboard: \(app.keyboards.firstMatch.debugDescription)",
                               file: file, line: line)
            }
            key.tap()
        }
    }

    private func assertResult(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = app.staticTexts["terminalInputResult"]
        let predicate = NSPredicate(format: "label == %@", expected.debugDescription)
        expectation(for: predicate, evaluatedWith: result)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func assertDraft(_ expected: String, outgoing: String, screenshotName: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let editor = app.textViews["terminalInputSurface"]
        let currentDraft = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [currentDraft], timeout: 5), .completed,
                       "Unexpected native draft", file: file, line: line)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "Inline editor is outside the visible viewport", file: file, line: line)
        assertResult(outgoing, file: file, line: line)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func waitForOrientation(landscape: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let frame = app.frame
            return !frame.isEmpty && (frame.width > frame.height) == landscape
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed,
                       "The app did not reach the requested orientation", file: file, line: line)
    }
}
