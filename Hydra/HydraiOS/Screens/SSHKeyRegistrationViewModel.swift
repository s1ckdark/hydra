import SwiftUI
import SSHTransport

@MainActor
final class SSHKeyRegistrationViewModel: ObservableObject {
    struct Confirmation: Identifiable {
        let id = UUID()
        let target: SSHKeyRegistrationTarget
        let publicKeyLine: String
        let fingerprint: String
    }

    @Published var host = "" {
        didSet { if oldValue != host { registrationResult = nil } }
    }
    @Published var username: String {
        didSet { if oldValue != username { registrationResult = nil } }
    }
    @Published var password = ""
    @Published private(set) var port: Int
    @Published private(set) var devices: [Device] = []
    @Published private(set) var isLoading = false
    @Published private(set) var devicesError: String?
    @Published private(set) var publicKeyLine = ""
    @Published private(set) var fingerprint = ""
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var pendingHostKey: HostKeyFingerprint?
    @Published private(set) var activeTarget: SSHKeyRegistrationTarget?
    @Published private(set) var isRegistering = false
    @Published private(set) var progress: SSHKeyRegistrationProgress?
    @Published private(set) var registrationResult: SSHKeyRegistrationResult?
    @Published private(set) var errorMessage: String?

    private let keyProvider: () -> Data?
    private let service: any SSHKeyRegistering
    private let devicesProvider: () async throws -> [Device]
    private var confirmedPrivateKey: Data?
    private var hostContinuation: CheckedContinuation<Bool, Never>?
    private var registrationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var loadID = UUID()

    init(initialUsername: String, initialTarget: SSHKeyRegistrationTarget? = nil,
         keyProvider: @escaping () -> Data?,
         service: any SSHKeyRegistering,
         devicesProvider: @escaping () async throws -> [Device]) {
        username = initialTarget?.user ?? initialUsername
        port = initialTarget?.port ?? 22
        self.keyProvider = keyProvider
        self.service = service
        self.devicesProvider = devicesProvider
        host = initialTarget?.host ?? ""
    }

    static func live(target: SSHKeyRegistrationTarget? = nil) -> SSHKeyRegistrationViewModel {
        SSHKeyRegistrationViewModel(
            initialUsername: UserDefaults.standard.string(forKey: "sshUsername") ?? "root",
            initialTarget: target,
            keyProvider: {
                let key = CredentialStore.shared.get(.sshPrivateKeyPEM)
                return key.isEmpty ? nil : Data(key.utf8)
            },
            service: SSHKeyRegistrationService(),
            devicesProvider: { try await APIClient.shared.listDevices() }
        )
    }

