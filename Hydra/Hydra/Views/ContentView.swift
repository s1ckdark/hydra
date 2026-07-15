import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.hasCompletedInitialLoad {
                mainContent
            } else {
                LaunchLoadingView(serverStatus: dashboardVM.serverStatus)
            }
        }
        .task { await initialLoad() }
    }

    /// 창을 띄우기 전에 임베디드 서버 기동과 첫 디바이스 로드를 끝내고 나서
    /// 본 화면을 연다. 서버가 끝내 안 뜨는 경우(오프라인 등)에도 데드라인이
    /// 지나면 화면을 열어 기존 오류 배너/빈 상태 처리에 맡긴다.
    private func initialLoad() async {
        guard !appState.hasCompletedInitialLoad else { return }
        // 임베디드 서버 기동 직후라 첫 시도는 흔히 connection refused — 짧게
        // 재시도한다. 단, 원격 서버 무응답이면 load() 한 번이 APIClient 타임아웃
        // (30초)까지 걸릴 수 있으므로 워치독으로 스플래시 체류를 상한한다.
        // 워치독이 실제로 동작하는 건 APIClient가 async URLSession 경로(취소 전파됨)를
        // 쓰기 때문이다 — 취소 불가능한 전송으로 바꾸면 30초 지연이 조용히 재발한다.
        // 불변식: retryDeadline < splashWatchdog (아니면 워치독이 죽은 코드가 된다).
        let retryDeadline: TimeInterval = 5
        let splashWatchdog: TimeInterval = 10
        let vm = dashboardVM
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                let deadline = Date().addingTimeInterval(retryDeadline)
                while !Task.isCancelled {
                    await vm.load()
                    // vm.error는 디바이스/오치 목록(핵심 콘텐츠) 실패만 반영한다 —
                    // GPU/메트릭 등 부가 페치 실패가 스플래시를 붙잡으면 안 된다.
                    if vm.serverStatus == .connected && vm.error == nil { break }
                    if Date() >= deadline { break }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(splashWatchdog)) }
            await group.next()
            group.cancelAll()
        }
        #if os(macOS)
        // 지난 실행의 터미널 세션 복원은 디바이스 목록이 준비된 직후, 사용자가
        // 다른 탭에서 새 세션을 열어 저장 목록을 덮어쓰기 전에 수행해야 한다.
        TerminalSessionStore.shared.restoreIfNeeded(devices: dashboardVM.devices)
        #endif
        withAnimation(.easeInOut(duration: 0.25)) {
            appState.hasCompletedInitialLoad = true
        }
    }

    private var mainContent: some View {
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

                TerminalTabView(dashboardVM: dashboardVM)
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
    }
}

/// 첫 로드가 끝날 때까지 탭 UI 대신 보여주는 런치 화면.
private struct LaunchLoadingView: View {
    let serverStatus: DashboardViewModel.ServerStatus

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Hydra")
                .font(.title2.bold())
            ProgressView()
                .controlSize(.small)
            Text(serverStatus == .connected
                 ? "디바이스 정보를 불러오는 중…"
                 : "로컬 서버 시작 중…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
