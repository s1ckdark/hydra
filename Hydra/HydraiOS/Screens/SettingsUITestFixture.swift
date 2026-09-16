#if DEBUG
import SwiftUI

/// Exercises the production settings sections with isolated preferences and a
/// synthetic inventory. No saved API keys, server calls or SSH credentials.
@MainActor
struct SettingsUITestFixture: View {
    @StateObject private var model: DashboardViewModel

    static let preferenceStore: UserDefaults = {
        let args = ProcessInfo.processInfo.arguments
        let suite = args.firstIndex(of: "--settings-test-suite")
            .flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "hydra.settings.qa.default"
        let prefs = UserDefaults(suiteName: suite)!
        prefs.register(defaults: ["appLanguage": "ko", "appTheme": "system"])
        return prefs
    }()

    init() {
        _model = StateObject(wrappedValue: DashboardViewModel(deviceInventoryLoader: {
            [Device(id: "settings-fixture", name: "intlmac.tail.test", hostname: "intlmac", ipAddresses: [],
                    tailscaleIp: "100.64.0.2", os: "macOS", status: "online", isExternal: false,
                    tags: nil, user: "fixture", lastSeen: Date(), sshEnabled: true, hasGpu: false,
                    gpuModel: nil, gpuCount: 0)]
        }, deviceInventorySource: { "fixture" }))
    }

    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    AppearanceSettingsSection()
                    DeviceRefreshSettingsSection(model: model)
                    SettingsAppearanceProbe()
                }.navigationTitle("설정")
            }.tabItem { Label("설정", systemImage: "gear") }
            NavigationStack {
                DeviceListScreen(onSelect: { _ in }, loadOnAppear: false)
            }.tabItem { Label("디바이스", systemImage: "server.rack") }
        }
        .environmentObject(model)
    }
}

private struct SettingsAppearanceProbe: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Text(verbatim: "\(locale.language.languageCode?.identifier ?? "-")|\(colorScheme == .dark ? "dark" : "light")")
            .font(.caption).accessibilityIdentifier("settings-appearance-probe")
    }
}
#endif
