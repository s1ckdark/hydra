import XCTest
import UIKit
import SwiftTerm
@testable import HydraiOS

@MainActor
final class InlineCaretGeometryTests: XCTestCase {
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

    private func prepareDraft(_ text: String, in view: NativeTerminalInputView) {
        view.input.text = text
        view.input.selectedRange = NSRange(location: text.utf16.count, length: 0)
        // This exercises the existing native document/selection integration,
        // not an invented hardware IME event or a transport commit boundary.
        view.textViewDidChangeSelection(view.input)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func assertCaretMatchesPreview(_ view: NativeTerminalInputView,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let selection = try XCTUnwrap(view.input.selectedTextRange, file: file, line: line)
        XCTAssertTrue(selection.isEmpty, file: file, line: line)
        let preview = view.terminal.convert(view.terminal.externalPreeditCaretRect, to: view)
        XCTAssertFalse(preview.isNull, file: file, line: line)
        let caret = view.input.convert(view.input.caretRect(for: selection.end), to: view)
        let first = view.input.convert(view.input.firstRect(for: selection), to: view)
        for (name, rectangle) in [("caretRect", caret), ("firstRect(empty selection)", first)] {
            XCTAssertEqual(rectangle.minX, preview.minX, accuracy: 0.5, name, file: file, line: line)
            XCTAssertEqual(rectangle.minY, preview.minY, accuracy: 0.5, name, file: file, line: line)
            XCTAssertEqual(rectangle.height, preview.height, accuracy: 0.5, name, file: file, line: line)
        }
    }

    func testNativeCaretAndEmptySelectionRectFollowPreeditWrappedAtRightEdge() throws {
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.layoutIfNeeded()
        let columns = view.terminal.getTerminal().cols
        view.terminal.feed(text: "\u{1b}[1;\(columns - 1)H")
        prepareDraft("어떨까한글", in: view)
        let anchor = view.terminal.convert(view.terminal.inputCursorRect, to: view)
        let caret = view.terminal.convert(view.terminal.externalPreeditCaretRect, to: view)
        XCTAssertGreaterThan(caret.minY, anchor.minY, "The fixture must actually wrap.")
        try assertCaretMatchesPreview(view)
        XCTAssertEqual(recorder.bytes, [])
    }

    func testNativeCaretFollowsBottomClampedLongPreeditAcrossRotationAndResize() throws {
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.layoutIfNeeded()
        let terminal = view.terminal.getTerminal()
        view.terminal.feed(text: "\u{1b}[\(terminal.rows);\(terminal.cols - 1)H")
        let draft = String(repeating: "어떨까한글", count: 30)
        prepareDraft(draft, in: view)
        let selection = view.input.selectedRange

        for size in [CGSize(width: 320, height: 180), CGSize(width: 640, height: 280),
                     CGSize(width: 280, height: 640), CGSize(width: 320, height: 180)] {
            view.frame.size = size
            view.setNeedsLayout()
            view.layoutIfNeeded()
            let caret = view.terminal.convert(view.terminal.externalPreeditCaretRect, to: view)
            XCTAssertGreaterThanOrEqual(caret.minY, view.bounds.minY)
            XCTAssertLessThanOrEqual(caret.maxY, view.bounds.maxY + 0.5)
            try assertCaretMatchesPreview(view)
            XCTAssertEqual(view.input.text, draft)
            XCTAssertEqual(view.input.selectedRange, selection)
            XCTAssertEqual(view.terminal.externalPreeditText, draft)
            XCTAssertEqual(recorder.bytes, [])
        }
    }

    func testMarkedDraftAndSelectionSurviveResizeAndCloseWithoutSending() throws {
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        view.layoutIfNeeded()
        let draft = String(repeating: "한글", count: 80)
        view.input.setMarkedText(draft, selectedRange: NSRange(location: draft.utf16.count, length: 0))
        view.textViewDidChangeSelection(view.input)
        let selection = view.input.selectedRange
        let marked = try XCTUnwrap(view.input.markedTextRange)
        let markedLength = view.input.offset(from: marked.start, to: marked.end)

        for size in [CGSize(width: 700, height: 250), CGSize(width: 250, height: 700)] {
            view.frame.size = size
            view.setNeedsLayout()
            view.layoutIfNeeded()
            XCTAssertEqual(view.input.text, draft)
            XCTAssertEqual(view.input.selectedRange, selection)
            let currentMarked = try XCTUnwrap(view.input.markedTextRange)
            XCTAssertEqual(view.input.offset(from: currentMarked.start, to: currentMarked.end), markedLength)
            try assertCaretMatchesPreview(view)
            XCTAssertEqual(recorder.bytes, [])
        }
        view.close()
        XCTAssertEqual(view.terminal.externalPreeditText, "")
        XCTAssertTrue(view.terminal.externalPreeditCaretRect.isNull)
        XCTAssertEqual(recorder.bytes, [])
    }
}
