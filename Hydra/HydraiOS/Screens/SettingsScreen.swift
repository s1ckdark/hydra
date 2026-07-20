import SwiftUI

struct SettingsScreen: View {
    @AppStorage("serverURL") private var serverURL: String = "http://localhost:8080"
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
        }
        .navigationTitle("설정")
        .onAppear {
            serverAPIKey = CredentialStore.shared.get(.serverAPIKey)
        }
        .onChange(of: serverURL) { _, newValue in
            Task { await APIClient.shared.setBaseURL(newValue) }
        }
        .onChange(of: serverAPIKey) { _, newValue in
            CredentialStore.shared.set(.serverAPIKey, value: newValue)
        }
    }
}
