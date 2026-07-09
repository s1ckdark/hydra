import SwiftUI

struct DeviceListScreen: View {
    let onSelect: (Device) -> Void
    @State private var devices: [Device] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            ForEach(devices) { device in
                Button { onSelect(device) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.displayName).font(.headline)
                            Text(device.tailscaleIp).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.sshEnabled { Image(systemName: "terminal") }
                    }
                }
                .disabled(!device.sshEnabled)
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle("디바이스")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { devices = try await APIClient.shared.listDevices(); error = nil }
        catch { self.error = "목록 조회 실패: \(error.localizedDescription)" }
    }
}
