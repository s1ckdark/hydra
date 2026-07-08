#if os(macOS)
import SwiftUI
import AppKit
import SwiftTerm

/// Wraps SwiftTerm's AppKit `TerminalView`. User input/resize flow to the
/// session; session output feeds into the terminal view. Disambiguation
/// note: SwiftTerm's NSView class is also named `TerminalView`, so this file
/// always spells it out as `SwiftTerm.TerminalView`; our own SwiftUI root is
/// named `TerminalTabView` (see TerminalView.swift) to avoid the clash.
struct SwiftTermRepresentable: NSViewRepresentable {
    let session: TerminalSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400), font: nil)
        view.terminalDelegate = context.coordinator
        // Feed session output into the terminal.
        session.onOutput = { [weak view] data in
            guard let view else { return }
            view.feed(byteArray: [UInt8](data)[...])
        }
        return view
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        init(session: TerminalSession) { self.session = session }

        // User typed → forward bytes to SSH. TerminalViewDelegate callbacks
        // arrive on a nonisolated (AppKit) context, but TerminalSession is
        // @MainActor, so hop over explicitly rather than mark the whole
        // Coordinator @MainActor (which NSObject/AppKit delegate dispatch
        // does not guarantee to call on).
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor in session.send(bytes) }
        }
        // Terminal resized → tell the remote PTY.
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in session.resize(cols: newCols, rows: newRows) }
        }

        // Remaining TerminalViewDelegate requirements not defaulted by
        // SwiftTerm's own `extension TerminalViewDelegate` (which only
        // supplies requestOpenLink/bell/iTermContent) — no-ops, we don't
        // need title/cwd/scroll-position/clipboard/range-changed tracking.
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
