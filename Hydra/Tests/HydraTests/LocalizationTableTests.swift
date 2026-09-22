import XCTest

/// 공유 번역 테이블(Hydra/Resources)의 ko·en 키가 어긋나지 않는지 소스 파일에서 직접 확인한다.
final class LocalizationTableTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // HydraTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root (hydra/Hydra)

    static func table(_ language: String) throws -> [String: String] {
        let url = packageRoot.appendingPathComponent("Hydra/Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(text.propertyListFromStringsFileFormat(), url.path)
    }

    func testKoreanAndEnglishTablesHaveTheSameKeys() throws {
        let ko = try Self.table("ko"), en = try Self.table("en")
        XCTAssertFalse(ko.isEmpty)
        XCTAssertEqual(Set(ko.keys).subtracting(en.keys).sorted(), [], "ko에만 있는 키")
        XCTAssertEqual(Set(en.keys).subtracting(ko.keys).sorted(), [], "en에만 있는 키")
    }
}
