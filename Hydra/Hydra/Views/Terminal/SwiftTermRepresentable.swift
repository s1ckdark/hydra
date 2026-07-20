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

    // SwiftTerm의 TerminalView는 intrinsicContentSize를 안 정하고 초기 프레임이
    // 640×400 고정이라, 기본 sizing에서는 SwiftUI가 뷰를 늘리지 않아 페인을 100%
    // 안 채운다(`.frame(maxWidth/maxHeight: .infinity)`를 줘도 내부 NSView가 안 커짐).
    // 제안된 크기를 그대로 받아들이게 해서 페인을 꽉 채운다 — 그러면 TerminalView의
    // setFrameSize→processSizeChange가 cols/rows를 재계산하고 sizeChanged로 원격 PTY도
    // 맞춘다.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SwiftTerm.TerminalView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        init(session: TerminalSession) { self.session = session }

        // TerminalViewDelegate 콜백은 메인 스레드로 오지만, SwiftUI가 이 NSView를
        // 호스팅/리사이즈하는 뷰-그래프 갱신 도중 재진입으로 호출될 수 있다
        // (setFrameSize → processSizeChange → sizeChanged). 그 재진입 컨텍스트에서
        // `MainActor.assumeIsolated`의 executor 체크(`swift_task_isCurrentExecutor`)가
        // macOS 26에서 "MainActor executor 아님"으로 크래시한다. assumeIsolated(체크)를
        // 쓰지 않고 `Task { @MainActor in }`로 메인 액터에 큐잉해 안전하게 넘긴다.
        // session.send/resize는 내부적으로도 async Task로 write/resize를 하므로 원래도
        // 완전한 동기 순서 보장은 없었고, 메인 액터 큐잉은 실사용 순서를 유지한다.
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor in self.session.send(bytes) }
        }
        // Terminal resized → tell the remote PTY.
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in self.session.resize(cols: newCols, rows: newRows) }
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
