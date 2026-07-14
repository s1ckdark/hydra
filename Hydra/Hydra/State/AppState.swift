import Foundation

/// App-scope UI state shared by the menubar and the dashboard window.
/// Promoted out of view-local `@StateObject` so cross-surface signals
/// (menubar → drawer open, selection → chat context) stay in one place.
@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable {
        case dashboard
        case devices
        case orchs
        case tasks
        case console
        case terminal
        case settings
    }

    @Published var activeTab: Tab = .dashboard

    /// 런치 후 첫 대시보드 로드가 끝났는지. ContentView는 이 값이 서기 전까지
    /// 탭 UI 대신 로딩 화면을 보여준다 — "화면 먼저, 로드 나중" 깜빡임 방지.
    /// 앱 스코프에 두는 이유: 창을 닫았다 다시 열어도(새 ContentView) 스플래시를
    /// 다시 보여주지 않기 위해.
    @Published var hasCompletedInitialLoad = false

    // Right-side chat drawer. Persisted across launches.
    @Published var isChatDrawerOpen: Bool = UserDefaults.standard.bool(forKey: "chatDrawerOpen") {
        didSet { UserDefaults.standard.set(isChatDrawerOpen, forKey: "chatDrawerOpen") }
    }
    @Published var chatDrawerWidth: Double = max(280, UserDefaults.standard.double(forKey: "chatDrawerWidth").nonZeroOr(350)) {
        didSet { UserDefaults.standard.set(chatDrawerWidth, forKey: "chatDrawerWidth") }
    }

    // Per-tab selection lifted from view-local @State so ChatContextProvider
    // can compose context without reaching into each view's internals.
    @Published var selectedDeviceId: String?
    @Published var selectedOrchId: String?
    @Published var selectedTaskId: String?
}

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double { self == 0 ? fallback : self }
}
