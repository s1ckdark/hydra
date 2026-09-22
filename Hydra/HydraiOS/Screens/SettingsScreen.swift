import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var dashboardVM: DashboardViewModel
    @AppStorage("serverURL") private var serverURL: String = APIClient.defaultServerURL
    @AppStorage("sshUsername") private var sshUsername: String = "root"
    @AppStorage("aiInstruction") private var aiInstruction: String = ""
    @State private var serverAPIKey: String = ""

    var body: some View {
        Form {
            Section("서버") {
                TextField("http://<host>:8080", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("API 키", text: $serverAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            AppearanceSettingsSection()
            DeviceRefreshSettingsSection(model: dashboardVM)
            Section("터미널") {
                NavigationLink("터미널 테마") { TerminalColorSchemeScreen() }
                    .accessibilityIdentifier("settings-terminal-scheme")
            }
            Section("SSH") {
                TextField("username", text: $sshUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                NavigationLink("SSH 키 관리") { KeyImportScreen() }
            }
            Section("AI") {
                TextField("AI에게 전달할 지침", text: $aiInstruction, axis: .vertical)
                    .lineLimit(3...8)
            }
            #if DEBUG
            Section("개발자 진단") {
                NavigationLink("키보드 입력 비교") {
                    CleanKeyboardComparisonScreen()
                        .navigationTitle("키보드 입력 비교")
                }
            }
            #endif
        }
        .navigationTitle("설정")
        .onAppear {
            serverAPIKey = CredentialStore.shared.get(.serverAPIKey)
        }
        .onChange(of: serverURL) { _, _ in
            dashboardVM.invalidateDeviceInventory()
            Task { await APIClient.shared.reloadBaseURL() }
        }
        .onChange(of: serverAPIKey) { _, newValue in
            guard CredentialStore.shared.get(.serverAPIKey) != newValue else { return }
            CredentialStore.shared.set(.serverAPIKey, value: newValue)
            dashboardVM.invalidateDeviceInventory()
        }
    }
}
