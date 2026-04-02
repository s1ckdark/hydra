import Foundation

@MainActor
class OrchViewModel: ObservableObject {
    @Published var orchs: [Orch] = []
    @Published var selectedOrch: Orch?
    @Published var health: OrchHealth?
    @Published var executeResult: ExecuteResponse?
    @Published var workerStatuses: [WorkerStatus] = []
    @Published var isLoading = false
    @Published var isExecuting = false
    @Published var showCreateSheet = false
    @Published var error: String?

    private let api = APIClient.shared
    private var processPollTask: Task<Void, Never>?

    func loadOrchs() async {
        isLoading = true
        do {
            orchs = try await api.listOrchs()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func selectOrch(_ orch: Orch) async {
        selectedOrch = orch
        do {
            health = try await api.getOrchHealth(id: orch.id)
        } catch {
            self.error = error.localizedDescription
        }
        startProcessPolling()
    }

    func startProcessPolling() {
        processPollTask?.cancel()
        guard let orch = selectedOrch else { return }
        processPollTask = Task {
            while !Task.isCancelled {
                await fetchProcesses(orchId: orch.id)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopProcessPolling() {
        processPollTask?.cancel()
        processPollTask = nil
    }

    private func fetchProcesses(orchId: String) async {
        do {
            let response = try await api.getOrchProcesses(id: orchId)
            workerStatuses = response.workers
        } catch {
            // silently retry
        }
    }

    func execute(command: String, timeout: Int = 30) async {
        guard let orch = selectedOrch else { return }
        isExecuting = true
        executeResult = nil
        do {
            executeResult = try await api.executeOnOrch(id: orch.id, command: command, timeout: timeout)
        } catch {
            self.error = error.localizedDescription
        }
        isExecuting = false
    }

    func deleteOrch(id: String) async {
        do {
            try await api.deleteOrch(id: id, force: true)
            orchs.removeAll { $0.id == id }
            if selectedOrch?.id == id { selectedOrch = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
