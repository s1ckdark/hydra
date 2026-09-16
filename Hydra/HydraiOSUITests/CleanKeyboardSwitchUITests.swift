import XCTest

final class CleanKeyboardSwitchUITests: XCTestCase {
    func testControlSpaceChangesInputLanguageWithoutSendingTerminalBytes() throws {
        continueAfterFailure = false
        // Language routing and compact-height layout have separate regressions.
        // Do not inherit landscape from a previously executed rotation test.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--clean-keyboard-comparison"]
        app.launch()

        let selector = app.segmentedControls["cleanKeyboardModeSelector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        tapWhenHittable(selector.buttons["C 터미널"])
        let input = app.textViews["terminalInputSurface"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        tapWhenHittable(input)

        let save = app.buttons["cleanKeyboardSave"]
        let language = app.staticTexts["cleanKeyboardInputLanguage"]
        let outgoing = app.staticTexts["cleanKeyboardOutgoing"]
        tapWhenHittable(save)
        let before = try XCTUnwrap(language.value as? String)
        XCTAssertNotEqual(before, "--", "The focused editor must report an input language.")
        XCTAssertEqual(outgoing.value as? String, "[]")
        capture(app, name: "control-space-before-switch")

        // This synthesizes only an OS keyboard-switch shortcut. It is not a
        // physical-keyboard Korean composition test and types no Hangul text.
        tapWhenHittable(input)
        input.typeKey(" ", modifierFlags: .control)
        tapWhenHittable(save)

        let after = try XCTUnwrap(language.value as? String)
        XCTAssertNotEqual(after, "--")
        XCTAssertNotEqual(after, before, "Control+Space must switch the configured input language.")
        XCTAssertEqual(outgoing.value as? String, "[]", "The input-source shortcut must not send NUL or any other terminal bytes.")
        capture(app, name: "control-space-after-switch-no-terminal-bytes")
    }

    private func tapWhenHittable(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "Control is not visible: \(element)", file: file, line: line)
        element.tap()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
