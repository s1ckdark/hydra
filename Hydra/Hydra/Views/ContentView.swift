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
        // 애니메이션 없이 즉시 전환. macOS 26.5.2에서 애니메이션이 유발하는 레이아웃
        // (`NSAnimationContext`→`NSHostingView.layout`) 중 SwiftUI가 `.task`/`.onAppear`
        // (`_AppearanceActionModifier`/`_TaskModifier`)를 실행하며 격리 체크
        // (`swift_task_isCurrentExecutor`)가 크래시하는 OS 회귀가 있어, 콘텐츠 리빌을
        // 애니메이션으로 감싸지 않는다.
        appState.hasCompletedInitialLoad = true
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                customTabBar
                Divider()
                selectedContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Drawer is otherwise only reachable via ⌘/ or the menubar.
            // Surface an in-window affordance, shown only while closed
            // (the drawer carries its own close button when open).
            // 일반 탭 어포던스(.bordered Button은 DesignLibrary라 아래 커스텀 탭 바
            // 주석의 크래시 경로를 타므로 .onTapGesture로 대체).
            .overlay(alignment: .topTrailing) {
                if !appState.isChatDrawerOpen {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { appState.isChatDrawerOpen = true }
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
            }
        }
        // 드로어 토글 애니메이션 제거 — 애니메이션이 유발하는 레이아웃 중 격리-체크
        // 크래시(위 런치 리빌 주석 참고)를 피하기 위해 즉시 전환한다.
    }

    // MARK: - 커스텀 탭 바 (SwiftUI TabView 대체)
    //
    // macOS 26.5.2에서 SwiftUI `TabView`의 시스템 탭 바는 DesignLibrary로 렌더링되는데,
    // 터미널 탭의 SwiftUI 트랜잭션(세션 상태 변화·연결 등) 중 그 HStack이 재평가되며
    // 격리-체크(`swift_task_isCurrentExecutor`)가 크래시한다(메인 스레드인데 MainActor
    // executor 아님 판정 — OS 회귀, legacy override로도 못 막음). 우리 일반 SwiftUI
    // 스택/`.onTapGesture`는 그 경로를 타지 않으므로 탭 바를 직접 만들어 크래시 지점
    // 자체를 없앤다. activeTab에 따라 활성 탭 콘텐츠만 생성한다(비활성 subtree 미생성).
    private struct TabItem: Identifiable {
        let tab: AppState.Tab
        let title: String
        let icon: String
        var id: AppState.Tab { tab }
    }

    private var tabItems: [TabItem] {
        var items: [TabItem] = [
            .init(tab: .dashboard, title: "Dashboard", icon: "gauge"),
            .init(tab: .devices, title: "Devices", icon: "desktopcomputer"),
            .init(tab: .orchs, title: "Orchs", icon: "server.rack"),
        ]
        #if os(macOS)
        items += [
            .init(tab: .tasks, title: "Tasks", icon: "list.bullet.clipboard"),
            .init(tab: .console, title: "Console", icon: "terminal"),
            .init(tab: .terminal, title: "Terminal", icon: "apple.terminal"),
            .init(tab: .settings, title: "Settings", icon: "gearshape"),
        ]
        #endif
        return items
    }

    private var customTabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabItems) { item in
                let active = appState.activeTab == item.tab
                HStack(spacing: 5) {
                    Image(systemName: item.icon)
                    Text(item.title)
                }
                .font(.callout)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { appState.activeTab = item.tab }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private var selectedContent: some View {
        switch appState.activeTab {
        case .dashboard: DashboardView()
        case .devices: DeviceListView()
        case .orchs: OrchListView()
        default:
            #if os(macOS)
            macTabContent
            #else
            EmptyView()
            #endif
        }
    }

    #if os(macOS)
    @ViewBuilder private var macTabContent: some View {
        switch appState.activeTab {
        case .tasks: TasksView()
        case .console: ConsoleView()
        case .terminal: TerminalTabView(dashboardVM: dashboardVM)
        case .settings: SettingsView()
        default: EmptyView()
        }
    }
    #endif
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
