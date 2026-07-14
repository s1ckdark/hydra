import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            TabView(selection: $appState.activeTab) {
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

                ConsoleView()
                    .tabItem { Label("Console", systemImage: "terminal") }
                    .tag(AppState.Tab.console)

                TerminalTabView()
                    .tabItem { Label("Terminal", systemImage: "apple.terminal") }
                    .tag(AppState.Tab.terminal)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppState.Tab.settings)
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Drawer is otherwise only reachable via ⌘/ or the menubar.
            // Surface an in-window affordance, shown only while closed
            // (the drawer carries its own close button when open).
            .overlay(alignment: .topTrailing) {
                if !appState.isChatDrawerOpen {
                    Button {
                        appState.isChatDrawerOpen = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Open chat (⌘/)")
                    .padding(.top, 6)
                    .padding(.trailing, 12)
                    .transition(.opacity)
                }
            }

            if appState.isChatDrawerOpen {
                DrawerResizeHandle(width: $appState.chatDrawerWidth)
                ChatDrawerView()
                    .frame(width: appState.chatDrawerWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appState.isChatDrawerOpen)
        .task {
            await dashboardVM.load()
            #if os(macOS)
            // 지난 실행의 터미널 세션 복원은 디바이스 목록이 준비된 직후, 사용자가
            // 다른 탭에서 새 세션을 열어 저장 목록을 덮어쓰기 전에 수행해야 한다.
            TerminalSessionStore.shared.restoreIfNeeded(devices: dashboardVM.devices)
            #endif
        }
    }
}

/// 4-px wide vertical drag handle between the TabView and the drawer.
/// Constrains drawer width to [280, 600].
private struct DrawerResizeHandle: View {
    @Binding var width: Double

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.001))   // invisible but hit-testable
            .frame(width: 4)
            .overlay(Divider())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let next = width - value.translation.width
                        width = min(max(next, 280), 600)
                    }
            )
    }
}
