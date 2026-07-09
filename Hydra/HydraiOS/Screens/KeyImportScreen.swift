import SwiftUI
import UniformTypeIdentifiers

struct KeyImportScreen: View {
    @State private var pem: String = CredentialStore.shared.get(.sshPrivateKeyPEM)
    @State private var showingImporter = false
    @State private var message: String?

    private var hasKey: Bool { !CredentialStore.shared.get(.sshPrivateKeyPEM).isEmpty }

    var body: some View {
        Form {
            Section("SSH 개인키 (PEM)") {
                TextEditor(text: $pem)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 160)
                Button("Files에서 가져오기") { showingImporter = true }
            }
            Section {
                Button("저장") { save() }
                if hasKey {
                    Button("삭제", role: .destructive) {
                        CredentialStore.shared.set(.sshPrivateKeyPEM, value: "")
                        pem = ""; message = "삭제됨"
                    }
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            Section {
                Text(hasKey ? "키 저장됨 ✓" : "저장된 키 없음")
                    .foregroundStyle(hasKey ? .green : .secondary)
            }
        }
        .navigationTitle("SSH 키")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data, .text, UTType.item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                    pem = text
                } else { message = "파일을 읽을 수 없습니다" }
            case .failure(let e): message = "가져오기 실패: \(e.localizedDescription)"
            }
        }
    }

    private func save() {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("PRIVATE KEY-----") else {
            message = "PEM 개인키 형식이 아닙니다 (-----BEGIN ... PRIVATE KEY----- 필요)"
            return
        }
        CredentialStore.shared.set(.sshPrivateKeyPEM, value: trimmed)
        message = "저장됨 ✓"
    }
}
