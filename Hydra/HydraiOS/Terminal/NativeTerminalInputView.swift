import UIKit
import SwiftTerm

/// UIKit owns the editable document; SwiftTerm displays its draft at the cursor
/// without feeding provisional characters into the terminal grid or SSH stream.
/// Korean keyboards revise text even with no marked range, so their transport
/// boundary remains a word boundary, independently of immediate inline display.
final class NativeTerminalInputView: UIView, UITextViewDelegate {
    let terminal = InputRoutedTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
    let input = TerminalTextView()
    private let commitButton = UIButton(type: .system)
    private let accessory = UIInputView(frame: CGRect(x: 0, y: 0, width: 640, height: 48), inputViewStyle: .keyboard)
    private var committing = false
    private var languageObserver: NSObjectProtocol?
    var onInputSnapshot: ((String, Bool) -> Void)?
    // Installed only by the explicit Debug input-test screen; no normal-session log.
    var onInputEvent: ((String) -> Void)?

    func traceInput(_ event: @autoclosure () -> String) { onInputEvent?(event()) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminal.inputReceiver = input
        input.terminal = terminal
        input.owner = self
        input.delegate = self
        input.font = terminal.font
        // Keep the real native editor focusable and accessible at the terminal
        // cursor. Only its ink is hidden; the cell-aligned preedit layer draws
        // the same document, so there is no second visible input row/caret.
        input.backgroundColor = .clear
        input.isOpaque = false
        input.textColor = .clear
        input.tintColor = .clear
        input.markedTextStyle = [.foregroundColor: UIColor.clear, .backgroundColor: UIColor.clear]
        input.textContainerInset = .zero
        input.textContainer.lineFragmentPadding = 0
        input.isScrollEnabled = false
        input.autocapitalizationType = .none
        input.autocorrectionType = .no
        input.spellCheckingType = .no
        input.smartQuotesType = .no
        input.smartDashesType = .no
        input.smartInsertDeleteType = .no
        input.accessibilityLabel = "터미널 입력"
        input.accessibilityHint = "조합 중인 한글은 커서 위치에 바로 표시되고 공백이나 Enter에서 전송됩니다."
        input.accessibilityIdentifier = "terminalInputSurface"
        terminal.onInputCursorChanged = { [weak self] in self?.setNeedsLayout() }
        terminal.externalInputCommit = { [weak self] in self?.commitPending() }
        terminal.externalInputKeyboardToggle = { [weak input] in input?.resignFirstResponder() }
        commitButton.setTitle("전송", for: .normal)
        commitButton.accessibilityIdentifier = "commitTerminalDraft"
        commitButton.accessibilityHint = "공백이나 줄바꿈 없이 조합한 글자만 전송합니다."
        commitButton.addTarget(self, action: #selector(commitTapped), for: .touchUpInside)
        commitButton.isEnabled = false
        addSubview(terminal)
        addSubview(input)
        // Keep explicit commit available beside the existing terminal keys,
        // without reserving a bottom row in the terminal viewport.
        accessory.allowsSelfSizing = true
        let keys = terminal.inputAccessoryView ?? UIView()
        accessory.addSubview(keys)
        accessory.addSubview(commitButton)
        keys.translatesAutoresizingMaskIntoConstraints = false
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            keys.topAnchor.constraint(equalTo: accessory.topAnchor),
            keys.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
            keys.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor),
            keys.heightAnchor.constraint(equalToConstant: 48),
            commitButton.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            commitButton.topAnchor.constraint(equalTo: accessory.topAnchor),
            commitButton.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
            commitButton.widthAnchor.constraint(equalToConstant: 56),
        ])
        input.inputAccessoryView = accessory
        languageObserver = NotificationCenter.default.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.traceInput("inputModeChanged language=\(self?.input.textInputMode?.primaryLanguage ?? "nil")")
                self?.commitPending()
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        terminal.frame = bounds
        terminal.layoutIfNeeded()
        if input.font != terminal.font { input.font = terminal.font }
        let cell = terminal.inputCellSize
        let cursor = terminal.convert(terminal.inputCursorRect, to: self)
        // The native field remains a small, hittable text surface. It does not
        // cover the whole terminal or take over its scrolling/selection gestures.
        let x = min(max(0, cursor.minX), max(0, bounds.width - cell.width))
        let height = max(cell.height, 28)
        let y = min(max(0, cursor.minY), max(0, bounds.height - height))
        input.frame = CGRect(x: x, y: y, width: max(cell.width, bounds.width - x), height: height)
    }

    func focusInput() {
        terminal.revealInputCursor()
        setNeedsLayout()
        layoutIfNeeded()
        input.becomeFirstResponder()
    }

    private func updateInlineDraft() {
        let selection = input.selectedRange
        terminal.setExternalPreedit(input.text ?? "", selectedRange: selection)
        input.displayedPreeditSelection = selection
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !committing else { return }
        updateInlineDraft()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !committing else { return }
        // Match normal terminal typing after the user has browsed scrollback.
        // Selection/layout callbacks must not do this, or reading old output
        // would continually snap back to the live cursor.
        terminal.revealInputCursor()
        let text = textView.text ?? ""
        traceInput("didChange language=\(textView.textInputMode?.primaryLanguage ?? "nil") text=\(text.debugDescription) marked=\(String(describing: textView.markedTextRange))")
        updateInlineDraft()
        commitButton.isEnabled = !text.isEmpty
        onInputSnapshot?(text, textView.markedTextRange != nil)
        if Self.shouldCommit(text: text, language: textView.textInputMode?.primaryLanguage,
                             hasMarkedText: textView.markedTextRange != nil) { commitPending() }
    }

    static func shouldCommit(text: String, language: String?, hasMarkedText: Bool) -> Bool {
        guard !hasMarkedText, !text.isEmpty else { return false }
        if language?.hasPrefix("ko") == true, let last = text.unicodeScalars.last, isHangul(last) { return false }
        return true
    }

    private static func isHangul(_ scalar: UnicodeScalar) -> Bool {
        (0x1100...0x11FF).contains(scalar.value) || (0x3130...0x318F).contains(scalar.value)
            || (0xAC00...0xD7A3).contains(scalar.value)
            || (0xA960...0xA97F).contains(scalar.value) || (0xD7B0...0xD7FF).contains(scalar.value)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" || text == "\t" {
            commitPending()
            terminal.insertText(text)
            return false
        }
        return true
    }

    func textViewDidEndEditing(_ textView: UITextView) { commitPending() }
    @objc private func commitTapped() { commitPending() }

    func commitPending() {
        guard !committing else { return }
        committing = true
        defer { committing = false }
        // Unmark the native editor before taking its final text; callbacks can
        // be reentrant, hence the guard. Clear only at an explicit boundary.
        input.unmarkText()
        let text = input.text ?? ""
        // Remove provisional ink before any synchronous local or remote echo.
        input.displayedPreeditSelection = nil
        terminal.setExternalPreedit("", selectedRange: NSRange(location: 0, length: 0))
        guard !text.isEmpty else { return }
        input.text = ""
        commitButton.isEnabled = false
        terminal.insertText(text.precomposedStringWithCanonicalMapping)
    }

    func close() {
        // Teardown ends the session; discard a local draft instead of submitting it.
        committing = true
        input.delegate = nil
        input.resignFirstResponder()
        input.displayedPreeditSelection = nil
        terminal.setExternalPreedit("", selectedRange: NSRange(location: 0, length: 0))
        terminal.onInputCursorChanged = nil
        terminal.pressesCancelled([], with: nil)
        terminal.updateUiClosed()
        terminal.externalInputCommit = nil
        terminal.externalInputKeyboardToggle = nil
    }
}

