import Foundation

/// App-scope UI state shared by the menubar and the dashboard window.
/// Promoted out of view-local `@StateObject` so cross-surface signals
/// (menubar → drawer open, selection → chat context) stay in one place.
@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable {
        case chat
        case dashboard
        case devices
        case orchs
        case tasks
        case settings
    }

    @Published var activeTab: Tab = .dashboard

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
    @Published var selectedTaskId: UUID?
}

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double { self == 0 ? fallback : self }
}
