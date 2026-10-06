import SwiftUI

@main
struct HydraiOSApp: App {
    @StateObject private var dashboardVM = DashboardViewModel()
    @StateObject private var appState = AppState()

    init() {
        TerminalFontCatalog.registerBundledFonts()
        AppAppearancePreferences(defaults: Self.appearanceDefaults).migrateLanguageIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .hydraAppearancePreferences()
                .defaultAppStorage(Self.appearanceDefaults)
                .environmentObject(dashboardVM)
                .environmentObject(appState)
        }
    }

    private static var appearanceDefaults: UserDefaults {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--settings-ui-test") {
            return SettingsUITestFixture.preferenceStore
        }
        #endif
        return .standard
    }
}
