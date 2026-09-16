import SwiftUI

struct RootView: View {
    @State private var selected: Device?

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--terminal-recovery-ui-test") {
            TerminalKeyRecoveryUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--settings-ui-test") {
            SettingsUITestFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--ssh-trust-storage-probe") {
            NavigationStack { SSHTrustStorageDiagnosticScreen() }
        } else if ProcessInfo.processInfo.arguments.contains("--ssh-registration-ui-test") {
            NavigationStack {
                SSHKeyRegistrationScreen(model: .uiTestFixture())
            }
        } else if ProcessInfo.processInfo.arguments.contains("--clean-keyboard-comparison") {
            CleanKeyboardComparisonScreen()
        } else if ProcessInfo.processInfo.arguments.contains("--terminal-input-ui-test") {
            TerminalInputHarnessScreen()
        } else {
            mainTabs
        }
        #else
        mainTabs
        #endif
    }

    private var mainTabs: some View {
        TabView {
            DashboardScreen()
                .tabItem { Label("대시보드", systemImage: "gauge") }

            NavigationStack {
                DeviceListScreen(onSelect: { selected = $0 })
            }
            .tabItem { Label("디바이스", systemImage: "server.rack") }

            OrchsScreen()
                .tabItem { Label("Orchs", systemImage: "cpu") }

            TasksScreen()
                .tabItem { Label("Tasks", systemImage: "list.bullet.clipboard") }

            ChatScreen()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack { SettingsScreen() }
                .tabItem { Label("설정", systemImage: "gear") }
        }
        // fullScreenCover requires only Identifiable (Device is Codable+Identifiable),
        // avoiding a Hashable conformance on the shared Device model. The terminal
        // gets its own NavigationStack for the title/Done button.
        .fullScreenCover(item: $selected) { device in
            NavigationStack {
                TerminalScreen(device: device)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { selected = nil }
                    } }
            }
        }
    }
}
