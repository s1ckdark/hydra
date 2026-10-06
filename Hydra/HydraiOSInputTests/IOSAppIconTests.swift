import XCTest

final class IOSAppIconTests: XCTestCase {
    func testIPhonePrimaryIconIsCompiledAndRegistered() throws {
        try assertPrimaryIcon(in: "CFBundleIcons")
    }

    func testIPadPrimaryIconIsCompiledAndRegistered() throws {
        try assertPrimaryIcon(in: "CFBundleIcons~ipad")
    }

    // Bundle.main drops device-suffixed keys (e.g. "~ipad" on an iPhone), so parse the
    // built Info.plist directly to verify both families on any simulator.
    private func assertPrimaryIcon(in key: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let plistURL = try XCTUnwrap(Bundle.main.url(forResource: "Info", withExtension: "plist"),
                                     file: file, line: line)
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any],
            file: file, line: line)
        let icons = try XCTUnwrap(info[key] as? [String: Any], file: file, line: line)
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon", file: file, line: line)
        let files = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String], file: file, line: line)
        XCTAssertFalse(files.isEmpty, file: file, line: line)
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"), file: file, line: line)
    }
}
