import Foundation

/// The minimal client surface DeviceIdentity needs. APIClient conforms
/// to this; tests inject a fake.
protocol DeviceMatchClient {
    func matchDevice(hostname: String, ip: String?) async throws -> String
}

/// Resolves the local device's canonical Tailscale ID once per session.
///
/// Hostname is the strong key — Tailscale hostnames are unique within a
/// tailnet. We deliberately don't pass an IP here: discovering the
/// machine's Tailnet IP from Swift would require walking utun
/// interfaces, which adds complexity for diminishing returns. If
/// hostname lookup fails (404), the reporter logs and stops; that's a
/// preferable failure mode to silently mis-identifying a device by IP.
actor DeviceIdentity {
    static let shared = DeviceIdentity()
    private var cached: String?

    /// Returns the resolved device ID, or nil on failure. Failures are
    /// not cached, so the next call retries — a temporary network
    /// hiccup at launch shouldn't keep the reporter dormant for the
    /// whole session.
    func current(via client: DeviceMatchClient) async -> String? {
        if let id = cached { return id }
        let hostname = ProcessInfo.processInfo.hostName
        do {
            let id = try await client.matchDevice(hostname: hostname, ip: nil)
            cached = id
            return id
        } catch {
            NSLog("[DeviceIdentity] hostname=%@ resolve failed: %@", hostname, "\(error)")
            return nil
        }
    }
}
