import SwiftUI
import SwiftTerm

/// iOS mirror of the macOS SwiftTermRepresentable. Wraps SwiftTerm's UIKit
/// `TerminalView`: session output feeds the view; user input/resize flow back
/// to the SSH session via the delegate.
struct SwiftTermRepresentableiOS: UIViewRepresentable {
    let session: TerminalSession
    var scheme: TerminalColorScheme = .defaultDark

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> NativeTerminalInputView {
        let container = NativeTerminalInputView(frame: .zero)
        let view = container.terminal
        view.terminalDelegate = context.coordinator
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--terminal-recovery-ui-test") {
            // An infinite cursor animation prevents XCTest from reaching UI idle.
            // Only the isolated navigation fixture uses a steady cursor.
            view.getTerminal().setCursorStyle(.steadyBlock)
        }
        #endif
        // Feed session output into the terminal.
        session.onOutput = { [weak view] data in
            guard let view else { return }
            view.feed(byteArray: [UInt8](data)[...])
        }
        applyScheme(to: container, coordinator: context.coordinator)
        return container
    }

    func updateUIView(_ uiView: NativeTerminalInputView, context: Context) {
        applyScheme(to: uiView, coordinator: context.coordinator)
    }

    /// SwiftUI는 update를 자주 부른다 — id가 바뀔 때만 팔레트를 다시 설치한다.
    /// SwiftTerm iOS 뷰는 non-opaque라 컨테이너 배경이 비치므로 같이 칠한다.
    private func applyScheme(to container: NativeTerminalInputView, coordinator: Coordinator) {
        guard coordinator.appliedSchemeID != scheme.id else { return }
        scheme.apply(to: container.terminal)
        container.backgroundColor = TerminalColorScheme.platformColor(scheme.background)
        coordinator.appliedSchemeID = scheme.id
    }

    static func dismantleUIView(_ uiView: NativeTerminalInputView, coordinator: Coordinator) {
        // onOutput은 makeUIView에서 설치한 뷰 캡처 클로저다. 끊지 않으면 세션이
        // 뷰보다 오래 살 때 사라진 뷰로 계속 feed를 시도한다.
        coordinator.session.onOutput = nil
        uiView.close()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        var appliedSchemeID: String?
        init(session: TerminalSession) { self.session = session }

        // User typed → forward bytes to SSH. TerminalViewDelegate callbacks
        // arrive on the main thread, which is the same executor as @MainActor,
        // so we synchronously assume isolation rather than hop through an
        // unstructured Task (mirrors the macOS Coordinator's rationale).
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { session.send(Data(data)) }
        }
        // Terminal resized → tell the remote PTY.
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }

        // Remaining TerminalViewDelegate requirements — no-ops, we don't need
        // title/cwd/scroll-position/clipboard/range-changed/link/bell/iTerm
        // tracking. iOS's TerminalViewDelegate extension only defaults
        // bell/iTermContent (unlike macOS, which also defaults
        // requestOpenLink), so requestOpenLink must be implemented here.
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    }
}
