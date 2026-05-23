import XCTest
@testable import Hydra

@MainActor
final class AppStateTests: XCTestCase {
    func testActiveTab_defaultsToChat() {
        let s = AppState()
        XCTAssertEqual(s.activeTab, .chat)
    }

    func testActiveTab_isMutable() {
        let s = AppState()
        s.activeTab = .devices
        XCTAssertEqual(s.activeTab, .devices)
    }
}
