// Hydra/Hydra/ViewModels/ConsoleViewModel.swift
#if os(macOS)
import Foundation
import Combine

@MainActor
final class ConsoleViewModel: ObservableObject {
    @Published var selectedID: String?
    @Published var draftName: String = ""
    @Published var draftCode: String = ""

    let store: PySnippetStore
    let executor: PYExecutor

    private var cancellables = Set<AnyCancellable>()

    init(store: PySnippetStore = .shared, executor: PYExecutor? = nil) {
        self.store = store
        self.executor = executor ?? PYExecutor()

        // 중첩 ObservableObject(store/executor)의 변경을 vm의 objectWillChange로 재발행
        // (@StateObject var vm 뷰가 자식 변경에도 재렌더링되도록)
        self.store.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.executor.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if let first = store.snippets.first { select(first.id) }
    }

    func select(_ id: String?) {
        selectedID = id
        if let s = store.snippets.first(where: { $0.id == id }) {
            draftName = s.name
            draftCode = s.code
        } else {
            draftName = ""; draftCode = ""
        }
    }

    func newSnippet() {
        let s = PySnippet(name: "새 스니펫", code: "# client 가 이미 주입돼 있습니다\nprint(client.list_devices())\n")
        store.add(s)
        select(s.id)
    }

    func saveDraft() {
        guard let id = selectedID, var s = store.snippets.first(where: { $0.id == id }) else { return }
        s.name = draftName
        s.code = draftCode
        store.update(s)
    }

    func deleteSelected() {
        guard let id = selectedID, let s = store.snippets.first(where: { $0.id == id }) else { return }
        store.delete(s)
        select(store.snippets.first?.id)
    }

    func run() async {
        saveDraft()
        await executor.run(draftCode)
        if let id = selectedID {
            store.recordRun(id: id, exitCode: executor.lastExitCode)
        }
    }
}
#endif
