#if DEBUG
import SwiftUI
import SSHTransport

@MainActor
struct TerminalKeyRecoveryUITestFixture: View {
    @StateObject private var inventory = DashboardViewModel()
    @StateObject private var counts = RecoveryAttemptCounter()
    @State private var selected: Presentation?
    private struct Presentation: Identifiable {
        let device: Device
        let session: TerminalSession
        var id: String { device.id }
    }
    private let key = SSHKeyGenerator.generate(comment: "recovery-ui-fixture")
    private var noKey: Bool { ProcessInfo.processInfo.arguments.contains("--terminal-recovery-no-key") }
    private let device = Device(id: "recovery-fixture", name: "fixture.tail.test", hostname: "fixture-machine",
        ipAddresses: [], tailscaleIp: "100.64.0.77", os: "macOS", status: "online", isExternal: false,
        tags: nil, user: "not-the-ssh-account", lastSeen: Date(), sshEnabled: true, hasGpu: false, gpuModel: nil, gpuCount: 0)

    var body: some View {
        NavigationStack {
            DeviceListScreen(onSelect: { device in
                let session = TerminalSession(device: device,
                    sessionFactory: { RecoveryFailureBackend(counts: counts) }, credentialResolver: {
                        SSHCredentials(user: "attempt-user", port: 2222, keys: noKey ? [] : [
                            .init(path: "fixture-only", pem: Data(key.privateKeyOpenSSH.utf8), algorithm: "ed25519")])
                    })
                selected = Presentation(device: device, session: session)
            }, loadOnAppear: false)
        }
        .environmentObject(inventory)
        .task { inventory.devices = [device] }
        .fullScreenCover(item: $selected) { presentation in
                NavigationStack {
                    TerminalScreen(device: presentation.device, session: presentation.session, registrationModelFactory: { target in
                        SSHKeyRegistrationViewModel(initialUsername: "wrong-settings-user", initialTarget: target,
                            keyProvider: { noKey ? nil : Data(key.privateKeyOpenSSH.utf8) },
                            service: RecoveryNoRegistrationService(counts: counts), devicesProvider: { [] })
                    })
                }
                .safeAreaInset(edge: .top) { RecoveryAttemptLabel(counts: counts) }
        }
    }
}

@MainActor private final class RecoveryAttemptCounter: ObservableObject {
    @Published var attempts = 0
    @Published var registrations = 0
}

private struct RecoveryAttemptLabel: View {
    @ObservedObject var counts: RecoveryAttemptCounter
    var body: some View {
        Text(verbatim: "attempts=\(counts.attempts);registrations=\(counts.registrations)")
            .font(.caption).accessibilityIdentifier("recovery-attempt-count")
    }
}

private final class RecoveryFailureBackend: SSHSession {
    let output = AsyncStream<Data> { $0.finish() }
    let state = AsyncStream<SSHState> { $0.finish() }
    let remoteHostKey: HostKeyFingerprint? = nil
    let counts: RecoveryAttemptCounter
    init(counts: RecoveryAttemptCounter) { self.counts = counts }
    func connect(host: String, port: Int, user: String, auth: SSHAuth) async throws {
        await MainActor.run { counts.attempts += 1 }
        throw SSHFailure.authenticationRejected
    }
    func openShell(termType: String, cols: Int, rows: Int) async throws {}
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func disconnect() {}
}

@MainActor private final class RecoveryNoRegistrationService: SSHKeyRegistering {
    let counts: RecoveryAttemptCounter
    init(counts: RecoveryAttemptCounter) { self.counts = counts }
    func register(target: SSHKeyRegistrationTarget, privateKey: Data, password: String,
                  approveHost: @escaping @MainActor (HostKeyFingerprint) async -> Bool,
                  onProgress: @escaping @MainActor (SSHKeyRegistrationProgress) -> Void) async throws -> SSHKeyRegistrationResult {
        counts.registrations += 1
        throw SSHKeyRegistrationError.registrationFailed
    }
    func cancel() {}
}
#endif
