import XCTest
@testable import Hydra

final class TerminalColorSchemeTests: XCTestCase {
    func testPresetsHaveSixteenANSIColors() {
        for scheme in TerminalColorScheme.presets {
            XCTAssertEqual(scheme.ansi.count, 16, scheme.id)
        }
    }

    func testPresetIDsAreUnique() {
        let ids = TerminalColorScheme.presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["default-dark", "solarized-dark", "solarized-light", "dracula", "nord"])
    }

    func testFindReturnsPresetOrFallsBackToDefaultDark() {
        for scheme in TerminalColorScheme.presets {
            XCTAssertEqual(TerminalColorScheme.find(id: scheme.id), scheme)
        }
        XCTAssertEqual(TerminalColorScheme.find(id: "nope"), .defaultDark)
        XCTAssertEqual(TerminalColorScheme.find(id: ""), .defaultDark)
    }

    func testRGBComponents() {
        let c = TerminalColorScheme.rgbComponents(0x12AB7F)
        XCTAssertEqual(c.r, 0x12); XCTAssertEqual(c.g, 0xAB); XCTAssertEqual(c.b, 0x7F)
    }

    func testSwiftTermColorScalesEightBitToSixteenBit() {
        let red = TerminalColorScheme.swiftTermColor(0xFF0000)
        XCTAssertEqual(red.red, 65535); XCTAssertEqual(red.green, 0); XCTAssertEqual(red.blue, 0)
        let mid = TerminalColorScheme.swiftTermColor(0x000180)
        XCTAssertEqual(mid.green, 257); XCTAssertEqual(mid.blue, 0x80 * 257)
    }

    func testPaletteMatchesANSIOrder() {
        let scheme = TerminalColorScheme.dracula
        let palette = scheme.swiftTermPalette()
        XCTAssertEqual(palette.count, 16)
        XCTAssertEqual(palette[1].red, 0xFF * 257)   // 0xFF5555
        XCTAssertEqual(palette[1].green, 0x55 * 257)
    }
}
