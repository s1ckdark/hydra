import Foundation
#if os(macOS)
import Metal

/// Declares that this device has a GPU usable for compute. Available iff
/// Metal can return a default system device. Mirrors `domain.CapGPU = "gpu"`.
///
/// Apple Silicon Macs always satisfy this; Intel Macs depend on whether the
/// kernel exposes a Metal-capable GPU at boot.
final class MetalGPUCapability: DeviceCapability {
    let identifier = "gpu"
    let displayName = "GPU (Metal)"
    let capabilityDescription = "Metal-capable GPU available for compute tasks"
    var isEnabled = false
    var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    func requestPermissions() async -> Bool { true }

    func execute(payload: [String: Any]) async throws -> [String: Any] {
        throw CapabilityError.executionFailed("gpu task execution not yet implemented in macOS GUI")
    }
}
#endif
