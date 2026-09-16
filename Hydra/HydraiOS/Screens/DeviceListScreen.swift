import SwiftUI

struct DeviceListScreen: View {
    let onSelect: (Device) -> Void
    var loadOnAppear = true
    @EnvironmentObject private var dashboardVM: DashboardViewModel

    var body: some View {
        List {
            if let error = dashboardVM.deviceRefreshError ?? dashboardVM.error {
                Section { AppLocalizedText(error).foregroundStyle(.red) }
            }
            ForEach(dashboardVM.devices) { device in
                let machineName = device.hostname.isEmpty
                    ? (device.name.split(separator: ".").first.map(String.init) ?? device.tailscaleIp)
                    : device.hostname
                let address = device.name.isEmpty || device.name == machineName ? device.tailscaleIp : device.name
                let title = address.isEmpty || address == machineName ? machineName : "\(machineName) (\(address))"
                Button { onSelect(device) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: title).font(.headline)
                            if !device.tailscaleIp.isEmpty && device.tailscaleIp != address {
                                Text(verbatim: device.tailscaleIp).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if device.sshEnabled { Image(systemName: "terminal") }
                    }
                }
                .disabled(!device.sshEnabled)
            }
        }
        .overlay { if dashboardVM.isLoading || dashboardVM.isRefreshingDevices { ProgressView() } }
        .navigationTitle("디바이스")
        .refreshable { await dashboardVM.refreshDeviceInventory() }
        .task { if loadOnAppear { await dashboardVM.load() } }
    }
}
