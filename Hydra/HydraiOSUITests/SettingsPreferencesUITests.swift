import XCTest

final class SettingsPreferencesUITests: XCTestCase {
    func testLanguageThemePersistenceAndManualRefreshUpdatesDevices() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--settings-ui-test", "--settings-test-suite", "hydra.settings.qa.\(UUID().uuidString)"]
        app.launch()
        let probe = app.staticTexts["settings-appearance-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        XCTAssertTrue(probe.label.hasPrefix("ko|"))

        app.buttons["settings.appLanguage"].firstMatch.tap()
        app.buttons["English"].firstMatch.tap()
        XCTAssertTrue(probe.label.hasPrefix("en|"))
        app.buttons["settings.appTheme"].firstMatch.tap()
        app.buttons["Dark"].firstMatch.tap()
        XCTAssertEqual(probe.label, "en|dark")

        let refresh = app.buttons["settings-refresh-devices"]
        XCTAssertTrue(refresh.exists)
        refresh.tap()
        let count = app.staticTexts["settings-device-refresh-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.label.contains("1"))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "settings-english-dark-refresh"
        capture.lifetime = .keepAlways
        add(capture)

        // iPadOS can present tabs in a top/sidebar container, not XCUI TabBar.
        let devicesTab = app.buttons["Devices"].firstMatch
        XCTAssertTrue(devicesTab.exists)
        devicesTab.tap()
        XCTAssertTrue(app.staticTexts["intlmac (intlmac.tail.test)"].waitForExistence(timeout: 5))
        let deviceCapture = XCTAttachment(screenshot: app.screenshot())
        deviceCapture.name = "devices-machine-name-and-address"
        deviceCapture.lifetime = .keepAlways
        add(deviceCapture)
        app.terminate()
        app.launch()
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        XCTAssertEqual(probe.label, "en|dark", "Preferences must survive app restart")
        app.terminate()
    }
}
