import XCTest
@testable import Hydra

@MainActor
final class AppStateTests: XCTestCase {
    func testActiveTab_defaultsToDashboard() {
        // Chat is no longer a tab — it moved to the right-side drawer, so
        // the default operational surface is Dashboard.
        let s = AppState()
        XCTAssertEqual(s.activeTab, .dashboard)
    }

    func testActiveTab_isMutable() {
        let s = AppState()
        s.activeTab = .devices
        XCTAssertEqual(s.activeTab, .devices)
    }

    func testChatDrawer_defaultsClosed() {
        // Fresh install (no persisted UserDefaults key) starts with the
        // drawer closed.
        UserDefaults.standard.removeObject(forKey: "chatDrawerOpen")
        let s = AppState()
        XCTAssertFalse(s.isChatDrawerOpen)
    }

    func testActiveTab_supportsConsole() {
        let s = AppState()
        s.activeTab = .console
        XCTAssertEqual(s.activeTab, .console)
    }
}
