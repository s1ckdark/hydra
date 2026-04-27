import Foundation

/// Coordinates auto-detection and server registration of this device's
/// capabilities. The macOS Hydra GUI uses a stable Keychain UUID as its
/// device ID (Tailscale-derived IDs are out of scope for now), and reports
/// every capability whose isAvailable returns true so the AI scheduler
/// can route capability-tagged tasks here.
@MainActor
final class CapabilityReporter: ObservableObject {
    static let shared = CapabilityReporter()

    /// Stable device identifier persisted in Keychain. Generated on first
    /// launch and reused thereafter.
    let deviceID: String

    private init() {
        let stored = CredentialStore.shared.get(.deviceUUID)
        if !stored.isEmpty {
            self.deviceID = stored
        } else {
            let generated = UUID().uuidString
            CredentialStore.shared.set(.deviceUUID, value: generated)
            self.deviceID = generated
        }
    }

    /// Registers every detected capability into the registry and auto-enables
    /// the ones whose hardware is actually present on this machine.
    /// Auto-enable here is intentional: the macOS GUI advertises hardware
    /// it has, not features the user opts into. The user can still toggle
    /// individual entries off via Settings if they want to opt out.
    func register(into registry: CapabilityRegistry) {
        var detected: [any DeviceCapability] = [
            ComputeCapability(),
            NetworkCapability(),
            StorageCapability(),
        ]
        #if os(macOS)
        detected.append(MetalGPUCapability())
        #endif

        for cap in detected {
            registry.register(cap)
            if cap.isAvailable && !registry.enabledCapabilities.contains(cap.identifier) {
                registry.enabledCapabilities.insert(cap.identifier)
                cap.isEnabled = true
            } else if cap.isAvailable {
                cap.isEnabled = true
            }
        }
    }

    /// POSTs the currently enabled+available capability identifiers to
    /// `/api/devices/{deviceID}/capabilities`. Retries up to 3 times with
    /// exponential backoff. Failures are logged via NSLog but never thrown
    /// — capability reporting is best-effort and must not break app launch.
    func report(via apiClient: APIClient) async {
        let caps = CapabilityRegistry.shared.enabledIdentifiers()
        let id = self.deviceID

        var delay: UInt64 = 500_000_000 // 500ms
        for attempt in 1...3 {
            do {
                _ = try await apiClient.registerCapabilities(deviceID: id, capabilities: caps)
                NSLog("[CapabilityReporter] registered \(caps) as device \(id)")
                return
            } catch {
                NSLog("[CapabilityReporter] attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                }
            }
        }
        NSLog("[CapabilityReporter] all retries exhausted; capabilities not registered with server")
    }
}
