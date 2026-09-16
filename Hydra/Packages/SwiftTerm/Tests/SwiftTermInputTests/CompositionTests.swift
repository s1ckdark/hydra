#if os(iOS)
import XCTest
import UIKit
@testable import SwiftTerm

@MainActor
final class CompositionTests: XCTestCase {
    final class InputDelegate: NSObject, UITextInputDelegate {
        var notifications = 0
        func selectionWillChange(_ textInput: UITextInput?) { notifications += 1 }
        func selectionDidChange(_ textInput: UITextInput?) { notifications += 1 }
        func textWillChange(_ textInput: UITextInput?) { notifications += 1 }
        func textDidChange(_ textInput: UITextInput?) { notifications += 1 }
        @available(iOS 18.4, *)
        func conversationContext(_ context: UIConversationContext?, didChange textInput: UITextInput?) {}
    }

    func testKeyboardInitiatedEditsDoNotNotifyTheKeyboardAsExternalChanges() {
        run { view, _ in
            let delegate = InputDelegate()
            view.inputDelegate = delegate
            mark("ㅎ", in: view)
            mark("하", in: view)
            mark("한", in: view)
            view.insertText("한")
            view.deleteBackward()
            XCTAssertEqual(delegate.notifications, 0)
        }
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

    private func run(_ test: (TerminalView, Recorder) -> Void) {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        defer { view.updateUiClosed() }
        test(view, recorder)
    }

    private func mark(_ text: String, in view: TerminalView) {
        view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
    }

    func testControlFromEitherSourceSendsControlByteAndResetsBothFlags() {
        for (viewControl, accessoryControl) in [(true, false), (false, true), (true, true)] {
            run { view, recorder in
                XCTAssertNotNil(view.terminalAccessory)
                XCTAssertEqual(view.terminalAccessory?.controlModifier, false)
                view.controlModifier = viewControl
                view.terminalAccessory?.controlModifier = accessoryControl

                view.insertText("c")

                XCTAssertEqual(recorder.bytes, [0x03])
                XCTAssertFalse(view.controlModifier)
                XCTAssertEqual(view.terminalAccessory?.controlModifier, false)
                view.insertText("c")
                XCTAssertEqual(recorder.bytes, [0x03, 0x63])
            }
        }
    }

    func testKittyControlFromEitherSourceSendsModifiedKeyAndResetsBothFlags() {
        for (viewControl, accessoryControl) in [(true, false), (false, true), (true, true)] {
            run { view, recorder in
                XCTAssertNotNil(view.terminalAccessory)
                view.feed(text: "\u{1b}[>1u")
                XCTAssertEqual(view.getTerminal().keyboardEnhancementFlags, [.disambiguate])
                view.controlModifier = viewControl
                view.terminalAccessory?.controlModifier = accessoryControl

                view.insertText("c")

                XCTAssertEqual(recorder.bytes, Array("\u{1b}[99;5u".utf8))
                XCTAssertFalse(view.controlModifier)
                XCTAssertEqual(view.terminalAccessory?.controlModifier, false)
                view.insertText("c")
                XCTAssertEqual(recorder.bytes, Array("\u{1b}[99;5uc".utf8))
            }
        }
    }

    func testMouseControlFromEitherSourceEncodesModifierAndResetsBothFlags() {
        for (viewControl, accessoryControl) in [(true, false), (false, true), (true, true)] {
            run { view, _ in
                XCTAssertNotNil(view.terminalAccessory)
                view.feed(text: "\u{1b}[?1000h")
                view.controlModifier = viewControl
                view.terminalAccessory?.controlModifier = accessoryControl

                XCTAssertEqual(view.encodeFlags(release: false), 17)

                XCTAssertFalse(view.controlModifier)
                XCTAssertEqual(view.terminalAccessory?.controlModifier, false)
                XCTAssertEqual(view.encodeFlags(release: false), 1)
            }
        }
    }

    func testCancelledPressesStopRepeatAndClearCommandWithoutSendingARelease() {
        run { view, recorder in
            view.feed(text: "\u{1b}[>11u")
            view.commandActive = true
            let timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                recorder.bytes.append(0x63)
            }
            defer { timer.invalidate() }
            view.keyRepeat = timer

            view.pressesCancelled([], with: nil)

            XCTAssertFalse(timer.isValid)
            XCTAssertNil(view.keyRepeat)
            XCTAssertFalse(view.commandActive)
            XCTAssertEqual(recorder.bytes, [])
        }
    }

