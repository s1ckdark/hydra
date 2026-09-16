import SwiftUI
import SSHTransport
import CryptoKit

@MainActor
struct SSHKeyRegistrationScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: SSHKeyRegistrationViewModel
    @State private var copyMessage: String?
    @State private var confirmationSheetIsVisible = false

    init(model: SSHKeyRegistrationViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? .live())
    }

    var body: some View {
        Form {
            targetSection
            if model.publicKeyLine.isEmpty {
                Section {
                    NavigationLink("SSH 키 관리") { KeyImportScreen(showsRegistrationLink: false) }
                        .accessibilityIdentifier("ssh-registration-manage-key")
                }
            }
            if !model.publicKeyLine.isEmpty { publicKeySection }
            Section {
                SecureField("서버 로그인 비밀번호", text: $model.password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(model.isRegistering || model.confirmation != nil)
                    .accessibilityIdentifier("ssh-registration-password")
                Button {
                    copyMessage = nil
                    model.requestRegistration()
                    confirmationSheetIsVisible = model.confirmation != nil
                } label: {
                    Label("공개키 등록", systemImage: "key.horizontal.fill")
                }
                .disabled(!model.canRequestRegistration)
                .accessibilityIdentifier("ssh-registration-submit")
            } footer: {
                Text("최초 등록에 서버 로그인 비밀번호를 사용합니다. 비밀번호는 저장하지 않습니다.")
            }

            if model.isRegistering {
                Section {
                    ProgressView { AppLocalizedText(progressText) }
                    Button("등록 취소", role: .cancel) { model.cancel() }
                        .accessibilityIdentifier("ssh-registration-cancel")
                }
            }
            if let result = model.registrationResult {
                Section {
                    Label {
                        AppLocalizedText(result.alreadyRegistered
                          ? "이미 등록된 공개키입니다. 키 로그인도 확인했습니다."
                          : "공개키를 등록하고 키 로그인까지 확인했습니다.")
                    } icon: { Image(systemName: "checkmark.circle.fill") }
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("ssh-registration-result")
                }
            }
            if let error = model.errorMessage {
                Section { AppLocalizedText(error).foregroundStyle(.red).accessibilityIdentifier("ssh-registration-error") }
            }
            manualSection
        }
        .navigationTitle("서버에 공개키 등록")
        .task { await model.load() }
        .onDisappear { model.close() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.close() }
        }
        .sheet(item: Binding(get: { model.confirmation }, set: { value in
            if value == nil, model.confirmation != nil { model.cancel() }
        }), onDismiss: { confirmationSheetIsVisible = false }) { confirmation in
            confirmationSheet(confirmation)
                .onAppear { confirmationSheetIsVisible = true }
        }
        .alert("서버 신원 확인",
               isPresented: Binding(get: { model.pendingHostKey != nil && !confirmationSheetIsVisible }, set: { _ in })) {
            Button("확인 후 신뢰") { model.respondToHostKey(approve: true) }
                .accessibilityIdentifier("ssh-registration-trust-host")
            Button("취소", role: .cancel) { model.respondToHostKey(approve: false) }
                .accessibilityIdentifier("ssh-registration-reject-host")
        } message: {
            if let key = model.pendingHostKey {
                Text("\(model.activeTarget?.host ?? "서버")\n처음 연결하는 서버입니다. 서버 관리자에게 아래 호스트 키 지문이 맞는지 확인해 주세요.\n\n\(key.keyType)\n\(hostFingerprint(key))")
            }
        }
    }

    private func confirmationSheet(_ confirmation: SSHKeyRegistrationViewModel.Confirmation) -> some View {
        NavigationStack {
            Form {
                Section("등록할 서버 계정") {
                    LabeledContent("서버", value: confirmation.target.host)
                    LabeledContent("계정", value: confirmation.target.user)
                    LabeledContent("포트", value: String(confirmation.target.port))
                }
                Section("공개키 지문") {
                    Text(confirmation.fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section {
                    Text("이 계정에 공개키를 추가하며 기존 키는 유지합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("등록 확인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", role: .cancel) { model.cancel() }
                        .accessibilityIdentifier("ssh-registration-cancel-confirmation")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("등록 확인") { model.confirmRegistration() }
                        .accessibilityIdentifier("ssh-registration-confirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func hostFingerprint(_ key: HostKeyFingerprint) -> String {
        guard let bytes = Data(base64Encoded: key.publicKeyBase64) else { return "SHA256 (hex): " + key.sha256Hex }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    private var targetSection: some View {
        Section {
            if !model.devices.isEmpty {
                Menu {
                    ForEach(model.devices) { device in
                        Button("\(device.displayName) · \(device.tailscaleIp)") { model.selectDevice(device) }
                    }
                } label: {
                    Label("디바이스에서 선택", systemImage: "server.rack")
                }
                .disabled(model.isRegistering || model.confirmation != nil)
            }
            TextField("서버 주소 또는 IP", text: $model.host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(model.isRegistering || model.confirmation != nil)
                .accessibilityIdentifier("ssh-registration-host")
            TextField("SSH 계정", text: $model.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.isRegistering || model.confirmation != nil)
                .accessibilityIdentifier("ssh-registration-username")
            LabeledContent("포트", value: String(model.port))
                .accessibilityIdentifier("ssh-registration-port")
                .accessibilityValue(String(model.port))
            if model.isLoading { ProgressView("디바이스 목록 불러오는 중") }
            if let error = model.devicesError { AppLocalizedText(error).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("등록할 서버")
        } footer: {
            Text("등록 후 같은 SSH 계정으로 터미널에 연결하세요. 터미널의 접속 계정은 설정에서 변경할 수 있습니다.")
        }
    }

    private var publicKeySection: some View {
        Section("등록할 공개키") {
            Text(model.fingerprint)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            DisclosureGroup("공개키 보기") {
                Text(model.publicKeyLine)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var manualSection: some View {
        Section {
            Button {
                do {
                    UIPasteboard.general.string = try model.manualRegistrationCommand()
                    copyMessage = "등록 명령을 복사했습니다. 해당 서버의 SSH 계정으로 로그인한 터미널에서 실행하세요."
                } catch {
                    copyMessage = "등록 명령을 만들 수 없습니다. 서버 계정과 저장된 SSH 키를 확인해 주세요."
                }
            } label: {
                Label("서버 등록 명령 복사", systemImage: "doc.on.doc")
            }
            .disabled(!model.canCopyManualCommand)
            .accessibilityIdentifier("ssh-registration-copy-command")
            if let copyMessage { AppLocalizedText(copyMessage).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("직접 등록")
        } footer: {
            Text("서버가 비밀번호 로그인을 허용하지 않는다면, 이미 접속할 수 있는 터미널에서 복사한 명령을 실행하세요.")
        }
    }

    private var progressText: String {
        switch model.progress {
        case .checkingHost: return "서버 신원 확인 중"
        case .awaitingHostApproval: return "서버 신원 확인 대기 중"
        case .connecting: return "서버 로그인 중"
        case .registering: return "공개키 등록 중"
        case .verifying: return "공개키 로그인 확인 중"
        case nil: return "준비 중"
        }
    }
}
