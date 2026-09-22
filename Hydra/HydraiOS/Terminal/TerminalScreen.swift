import SwiftUI
import SSHTransport

/// Connects to a device's SSH session and hosts the SwiftTerm terminal view.
/// Mirrors the macOS terminal tab's connect/TOFU flow for a single full-screen
/// iOS terminal.
@MainActor
struct TerminalScreen: View {
    let device: Device
    @StateObject private var session: TerminalSession
    @State private var trustSHA: String?
    @State private var connectionRequest = UUID()
    @State private var startedRequest: UUID?
    @State private var registration: RegistrationPresentation?
    @ObservedObject private var settingsStore = TerminalSettingsStore.shared
    private let registrationModelFactory: @MainActor (SSHKeyRegistrationTarget) -> SSHKeyRegistrationViewModel

    private struct RegistrationPresentation: Identifiable {
        let id = UUID()
        let model: SSHKeyRegistrationViewModel
    }

    init(device: Device, session: TerminalSession? = nil,
         registrationModelFactory: @escaping @MainActor (SSHKeyRegistrationTarget) -> SSHKeyRegistrationViewModel = { .live(target: $0) }) {
        self.device = device
        self.registrationModelFactory = registrationModelFactory
        _session = StateObject(wrappedValue: session ?? TerminalSession(device: device,
            sessionFactory: { TerminalSessionStore.defaultBackend() }))
    }

    var body: some View {
        SwiftTermRepresentableiOS(session: session, settings: settingsStore.effective(for: session.deviceId))
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(device.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: connectionRequest) {
                guard startedRequest != connectionRequest, !Task.isCancelled else { return }
                startedRequest = connectionRequest
                await session.connect(cols: 80, rows: 24)
            }
            .onDisappear {
                if registration == nil || session.prepareKeyRegistration() == nil { session.close() }
            }
            .onChange(of: hostKeyPromptSHA) { _, sha in trustSHA = sha }
            .alert("호스트 키 신뢰?", isPresented: Binding(
                get: { trustSHA != nil }, set: { if !$0 { trustSHA = nil } })) {
                Button("신뢰") { Task { await session.trustPendingHostKey() }; trustSHA = nil }
                Button("취소", role: .cancel) { session.cancelPendingHostKey(); trustSHA = nil }
            } message: {
                Text("SHA256:\n\(trustSHA ?? "")")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .sheet(item: $registration) { presentation in
                NavigationStack {
                    SSHKeyRegistrationScreen(model: presentation.model)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("닫기") { registration = nil }
                                    .accessibilityIdentifier("terminal-registration-close")
                            }
                        }
                }
            }
    }

    private var hostKeyPromptSHA: String? {
        if case .needsTrust(let sha) = session.hostKeyPrompt { return sha }
        return nil
    }

    @ViewBuilder private var statusBar: some View {
        if case .disconnected(let reason) = session.state, let reason,
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                AppLocalizedText(reason).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("terminal-connection-error")
                HStack {
                    Button {
                        guard let target = session.prepareKeyRegistration() else { return }
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        registration = RegistrationPresentation(model: registrationModelFactory(target))
                    } label: {
                        Label("SSH 키 등록", systemImage: "key.fill")
                    }
                    .disabled(session.connectionTarget == nil)
                    .accessibilityIdentifier("terminal-register-key")
                    Button("다시 연결") { connectionRequest = UUID() }
                        .accessibilityIdentifier("terminal-retry")
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
    }
}
