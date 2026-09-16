import SwiftUI

struct DeviceRefreshSettingsSection: View {
    @ObservedObject var model: DashboardViewModel

    var body: some View {
        Section("Tailscale") {
            Button {
                Task { await model.refreshDeviceInventory() }
            } label: {
                HStack {
                    Label("기기 정보 업데이트", systemImage: "arrow.clockwise")
                    Spacer()
                    if model.isRefreshingDevices { ProgressView() }
                }
            }
            .disabled(model.isRefreshingDevices)
            .accessibilityIdentifier("settings-refresh-devices")
            if model.isRefreshingDevices {
                Text("기기 정보를 업데이트하고 있습니다…").font(.caption)
            }
            if let date = model.lastDeviceRefresh {
                HStack {
                    Text("마지막 업데이트")
                    Spacer()
                    Text(date, style: .time)
                }
                Text("\(model.devices.count)개 기기")
                    .accessibilityIdentifier("settings-device-refresh-count")
            }
            if let error = model.deviceRefreshError {
                AppLocalizedText(error).foregroundStyle(.red)
                    .accessibilityIdentifier("settings-device-refresh-error")
            }
            Text("서버에서 최신 Tailscale 기기 목록을 다시 가져옵니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
