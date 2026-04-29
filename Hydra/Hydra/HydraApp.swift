import SwiftUI

@main
struct HydraApp: App {
    @StateObject private var dashboardVM = DashboardViewModel()

    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            iOSContentView()
                .onAppear { setupCapabilities() }
                .task { await autoDiscoverServer() }
        }
        #else
        WindowGroup(id: "dashboard") {
            ContentView()
                .environmentObject(dashboardVM)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    setupCapabilities()
                }
                .task {
                    await autoDiscoverServer()
                    await reportCapabilities()
                }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandMenu("Edit") {
                Button("Cut") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x")

                Button("Copy") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c")

                Button("Paste") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v")

                Button("Select All") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a")

                Divider()

                Button("Undo") {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                }
                .keyboardShortcut("z")

                Button("Redo") {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("GPU Orch", systemImage: "server.rack") {
            MenuBarView()
                .environmentObject(dashboardVM)
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    /// Tries to find the server via Bonjour if no URL is saved yet.
    private func autoDiscoverServer() async {
        let savedURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        // Already configured — nothing to do
        if !savedURL.isEmpty { return }

        // Try localhost first (most common dev setup)
        if let url = URL(string: "http://localhost:8080/health") {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    await APIClient.shared.setBaseURL("http://localhost:8080")
                    NSLog("[autoDiscover] found server at localhost:8080")
                    return
                }
            } catch {}
        }

        // Fallback: Bonjour discovery runs in the background
        // If found, it will update the server URL automatically
        NSLog("[autoDiscover] no server found, waiting for Bonjour discovery")
    }

    @MainActor
    private func setupCapabilities() {
        let registry = CapabilityRegistry.shared
        #if os(iOS)
        registry.register(GPSCapability())
        registry.register(CameraCapability())
        #endif
        registry.register(DeviceInfoCapability())

        #if os(macOS)
        // Auto-detect macOS hardware capabilities (Compute/Network/Storage/GPU)
        // and enable those that are actually present, so reportCapabilities()
        // can advertise them to the server right after discovery.
        CapabilityReporter.shared.register(into: registry)
        #endif
    }

    /// Reports this device's enabled+available capabilities to the Hydra
    /// server. macOS-only — iOS capability reporting is a follow-up task.
    private func reportCapabilities() async {
        #if os(macOS)
        await CapabilityReporter.shared.report(via: APIClient.shared)
        #endif
    }
}
