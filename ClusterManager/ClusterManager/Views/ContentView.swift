import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge") }

            DeviceListView()
                .tabItem { Label("Devices", systemImage: "desktopcomputer") }

            OrchListView()
                .tabItem { Label("Orchs", systemImage: "server.rack") }

            #if os(macOS)
            TasksView()
                .tabItem { Label("Tasks", systemImage: "list.bullet.clipboard") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
            #endif
        }
        .task {
            await dashboardVM.load()
        }
    }
}
