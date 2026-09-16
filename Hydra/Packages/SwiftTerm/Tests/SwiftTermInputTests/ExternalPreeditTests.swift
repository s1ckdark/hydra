#if os(iOS)
import XCTest
import UIKit
@testable import SwiftTerm

@MainActor
final class ExternalPreeditTests: XCTestCase {
    private final class Recorder: NSObject, TerminalViewDelegate {
        var bytes: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }

    private func run(_ test: (TerminalView, Recorder) -> Void) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 240))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        view.getTerminal().options.cursorStyle = .steadyBar
        view.cursorStyleChanged(source: view.getTerminal(), newStyle: .steadyBar)
        view.layoutIfNeeded()
        defer { view.updateUiClosed() }
        test(view, recorder)
    }

    private func preview(_ text: String, in view: TerminalView) {
        view.setExternalPreedit(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
    }

    func testDraftUpdatesNeitherSendBytesNorModifyTheTerminalModel() {
        run { view, recorder in
            view.feed(text: "$ ")
            view.updateDisplay()
            let before = view.getTerminal().getBufferAsData()
            let originalCursor = view.inputCursorRect
            for draft in ["ㅇ", "어", "어ㄸ", "어떠", "어떨", "어떨ㄲ", "어떨까"] {
                preview(draft, in: view)
                XCTAssertEqual(view.externalPreeditText, draft)
                XCTAssertEqual(view.getTerminal().getBufferAsData(), before)
                XCTAssertEqual(view.inputCursorRect, originalCursor)
                XCTAssertEqual(recorder.bytes, [])
                XCTAssertEqual(view.caretView?.isHidden, true)
                XCTAssertFalse(view.externalPreeditCaretRect.isNull)
            }
        }
    }

    func testDeletingAndClearingDraftRemovesPreviewAndRestoresCursor() {
        run { view, recorder in
            preview("어떨까", in: view)
            XCTAssertEqual(view.externalPreeditView?.layout.glyphs.count, 3)
            preview("어", in: view)
            XCTAssertEqual(view.externalPreeditView?.layout.glyphs.count, 1)
            preview("", in: view)
            XCTAssertNil(view.externalPreeditView)
            XCTAssertTrue(view.externalPreeditCaretRect.isNull)
            XCTAssertEqual(view.caretView?.isHidden, false)
            XCTAssertEqual(recorder.bytes, [])
        }
    }

    func testClearingPreviewRestoresTheSameRenderedTerminalPixels() {
        run { view, _ in
            func snapshot() -> Data? {
                view.layer.displayIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
                    view.layer.render(in: context.cgContext)
                }.pngData()
            }
            view.feed(text: "$ existing output")
            view.updateDisplay()
            let original = snapshot()
            XCTAssertNotNil(original)
            preview("어떨까", in: view)
            XCTAssertNotEqual(snapshot(), original)
            preview("어", in: view)
            preview("", in: view)
            XCTAssertEqual(snapshot(), original)
        }
    }

    func testAnchorFollowsPromptAndRemoteOutputWithoutCommittingDraft() {
        run { view, recorder in
            let cell = view.inputCellSize
            view.feed(text: "$ ")
            view.updateDisplay()
            preview("한", in: view)
            XCTAssertEqual(view.inputCursorRect.minX, 2 * cell.width, accuracy: 0.01)
            XCTAssertEqual(view.externalPreeditCaretRect.minX, 4 * cell.width, accuracy: 0.01)
            let oldY = view.inputCursorRect.minY
            view.feed(text: "\r\nremote output\r\n> ")
            view.updateDisplay()
            XCTAssertGreaterThan(view.inputCursorRect.minY, oldY)
            XCTAssertEqual(view.externalPreeditCaretRect.minY, view.inputCursorRect.minY, accuracy: 0.01)
            XCTAssertEqual(view.externalPreeditText, "한")
            XCTAssertEqual(recorder.bytes, [])
        }
    }

    func testScrollbackHidesDraftUntilActualInputCursorIsVisibleAgain() {
        run { view, _ in
            view.feed(text: String(repeating: "line\r\n", count: 60))
            view.updateDisplay()
            let liveOffset = view.contentOffset
            XCTAssertGreaterThan(liveOffset.y, view.bounds.height)
            preview("한", in: view)
            XCTAssertFalse(view.externalPreeditCaretRect.isNull)
            view.contentOffset = .zero
            XCTAssertTrue(view.externalPreeditCaretRect.isNull)
            XCTAssertEqual(view.externalPreeditText, "한")
            view.contentOffset = liveOffset
            XCTAssertFalse(view.externalPreeditCaretRect.isNull)
        }
    }

    func testResizeReflowsPreviewUsingNewTerminalColumns() {
        run { view, recorder in
            let cell = view.inputCellSize
            preview("한글abc", in: view)
            XCTAssertEqual(view.externalPreeditView?.layout.glyphs.last?.rect.minY, 0)
            view.frame.size.width = cell.width * 5
            view.setNeedsLayout()
            view.layoutIfNeeded()
            XCTAssertEqual(view.getTerminal().cols, 5)
            XCTAssertEqual(view.externalPreeditView?.layout.glyphs.last?.rect.minY, cell.height)
            XCTAssertEqual(recorder.bytes, [])
        }
    }

    func testWideGraphemeWrapsBeforeLastSingleCellAtRightEdge() {
        let layout = ExternalPreeditLayout.make(text: "한ab", selectedRange: NSRange(location: 3, length: 0),
            columns: 5, cell: CGSize(width: 10, height: 20),
            anchor: CGPoint(x: 40, y: 0), viewport: CGSize(width: 50, height: 100))
        XCTAssertEqual(layout.glyphs.map(\.rect), [
            CGRect(x: 0, y: 20, width: 20, height: 20),
            CGRect(x: 20, y: 20, width: 10, height: 20),
            CGRect(x: 30, y: 20, width: 10, height: 20)
        ])
        XCTAssertEqual(layout.caret.origin, CGPoint(x: 40, y: 20))
    }

    func testUTF16SelectionUsesGraphemeCellWidths() {
        let text = "한👨‍👩‍👧‍👦e\u{301}"
        let familyEnd = "한👨‍👩‍👧‍👦".utf16.count
        let layout = ExternalPreeditLayout.make(text: text,
            selectedRange: NSRange(location: familyEnd, length: 0), columns: 20,
            cell: CGSize(width: 10, height: 20), anchor: .zero,
            viewport: CGSize(width: 200, height: 100))
        XCTAssertEqual(layout.glyphs.map { $0.rect.width }, [20, 20, 10])
        XCTAssertEqual(layout.caret.minX, 40)
        XCTAssertEqual(ExternalPreeditLayout.columnWidth(of: "한"), 2)
        XCTAssertEqual(ExternalPreeditLayout.columnWidth(of: "❤️"), 2)
    }

    func testBottomOverflowKeepsCaretVisibleAndDisplayListBounded() {
        let text = String(repeating: "한", count: 10_000)
        let layout = ExternalPreeditLayout.make(text: text,
            selectedRange: NSRange(location: text.utf16.count, length: 0), columns: 10,
            cell: CGSize(width: 10, height: 20), anchor: CGPoint(x: 0, y: 80),
            viewport: CGSize(width: 100, height: 100))
        XCTAssertGreaterThanOrEqual(layout.caret.minY, 0)
        XCTAssertLessThanOrEqual(layout.caret.maxY, 100)
        XCTAssertLessThanOrEqual(layout.glyphs.count, 25)
        XCTAssertTrue(layout.glyphs.allSatisfy { $0.rect.maxY > 0 && $0.rect.minY < 100 })
    }

    func testDraftRemainsVisibleWhileRemoteCursorIsHidden() {
        run { view, _ in
            preview("한", in: view)
            view.feed(text: "\u{1b}[?25l")
            view.updateDisplay()
            XCTAssertTrue(view.getTerminal().cursorHidden)
            XCTAssertNil(view.caretView?.superview)
            XCTAssertEqual(view.externalPreeditView?.isHidden, false)
            XCTAssertEqual(view.externalPreeditView?.layout.glyphs.map(\.text), ["한"])
            XCTAssertFalse(view.externalPreeditCaretRect.isNull)

            preview("", in: view)
            XCTAssertTrue(view.externalPreeditCaretRect.isNull)
            XCTAssertNil(view.externalPreeditView)
            XCTAssertTrue(view.getTerminal().cursorHidden)
            XCTAssertNil(view.caretView?.superview)
            view.updateDisplay()
            XCTAssertNil(view.caretView?.superview)
        }
    }

    func testGeometryNotificationDoesNotLoopForUnchangedLayout() {
        run { view, _ in
            var notifications = 0
            view.onInputCursorChanged = { notifications += 1 }
            preview("한", in: view)
            let afterDraft = notifications
            XCTAssertGreaterThan(afterDraft, 0)
            view.updateExternalPreeditDisplay()
            view.layoutSubviews()
            XCTAssertEqual(notifications, afterDraft)
            view.feed(text: "a")
            view.updateDisplay()
            XCTAssertGreaterThan(notifications, afterDraft)
            view.onInputCursorChanged = nil
        }
    }
}
#endif
