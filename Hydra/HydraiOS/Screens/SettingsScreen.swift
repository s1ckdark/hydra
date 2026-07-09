import SwiftUI

struct SettingsScreen: View {
    @AppStorage("serverURL") private var serverURL: String = "http://localhost:8080"
    @AppStorage("sshUsername") private var sshUsername: String = "root"

    var body: some View {
        Form {
            Section("서버") {
                TextField("http://<host>:8080", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            Section("SSH") {
                TextField("username", text: $sshUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                NavigationLink("SSH 키 관리") { KeyImportScreen() }
            }
        }
        .navigationTitle("설정")
        .onChange(of: serverURL) { _, newValue in
            Task { await APIClient.shared.setBaseURL(newValue) }
        }
    }
}