final class InputRoutedTerminalView: SwiftTerm.TerminalView {
    weak var inputReceiver: UITextView?
    override var canBecomeFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { inputReceiver?.becomeFirstResponder() ?? false }
}

final class TerminalTextView: UITextView {
    weak var owner: NativeTerminalInputView?
    weak var terminal: SwiftTerm.TerminalView?
    private var terminalPresses = Set<UIPress>()
    fileprivate var displayedPreeditSelection: NSRange?

    private func displayedCaretRect(for position: UITextPosition) -> CGRect? {
        // UIKit still owns its document, marked range and selection. Only the
        // current insertion-point geometry follows the cell-aligned preview:
        // the native field's narrow first line cannot model terminal wrapping
        // or the preview's upward shift at the bottom of the viewport.
        guard let terminal, let displayedPreeditSelection,
              displayedPreeditSelection == selectedRange,
              let selection = selectedTextRange,
              compare(position, to: selection.end) == .orderedSame,
              !text.isEmpty, terminal.externalPreeditText == text else { return nil }
        let caret = terminal.externalPreeditCaretRect
        guard !caret.isNull else { return nil }
        return terminal.convert(caret, to: self)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        if let caret = displayedCaretRect(for: position) { return caret }
        return super.caretRect(for: position)
    }

    override func firstRect(for range: UITextRange) -> CGRect {
        // A nonempty range asks for its first-line enclosure, not its trailing
        // caret. Preserve UIKit's range semantics until the renderer provides
        // range geometry; never substitute a fabricated selection rectangle.
        if range.isEmpty, let caret = displayedCaretRect(for: range.end) { return caret }
        return super.firstRect(for: range)
    }

