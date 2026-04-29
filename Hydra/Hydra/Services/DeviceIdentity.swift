import Foundation
import Darwin

/// The minimal client surface DeviceIdentity needs. APIClient conforms
/// to this; tests inject a fake.
protocol DeviceMatchClient {
    func matchDevice(hostname: String, ip: String?) async throws -> String
}

/// Resolves the local device's canonical Tailscale ID once per session.
///
/// We send BOTH hostname and Tailnet IP — empirically, the local hostname
/// (`ProcessInfo.processInfo.hostName`, e.g. "daves-MacBook-Pro.local")
/// rarely matches the Tailscale-stored hostname (e.g. "dave's MacBook
/// Pro"), so hostname alone yields 404 in real deployments. The Tailnet
/// IP — discovered via `getifaddrs` filtered to the 100.64.0.0/10 CGNAT
/// range — is the strong key the server can match against
/// `device.IPAddresses`. Hostname remains as a backup.
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
        let ip = Self.discoverTailnetIP()
        do {
            let id = try await client.matchDevice(hostname: hostname, ip: ip)
            cached = id
            return id
        } catch {
            NSLog("[DeviceIdentity] hostname=%@ ip=%@ resolve failed: %@",
                  hostname, ip ?? "(none)", "\(error)")
            return nil
        }
    }

    /// Walks the system's network interfaces and returns the first IPv4
    /// address in Tailscale's CGNAT range (100.64.0.0/10 — i.e.
    /// 100.64.0.0 through 100.127.255.255). Returns nil when the
    /// Tailscale daemon isn't running or no Tailnet IP is assigned.
    static func discoverTailnetIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            guard let saddr = ptr.pointee.ifa_addr,
                  saddr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(saddr, socklen_t(MemoryLayout<sockaddr_in>.stride),
                                 &buf, socklen_t(buf.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }

            let ip = String(cString: buf)
            // CGNAT: first octet 100, second octet 64..127 inclusive.
            let parts = ip.split(separator: ".")
            if parts.count == 4, parts[0] == "100",
               let second = Int(parts[1]), (64...127).contains(second) {
                return ip
            }
        }
        return nil
    }
}
