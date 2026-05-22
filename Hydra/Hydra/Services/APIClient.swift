import Foundation

actor APIClient {
    static let shared = APIClient()

    private var baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let stored = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:8080"
        self.baseURL = URL(string: stored)!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            // Try ISO8601 with fractional seconds
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(str)")
        }
        self.decoder = decoder
    }

    /// Reloads base URL from UserDefaults (call after settings change).
    func reloadBaseURL() {
        let stored = UserDefaults.standard.string(forKey: "serverURL") ?? "http://localhost:8080"
        self.baseURL = URL(string: stored)!
    }

    // MARK: - Devices

    /// Lists devices. Mobile devices (iPhone/iPad) are visible by default
    /// since they're used as orchestration controllers. Pass
    /// `includeMobile: false` to suppress them in worker-only views.
    func listDevices(refresh: Bool = false, includeMobile: Bool = true) async throws -> [Device] {
        var items: [String] = []
        if refresh { items.append("refresh=true") }
        if !includeMobile { items.append("include_mobile=false") }
        let path = items.isEmpty ? "/api/devices" : "/api/devices?" + items.joined(separator: "&")
        return try await get(path)
    }

    func getDevice(id: String) async throws -> Device {
        return try await get("/api/devices/\(id)")
    }

    func getDeviceMetrics(id: String) async throws -> DeviceMetrics {
        return try await get("/api/devices/\(id)/metrics")
    }

    func executeOnDevice(id: String, command: String, timeout: Int = 30) async throws -> TaskResult {
        return try await post("/api/devices/\(id)/execute", body: ExecuteRequest(command: command, timeout_seconds: timeout))
    }

    private struct PingRequest: Encodable {
        let count: Int
        let port: Int
    }

    /// Runs a TCP-connect speed test against the device's Tailscale IP.
    /// Default count=5 mirrors the server-side cap; port 22 is the SSH probe.
    func pingDevice(id: String, count: Int = 5, port: Int = 22) async throws -> PingResult {
        return try await post("/api/devices/\(id)/ping", body: PingRequest(count: count, port: port))
    }

    /// Result for a Taildrop send. Fields mirror the JSON returned by the
    /// server's APIDeviceTaildrop handler.
    struct TaildropResponse: Decodable {
        let status: String
        let target: String
        let filename: String
        let bytes: Int64
    }

    /// Sends a file to the target device via the host's `tailscale file cp`
    /// CLI. The actual transfer happens server-side; we just upload the file
    /// over multipart. Long-running — caller should keep the UI responsive
    /// with a ProgressView until this returns.
    func sendTaildrop(deviceId: String, fileURL: URL) async throws -> TaildropResponse {
        let url = makeURL("/api/devices/\(deviceId)/taildrop")
        let boundary = "hydra-taildrop-" + UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Taildrop can take minutes for large files; bump above the
        // default 30s without going so high a stuck cp hangs the UI forever.
        request.timeoutInterval = 600
        applyAuth(&request)

        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        func append(_ s: String, to data: inout Data) {
            if let d = s.data(using: .utf8) { data.append(d) }
        }
        var body = Data()
        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n", to: &body)
        append("Content-Type: application/octet-stream\r\n\r\n", to: &body)
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n", to: &body)

        let (data, response) = try await session.upload(for: request, from: body)
        try checkResponse(response, data)
        return try decoder.decode(TaildropResponse.self, from: data)
    }

    /// Reports the device's enabled capabilities to the server. Used by
    /// CapabilityReporter on app launch and reconnect so the AI scheduler
    /// can route capability-tagged tasks here.
    func registerCapabilities(deviceID: String, capabilities: [String]) async throws -> CapabilityRegisterResponse {
        let req = CapabilityRegisterRequest(capabilities: capabilities)
        return try await post("/api/devices/\(deviceID)/capabilities", body: req)
    }

    private struct CapabilityRegisterRequest: Encodable {
        let capabilities: [String]
    }

    struct CapabilityRegisterResponse: Decodable {
        let deviceId: String
        let capabilities: [String]
    }

    // MARK: - SSH Recovery

    struct EmptyBody: Codable {}

    struct AcceptKeyRequest: Encodable { let fingerprint: String }

    struct OKResponse: Decodable { let status: String }

    func diagnoseSSH(id: String) async throws -> SSHDiagnosis {
        return try await post("/api/devices/\(id)/ssh/diagnose", body: EmptyBody())
    }

    func acceptSSHHostKey(id: String, fingerprint: String) async throws -> OKResponse {
        return try await post("/api/devices/\(id)/ssh/accept-key", body: AcceptKeyRequest(fingerprint: fingerprint))
    }

    // MARK: - Orchs

    func listOrchs() async throws -> [Orch] {
        return try await get("/api/orchs")
    }

    func getOrch(id: String) async throws -> Orch {
        return try await get("/api/orchs/\(id)")
    }

    func createOrch(name: String, headID: String, workerIDs: [String]) async throws -> Orch {
        let req = CreateOrchRequest(name: name, head_id: headID, worker_ids: workerIDs)
        return try await post("/api/orchs", body: req)
    }

    func getOrchProcesses(id: String) async throws -> OrchProcessesResponse {
        return try await get("/api/orchs/\(id)/processes")
    }

    func getGPUMonitor() async throws -> GPUMonitorResponse {
        return try await get("/api/monitor/gpu")
    }

    func deleteOrch(id: String, force: Bool = false) async throws {
        let path = force ? "/api/orchs/\(id)?force=true" : "/api/orchs/\(id)"
        let _: [String: String] = try await delete(path)
    }

    func getOrchHealth(id: String) async throws -> OrchHealth {
        return try await get("/api/orchs/\(id)/health")
    }

    func executeOnOrch(id: String, command: String, timeout: Int = 30) async throws -> ExecuteResponse {
        return try await post("/api/orchs/\(id)/execute", body: ExecuteRequest(command: command, timeout_seconds: timeout))
    }

    // MARK: - Tasks

    func listTasks() async throws -> [NagaTask] {
        return try await get("/api/tasks")
    }

    // MARK: - Health

    func healthCheck() async throws -> HealthResponse {
        return try await get("/health")
    }

    struct HealthResponse: Decodable {
        let status: String
        let version: String
    }

    // MARK: - Auth

    struct AuthMeResponse: Decodable {
        let authenticated: Bool
        let ip: String?
        let network: String?
        let user: String?
        let device: Device?
    }

    func authMe() async throws -> AuthMeResponse {
        return try await get("/api/auth/me")
    }

    func setBaseURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        self.baseURL = url
        UserDefaults.standard.set(urlString, forKey: "serverURL")
    }

    // MARK: - HTTP

    private func makeURL(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(from: makeURL(path))
        try checkResponse(response, data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data)
        return try decoder.decode(T.self, from: data)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "DELETE"
        applyAuth(&request)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data)
        return try decoder.decode(T.self, from: data)
    }

    private func applyAuth(_ request: inout URLRequest) {
        let key = CredentialStore.shared.get(.serverAPIKey)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func checkResponse(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Unknown error"
            throw APIError.server(status: http.statusCode, message: msg)
        }
    }
}

