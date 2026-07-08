import Foundation

/// Named Python snippet persistence with JSON file storage. Mirrors
/// SavedTaskStore's shape but is manual-run only (no scheduler). Seeds a few
/// starter snippets on first launch (empty/missing file).
@MainActor
final class PySnippetStore: ObservableObject {
    static let shared = PySnippetStore()

    @Published var snippets: [PySnippet] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = docs.appendingPathComponent("py_snippets.json")
        }
        load()
    }

    // MARK: - CRUD
    func add(_ snippet: PySnippet) { snippets.append(snippet); save() }

    func update(_ snippet: PySnippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[idx] = snippet
        save()
    }

    func delete(_ snippet: PySnippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        snippets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func recordRun(id: String, exitCode: Int32?) {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[idx].lastRunAt = Date()
        snippets[idx].lastExitCode = exitCode
        save()
    }

    // MARK: - Persistence
    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PySnippet].self, from: data),
              !decoded.isEmpty else {
            snippets = Self.seedSnippets()
            save()
            return
        }
        snippets = decoded
    }

    // MARK: - Seeds
    static func seedSnippets() -> [PySnippet] {
        [
            PySnippet(name: "제출 & 대기", code: """
            t = client.submit_task("echo hello-from-console", required_capabilities=[])
            print("submitted:", t.id, t.status)
            t.wait(timeout=30, poll_interval=0.5)
            print("final:", t.status, t.result.output if t.result else None)
            """),
            PySnippet(name: "GPU 현황", code: """
            for d in client.list_devices():
                if d.has_gpu:
                    print(d.name, d.gpu_model, "x", d.gpu_count)
            """),
            PySnippet(name: "sim: 어디 배치될까", code: """
            spec = TaskSpec.command("train.py", required_capabilities=["gpu"], priority="high")
            for row in sim.explain(spec, client.cluster_snapshot()):
                print(row.worker_id, row.eligible, row.total, row.reject_reason)
            """),
        ]
    }
}
