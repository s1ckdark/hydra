import SwiftUI

@main
struct HydraiOSApp: App {
    @StateObject private var dashboardVM = DashboardViewModel()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(dashboardVM)
                .environmentObject(appState)
        }
    }
}
