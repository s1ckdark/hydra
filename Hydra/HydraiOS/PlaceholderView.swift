import SwiftUI

/// B2a placeholder. The shared service layer (networking, terminal orchestration,
/// Citadel SSH) is linked and compiled into this target; the real device-list and
/// terminal UI arrive in sub-project B2b.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
            Text("Hydra iOS")
                .font(.title.bold())
            Text("UI arrives in B2b")
                .foregroundStyle(.secondary)
        }
    }
}