    override func paste(_ sender: Any?) {
        owner?.commitPending()
        terminal?.paste(sender)
    }

    override func deleteBackward() {
        owner?.traceInput("deleteBackward text=\(text.debugDescription) marked=\(String(describing: markedTextRange))")
        if text.isEmpty && markedTextRange == nil { terminal?.deleteBackward() }
        else { super.deleteBackward() }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        for scalar in "abcdefghijklmnopqrstuvwxyz" {
            let command = UIKeyCommand(input: String(scalar), modifierFlags: .control,
                                       action: #selector(controlChord(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    @objc private func controlChord(_ command: UIKeyCommand) {
        guard let key = command.input else { return }
        owner?.traceInput("controlChord key=\(key)")
        owner?.commitPending()
        terminal?.controlModifier = true
        terminal?.insertText(key)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var textPresses = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                owner?.traceInput("press withoutKey type=\(press.type.rawValue) eventFlags=\(event?.modifierFlags.rawValue ?? 0)")
                textPresses.insert(press)
                continue
            }
            owner?.traceInput("press keyCode=\(key.keyCode.rawValue) chars=\(key.characters.debugDescription) flags=\(key.modifierFlags.rawValue) language=\(textInputMode?.primaryLanguage ?? "nil")")
            let special = Self.routesToTerminal(keyCode: key.keyCode, modifiers: key.modifierFlags,
                                                hasMarkedText: markedTextRange != nil,
                                                optionAsMetaKey: terminal?.optionAsMetaKey == true)
            if special {
                owner?.traceInput("route=terminal")
                owner?.commitPending()
                terminalPresses.insert(press)
                terminal?.pressesBegan([press], with: event)
            } else {
                owner?.traceInput("route=native")
                textPresses.insert(press)
            }
        }
        if !textPresses.isEmpty { super.pressesBegan(textPresses, with: event) }
    }

    static func routesToTerminal(keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags,
                                 hasMarkedText: Bool, optionAsMetaKey: Bool) -> Bool {
        guard !hasMarkedText else { return false }
        // iPadOS uses Ctrl+Space to change input languages. Preserve Shift
        // variants too, rather than treating them as terminal control bytes.
        // Encoding this as a terminal Ctrl+Space (NUL) traps the native editor
        // in its current layout, so Korean keystrokes arrive as Latin letters.
        if keyCode == .keyboardSpacebar, modifiers.contains(.control),
           !modifiers.contains(.alternate), !modifiers.contains(.command) {
            return false
        }
        switch keyCode {
            // A modifier alone is not a command or a composition boundary.
            // UIKit needs the complete down/change/up lifecycle to maintain it.
            case .keyboardLeftControl, .keyboardRightControl, .keyboardLeftShift, .keyboardRightShift,
                 .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI,
                 .keyboardCapsLock, .keyboardLockingCapsLock:
                return false
            case .keyboardEscape, .keyboardTab, .keyboardUpArrow, .keyboardDownArrow,
                 .keyboardLeftArrow, .keyboardRightArrow, .keyboardHome, .keyboardEnd,
                 .keyboardPageUp, .keyboardPageDown, .keyboardDeleteForward,
                 .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5,
                 .keyboardF6, .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10,
                 .keyboardF11, .keyboardF12:
                return true
            default:
                return modifiers.contains(.control) || (modifiers.contains(.alternate) && optionAsMetaKey)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Send each release to the responder that received its press. A native
        // Shift/letter release must not also run SwiftTerm's responder chain or
        // produce an unmatched Kitty key-release event while text is composing.
        let forwarded = presses.intersection(terminalPresses)
        terminalPresses.subtract(presses)
        let native = presses.subtracting(forwarded)
        if !forwarded.isEmpty { terminal?.pressesEnded(forwarded, with: event) }
        if !native.isEmpty { super.pressesEnded(native, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let forwarded = presses.intersection(terminalPresses)
        terminalPresses.subtract(presses)
        let native = presses.subtracting(forwarded)
        if !forwarded.isEmpty { terminal?.pressesCancelled(forwarded, with: event) }
        if !native.isEmpty { super.pressesCancelled(native, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            owner?.traceInput("pressChanged key=\(press.key?.keyCode.rawValue ?? 0) flags=\(press.key?.modifierFlags.rawValue ?? 0) eventFlags=\(event?.modifierFlags.rawValue ?? 0)")
        }
        let native = presses.subtracting(terminalPresses)
        if !native.isEmpty { super.pressesChanged(native, with: event) }
    }
}
