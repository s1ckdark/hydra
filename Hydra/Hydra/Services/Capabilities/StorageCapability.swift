import Foundation

/// Declares that this device has local storage available for staging task
/// inputs/outputs. Always available — every host has a filesystem.
/// Mirrors `domain.CapStorage = "storage"`.
final class StorageCapability: DeviceCapability {
    let identifier = "storage"
    let displayName = "Storage"
    let capabilityDescription = "Local filesystem for task data staging"
    var isEnabled = false
    var isAvailable: Bool { true }

    func requestPermissions() async -> Bool { true }

    func execute(payload: [String: Any]) async throws -> [String: Any] {
        throw CapabilityError.executionFailed("storage task execution not yet implemented in macOS GUI")
    }
}
