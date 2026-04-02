import SwiftUI

#if os(macOS)
struct TasksView: View {
    @ObservedObject private var store = SavedTaskStore.shared
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @State private var showingEditor = false
    @State private var editingTask: SavedTask?
    @State private var selectedTask: SavedTask?

    var body: some View {
        NavigationSplitView {
            List(store.tasks, selection: $selectedTask) { task in
                TaskRow(task: task, isRunning: store.runningTaskIds.contains(task.id))
                    .tag(task)
                    .contextMenu {
                        Button("Edit") { editingTask = task; showingEditor = true }
                        Button("Duplicate") { duplicateTask(task) }
                        Divider()
                        Button("Delete", role: .destructive) { store.delete(task) }
                    }
            }
            .navigationTitle("Tasks")
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
            .toolbar {
                ToolbarItem {
                    Button(action: { editingTask = nil; showingEditor = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task, store: store, devices: dashboardVM.onlineDevices)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Select a task or create a new one")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            TaskEditorSheet(
                task: editingTask,
                devices: dashboardVM.devices,
                onSave: { task in
                    if editingTask != nil {
                        store.update(task)
                    } else {
                        store.add(task)
                    }
                    showingEditor = false
                },
                onCancel: { showingEditor = false }
            )
        }
    }

    private func duplicateTask(_ task: SavedTask) {
        var copy = task
        copy.id = UUID().uuidString
        copy.name = "\(task.name) (copy)"
        copy.lastRunAt = nil
        copy.lastRunStatus = nil
        copy.createdAt = Date()
        store.add(copy)
    }
}

// MARK: - Task Row

struct TaskRow: View {
    let task: SavedTask
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.priority.icon)
                .font(.caption2)
                .foregroundStyle(priorityColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(task.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                HStack(spacing: 4) {
                    Text(task.command)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let schedule = task.schedule, schedule.enabled {
                    Text(schedule.displayText)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                }
                if let status = task.lastRunStatus {
                    Circle()
                        .fill(status == "success" ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var priorityColor: Color {
        switch task.priority {
        case .low: return .gray
        case .normal: return .blue
        case .high: return .orange
        case .urgent: return .red
        }
    }
}

// MARK: - Task Detail

struct TaskDetailView: View {
    let task: SavedTask
    @ObservedObject var store: SavedTaskStore
    let devices: [Device]
    @State private var runtimeDeviceId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text(task.name)
                            .font(.title2.bold())
                        Text(task.command)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    priorityBadge
                }

                // Info grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    InfoCard(label: "Target", value: task.targetDeviceName ?? "Select at runtime")
                    InfoCard(label: "Timeout", value: "\(task.timeout)s")
                    InfoCard(label: "Priority", value: task.priority.rawValue.capitalized)
                    InfoCard(label: "Schedule", value: task.schedule?.displayText ?? "Off")
                    if !task.requiredCapabilities.isEmpty {
                        InfoCard(label: "Capabilities", value: task.requiredCapabilities.joined(separator: ", "))
                    }
                    if let lastRun = task.lastRunAt {
                        InfoCard(label: "Last Run", value: lastRun.formatted(.dateTime.month().day().hour().minute()))
                    }
                }

                Divider()

                // Execute section
                GroupBox("Execute") {
                    VStack(alignment: .leading, spacing: 8) {
                        if task.targetDeviceId == nil {
                            HStack {
                                Text("Target device:")
                                    .font(.caption)
                                Picker("", selection: $runtimeDeviceId) {
                                    Text("Select...").tag(nil as String?)
                                    ForEach(devices) { d in
                                        Text(d.shortName).tag(d.id as String?)
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        Button {
                            Task { await store.execute(task, deviceId: runtimeDeviceId) }
                        } label: {
                            HStack {
                                Image(systemName: store.runningTaskIds.contains(task.id) ? "hourglass" : "play.fill")
                                Text(store.runningTaskIds.contains(task.id) ? "Running..." : "Run Now")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.runningTaskIds.contains(task.id) ||
                                  (task.targetDeviceId == nil && runtimeDeviceId == nil))

                        // Result
                        if let result = store.lastResults[task.id] {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: result.hasError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(result.hasError ? .red : .green)
                                    Text(result.hasError ? "Failed" : "Success")
                                        .font(.caption.bold())
                                    Spacer()
                                    Text(String(format: "%.0fms", result.durationMs))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(result.hasError ? (result.error ?? "") : result.output)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(result.hasError ? .red : .primary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(task.name)
    }

    private var priorityBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: task.priority.icon)
            Text(task.priority.rawValue.capitalized)
        }
        .font(.caption.bold())
        .foregroundStyle(priorityColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(priorityColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var priorityColor: Color {
        switch task.priority {
        case .low: return .gray
        case .normal: return .blue
        case .high: return .orange
        case .urgent: return .red
        }
    }
}

private struct InfoCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Task Editor Sheet

struct TaskEditorSheet: View {
    @State private var task: SavedTask
    let devices: [Device]
    let onSave: (SavedTask) -> Void
    let onCancel: () -> Void
    private let isEditing: Bool

    init(task: SavedTask?, devices: [Device], onSave: @escaping (SavedTask) -> Void, onCancel: @escaping () -> Void) {
        self.isEditing = task != nil
        self._task = State(initialValue: task ?? SavedTask(name: "", command: ""))
        self.devices = devices
        self.onSave = onSave
        self.onCancel = onCancel
    }

    @State private var capabilityInput = ""

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(isEditing ? "Edit Task" : "New Task")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(task) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(task.name.isEmpty || task.command.isEmpty)
            }
            .padding()

            Divider()

            Form {
                // Basic
                Section("Basic") {
                    TextField("Task Name", text: $task.name)
                    TextField("Command", text: $task.command)
                        .font(.system(.body, design: .monospaced))
                }

                // Target
                Section("Target Device") {
                    Picker("Device", selection: $task.targetDeviceId) {
                        Text("Select at runtime").tag(nil as String?)
                        ForEach(devices) { d in
                            Text("\(d.shortName) (\(d.tailscaleIp))").tag(d.id as String?)
                        }
                    }
                    .onChange(of: task.targetDeviceId) {
                        task.targetDeviceName = devices.first { $0.id == task.targetDeviceId }?.shortName
                    }
                }

                // Execution
                Section("Execution") {
                    HStack {
                        Text("Timeout")
                        Spacer()
                        TextField("", value: $task.timeout, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }

                    Picker("Priority", selection: $task.priority) {
                        ForEach(SavedTask.Priority.allCases, id: \.self) { p in
                            HStack {
                                Image(systemName: p.icon)
                                Text(p.rawValue.capitalized)
                            }
                            .tag(p)
                        }
                    }
                }

                // Capabilities
                Section("Required Capabilities") {
                    HStack {
                        TextField("Add capability (e.g. gpu, gps)", text: $capabilityInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let cap = capabilityInput.trimmingCharacters(in: .whitespaces).lowercased()
                            if !cap.isEmpty && !task.requiredCapabilities.contains(cap) {
                                task.requiredCapabilities.append(cap)
                                capabilityInput = ""
                            }
                        }
                        .disabled(capabilityInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !task.requiredCapabilities.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(task.requiredCapabilities, id: \.self) { cap in
                                HStack(spacing: 2) {
                                    Text(cap)
                                        .font(.caption)
                                    Button {
                                        task.requiredCapabilities.removeAll { $0 == cap }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }

                // Schedule
                Section("Schedule") {
                    Toggle("Enable Schedule", isOn: Binding(
                        get: { task.schedule?.enabled ?? false },
                        set: { enabled in
                            if task.schedule == nil {
                                task.schedule = SavedTask.Schedule()
                            }
                            task.schedule?.enabled = enabled
                        }
                    ))

                    if task.schedule?.enabled == true {
                        Picker("Type", selection: Binding(
                            get: { task.schedule?.type ?? .interval },
                            set: { task.schedule?.type = $0 }
                        )) {
                            ForEach(SavedTask.Schedule.ScheduleType.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }

                        if task.schedule?.type == .interval {
                            HStack {
                                Text("Every")
                                TextField("", value: Binding(
                                    get: { task.schedule?.intervalMinutes ?? 60 },
                                    set: { task.schedule?.intervalMinutes = $0 }
                                ), format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                Text("minutes")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if task.targetDeviceId == nil {
                            Text("Schedule requires a target device. Select one above.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 620)
    }
}

// MARK: - Flow Layout for capability tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let point = CGPoint(x: bounds.minX + result.positions[index].x,
                              y: bounds.minY + result.positions[index].y)
            subview.place(at: point, anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}

// MARK: - SavedTask Hashable for List selection

extension SavedTask: Hashable {
    static func == (lhs: SavedTask, rhs: SavedTask) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
#endif