    private var target: SSHKeyRegistrationTarget {
        .init(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
              user: username.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    }

    var canRequestRegistration: Bool {
        !isRegistering && confirmation == nil && !publicKeyLine.isEmpty &&
            !password.isEmpty && (try? target.validate()) != nil
    }

    var canCopyManualCommand: Bool {
        !isRegistering && confirmation == nil && !publicKeyLine.isEmpty &&
            (try? target.validate()) != nil
    }

    func load() async {
        guard !isRegistering else { return }
        let currentLoad = UUID()
        loadID = currentLoad
        isLoading = true
        errorMessage = nil
        do {
            guard let key = keyProvider() else { throw SSHKeyRegistrationError.invalidPublicKey }
            let summary = try SSHKeyRegistrationCommand.publicKeySummary(fromPrivateKey: key)
            publicKeyLine = summary.publicKeyLine
            fingerprint = summary.fingerprint
        } catch {
            publicKeyLine = ""
            fingerprint = ""
            errorMessage = "저장된 SSH 키를 사용할 수 없습니다. SSH 키 관리에서 키를 생성하거나 올바른 개인키를 저장해 주세요."
        }
        do {
            let available = try await devicesProvider()
            guard loadID == currentLoad else { return }
            devices = available.filter { $0.sshEnabled && !$0.tailscaleIp.isEmpty }
            devicesError = nil
        } catch {
            guard loadID == currentLoad else { return }
            devices = []
            devicesError = "디바이스 목록을 불러오지 못했습니다. 서버 주소를 직접 입력할 수 있습니다."
        }
        isLoading = false
    }

    func selectDevice(_ device: Device) {
        guard !isRegistering, confirmation == nil, device.sshEnabled else { return }
        host = device.tailscaleIp
    }

    func requestRegistration() {
        guard canRequestRegistration else { return }
        errorMessage = nil
        registrationResult = nil
        do {
            guard let key = keyProvider() else { throw SSHKeyRegistrationError.invalidPublicKey }
            let summary = try SSHKeyRegistrationCommand.publicKeySummary(fromPrivateKey: key)
            try target.validate()
            publicKeyLine = summary.publicKeyLine
            fingerprint = summary.fingerprint
            confirmedPrivateKey = key
            confirmation = Confirmation(target: target, publicKeyLine: summary.publicKeyLine,
                                        fingerprint: summary.fingerprint)
        } catch {
            password = ""
            errorMessage = Self.message(for: error)
        }
    }

    func confirmRegistration() {
        let submittedPassword = password
        password = ""
        guard !isRegistering, let confirmation, let key = confirmedPrivateKey else { return }
        self.confirmation = nil
        confirmedPrivateKey = nil
        guard !submittedPassword.isEmpty else {
            errorMessage = "서버 로그인 비밀번호를 입력해 주세요."
            return
        }
        guard keyProvider() == key else {
            errorMessage = "저장된 SSH 키가 변경되었습니다. 키를 다시 확인한 뒤 등록해 주세요."
            return
        }
        let id = UUID()
        operationID = id
        isRegistering = true
        activeTarget = confirmation.target
        progress = .checkingHost
        errorMessage = nil
        registrationResult = nil
        registrationTask = Task { [weak self, service] in
            guard self?.operationID == id, self?.isRegistering == true, !Task.isCancelled else { return }
            do {
                let result = try await service.register(
                    target: confirmation.target, privateKey: key, password: submittedPassword,
                    approveHost: { [weak self] fingerprint in
                        guard let self, self.operationID == id, self.isRegistering else { return false }
                        return await self.requestHostApproval(fingerprint, operation: id)
                    },
                    onProgress: { [weak self] progress in
                        guard let self, self.operationID == id, self.isRegistering else { return }
                        self.progress = progress
                    }
                )
                guard let self, self.operationID == id, self.isRegistering else { return }
                self.registrationResult = result
                self.finishRegistration()
            } catch {
                guard let self, self.operationID == id, self.isRegistering else { return }
                self.errorMessage = Self.message(for: error)
                self.finishRegistration()
            }
        }
    }

    private func requestHostApproval(_ fingerprint: HostKeyFingerprint, operation: UUID) async -> Bool {
        guard operationID == operation, isRegistering, !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            hostContinuation?.resume(returning: false)
            hostContinuation = continuation
            pendingHostKey = fingerprint
        }
    }

    func respondToHostKey(approve: Bool) {
        let continuation = hostContinuation
        hostContinuation = nil
        pendingHostKey = nil
        continuation?.resume(returning: approve && isRegistering)
    }

    func cancel() {
        let wasRegistering = isRegistering
        let mayHaveRegistered = progress == .registering || progress == .verifying
        operationID = UUID()
        password = ""
        confirmation = nil
        confirmedPrivateKey = nil
        respondToHostKey(approve: false)
        registrationTask?.cancel()
        registrationTask = nil
        isRegistering = false
        activeTarget = nil
        progress = nil
        if wasRegistering {
            service.cancel()
            errorMessage = Self.message(for: SSHKeyRegistrationError.cancelled(mayHaveRegistered: mayHaveRegistered))
        }
    }

    /// Called on navigation away or app backgrounding, including an open confirmation.
    func close() {
        loadID = UUID()
        isLoading = false
        cancel()
    }

    func manualRegistrationCommand() throws -> String {
        try target.validate()
        guard let key = keyProvider() else { throw SSHKeyRegistrationError.invalidPublicKey }
        let summary = try SSHKeyRegistrationCommand.publicKeySummary(fromPrivateKey: key)
        return try SSHKeyRegistrationCommand.make(publicKeyLine: summary.publicKeyLine,
            expectedUser: target.user, marker: "HYDRA_KEY_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    }

    private func finishRegistration() {
        respondToHostKey(approve: false)
        password = ""
        isRegistering = false
        activeTarget = nil
        progress = nil
        registrationTask = nil
    }

    private static func message(for error: Error) -> String {
        // Server-supplied error descriptions can contain secrets or control characters.
        // Only local, typed messages are rendered in the registration screen.
        guard let error = error as? SSHKeyRegistrationError else {
            return "공개키 등록을 완료하지 못했지만 원인을 특정할 수 없습니다. 다시 시도하고, 반복되면 서버의 SSH 로그를 확인하세요."
        }
        return error.localizedDescription
    }
}
