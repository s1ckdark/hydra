#if DEBUG && os(iOS)
import SwiftUI
import SwiftTerm
import GameController

/// Device-only test surface for exercising the real system keyboard and the
/// same SwiftTerm view used by TerminalScreen, without requiring SSH.
struct TerminalInputHarnessScreen: View {
    @State private var sentText = ""
    private let usesNativeBaseline = ProcessInfo.processInfo.arguments.contains("--native-keyboard-baseline")

    var body: some View {
        VStack(spacing: 12) {
            if usesNativeBaseline {
                Text("기본 UIKit 입력 비교 — 외장 키보드로 ‘어떨까?’를 입력하세요")
                    .font(.headline)
            }
            Text(sentText.debugDescription)
                .frame(height: 50)
                .accessibilityIdentifier("terminalInputResult")
            if usesNativeBaseline {
                NativeKeyboardBaselineRepresentable(sentText: $sentText)
            } else {
                TerminalInputHarnessRepresentable(sentText: $sentText)
            }
        }
        .padding()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct TerminalInputHarnessRepresentable: UIViewRepresentable {
    @Binding var sentText: String

    func makeCoordinator() -> Coordinator { Coordinator(sentText: $sentText) }

    func makeUIView(context: Context) -> NativeTerminalInputView {
        let container = NativeTerminalInputView(frame: .zero)
        let view = container.terminal
        view.terminalDelegate = context.coordinator
        // A continuously animated caret prevents XCUITest's idle detection.
        view.feed(text: "\u{1b}[2 q")
        context.coordinator.record("RUN \(Date())")
        context.coordinator.startKeyboardDiagnostics()
        container.onInputSnapshot = { [weak coordinator = context.coordinator] text, marked in
            coordinator?.record("NATIVE text=\(text.debugDescription) marked=\(marked)")
        }
        container.onInputEvent = { [weak coordinator = context.coordinator] event in
            coordinator?.recordInputEvent(event)
        }
        context.coordinator.captureView = container
        DispatchQueue.main.async { container.focusInput() }
        return container
    }

    func updateUIView(_ uiView: NativeTerminalInputView, context: Context) {}
    static func dismantleUIView(_ uiView: NativeTerminalInputView, coordinator: Coordinator) {
        coordinator.stopKeyboardDiagnostics()
        coordinator.captureView = nil
        uiView.close()
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UITextViewDelegate {
        private var bytes: [UInt8] = []
        private var echoedCellWidths: [Int] = []
        private var sentText: Binding<String>
        private var trace: [String] = []
        weak var captureView: UIView?
        private var captureScheduled = false
        private var keyboardDiagnostics: HarnessKeyboardDiagnostics?

        func startKeyboardDiagnostics() {
            // Observing the GameController keyboard is itself an experimental
            // variable. The ordinary diagnostic must exercise UIKit exactly
            // like the production terminal, without accessing GCKeyboard.
            guard ProcessInfo.processInfo.arguments.contains("--observe-hardware-keyboard") else {
                record("GC observation disabled; UIKit-only keyboard diagnostics")
                return
            }
            keyboardDiagnostics = HarnessKeyboardDiagnostics { [weak self] line in
                self?.record(line)
            }
        }

        func stopKeyboardDiagnostics() {
            keyboardDiagnostics?.stop()
            keyboardDiagnostics = nil
        }

        func recordInputEvent(_ event: String) {
            record("\(event) \(keyboardDiagnosticState)")
        }

        private var keyboardDiagnosticState: String {
            guard keyboardDiagnostics != nil else { return "GC disabled" }
            return HarnessKeyboardDiagnostics.snapshot()
        }

        func textViewDidChange(_ textView: UITextView) {
            sentText.wrappedValue = textView.text ?? ""
            recordBaselineSnapshot(textView, event: "change")
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            recordBaselineSnapshot(textView, event: "selection")
        }

        private func recordBaselineSnapshot(_ textView: UITextView, event: String) {
            let marked = textView.markedTextRange.map { textView.text(in: $0) ?? "" }
            record("BASELINE \(event) text=\((textView.text ?? "").debugDescription) marked=\(String(reflecting: marked)) language=\(textView.textInputMode?.primaryLanguage ?? "--") selected=\(textView.selectedRange) \(keyboardDiagnosticState)")
        }

        func record(_ line: String) {
            guard trace.count < 12000 else { return }
            trace.append("\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) \(line)")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("terminal-input-test-trace.txt")
            try? trace.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            if !captureScheduled {
                captureScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self else { return }
                    self.captureScheduled = false
                    guard let view = self.captureView, !view.bounds.isEmpty else { return }
                    let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                    }
                    try? image.pngData()?.write(to: url.deletingLastPathComponent().appendingPathComponent("terminal-input-test-screen.png"), options: .atomic)
                }
            }
        }

        init(sentText: Binding<String>) { self.sentText = sentText }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                bytes.append(contentsOf: data)
                record("PTY: \(Array(data)) text=\(String(decoding: data, as: UTF8.self).debugDescription)")
                sentText.wrappedValue = String(decoding: bytes, as: UTF8.self)
                // Simulate line-discipline echo, not a raw loopback: CR starts
                // a new line and DEL erases the previous displayed character.
                // Otherwise manual Enter/backspace testing leaves old glyphs
                // on screen even when the bytes sent by the input are correct.
                let text = String(decoding: data, as: UTF8.self)
                if text.contains("\u{1b}") {
                    source.feed(byteArray: data)
                    return
                }
                for character in text {
                    if character == "\r" {
                        source.feed(text: "\r\n")
                        echoedCellWidths.removeAll()
                    } else if character == "\u{7f}" || character == "\u{08}" {
                        let width = echoedCellWidths.popLast() ?? 0
                        for _ in 0..<width { source.feed(text: "\u{08} \u{08}") }
                    } else {
                        let terminal = source.getTerminal()
                        let before = terminal.getCursorLocation()
                        source.feed(text: String(character))
                        let after = terminal.getCursorLocation()
                        let advance = (after.x - before.x + terminal.cols) % terminal.cols
                        echoedCellWidths.append(min(2, advance))
                    }
                }
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
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

/// A deliberately ordinary editor: UIKit alone owns key commands and presses.
private struct NativeKeyboardBaselineRepresentable: UIViewRepresentable {
    @Binding var sentText: String

    func makeCoordinator() -> TerminalInputHarnessRepresentable.Coordinator {
        TerminalInputHarnessRepresentable.Coordinator(sentText: $sentText)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        view.backgroundColor = .secondarySystemBackground
        view.textColor = .label
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.accessibilityIdentifier = "nativeKeyboardBaselineInput"
        view.delegate = context.coordinator
        context.coordinator.captureView = view
        context.coordinator.record("RUN \(Date()) mode=plain-UITextView-baseline")
        context.coordinator.startKeyboardDiagnostics()
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}

    static func dismantleUIView(_ uiView: UITextView, coordinator: TerminalInputHarnessRepresentable.Coordinator) {
        uiView.delegate = nil
        uiView.resignFirstResponder()
        coordinator.captureView = nil
        coordinator.stopKeyboardDiagnostics()
    }
}

/// Explicitly opt-in experiment for comparing GC and UIKit delivery. Do not
/// assume installing a global keyboard observer has no effect on native input.
private final class HarnessKeyboardDiagnostics {
    private var input: GCKeyboardInput?
    private var previousHandler: GCKeyboardValueChangedHandler?
    private var observers: [NSObjectProtocol] = []
    private let record: (String) -> Void

    init(record: @escaping (String) -> Void) {
        self.record = record
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] notification in
            self?.attach(notification.object as? GCKeyboard ?? GCKeyboard.coalesced)
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.detach()
            self?.record("GC disconnected")
        })
        attach(GCKeyboard.coalesced)
    }

