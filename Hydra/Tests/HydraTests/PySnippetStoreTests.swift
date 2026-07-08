import XCTest
@testable import Hydra

@MainActor
final class PySnippetStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pysnip-test-\(UUID().uuidString).json")
    }

    func testAddPersistsAndReloads() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PySnippetStore(fileURL: url)
        let before = store.snippets.count
        store.add(PySnippet(name: "hello", code: "print(1)"))
        XCTAssertEqual(store.snippets.count, before + 1)
        // 새 스토어가 같은 파일에서 로드
        let reloaded = PySnippetStore(fileURL: url)
        XCTAssertTrue(reloaded.snippets.contains { $0.name == "hello" })
    }

    func testUpdateAndDelete() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PySnippetStore(fileURL: url)
        var s = PySnippet(name: "a", code: "x")
        store.add(s)
        s.code = "y"
        store.update(s)
        XCTAssertEqual(store.snippets.first { $0.id == s.id }?.code, "y")
        store.delete(s)
        XCTAssertFalse(store.snippets.contains { $0.id == s.id })
    }

    func testRecordRunUpdatesMetadata() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PySnippetStore(fileURL: url)
        let s = PySnippet(name: "a", code: "x")
        store.add(s)
        store.recordRun(id: s.id, exitCode: 0)
        let got = store.snippets.first { $0.id == s.id }
        XCTAssertEqual(got?.lastExitCode, 0)
        XCTAssertNotNil(got?.lastRunAt)
    }

    func testSeedSnippetsNonEmptyAndValid() {
        let seeds = PySnippetStore.seedSnippets()
        XCTAssertFalse(seeds.isEmpty)
        XCTAssertTrue(seeds.allSatisfy { !$0.name.isEmpty && !$0.code.isEmpty })
    }

    func testEmptyFileSeedsOnFirstLoad() {
        let url = tempURL()   // 존재하지 않는 파일 → 최초 실행
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PySnippetStore(fileURL: url)
        XCTAssertFalse(store.snippets.isEmpty)   // 시드가 주입됨
    }
}
