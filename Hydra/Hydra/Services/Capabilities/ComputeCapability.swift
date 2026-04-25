import Foundation

/// Declares that this device can run general compute tasks.
/// Always available — every host has a CPU. Mirrors the server-side
/// `domain.CapCompute = "compute"` constant.
final class ComputeCapability: DeviceCapability {
    let identifier = "compute"
    let displayName = "Compute"
    let capabilityDescription = "General CPU-bound task execution"
    var isEnabled = false
    var isAvailable: Bool { true }

    func requestPermissions() async -> Bool { true }

    func execute(payload: [String: Any]) async throws -> [String: Any] {
        // The macOS GUI advertises this capability so the server scheduler can
        // route compute tasks here, but task execution itself is handled by a
        // separate worker daemon (out of scope for this capability class).
        throw CapabilityError.executionFailed("compute task execution not yet implemented in macOS GUI")
    }
}
