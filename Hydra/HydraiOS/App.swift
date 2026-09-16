import SwiftUI

@main
struct HydraiOSApp: App {
    @StateObject private var dashboardVM = DashboardViewModel()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .hydraAppearancePreferences()
                .defaultAppStorage(appearanceDefaults)
                .environmentObject(dashboardVM)
                .environmentObject(appState)
        }
    }

    private var appearanceDefaults: UserDefaults {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--settings-ui-test") {
            return SettingsUITestFixture.preferenceStore
        }
        #endif
        return .standard
    }
}
