#if os(macOS)
import XCTest
@testable import Hydra
import SSHTransport

/// 사이드바 행 병합 규칙(TerminalSidebarRow.rows) 검증 —
/// 스펙: docs/superpowers/specs/2026-07-14-terminal-sidebar-design.md
final class TerminalSidebarModelTests: XCTestCase {
    private func device(_ id: String, online: Bool = true, ssh: Bool = true) -> TerminalSidebarRow.DeviceInfo {
        .init(id: id, name: id, online: online, sshEnabled: ssh)
    }
    private func session(_ id: String, deviceId: String, state: SSHState = .connected) -> TerminalSidebarRow.SessionInfo {
        .init(id: id, deviceId: deviceId, deviceName: "dev-\(deviceId)", state: state)
    }

    func testDeviceWithSessionCarriesSessionIdAndState() {
        let rows = TerminalSidebarRow.rows(
            devices: [device("a"), device("b")],
            sessions: [session("s1", deviceId: "a", state: .connecting)])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].sessionId, "s1")
        XCTAssertEqual(rows[0].state, .connecting)
        XCTAssertNil(rows[1].sessionId)
        XCTAssertNil(rows[1].state)
    }

    func testDeviceOrderFollowsInput() {
        let rows = TerminalSidebarRow.rows(
            devices: [device("b"), device("a")], sessions: [])
        XCTAssertEqual(rows.map(\.id), ["b", "a"])
    }

    func testOnlineSSHDeviceWithoutSessionIsEnabled() {
        let rows = TerminalSidebarRow.rows(devices: [device("a")], sessions: [])
        XCTAssertTrue(rows[0].isEnabled)
    }

    func testOfflineOrNonSSHDeviceWithoutSessionIsDisabled() {
        let rows = TerminalSidebarRow.rows(
            devices: [device("off", online: false), device("nossh", ssh: false)],
            sessions: [])
        XCTAssertFalse(rows[0].isEnabled)
        XCTAssertFalse(rows[1].isEnabled)
    }

    func testDeviceWithSessionStaysEnabledWhenOffline() {
        let rows = TerminalSidebarRow.rows(
            devices: [device("a", online: false)],
            sessions: [session("s1", deviceId: "a", state: .disconnected(reason: nil))])
        XCTAssertTrue(rows[0].isEnabled)
        XCTAssertEqual(rows[0].sessionId, "s1")
    }

    func testOrphanSessionAppendedAtBottomWithPrefixedId() {
        let rows = TerminalSidebarRow.rows(
            devices: [device("a")],
            sessions: [session("s9", deviceId: "gone")])
        XCTAssertEqual(rows.count, 2)
        let orphan = rows[1]
        XCTAssertEqual(orphan.id, "session:s9")
        XCTAssertNil(orphan.deviceId)
        XCTAssertEqual(orphan.sessionId, "s9")
        XCTAssertEqual(orphan.name, "dev-gone")
        XCTAssertTrue(orphan.isEnabled)
    }

    func testOrphanIdDoesNotCollideWithDeviceRowId() {
        // 디바이스 id가 우연히 세션 id와 같아도 행 id는 겹치지 않는다.
        let rows = TerminalSidebarRow.rows(
            devices: [device("s9")],
            sessions: [session("s9", deviceId: "gone")])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}
#endif
