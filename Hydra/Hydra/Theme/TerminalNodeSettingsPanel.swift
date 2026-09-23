import SwiftUI

extension TerminalSettingsStore {
    /// ⌘= / ⌘- — 그 노드만 바꾼다(전체 설정을 따르던 노드는 자동으로 노드 설정이 된다).
    func adjustFontSize(_ deviceID: String, by delta: Double) {
        update(deviceID) { $0.fontSize += delta }
    }

    /// ⌘0 — 노드 크기를 전체 설정의 크기로 되돌린다.
    func resetFontSize(_ deviceID: String) {
        let size = global.fontSize
        update(deviceID) { $0.fontSize = size }
    }
}

/// 터미널 화면 안 설정 패널. 끄면 이 노드만의 설정을 편집하고, 켜면 전체 설정을 보여 주기만 한다.
struct TerminalNodeSettingsPanel: View {
    let deviceID: String
    let nodeName: String
    @ObservedObject var store: TerminalSettingsStore

    init(deviceID: String, nodeName: String, store: TerminalSettingsStore = .shared) {
        self.deviceID = deviceID
        self.nodeName = nodeName
        self.store = store
    }

    private var follow: Binding<Bool> {
        Binding(get: { store.isFollowingGlobal(deviceID) },
                set: { store.setFollowingGlobal($0, for: deviceID) })
    }

    var body: some View {
        Form {
            Section {
                Toggle("전체 설정 따르기", isOn: follow)
                    .accessibilityIdentifier("terminal-node-follow-global")
            } header: {
                Text(verbatim: nodeName)
            } footer: {
                Text(LocalizedStringKey(follow.wrappedValue
                     ? "설정 화면의 터미널 설정을 그대로 씁니다."
                     : "여기서 바꾼 값은 이 노드에만 적용됩니다."))
            }
            Group {
                if follow.wrappedValue {
                    TerminalSettingsForm(settings: .constant(store.global)).disabled(true)
                } else {
                    TerminalSettingsForm(settings: store.binding(for: deviceID))
                }
            }
        }
        .formStyle(.grouped)
    }
}