    static func snapshot() -> String {
        let keyboard = GCKeyboard.coalesced
        return "GC vendor=\(String(reflecting: keyboard?.vendorName)) \(shiftState(keyboard?.keyboardInput))"
    }

    private static func shiftState(_ input: GCKeyboardInput?) -> String {
        let left = input?.button(forKeyCode: .leftShift).map { String($0.isPressed) } ?? "--"
        let right = input?.button(forKeyCode: .rightShift).map { String($0.isPressed) } ?? "--"
        return "leftShift=\(left) rightShift=\(right)"
    }

    private func attach(_ keyboard: GCKeyboard?) {
        guard let newInput = keyboard?.keyboardInput else {
            detach()
            record("GC unavailable")
            return
        }
        guard input !== newInput else { return }
        detach()
        input = newInput
        let priorHandler = newInput.keyChangedHandler
        previousHandler = priorHandler
        let vendor = String(reflecting: keyboard?.vendorName)
        newInput.keyChangedHandler = { [weak self] input, key, code, pressed in
            let time = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            let line = "GC key=\(code.rawValue) pressed=\(pressed) vendor=\(vendor) \(Self.shiftState(input)) eventTime=\(time)"
            priorHandler?(input, key, code, pressed)
            DispatchQueue.main.async { [weak self] in self?.record(line) }
        }
        record("GC attached vendor=\(vendor) \(Self.shiftState(newInput))")
    }

    private func detach() {
        input?.keyChangedHandler = previousHandler
        input = nil
        previousHandler = nil
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        detach()
    }

    deinit { stop() }
}
#endif
