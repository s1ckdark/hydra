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

    var isOnline: Bool { status == "online" }
    var displayName: String { name.isEmpty ? hostname : name }

    /// Best short label that actually distinguishes this device.
    /// Falls back through: hostname → tailscale name → raw name.
    var shortName: String {
        let host = hostnameShort
        // If hostname is generic (localhost, iPhone, iPad, etc.), prefer the tailscale name
        if isGenericHostname(host) {
            let tsName = tailscaleShortName
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
