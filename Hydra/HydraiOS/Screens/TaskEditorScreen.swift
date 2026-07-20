import SwiftUI

/// iOS Task creation/edit sheet — reuses `SavedTaskStore.shared` (same store
/// and `SavedTask` model as macOS's `TaskEditorSheet`), presented as a `Form`
/// with toolbar Cancel/Save instead of a custom title bar, and no fixed
/// `.frame` so it sizes to the sheet's available height.
struct TaskEditorScreen: View {
    let task: SavedTask?

    @ObservedObject private var store = SavedTaskStore.shared
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var command: String
    @State private var targetDeviceId: String?
    @State private var timeout: Int
    @State private var priority: SavedTask.Priority
    @State private var capabilities: [String]
    @State private var capabilityInput = ""
    @State private var scheduleEnabled: Bool
    @State private var scheduleType: SavedTask.Schedule.ScheduleType
    @State private var scheduleIntervalMinutes: Int

    private let isEditing: Bool

    init(task: SavedTask?) {
        self.task = task
        self.isEditing = task != nil
        _name = State(initialValue: task?.name ?? "")
        _command = State(initialValue: task?.command ?? "")
        _targetDeviceId = State(initialValue: task?.targetDeviceId)
        _timeout = State(initialValue: task?.timeout ?? 30)
        _priority = State(initialValue: task?.priority ?? .normal)
        _capabilities = State(initialValue: task?.requiredCapabilities ?? [])
        _scheduleEnabled = State(initialValue: task?.schedule?.enabled ?? false)
        _scheduleType = State(initialValue: task?.schedule?.type ?? .interval)
        _scheduleIntervalMinutes = State(initialValue: task?.schedule?.intervalMinutes ?? 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic") {
                    TextField("Task Name", text: $name)
                    TextField("Command", text: $command)
                        .font(.system(.body, design: .monospaced))
                }

                Section("Target Device") {
                    Picker("Device", selection: $targetDeviceId) {
                        Text("Select at runtime").tag(nil as String?)
                        ForEach(dashboardVM.devices, id: \.id) { d in
                            Text("\(d.shortName) (\(d.tailscaleIp))").tag(d.id as String?)
                        }
                    }
                }

                Section("Execution") {
                    Stepper("Timeout: \(timeout)s", value: $timeout, in: 5...600, step: 5)
                    Picker("Priority", selection: $priority) {
                        ForEach(SavedTask.Priority.allCases, id: \.self) { p in
                            Label(p.rawValue.capitalized, systemImage: p.icon).tag(p)
                        }
                    }
                }

                Section("Required Capabilities") {
                    HStack {
                        TextField("Add capability (e.g. gpu, gps)", text: $capabilityInput)
                        Button("Add") {
                            let cap = capabilityInput.trimmingCharacters(in: .whitespaces).lowercased()
                            if !cap.isEmpty && !capabilities.contains(cap) {
                                capabilities.append(cap)
                                capabilityInput = ""
                            }
                        }
                        .disabled(capabilityInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(capabilities, id: \.self) { cap in
                        Text(cap)
                    }
                    .onDelete { offsets in
                        capabilities.remove(atOffsets: offsets)
                    }
                }

                Section("Schedule") {
                    Toggle("Enable Schedule", isOn: $scheduleEnabled)

                    if scheduleEnabled {
                        Picker("Type", selection: $scheduleType) {
                            ForEach(SavedTask.Schedule.ScheduleType.allCases, id: \.self) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }

                        if scheduleType == .interval {
                            Stepper("Every \(scheduleIntervalMinutes)m", value: $scheduleIntervalMinutes, in: 1...1440)
                        }

                        if targetDeviceId == nil {
                            Text("Schedule requires a target device. Select one above.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Task" : "New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || command.isEmpty)
                        .bold()
                }
            }
        }
    }

    private func save() {
        var updated = task ?? SavedTask(name: name, command: command)
        updated.name = name
        updated.command = command
        updated.targetDeviceId = targetDeviceId
        updated.targetDeviceName = dashboardVM.devices.first { $0.id == targetDeviceId }?.shortName
        updated.timeout = timeout
        updated.priority = priority
        updated.requiredCapabilities = capabilities
        updated.schedule = SavedTask.Schedule(
            enabled: scheduleEnabled,
            intervalMinutes: scheduleIntervalMinutes,
            type: scheduleType
        )

        if isEditing {
            store.update(updated)
        } else {
            store.add(updated)
        }
        dismiss()
    }
}
