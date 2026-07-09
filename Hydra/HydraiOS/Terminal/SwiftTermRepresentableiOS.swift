import SwiftUI
import SwiftTerm

/// iOS mirror of the macOS SwiftTermRepresentable. Wraps SwiftTerm's UIKit
/// `TerminalView`: session output feeds the view; user input/resize flow back
/// to the SSH session via the delegate.
struct SwiftTermRepresentableiOS: UIViewRepresentable {
    let session: TerminalSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.terminalDelegate = context.coordinator
        // Feed session output into the terminal.
        session.onOutput = { [weak view] data in
            guard let view else { return }
            view.feed(byteArray: [UInt8](data)[...])
        }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
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
