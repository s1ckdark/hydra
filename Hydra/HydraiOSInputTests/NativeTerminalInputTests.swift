import XCTest
import UIKit
import SwiftTerm
@testable import HydraiOS

@MainActor
final class NativeTerminalInputTests: XCTestCase {
    func testKeyboardLanguageSwitchChordsStayWithIPadOS() {
        let combinations: [UIKeyModifierFlags] = [.control, [.control, .shift], [.control, .alphaShift]]
        for flags in combinations {
            XCTAssertFalse(TerminalTextView.routesToTerminal(keyCode: .keyboardSpacebar, modifiers: flags,
                                                            hasMarkedText: false, optionAsMetaKey: true))
        }
        XCTAssertTrue(TerminalTextView.routesToTerminal(keyCode: .keyboardC, modifiers: .control,
                                                       hasMarkedText: false, optionAsMetaKey: true))
    }

    func testModifierKeysAndShiftedTextStayWithNativeIME() {
        for (key, flags) in [(UIKeyboardHIDUsage.keyboardLeftShift, UIKeyModifierFlags.shift),
                             (.keyboardRightShift, .shift), (.keyboardLeftControl, .control),
                             (.keyboardRightControl, .control), (.keyboardLeftAlt, .alternate),
                             (.keyboardRightAlt, .alternate)] {
            XCTAssertFalse(TerminalTextView.routesToTerminal(keyCode: key, modifiers: flags,
                                                            hasMarkedText: false, optionAsMetaKey: true))
        }
        for key in [UIKeyboardHIDUsage.keyboardE, .keyboardR, .keyboardSlash] {
            XCTAssertFalse(TerminalTextView.routesToTerminal(keyCode: key, modifiers: .shift,
                                                            hasMarkedText: false, optionAsMetaKey: true))
        }
        XCTAssertTrue(TerminalTextView.routesToTerminal(keyCode: .keyboardC, modifiers: .control,
                                                       hasMarkedText: false, optionAsMetaKey: true))
        XCTAssertFalse(TerminalTextView.routesToTerminal(keyCode: .keyboardRightArrow, modifiers: [],
                                                        hasMarkedText: true, optionAsMetaKey: true))
    }

    final class Recorder: NSObject, TerminalViewDelegate {
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

    func testKoreanWithoutMarkedRangeWaitsForWordBoundary() {
        for text in ["ㅎ", "하", "한", "한ㄱ", "한그", "한글", "않", "되", "값이", "ㅋㅋ"] {
            XCTAssertFalse(NativeTerminalInputView.shouldCommit(text: text, language: "ko-KR", hasMarkedText: false))
        }
        for text in ["한글 ", "한글.", "한글a"] {
            XCTAssertTrue(NativeTerminalInputView.shouldCommit(text: text, language: "ko-KR", hasMarkedText: false))
        }
        XCTAssertFalse(NativeTerminalInputView.shouldCommit(text: "", language: "ko-KR", hasMarkedText: false))
        XCTAssertFalse(NativeTerminalInputView.shouldCommit(text: "日本語", language: "ja", hasMarkedText: true))
        XCTAssertTrue(NativeTerminalInputView.shouldCommit(text: "日本語", language: "ja", hasMarkedText: false))
        XCTAssertTrue(NativeTerminalInputView.shouldCommit(text: "a", language: "en-US", hasMarkedText: false))
    }

    func testCommitDoesNotDuplicateNativeDraft() {
        let view = NativeTerminalInputView(frame: .zero)
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.input.text = "한글"
        view.commitPending()
        view.commitPending()
        XCTAssertEqual(recorder.bytes, Array("한글".utf8))
        XCTAssertEqual(view.input.text, "")
    }

    func testEnterFlushesDraftBeforeCarriageReturn() {
        let view = NativeTerminalInputView(frame: .zero)
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.input.text = "한글"
        XCTAssertFalse(view.textView(view.input, shouldChangeTextIn: NSRange(location: 2, length: 0), replacementText: "\n"))
        XCTAssertEqual(recorder.bytes, Array("한글".utf8) + [13])
    }

    func testClosingDoesNotSendProvisionalText() {
        let view = NativeTerminalInputView(frame: .zero)
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        view.input.text = "한글"
        view.close()
        XCTAssertEqual(recorder.bytes, [])
    }

    func testBackspaceWithEmptyNativeEditorReachesTerminal() {
        let view = NativeTerminalInputView(frame: .zero)
        let recorder = Recorder()
        view.terminal.terminalDelegate = recorder
        defer { view.close() }
        view.input.deleteBackward()
        XCTAssertEqual(recorder.bytes, [127])
    }
}
