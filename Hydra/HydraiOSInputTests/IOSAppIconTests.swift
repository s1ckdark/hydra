import XCTest

final class IOSAppIconTests: XCTestCase {
    func testIPhonePrimaryIconIsCompiledAndRegistered() throws {
        try assertPrimaryIcon(in: "CFBundleIcons")
    }

    func testIPadPrimaryIconIsCompiledAndRegistered() throws {
        try assertPrimaryIcon(in: "CFBundleIcons~ipad")
    }

    private func assertPrimaryIcon(in key: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: key) as? [String: Any],
                                 file: file, line: line)
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon", file: file, line: line)
        let files = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String], file: file, line: line)
        XCTAssertFalse(files.isEmpty, file: file, line: line)
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"), file: file, line: line)
    }
}
