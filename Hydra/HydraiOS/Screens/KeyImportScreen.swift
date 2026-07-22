import SwiftUI
import UniformTypeIdentifiers

struct KeyImportScreen: View {
    @State private var pem: String = CredentialStore.shared.get(.sshPrivateKeyPEM)
    @State private var publicKey: String = CredentialStore.shared.get(.sshPublicKeyOpenSSH)
    @State private var showingImporter = false
    @State private var showingReplaceConfirm = false
    @State private var message: String?

    private var hasKey: Bool { !CredentialStore.shared.get(.sshPrivateKeyPEM).isEmpty }

    var body: some View {
        Form {
            generateSection
            if !publicKey.isEmpty { publicKeySection }
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
                        CredentialStore.shared.set(.sshPublicKeyOpenSSH, value: "")
                        pem = ""; publicKey = ""; message = "삭제됨"
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
        .confirmationDialog("기존 키를 새 키로 교체할까요?",
                            isPresented: $showingReplaceConfirm,
                            titleVisibility: .visible) {
            Button("교체", role: .destructive) { generateKey() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기존 키로 접속하던 서버 연결이 끊깁니다. 새 공개키를 서버에 다시 등록해야 해요.")
        }
    }

    private var generateSection: some View {
        Section("새 키 생성") {
            Button {
                if hasKey { showingReplaceConfirm = true } else { generateKey() }
            } label: {
                Label("새 키 생성 (Ed25519)", systemImage: "key.fill")
            }
            Text("이 기기에서 키를 만들고 개인키는 Keychain에만 보관합니다. 공개키를 서버 ~/.ssh/authorized_keys에 등록하세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var publicKeySection: some View {
        Section("공개키 (authorized_keys에 등록)") {
            Text(publicKey)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = publicKey
                message = "공개키 복사됨 ✓"
            } label: {
                Label("복사", systemImage: "doc.on.doc")
            }
            ShareLink(item: publicKey) {
                Label("공유", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func generateKey() {
        let device = UIDevice.current.name
        let sanitized = device.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.hasSuffix("-") { return }
                acc.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let comment = "hydra-\(sanitized.isEmpty ? "ios" : sanitized)"
        let key = SSHKeyGenerator.generate(comment: comment)
        CredentialStore.shared.set(.sshPrivateKeyPEM, value: key.privateKeyOpenSSH)
        CredentialStore.shared.set(.sshPublicKeyOpenSSH, value: key.publicKeyLine)
        pem = key.privateKeyOpenSSH
        publicKey = key.publicKeyLine
        message = "새 키 생성됨 ✓ — 공개키를 서버에 등록하세요"
    }

    private func save() {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("PRIVATE KEY-----") else {
            message = "PEM 개인키 형식이 아닙니다 (-----BEGIN ... PRIVATE KEY----- 필요)"
            return
        }
        let previous = CredentialStore.shared.get(.sshPrivateKeyPEM)
        CredentialStore.shared.set(.sshPrivateKeyPEM, value: trimmed)
        // 수동 붙여넣기로 키가 바뀌면 저장된 공개키는 더 이상 그 키의 짝이 아님
        if trimmed != previous {
            CredentialStore.shared.set(.sshPublicKeyOpenSSH, value: "")
            publicKey = ""
        }
        message = "저장됨 ✓"
    }
}
