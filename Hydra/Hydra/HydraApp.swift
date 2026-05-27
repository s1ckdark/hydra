import SwiftUI

@main
struct HydraApp: App {
    #if os(macOS)
    // AppDelegate pins activation policy at launch and surfaces existing
    // windows when the dock icon is clicked, working around macOS 14
    // SwiftUI quirks where pure-SwiftUI App lifecycles silently transition
    // to .accessory after the only WindowGroup window closes.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @StateObject private var dashboardVM = DashboardViewModel()
    @StateObject private var chatVM = ChatViewModel()
    @StateObject private var appState = AppState()

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
                .environmentObject(chatVM)
                .environmentObject(appState)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    setupCapabilities()
                }
                .task {
                    await autoDiscoverServer()
                    await reportCapabilities()
                    #if os(macOS)
                    MetricsReporter.shared.start(via: APIClient.shared)
                    #endif
                }
                .appAppearance()
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

            CommandMenu("Chat") {
                Button("Toggle Chat Drawer") {
                    appState.isChatDrawerOpen.toggle()
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }

        WindowGroup(id: "chat-expanded") {
            ChatTabView()
                .environmentObject(dashboardVM)
                .environmentObject(chatVM)
                .environmentObject(appState)
                .frame(minWidth: 600, minHeight: 500)
                .appAppearance()
        }
        .defaultSize(width: 720, height: 600)

        Settings {
            SettingsView()
                .appAppearance()
        }

        MenuBarExtra("GPU Orch", systemImage: "server.rack") {
            MenuBarView()
                .environmentObject(dashboardVM)
                .environmentObject(chatVM)
                .environmentObject(appState)
                .appAppearance()
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

#if os(macOS)
/// Pins the app's activation policy and re-surfaces the dashboard window
/// when the user clicks the dock icon. SwiftUI's pure App lifecycle is
/// not enough on macOS 14 because once the dashboard window closes, the
/// scene graph contains only a `MenuBarExtra` and a `Settings` scene —
/// configurations that some Sonoma builds treat as `.accessory`-eligible
/// and silently demote, dropping the dock icon. Pinning `.regular` from
/// `applicationDidFinishLaunching` keeps the dock icon, and
/// `applicationShouldHandleReopen` covers the "click dock icon to bring
/// back the closed window" case that pure SwiftUI doesn't wire up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { await EmbeddedServer.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EmbeddedServer.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeKey && !(window is NSPanel) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.orderFrontRegardless()
            }
        }
        sender.activate()
        return true
    }
}
#endif
