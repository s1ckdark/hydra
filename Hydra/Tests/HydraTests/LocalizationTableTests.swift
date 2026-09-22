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

    /// macOS 화면의 LocalizedStringKey 리터럴(보간 없는 것)은 모두 테이블에 키가 있어야 한다.
    func testMacViewLiteralsHaveTranslations() throws {
        let en = try Self.table("en")
        let views = Self.packageRoot.appendingPathComponent("Hydra/Views")
        let pattern = try NSRegularExpression(pattern:
            #"(?:Text|Button|Label|Section|Toggle|Picker|TextField|SecureField|Menu|LabeledContent|navigationTitle|help|alert|confirmationDialog)\(\s*"((?:[^"\\]|\\.)+)""#)
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Views/iOS/") && !$0.path.contains("/.omc/") }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                let key = String(source[Range(match.range(at: 1), in: source)!])
                if key.contains("\\(") { continue }        // 보간 리터럴은 포맷 키로 따로 관리
                if en[key] == nil { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        XCTAssertEqual(missing.sorted(), [], "번역 키 누락")
    }
}
