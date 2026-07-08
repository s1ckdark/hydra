#if os(macOS)
import XCTest
import Combine
@testable import Hydra

@MainActor
final class ConsoleViewModelTests: XCTestCase {
    private func makeVM() -> ConsoleViewModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pysnip-vm-\(UUID().uuidString).json")
        let store = PySnippetStore(fileURL: url)
        // 인터프리터 미발견 executor (테스트에서 실제 실행 안 함)
        let exec = PYExecutor(interpreterProvider: { nil }, pylibProvider: { nil })
        return ConsoleViewModel(store: store, executor: exec)
    }

    func testSelectLoadsDraft() {
        let vm = makeVM()
        let first = vm.store.snippets[0]
        vm.select(first.id)
        XCTAssertEqual(vm.draftCode, first.code)
        XCTAssertEqual(vm.draftName, first.name)
    }

    func testNewSnippetCreatesAndSelects() {
        let vm = makeVM()
        let before = vm.store.snippets.count
        vm.newSnippet()
        XCTAssertEqual(vm.store.snippets.count, before + 1)
        XCTAssertNotNil(vm.selectedID)
    }

    func testSaveDraftPersistsEdits() {
        let vm = makeVM()
        vm.newSnippet()
        vm.draftName = "edited"
        vm.draftCode = "print('edited')"
        vm.saveDraft()
        let saved = vm.store.snippets.first { $0.id == vm.selectedID }
        XCTAssertEqual(saved?.name, "edited")
        XCTAssertEqual(saved?.code, "print('edited')")
    }

    func testDeleteSelectedRemoves() {
        let vm = makeVM()
        vm.newSnippet()
        let id = vm.selectedID!
        vm.deleteSelected()
        XCTAssertFalse(vm.store.snippets.contains { $0.id == id })
    }

    func testViewModelRepublishesOnStoreChange() {
        let vm = makeVM()
        var fired = false
        let c = vm.objectWillChange.sink { fired = true }
        vm.store.add(PySnippet(name: "x", code: "y"))   // child @Published mutation
        XCTAssertTrue(fired, "vm should re-publish when its store changes")
        c.cancel()
    }
}
#endif
