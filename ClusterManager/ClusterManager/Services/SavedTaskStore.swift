import Foundation

/// Manages saved task templates with JSON file persistence and scheduled execution.
@MainActor
class SavedTaskStore: ObservableObject {
    static let shared = SavedTaskStore()

    @Published var tasks: [SavedTask] = []
    @Published var runningTaskIds: Set<String> = []
    @Published var lastResults: [String: TaskResult] = [:] // keyed by SavedTask.id

    private let fileURL: URL
    private var schedulerTasks: [String: Task<Void, Never>] = [:]

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("saved_tasks.json")
        load()
        startSchedulers()
    }

    // MARK: - CRUD

    func add(_ task: SavedTask) {
        tasks.append(task)
        save()
        if task.schedule?.enabled == true {
            startScheduler(for: task)
        }
    }

    func update(_ task: SavedTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx] = task
        save()
        // Restart scheduler if schedule changed
        stopScheduler(for: task.id)
        if task.schedule?.enabled == true {
            startScheduler(for: task)
        }
    }

    func delete(_ task: SavedTask) {
        stopScheduler(for: task.id)
        tasks.removeAll { $0.id == task.id }
        lastResults.removeValue(forKey: task.id)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tasks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Execute

    func execute(_ task: SavedTask, deviceId: String? = nil) async {
        let targetId = deviceId ?? task.targetDeviceId
        guard let target = targetId else { return }

        runningTaskIds.insert(task.id)
        defer { runningTaskIds.remove(task.id) }

        do {
            let result = try await APIClient.shared.executeOnDevice(
                id: target,
                command: task.command,
                timeout: task.timeout
            )
            lastResults[task.id] = result
            updateLastRun(taskId: task.id, status: result.hasError ? "failed" : "success")
        } catch {
            lastResults[task.id] = TaskResult(
                deviceId: target, deviceName: "", gpu: "",
                output: "", error: error.localizedDescription, durationMs: 0
            )
            updateLastRun(taskId: task.id, status: "failed")
        }
    }

    private func updateLastRun(taskId: String, status: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[idx].lastRunAt = Date()
        tasks[idx].lastRunStatus = status
        save()
    }

    // MARK: - Scheduling

    private func startSchedulers() {
        for task in tasks where task.schedule?.enabled == true {
            startScheduler(for: task)
        }
    }

    private func startScheduler(for task: SavedTask) {
        guard let schedule = task.schedule, schedule.enabled else { return }
        guard task.targetDeviceId != nil else { return } // Can't schedule without a target

        let intervalSeconds: TimeInterval
        switch schedule.type {
        case .interval: intervalSeconds = Double(schedule.intervalMinutes) * 60
        case .hourly: intervalSeconds = 3600
        case .daily: intervalSeconds = 86400
        }

        schedulerTasks[task.id] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                await execute(task)
            }
        }
    }

    private func stopScheduler(for taskId: String) {
        schedulerTasks[taskId]?.cancel()
        schedulerTasks.removeValue(forKey: taskId)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedTask].self, from: data) else { return }
        tasks = decoded
    }
}
