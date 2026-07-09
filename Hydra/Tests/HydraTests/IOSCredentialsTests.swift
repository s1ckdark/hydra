#if os(macOS)
import XCTest
@testable import Hydra

/// The iOS credential builder is a platform-agnostic pure function so it can be
/// unit-tested on macOS even though defaultCredentials() only calls it on iOS.
final class IOSCredentialsTests: XCTestCase {
    func testBuildsSingleImportedKey() {
        let creds = TerminalSession.makeImportedCredentials(pem: "PEMDATA", user: "dave", port: 22)
        XCTAssertEqual(creds.user, "dave")
        XCTAssertEqual(creds.port, 22)
        XCTAssertEqual(creds.keys.count, 1)
        XCTAssertEqual(creds.keys.first?.algorithm, "imported")
        XCTAssertEqual(creds.keys.first?.pem, Data("PEMDATA".utf8))
    }
    func testEmptyPemYieldsNoKeys() {
        let creds = TerminalSession.makeImportedCredentials(pem: "", user: "root", port: 22)
        XCTAssertEqual(creds.user, "root")
        XCTAssertTrue(creds.keys.isEmpty)
    }
}
#endif
