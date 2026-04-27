import Foundation

/// Declares that this device has network connectivity. Always available —
/// the app already requires the network to talk to the Hydra server.
/// Mirrors `domain.CapNetwork = "network"`.
final class NetworkCapability: DeviceCapability {
    let identifier = "network"
    let displayName = "Network"
    let capabilityDescription = "Network connectivity for fetch/upload tasks"
    var isEnabled = false
    var isAvailable: Bool { true }

    func requestPermissions() async -> Bool { true }

    func execute(payload: [String: Any]) async throws -> [String: Any] {
        throw CapabilityError.executionFailed("network task execution not yet implemented in macOS GUI")
    }
}
