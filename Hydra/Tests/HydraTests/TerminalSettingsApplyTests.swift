import XCTest
import AppKit
import SwiftTerm
@testable import Hydra

final class TerminalSettingsApplyTests: XCTestCase {
    private func makeView() -> SwiftTerm.TerminalView {
        SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), font: nil)
    }

    private func settings() -> TerminalSettings {
        var s = TerminalSettings()
        s.colorSchemeID = "dracula"
        s.fontName = TerminalFontCatalog.systemID
        s.fontSize = 17
        s.cursor = .steadyBar
        s.scrollback = 5_000
        return s
    }

    func testApplySetsFontColorsCursorAndScrollback() throws {
        let view = makeView()
        let s = settings()
        s.apply(to: view, previous: nil)
        XCTAssertEqual(view.font.pointSize, 17)
        let bg = try XCTUnwrap(view.nativeBackgroundColor.usingColorSpace(.sRGB))
        XCTAssertEqual(bg.redComponent, CGFloat(0x28) / 255, accuracy: 0.01)
        XCTAssertEqual(bg.blueComponent, CGFloat(0x36) / 255, accuracy: 0.01)
        XCTAssertEqual(view.getTerminal().options.scrollback, 5_000)
    }

    func testReapplyingSameSettingsKeepsFontObject() {
        let view = makeView()
        let s = settings()
        s.apply(to: view, previous: nil)
        let font = view.font
        s.apply(to: view, previous: s)
        XCTAssertTrue(view.font === font)
    }

    func testOnlyChangedFieldIsApplied() {
        let view = makeView()
        var s = settings()
        s.apply(to: view, previous: nil)
        let font = view.font
        var next = s
        next.scrollback = 50_000
        next.apply(to: view, previous: s)
        XCTAssertTrue(view.font === font)
        XCTAssertEqual(view.getTerminal().options.scrollback, 50_000)
        s = next
        next.fontSize = 20
        next.apply(to: view, previous: s)
        XCTAssertEqual(view.font.pointSize, 20)
    }

    func testCursorMapping() {
        XCTAssertEqual(TerminalCursor.allCases.count, 6)
        var s = TerminalSettings()
        s.cursor = .blinkUnderline
        if case .blinkUnderline = s.swiftTermCursor {} else { XCTFail("mapping") }
        s.cursor = .steadyBlock
        if case .steadyBlock = s.swiftTermCursor {} else { XCTFail("mapping") }
    }
}
