import SwiftUI

/// iOS Orch creation sheet — reuses `APIClient.shared` directly (same calls as
/// macOS's `CreateOrchView`), presented as a `Form` with toolbar Cancel/Create
/// instead of a custom header, and with no fixed `.frame` so it sizes to the
/// sheet's available height.
struct CreateOrchScreen: View {
    @ObservedObject var vm: OrchViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var devices: [Device] = []
    @State private var selectedWorkers: Set<String> = []
    @State private var coordinatorID = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Orchestration name", text: $name)
                }

                Section("Coordinator (Head)") {
                    Picker("Select coordinator", selection: $coordinatorID) {
                        Text("Select...").tag("")
                        ForEach(devices.filter { $0.isOnline }, id: \.id) { d in
                            Text("\(d.shortName) (\(d.tailscaleIp))").tag(d.id)
                        }
                    }
                }

                Section("Workers") {
                    ForEach(devices.filter { $0.isOnline && $0.id != coordinatorID }, id: \.id) { d in
                        Toggle(isOn: Binding(
                            get: { selectedWorkers.contains(d.id) },
                            set: { if $0 { selectedWorkers.insert(d.id) } else { selectedWorkers.remove(d.id) } }
                        )) {
                            HStack {
                                Text(d.shortName)
                                if d.hasGpu {
                                    Text("\(d.gpuCount)x \(d.gpuModel ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.purple)
                                }
                            }
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("New Orchestration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(name.isEmpty || coordinatorID.isEmpty || isCreating)
                    .bold()
                }
            }
            .overlay {
                if isCreating {
                    ProgressView()
                }
            }
            .task {
                do {
                    devices = try await APIClient.shared.listDevices()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func create() async {
        isCreating = true
        error = nil
        do {
            let orch = try await APIClient.shared.createOrch(
                name: name,
                headID: coordinatorID,
                workerIDs: Array(selectedWorkers)
            )
            vm.orchs.append(orch)
            vm.showCreateSheet = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }
}
