import Foundation

/// App-scope UI state shared by the menubar and the dashboard window.
/// Promoted out of view-local `@StateObject` so cross-surface signals
/// (e.g. "menubar wants the dashboard to switch to the Chat tab") stay
/// in one place.
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

    @Published var activeTab: Tab = .chat
}
