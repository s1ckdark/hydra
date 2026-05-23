import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.activeTab) {
            ChatTabView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppState.Tab.chat)

            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge") }
                .tag(AppState.Tab.dashboard)

            DeviceListView()
                .tabItem { Label("Devices", systemImage: "desktopcomputer") }
                .tag(AppState.Tab.devices)

            OrchListView()
                .tabItem { Label("Orchs", systemImage: "server.rack") }
                .tag(AppState.Tab.orchs)

            #if os(macOS)
            TasksView()
                .tabItem { Label("Tasks", systemImage: "list.bullet.clipboard") }
                .tag(AppState.Tab.tasks)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppState.Tab.settings)
            #endif
        }
        .task {
            await dashboardVM.load()
        }
    }
}