    func testKoreanPreeditIsLocalAndCommitIsSentOnce() {
        run { view, recorder in
            for text in ["ㅎ", "하", "한"] {
                mark(text, in: view)
                XCTAssertEqual(recorder.bytes, [])
                XCTAssertEqual(view.markedTextLabel.text, text)
            }
            view.insertText("한")
            view.unmarkText()
            XCTAssertEqual(recorder.bytes, Array("한".utf8))
            XCTAssertTrue(view.markedTextLabel.isHidden)
            XCTAssertNil(view.markedTextRange)
        }
    }

    func testRepeatedCommittedSyllablesAreNeverMergedOrDropped() {
        run { view, recorder in
            for text in ["가", "가", "하", "하", "되", "되", "한", "한"] { view.insertText(text) }
            XCTAssertEqual(recorder.bytes, Array("가가하하되되한한".utf8))
        }
    }

    func testCompoundVowelsFinalsAndLinkageUseIMEText() {
        run { view, recorder in
            for text in ["ㅇ", "아", "안", "않"] { mark(text, in: view) }
            view.insertText("않")
            for text in ["ㄷ", "도", "되"] { mark(text, in: view) }
            view.insertText("되")
            for text in ["ㄱ", "가", "갑", "값"] { mark(text, in: view) }
            view.insertText("갑")
            mark("시", in: view)
            view.unmarkText()
            XCTAssertEqual(recorder.bytes, Array("않되갑시".utf8))
        }
    }

    func testCancellationAndFastBackspacesDoNotLeakOrGetSwallowed() {
        run { view, recorder in
            view.insertText("ab")
            mark("한", in: view)
            view.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
            view.unmarkText()
            view.deleteBackward()
            view.deleteBackward()
            XCTAssertEqual(recorder.bytes, Array("ab".utf8) + [127, 127])
        }
    }

    func testDeletingPreeditDoesNotDeleteRemoteText() {
        run { view, recorder in
            view.insertText("a")
            mark("한글", in: view)
            view.deleteBackward()
            XCTAssertEqual(view.markedTextLabel.text, "한")
            view.deleteBackward()
            XCTAssertEqual(recorder.bytes, Array("a".utf8))
            XCTAssertNil(view.markedTextRange)
            view.deleteBackward()
            XCTAssertEqual(recorder.bytes, Array("a".utf8) + [127])
        }
    }

    func testReplacementInsidePreeditStaysLocal() {
        run { view, recorder in
            mark("하", in: view)
            view.replace(view.markedTextRange!, withText: "한")
            XCTAssertEqual(recorder.bytes, [])
            XCTAssertEqual(view.markedTextLabel.text, "한")
            view.unmarkText()
            view.unmarkText()
            XCTAssertEqual(recorder.bytes, Array("한".utf8))
        }
    }

    func testMixedCommitAndAccessoryEnterKeepOrder() {
        run { view, recorder in
            mark("한", in: view)
            view.insertText("한a ")
            mark("글", in: view)
            view.insertTextFromAccessory("\n")
            XCTAssertEqual(recorder.bytes, Array("한a 글".utf8) + [13])
        }
    }

    func testJapaneseChineseEmojiAndDecomposedHangulCommitCleanly() {
        run { view, recorder in
            for text in ["日本語", "中文", "👨‍👩‍👧‍👦", "한"] {
                mark(text, in: view)
                view.insertText(text)
            }
            XCTAssertEqual(recorder.bytes, Array("日本語中文👨‍👩‍👧‍👦한".utf8))
        }
    }

    func testEmojiPreeditBackspaceRemovesOneComposedCharacter() {
        run { view, recorder in
            mark("한👨‍👩‍👧‍👦", in: view)
            view.deleteBackward()
            XCTAssertEqual(view.markedTextLabel.text, "한")
            XCTAssertEqual(recorder.bytes, [])
            view.unmarkText()
            XCTAssertEqual(recorder.bytes, Array("한".utf8))
        }
    }

    func testCommittedEmojiBackspaceSendsOneDeleteAndKeepsValidStorage() {
        run { view, recorder in
            view.insertText("한👨‍👩‍👧‍👦")
            view.deleteBackward()
            view.insertText("글")
            XCTAssertEqual(recorder.bytes, Array("한👨‍👩‍👧‍👦".utf8) + [127] + Array("글".utf8))
        }
    }
}
#endif