enum APIError: LocalizedError {
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .server(let status, let message):
            return "[\(status)] \(message)"
        }
    }
}

// MARK: - Device match + self-reported metrics

extension APIClient: DeviceMatchClient {
    private struct MatchRequest: Encodable {
        let hostname: String
        let ip: String?
    }
    private struct MatchResponse: Decodable {
        let deviceId: String
    }

    func matchDevice(hostname: String, ip: String?) async throws -> String {
        let body = MatchRequest(hostname: hostname, ip: ip)
        let response: MatchResponse = try await post("/api/devices/match", body: body)
        return response.deviceId
    }

    func postMetrics(deviceID: String, payload: DeviceMetricsPayload) async throws {
        let _: EmptyBody = try await post("/api/devices/\(deviceID)/metrics", body: payload)
    }
}

/// JSON shape sent to POST /api/devices/{id}/metrics. Field names match the
/// server-side domain.DeviceMetrics exactly so no CodingKeys translation is
/// needed. Disk and GPU are array-of-records on the server (multiple
/// partitions / multiple GPUs); on macOS we send a single-element array
/// describing the root volume and the default Metal device respectively.
struct DeviceMetricsPayload: Encodable {
    struct CPUPayload: Encodable {
        let usagePercent: Double
        let cores: Int
        let loadAvg1: Double
        let loadAvg5: Double
        let loadAvg15: Double
    }
    struct MemoryPayload: Encodable {
        let total: UInt64
        let used: UInt64
        let free: UInt64
        let available: UInt64
        let usagePercent: Double
    }
    struct PartitionPayload: Encodable {
        let mountPoint: String
        let device: String
        let fsType: String
        let total: UInt64
        let used: UInt64
        let free: UInt64
        let usagePercent: Double
    }
    struct DiskPayload: Encodable {
        let partitions: [PartitionPayload]
    }
    struct SingleGPUPayload: Encodable {
        let index: Int
        let name: String
        let memoryTotal: UInt64
        let memoryUsed: UInt64
        let memoryFree: UInt64
        let usagePercent: Double
        let temperature: Double
        let powerDraw: Double
        let powerLimit: Double
    }
    struct GPUPayload: Encodable {
        let gpus: [SingleGPUPayload]
    }
    let cpu: CPUPayload
    let memory: MemoryPayload
    let disk: DiskPayload
    let gpu: GPUPayload?
}
