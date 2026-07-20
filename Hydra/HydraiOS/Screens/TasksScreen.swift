import SwiftUI

/// iOS Tasks screen — reuses `SavedTaskStore.shared` directly (same store as
/// macOS's `TasksView`), presented as a flat `List` with swipe actions and a
/// sheet-based editor instead of `NavigationSplitView` sidebar+detail.
struct TasksScreen: View {
    @ObservedObject private var store = SavedTaskStore.shared
    @EnvironmentObject var dashboardVM: DashboardViewModel

    @State private var showCreateSheet = false
    @State private var editingTask: SavedTask?
    @State private var runPickerTask: SavedTask?

    var body: some View {
        NavigationStack {
            List {
                if store.tasks.isEmpty {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Tap + to create a saved task.")
                    )
                } else {
                    ForEach(store.tasks) { task in
                        TaskRow(
                            task: task,
                            isRunning: store.runningTaskIds.contains(task.id),
                            result: store.lastResults[task.id]
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(task)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingTask = task
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                runTask(task)
                            } label: {
                                Label("Run", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                        .contextMenu {
                            Button {
                                runTask(task)
                            } label: {
                                Label("Run Now", systemImage: "play.fill")
                            }
                            Button {
                                editingTask = task
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.delete(task)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                TaskEditorScreen(task: nil)
                    .environmentObject(dashboardVM)
            }
            .sheet(item: $editingTask) { task in
                TaskEditorScreen(task: task)
                    .environmentObject(dashboardVM)
            }
            .confirmationDialog(
                "Select Target Device",
                isPresented: runPickerBinding,
                titleVisibility: .visible
            ) {
                ForEach(dashboardVM.devices, id: \.id) { device in
                    Button(device.displayName) {
                        if let task = runPickerTask {
                            Task { await store.execute(task, deviceId: device.id) }
                        }
                        runPickerTask = nil
                    }
                }
                Button("Cancel", role: .cancel) { runPickerTask = nil }
            }
        }
    }

    private var runPickerBinding: Binding<Bool> {
        Binding(get: { runPickerTask != nil }, set: { if !$0 { runPickerTask = nil } })
    }

    private func runTask(_ task: SavedTask) {
        if task.targetDeviceId != nil {
            Task { await store.execute(task) }
        } else {
            runPickerTask = task
        }
    }
}

private struct TaskRow: View {
    let task: SavedTask
    let isRunning: Bool
    let result: TaskResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: task.priority.icon)
                    .foregroundStyle(.secondary)
                Text(task.name)
                    .font(.headline)
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else if let result {
                    Image(systemName: result.hasError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(result.hasError ? .red : .green)
                }
            }
            Text(task.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Text(task.targetDeviceName ?? task.targetDeviceId ?? "Select at run")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let schedule = task.schedule, schedule.enabled {
                    Text(schedule.displayText)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
