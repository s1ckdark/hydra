import XCTest

final class TerminalNodeSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--terminal-recovery-ui-test", "-appLanguage", "ko"]
        app.launch()
        let device = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "fixture-machine")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        device.tap()
        XCTAssertTrue(app.staticTexts["terminal-settings-probe"].waitForExistence(timeout: 10))
    }

    override func tearDown() {
        // 다음 실행을 위해 노드 설정을 지운다.
        openPanel()
        setFollow(true)
        closePanel()
        app.terminate()
    }

    private func openPanel() {
        app.buttons["terminal-node-settings"].firstMatch.tap()
        app.buttons["터미널 설정"].firstMatch.tap()
        XCTAssertTrue(app.switches["terminal-node-follow-global"].firstMatch.waitForExistence(timeout: 5))
    }

    private func closePanel() {
        app.buttons["terminal-node-settings-done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["terminal-settings-probe"].waitForExistence(timeout: 5))
    }

    /// Form 안 `Toggle`의 접근성 요소는 행 전체(레이블 + 스위치)라서 `.tap()`은
    /// 행 한가운데 = 레이블 위를 눌러 아무 일도 일어나지 않는다. 실제 UISwitch는
    /// 행의 뒤쪽 끝에 있으므로 그 위치를 찍는다.
    private func tapSwitch(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// 패널은 `.presentationDetents([.medium, .large])` 시트라서 SwiftUI `Form`이 화면 밖
    /// (아래쪽) 행은 접근성 트리에 아예 만들지 않는다. 폰트 섹션의 Stepper는 기본 `.medium`
    /// 높이에서는 보이지 않으므로, 위로 스와이프해 시트를 `.large`로 키우고(필요하면 이어서
    /// 폼 내용을 스크롤해) Stepper가 나타날 때까지 최대 5번 반복한다.
    private func revealStepper() -> XCUIElement {
        let stepper = app.steppers["terminal-settings-size"].firstMatch
        let container: XCUIElement = {
            if app.scrollViews.firstMatch.exists { return app.scrollViews.firstMatch }
            if app.tables.firstMatch.exists { return app.tables.firstMatch }
            return app
        }()
        var attempts = 0
        while !stepper.exists && attempts < 5 {
            container.swipeUp()
            attempts += 1
        }
        return stepper
    }

    private func setFollow(_ on: Bool) {
        let follow = app.switches["terminal-node-follow-global"].firstMatch
        if (follow.value as? String == "1") != on { tapSwitch(follow) }
        let expected = on ? "1" : "0"
        if follow.value as? String != expected {
            let predicate = NSPredicate(format: "value == %@", expected)
            let met = XCTNSPredicateExpectation(predicate: predicate, object: follow)
            _ = XCTWaiter().wait(for: [met], timeout: 3)
        }
        XCTAssertEqual(follow.value as? String, expected)
    }

    private var probeSize: Int {
        Int(app.staticTexts["terminal-settings-probe"].label.split(separator: "|")[0])!
    }

    func testNodeOverrideChangesOnlyThisTerminal() {
        openPanel()
        setFollow(true)
        closePanel()
        let globalSize = probeSize

        openPanel()
        setFollow(false)
        let stepper = revealStepper()
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        stepper.buttons.element(boundBy: 1).tap()   // 증가
        closePanel()
        XCTAssertEqual(probeSize, globalSize + 1)

        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "terminal-node-override"
        capture.lifetime = .keepAlways
        add(capture)

        openPanel()
        setFollow(true)
        closePanel()
        XCTAssertEqual(probeSize, globalSize, "따르기를 다시 켜면 전체 설정 크기로 돌아와야 한다")
    }
}
