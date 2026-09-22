import XCTest
@testable import Hydra

final class TerminalFontCatalogTests: XCTestCase {
    private var bundledD2Coding: URL {
        LocalizationTableTests.packageRoot.appendingPathComponent("Hydra/Resources/Fonts/D2Coding.ttf")
    }

    func testBundledFontFileAndLicenseExist() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledD2Coding.path))
        let license = LocalizationTableTests.packageRoot.appendingPathComponent("Hydra/Resources/Fonts/OFL.txt")
        let text = (try? String(contentsOf: license, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(text.contains("NHN Corporation"))
    }

    func testRegisteredD2CodingResolvesWithoutFallback() {
        TerminalFontCatalog.registerFont(at: bundledD2Coding)
        let r = TerminalFontCatalog.resolve("D2Coding", size: 15)
        XCTAssertFalse(r.isFallback)
        XCTAssertEqual(r.font.pointSize, 15)
    }

    func testUnknownFontFallsBackToMonospacedSystemFont() {
        let r = TerminalFontCatalog.resolve("No-Such-Font-XYZ", size: 12)
        XCTAssertTrue(r.isFallback)
        XCTAssertEqual(r.font.pointSize, 12)
        XCTAssertTrue(r.font.isFixedPitch)
    }

    func testSystemIDIsNotAFallback() {
        let r = TerminalFontCatalog.resolve(TerminalFontCatalog.systemID, size: 12)
        XCTAssertFalse(r.isFallback)
    }

    func testAvailableFontsStartWithSystemAndHaveNoDuplicates() {
        TerminalFontCatalog.registerFont(at: bundledD2Coding)
        let fonts = TerminalFontCatalog.availableFonts()
        XCTAssertEqual(fonts.first?.id, TerminalFontCatalog.systemID)
        XCTAssertEqual(Set(fonts.map(\.id)).count, fonts.count)
        XCTAssertTrue(fonts.contains { $0.id == "D2Coding" })
    }
}
