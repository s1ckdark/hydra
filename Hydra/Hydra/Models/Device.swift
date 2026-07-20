import Foundation

struct Device: Codable, Identifiable {
    let id: String
    let name: String
    let hostname: String
    let ipAddresses: [String]
    let tailscaleIp: String
    let os: String
    let status: String
    let isExternal: Bool
    let tags: [String]?
    let user: String
    let lastSeen: Date
    let sshEnabled: Bool
    let hasGpu: Bool
    let gpuModel: String?
    let gpuCount: Int

    /// Trust the server's reported status. The 5-minute "freshness"
    /// override that used to live here was a defense against frozen
    /// Tailscale snapshots, but the server now (a) applies its own
    /// 24h stale-lastSeen filter to /api/devices and (b) promotes
    /// LastSeen/Status from fresh metrics before responding — so the
    /// client gating on a tighter 5-minute window only created a
    /// red dot / "Offline" badge for devices that don't self-report
    /// metrics (iPhone, iPad, anything without MetricsReporter).
    var isOnline: Bool {
        status == "online"
    }
    var displayName: String { name.isEmpty ? hostname : name }

    /// Best short label that actually distinguishes this device.
    /// Falls back through: hostname → tailscale name → raw name.
    var shortName: String {
        let host = hostnameShort
        let tsName = tailscaleShortName
        // OS hostname이 tailscale MagicDNS 이름의 구분자(하이픈/언더스코어) 제거판일 때
        // (예: HostName "high15" vs DNSName "high-15"), 사용자가 tailscale·known_hosts·
        // 연결에서 쓰는 canonical 이름(하이픈 포함)을 우선 표기한다.
        if !tsName.isEmpty, tsName != host,
           Self.normalizedName(tsName) == Self.normalizedName(host) {
            return tsName
        }
        // If hostname is generic (localhost, iPhone, iPad, etc.), prefer the tailscale name
        if isGenericHostname(host) {
            if !tsName.isEmpty && !isGenericHostname(tsName) {
                return tsName
            }
            // Both are generic — combine to disambiguate (e.g. "iPad mini · dave-ipad")
            if !tsName.isEmpty && tsName != host {
                return "\(host) · \(tsName)"
            }
        }
        return host
    }

    /// 대소문자·하이픈·언더스코어를 무시한 이름 비교용 정규화.
    private static func normalizedName(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private var hostnameShort: String {
        if let dot = hostname.firstIndex(of: ".") {
            return String(hostname[..<dot])
        }
        return hostname.isEmpty ? name : hostname
    }

    /// Extracts a readable short name from the Tailscale FQDN (e.g. "dave-ipad-mini.tail123.ts.net" → "dave-ipad-mini")
    private var tailscaleShortName: String {
        guard !name.isEmpty else { return "" }
        if let dot = name.firstIndex(of: ".") {
            return String(name[..<dot])
        }
        return name
    }

    private func isGenericHostname(_ h: String) -> Bool {
        let lower = h.lowercased()
        let generic = ["localhost", "iphone", "ipad", "ipod", "apple"]
        return generic.contains(where: { lower.hasPrefix($0) })
    }
}
