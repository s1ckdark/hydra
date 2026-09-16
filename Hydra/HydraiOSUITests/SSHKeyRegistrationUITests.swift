import XCTest

final class SSHKeyRegistrationUITests: XCTestCase {
    func testUnsupportedPasswordAuthenticationShowsReasonAndManualFallback() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ssh-registration-ui-test", "--ssh-registration-error-fixture", "-appLanguage", "ko"]
        app.launch()
        let host = app.textFields["ssh-registration-host"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()
        host.typeText("fixture.invalid")
        let password = app.secureTextFields["ssh-registration-password"]
        reveal(password, in: app)
        password.tap()
        password.typeText("fixture-only-password")
        let submit = app.buttons["ssh-registration-submit"]
        reveal(submit, in: app)
        submit.tap()
        let confirm = app.buttons["ssh-registration-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let error = app.staticTexts["ssh-registration-error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 8))
        XCTAssertTrue(error.label.contains("비밀번호 인증을 허용하지 않습니다"))
        XCTAssertTrue(error.label.contains("서버 등록 명령 복사"))
        XCTAssertFalse(error.label.contains("fixture-only-password"))
        let copy = app.buttons["ssh-registration-copy-command"]
        reveal(copy, in: app)
        XCTAssertTrue(copy.isEnabled)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "ssh-registration-password-policy-error"
        capture.lifetime = .keepAlways
        add(capture)
        app.terminate()
    }

    func testRegistrationRequiresConfirmationAndHostApproval() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ssh-registration-ui-test", "-appLanguage", "ko"]
        app.launch()
        let host = app.textFields["ssh-registration-host"]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        let submit = app.buttons["ssh-registration-submit"]
        XCTAssertFalse(submit.isEnabled)
        host.tap()
        host.typeText("fixture.invalid")
        let password = app.secureTextFields["ssh-registration-password"]
        reveal(password, in: app)
        password.tap()
        password.typeText("fixture-only-password")
        reveal(submit, in: app)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let confirm = app.buttons["ssh-registration-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // LabeledContent exposes its label and value as one accessibility element.
        let target = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "fixture.invalid")).firstMatch
        let confirmationCapture = XCTAttachment(screenshot: app.screenshot())
        confirmationCapture.name = "ssh-key-registration-confirmation"
        confirmationCapture.lifetime = .keepAlways
        add(confirmationCapture)
        XCTAssertTrue(target.exists)
        confirm.tap()
        // SwiftUI alerts can expose both a button and its nested button label.
        let trust = app.alerts.buttons["ssh-registration-trust-host"].firstMatch
        XCTAssertTrue(trust.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["ssh-registration-result"].exists)
        trust.tap()
        // Label's decorative image inherits its identifier, so select the text.
        let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "공개키를 등록하고 키 로그인까지 확인했습니다")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        reveal(result, in: app)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "ssh-key-registration-synthetic-success"
        capture.lifetime = .keepAlways
        add(capture)
        app.terminate()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}
