#if os(macOS)
import Foundation
import SSHTransport
import KnownHosts

enum HostKeyDecision: Equatable {
    case proceed
    case needsTrust(sha256: String)
    case blocked
}

/// TOFU gate: Citadel's transport uses acceptAnything, so host-key enforcement
/// happens here at the app layer after connect() and before openShell().
enum HostKeyGate {
    static func entry(host: String, fingerprint: HostKeyFingerprint) -> KnownHostsEntry {
        KnownHostsEntry(hostPattern: host,
                        keyType: fingerprint.keyType,
                        publicKey: fingerprint.publicKeyBase64)
    }

    static func evaluate(host: String, fingerprint: HostKeyFingerprint?, store: KnownHostsStore) -> HostKeyDecision {
        guard let fp = fingerprint else { return .blocked }
        let e = entry(host: host, fingerprint: fp)
        let check = (try? store.check(e)) ?? .unknown
        switch check {
        case .match:    return .proceed
        case .unknown:  return .needsTrust(sha256: fp.sha256Hex)
        case .mismatch: return .blocked
        }
    }
}
#endif
