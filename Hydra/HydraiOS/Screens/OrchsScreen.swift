import SwiftUI

/// iOS Orchs list — reuses the shared `OrchViewModel` (same data/logic as the
/// macOS `OrchListView`), laid out with push navigation instead of
/// `NavigationSplitView` so it collapses correctly on iPhone.
struct OrchsScreen: View {
    @StateObject private var vm = OrchViewModel()

    var body: some View {
        NavigationStack {
            List {
                if let error = vm.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                ForEach(vm.orchs) { orch in
                    NavigationLink(destination: OrchDetailScreen(orch: orch, vm: vm)) {
                        OrchRow(orch: orch)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await vm.deleteOrch(id: orch.id) }
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            Task { await vm.deleteOrch(id: orch.id) }
                        }
                    }
                }
            }
            .overlay {
                if vm.isLoading && vm.orchs.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Orchs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $vm.showCreateSheet) {
                CreateOrchScreen(vm: vm)
            }
            .task { await vm.loadOrchs() }
            .refreshable { await vm.loadOrchs() }
        }
    }
}

private struct OrchRow: View {
    let orch: Orch

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(orch.name)
                    .fontWeight(.medium)
                Text("\(orch.workerCount) workers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(orch.status)
                .font(.caption.bold())
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    private var statusColor: Color {
        switch orch.status {
        case "running": return .green
        case "starting": return .yellow
        case "error": return .red
        default: return .gray
        }
    }
}
