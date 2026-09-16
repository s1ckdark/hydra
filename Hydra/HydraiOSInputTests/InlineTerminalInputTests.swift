import XCTest
import UIKit
import SwiftTerm
@testable import HydraiOS

@MainActor
final class InlineTerminalInputTests: XCTestCase {
    private final class Recorder: NSObject, TerminalViewDelegate {
        var bytes: [UInt8] = []
        var onSend: ((ArraySlice<UInt8>) -> Void)?
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data; onSend?(data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }

    private func setDraft(_ text: String, in view: NativeTerminalInputView) {
        view.input.text = text
        view.input.selectedRange = NSRange(location: text.utf16.count, length: 0)
        // The selection callback redraws the native document independently of
        // its commit policy; tests do not pretend to synthesize the actual IME.
        view.textViewDidChangeSelection(view.input)
    }

    func testEveryNativeDraftRevisionAppearsInlineWithoutSendingOrChangingGrid() {
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.layoutIfNeeded()
        view.terminal.feed(text: "$ ")
        let original = view.terminal.getTerminal().getLine(row: 0)?.translateToString()
        for text in ["ㅎ", "하", "한", "한ㄱ", "한그", "한글", "앙", "아아", "어떨까", ""] {
            setDraft(text, in: view)
            XCTAssertEqual(view.terminal.externalPreeditText, text)
            XCTAssertEqual(recorder.bytes, [])
            XCTAssertEqual(view.terminal.getTerminal().getLine(row: 0)?.translateToString(), original)
        }
    }

    func testCommitRemovesPreviewBeforeEchoAndSendsExactlyOnce() {
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.layoutIfNeeded()
        setDraft("어떨까?", in: view)
        recorder.onSend = { [weak view] data in
            XCTAssertEqual(view?.terminal.externalPreeditText, "")
            view?.terminal.feed(byteArray: data)
        }
        view.commitPending()
        view.commitPending()
        XCTAssertEqual(recorder.bytes, Array("어떨까?".utf8))
        XCTAssertEqual(view.input.text, "")
        XCTAssertEqual(view.terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true), "어떨까?")
    }

    func testViewportNoLongerReservesSeparateBottomInputRow() {
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        defer { view.close() }
        view.layoutIfNeeded()
        view.terminal.feed(text: "$ ")
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.terminal.frame, view.bounds)
        let anchor = view.terminal.convert(view.terminal.inputCursorRect, to: view)
        XCTAssertEqual(view.input.frame.minX, anchor.minX, accuracy: 0.5)
        XCTAssertEqual(view.input.frame.minY, anchor.minY, accuracy: 0.5)
        XCTAssertEqual(view.input.textColor, .clear)
        XCTAssertNotNil(view.input.inputAccessoryView)
    }

    func testClosingDiscardsInlineDraftWithoutSending() {
        let view = NativeTerminalInputView(frame: .zero)
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        setDraft("한글", in: view)
        view.close()
        XCTAssertEqual(view.terminal.externalPreeditText, "")
        XCTAssertEqual(recorder.bytes, [])
    }

    func testNativeTypingReturnsFromScrollbackButSelectionDoesNot() {
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 640, height: 200))
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.layoutIfNeeded()
        view.terminal.feed(text: String(repeating: "old output\r\n", count: 80))
        view.terminal.contentOffset = .zero
        XCTAssertEqual(view.terminal.contentOffset.y, 0)
        view.input.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(view.input.markedTextRange)
        view.textViewDidChange(view.input)
        XCTAssertGreaterThan(view.terminal.contentOffset.y, 0)
        XCTAssertEqual(view.terminal.externalPreeditText, "한")
        XCTAssertFalse(view.terminal.externalPreeditCaretRect.isNull)
        XCTAssertEqual(recorder.bytes, [])
        view.terminal.contentOffset = .zero
        view.textViewDidChangeSelection(view.input)
        XCTAssertEqual(view.terminal.contentOffset.y, 0)
    }

    func testInlineDraftRasterBeforeSpaceAndAfterCommit() async throws {
        let view = NativeTerminalInputView(frame: CGRect(x: 0, y: 0, width: 640, height: 200))
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.layoutIfNeeded()
        view.terminal.feed(text: "\u{1b}[2 q$ ")
        func capture(_ name: String) async throws -> Data {
            view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            view.layer.displayIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
                view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return try XCTUnwrap(image.pngData())
        }
        let before = try await capture("inline-empty-prompt")
        setDraft("어떨까", in: view)
        let draft = try await capture("inline-korean-before-space")
        XCTAssertNotEqual(draft, before)
        XCTAssertEqual(recorder.bytes, [])
        XCTAssertEqual(view.terminal.externalPreeditText, "어떨까")
        view.commitPending()
        XCTAssertEqual(recorder.bytes, Array("어떨까".utf8))
        let awaitingEcho = try await capture("inline-awaiting-remote-echo")
        XCTAssertEqual(awaitingEcho, before, "The preview must not remain as a second local echo.")
        view.terminal.feed(text: "어떨까")
        _ = try await capture("inline-committed-remote-echo")
    }
}
