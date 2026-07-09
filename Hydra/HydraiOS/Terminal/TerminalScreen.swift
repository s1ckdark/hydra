import SwiftUI
import SSHTransport

/// Connects to a device's SSH session and hosts the SwiftTerm terminal view.
/// Mirrors the macOS terminal tab's connect/TOFU flow for a single full-screen
/// iOS terminal.
struct TerminalScreen: View {
    let device: Device
    @StateObject private var session: TerminalSession
    @State private var trustSHA: String?

    init(device: Device) {
        self.device = device
        _session = StateObject(wrappedValue: TerminalSession(device: device,
            sessionFactory: { TerminalSessionStore.defaultBackend() }))
    }

    var body: some View {
        SwiftTermRepresentableiOS(session: session)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(device.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task { await session.connect(cols: 80, rows: 24) }
            .onDisappear { session.close() }
            .onChange(of: hostKeyPromptSHA) { _, sha in trustSHA = sha }
            .alert("호스트 키 신뢰?", isPresented: Binding(
                get: { trustSHA != nil }, set: { if !$0 { trustSHA = nil } })) {
                Button("신뢰") { Task { await session.trustPendingHostKey() }; trustSHA = nil }
                Button("취소", role: .cancel) { session.cancelPendingHostKey(); trustSHA = nil }
            } message: {
                Text("SHA256:\n\(trustSHA ?? "")")
            }
            .overlay(alignment: .bottom) { statusBar }
    }

    private var hostKeyPromptSHA: String? {
        if case .needsTrust(let sha) = session.hostKeyPrompt { return sha }
        return nil
    }

    @ViewBuilder private var statusBar: some View {
        if case .disconnected(let reason) = session.state, let reason {
            Text(reason).font(.caption).padding(6)
                .background(.ultraThinMaterial).foregroundStyle(.red)
        }
    }
}
