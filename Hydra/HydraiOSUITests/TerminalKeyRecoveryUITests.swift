import XCTest

final class TerminalKeyRecoveryUITests: XCTestCase {
    func testFailedConnectionOpensPrefilledRegistrationWithoutAutomaticRetry() {
        let app = openFixture()
        defer { app.terminate() }
        let attempts = app.staticTexts["recovery-attempt-count"]
        waitForLabel("attempts=1;registrations=0", of: attempts)
        openRegistration(app)
        assertTarget(app)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "failed-connection-prefilled-key-registration"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["terminal-registration-close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["terminal-register-key"].waitForExistence(timeout: 5))
        XCTAssertEqual(attempts.label, "attempts=1;registrations=0")
        app.buttons["terminal-retry"].tap()
        waitForLabel("attempts=2;registrations=0", of: attempts)
    }

    func testMissingKeyOffersKeyManagementWithTheSameTarget() {
        let app = openFixture(noKey: true)
        defer { app.terminate() }
        openRegistration(app)
        assertTarget(app)
        XCTAssertTrue(app.buttons["ssh-registration-manage-key"].exists)
        XCTAssertFalse(app.buttons["ssh-registration-submit"].isEnabled)
    }

    private func openFixture(noKey: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--terminal-recovery-ui-test", "-appLanguage", "ko"]
        if noKey { app.launchArguments.append("--terminal-recovery-no-key") }
        app.launch()
        let device = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "fixture-machine")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        device.tap()
        XCTAssertTrue(app.buttons["terminal-register-key"].waitForExistence(timeout: 5))
        return app
    }

    private func openRegistration(_ app: XCUIApplication) {
        app.buttons["terminal-register-key"].tap()
        XCTAssertTrue(app.textFields["ssh-registration-host"].waitForExistence(timeout: 5))
    }

    private func assertTarget(_ app: XCUIApplication) {
        XCTAssertEqual(app.textFields["ssh-registration-host"].value as? String, "100.64.0.77")
        XCTAssertEqual(app.textFields["ssh-registration-username"].value as? String, "attempt-user")
        let port = app.descendants(matching: .any)["ssh-registration-port"].firstMatch
        XCTAssertTrue(port.label.contains("2222") || (port.value as? String) == "2222")
    }

    private func waitForLabel(_ label: String, of element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
