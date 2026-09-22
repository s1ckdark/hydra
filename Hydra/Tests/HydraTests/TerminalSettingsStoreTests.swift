import XCTest
import Combine
@testable import Hydra

final class TerminalSettingsStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: TerminalSettingsStore!

    override func setUpWithError() throws {
        suite = "hydra.terminal-settings.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = TerminalSettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaults() {
        let s = store.global
        XCTAssertEqual(s.colorSchemeID, "default-dark")
        XCTAssertEqual(s.fontName, "D2Coding")
        XCTAssertEqual(s.fontSize, TerminalSettings.defaultFontSize)
        XCTAssertEqual(s.cursor, .blinkBlock)
        XCTAssertEqual(s.scrollback, 10_000)
    }

    func testNormalizationClampsSizeAndScrollback() {
        var s = TerminalSettings()
        s.fontSize = 4; s.scrollback = 123
        XCTAssertEqual(s.normalized().fontSize, 8)
        XCTAssertEqual(s.normalized().scrollback, 10_000)
        s.fontSize = 99
        XCTAssertEqual(s.normalized().fontSize, 32)
    }

    func testInvalidStoredGlobalValuesFallBack() {
        defaults.set("weird", forKey: "terminalCursor")
        defaults.set("nope", forKey: "terminalColorScheme")
        defaults.set(77, forKey: "terminalScrollback")
        let s = store.global
        XCTAssertEqual(s.cursor, .blinkBlock)
        XCTAssertEqual(s.colorSchemeID, "default-dark")
        XCTAssertEqual(s.scrollback, 10_000)
    }

    func testExistingColorSchemeKeyIsReadAsGlobal() {
        defaults.set("dracula", forKey: "terminalColorScheme")
        XCTAssertEqual(store.global.colorSchemeID, "dracula")
    }

    func testGlobalRoundTrip() {
        var s = TerminalSettings()
        s.colorSchemeID = "nord"; s.fontName = "Menlo-Regular"; s.fontSize = 16; s.cursor = .steadyBar; s.scrollback = 50_000
        store.global = s
        XCTAssertEqual(TerminalSettingsStore(defaults: defaults).global, s)
        XCTAssertEqual(defaults.string(forKey: "terminalColorScheme"), "nord")
    }

    func testFollowingGlobalByDefaultAndEffectiveUsesGlobal() {
        XCTAssertTrue(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.effective(for: "node-a"), store.global)
    }

    func testTurningOffFollowCopiesGlobalAndTurningOnRemoves() {
        var g = store.global; g.fontSize = 18; store.global = g
        store.setFollowingGlobal(false, for: "node-a")
        XCTAssertFalse(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 18)
        store.setFollowingGlobal(true, for: "node-a")
        XCTAssertTrue(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.overriddenDeviceIDs, [])
    }

    func testUpdateAffectsOnlyThatNode() {
        let before = store.global
        store.update("node-a") { $0.colorSchemeID = "dracula"; $0.fontSize = 20 }
        XCTAssertFalse(store.isFollowingGlobal("node-a"))
        XCTAssertEqual(store.effective(for: "node-a").colorSchemeID, "dracula")
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 20)
        XCTAssertEqual(store.global, before)
        XCTAssertEqual(store.effective(for: "node-b"), before)
        XCTAssertEqual(store.overriddenDeviceIDs, ["node-a"])
    }

    func testUpdateNormalizes() {
        store.update("node-a") { $0.fontSize = 100 }
        XCTAssertEqual(store.effective(for: "node-a").fontSize, 32)
    }

    func testResetOverride() {
        store.update("node-a") { $0.fontSize = 20 }
        store.resetOverride("node-a")
        XCTAssertTrue(store.isFollowingGlobal("node-a"))
    }

    func testCorruptOverrideEntryIsDroppedOthersKept() throws {
        var good = TerminalSettings(); good.fontSize = 15
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let raw: [String: Any] = ["good": goodJSON, "bad": ["fontName": 1]]
        defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: "terminalNodeOverrides")
        XCTAssertEqual(store.effective(for: "good").fontSize, 15)
        XCTAssertTrue(store.isFollowingGlobal("bad"))
    }

    func testChangesNotifyObservers() {
        var fired = 0
        let c = store.objectWillChange.sink { fired += 1 }
        store.update("node-a") { $0.fontSize = 20 }
        var g = store.global; g.fontSize = 9; store.global = g
        XCTAssertEqual(fired, 2)
        c.cancel()
    }
}
