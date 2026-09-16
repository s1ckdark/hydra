#if DEBUG && os(iOS)
import SwiftUI
import SwiftTerm

/// Manual comparison with no key observers, live snapshots, or typing logs.
struct CleanKeyboardComparisonScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController {
        private enum Mode: Int, CaseIterable {
            case plain, terminalTraits, terminal
            var title: String {
                switch self {
                case .plain: return "A 기본"
                case .terminalTraits: return "B 입력 설정"
                case .terminal: return "C 터미널"
                }
            }
        }

        private struct Sample: Codable {
            let mode: String
            let text: String
            let inputLanguage: String?
            let outgoingUTF8: String?
            let outgoingBytes: [UInt8]?
            let inlinePreedit: String?
            let timestamp: Date
        }

        private let plain = UITextView(frame: .zero)
        private let withTerminalTraits = UITextView(frame: .zero)
        private var nativeTerminal: NativeTerminalInputView?
        private let recorder = Recorder()
        private var mode = Mode.plain
        private var samples: [Int: Sample] = [:]
        private let surface = UIView()
        private let modeDescription = UILabel()
        private let result = UILabel()
        private let inputLanguageResult = UILabel()
        private let outgoingResult = UILabel()
        private var activeView: UIView?
        private var previousIdleTimerDisabled = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            plain.accessibilityIdentifier = "cleanKeyboardPlain"
            withTerminalTraits.accessibilityIdentifier = "cleanKeyboardTerminalTraits"
            withTerminalTraits.autocapitalizationType = .none
            withTerminalTraits.autocorrectionType = .no
            withTerminalTraits.spellCheckingType = .no
            withTerminalTraits.smartQuotesType = .no
            withTerminalTraits.smartDashesType = .no
            withTerminalTraits.smartInsertDeleteType = .no

            let prompt = UILabel()
            prompt.text = "같은 외장 키보드로 입력: 어떨까? / English ER?"
            prompt.numberOfLines = 0
            let selector = UISegmentedControl(items: Mode.allCases.map(\.title))
            selector.accessibilityIdentifier = "cleanKeyboardModeSelector"
            selector.selectedSegmentIndex = mode.rawValue
            selector.addTarget(self, action: #selector(changeMode(_:)), for: .valueChanged)
            let save = UIButton(type: .system)
            save.setTitle("결과 저장", for: .normal)
            save.accessibilityIdentifier = "cleanKeyboardSave"
            save.addTarget(self, action: #selector(saveResult), for: .touchUpInside)
            save.setContentHuggingPriority(.required, for: .horizontal)
            save.setContentCompressionResistancePriority(.required, for: .horizontal)
            result.numberOfLines = 4
            result.font = .preferredFont(forTextStyle: .footnote)
            result.text = "입력을 마친 뒤 결과 저장을 눌러주세요."
            result.accessibilityIdentifier = "cleanKeyboardResult"
            inputLanguageResult.font = .preferredFont(forTextStyle: .footnote)
            inputLanguageResult.text = "저장 시 입력 언어: --"
            inputLanguageResult.accessibilityIdentifier = "cleanKeyboardInputLanguage"
            inputLanguageResult.accessibilityValue = "--"
            outgoingResult.font = .preferredFont(forTextStyle: .footnote)
            outgoingResult.numberOfLines = 2
            outgoingResult.text = "저장된 전송 바이트: --"
            outgoingResult.accessibilityIdentifier = "cleanKeyboardOutgoing"
            outgoingResult.accessibilityValue = "--"
            modeDescription.numberOfLines = 0
            modeDescription.font = .preferredFont(forTextStyle: .footnote)

            // Keep the actions above the editor. A growing byte/result label
            // must never compress Save to zero height in landscape + keyboard.
            let controls = UIStackView(arrangedSubviews: [selector, save])
            controls.alignment = .center
            controls.spacing = 12
            let details = UIStackView(arrangedSubviews: [inputLanguageResult, outgoingResult, result, modeDescription])
            details.axis = .vertical
            details.spacing = 6
            details.translatesAutoresizingMaskIntoConstraints = false
            let detailsScroll = UIScrollView()
            detailsScroll.accessibilityIdentifier = "cleanKeyboardDetails"
            detailsScroll.addSubview(details)
            // Let this informational area shrink and scroll before sacrificing
            // either keyboard controls or the terminal viewport.
            let preferredDetailsHeight = detailsScroll.heightAnchor.constraint(equalToConstant: 120)
            preferredDetailsHeight.priority = .defaultLow
            let stack = UIStackView(arrangedSubviews: [prompt, controls, surface, detailsScroll])
            stack.axis = .vertical
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
                selector.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
                save.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                save.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
                surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
                detailsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
                preferredDetailsHeight,
                details.leadingAnchor.constraint(equalTo: detailsScroll.contentLayoutGuide.leadingAnchor),
                details.trailingAnchor.constraint(equalTo: detailsScroll.contentLayoutGuide.trailingAnchor),
                details.topAnchor.constraint(equalTo: detailsScroll.contentLayoutGuide.topAnchor),
                details.bottomAnchor.constraint(equalTo: detailsScroll.contentLayoutGuide.bottomAnchor),
                details.widthAnchor.constraint(equalTo: detailsScroll.frameLayoutGuide.widthAnchor)
            ])
            showMode()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            focusCurrentEditor()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }

        @objc private func changeMode(_ sender: UISegmentedControl) {
            guard let next = Mode(rawValue: sender.selectedSegmentIndex), next != mode else { return }
            if mode == .terminal, let nativeTerminal {
                // Preserve the draft when changing comparison panels. The
                // normal terminal end-editing delegate would submit it here.
                nativeTerminal.input.delegate = nil
                nativeTerminal.input.resignFirstResponder()
                nativeTerminal.terminal.pressesCancelled([], with: nil)
            } else {
                activeView?.resignFirstResponder()
            }
            mode = next
            showMode()
            focusCurrentEditor()
        }

        private func showMode() {
            activeView?.removeFromSuperview()
            let next: UIView
            switch mode {
            case .plain:
                next = plain
                modeDescription.text = "A: 입력 설정을 바꾸지 않은 기본 UIKit 편집기"
            case .terminalTraits:
                next = withTerminalTraits
                modeDescription.text = "B: 자동 수정 등 입력 설정 6개만 바꾼 UIKit 편집기"
            case .terminal:
                modeDescription.text = "C: 실시간 인라인 표시·로컬 에코 (SSH 미연결). 한글은 커서에 즉시 표시되며, 공백·문장부호 등에서 전송됩니다."
                // A/B's initial comparison creates no SwiftTerm objects or
                // terminal observers. C is constructed only when selected.
                if nativeTerminal == nil {
                    let terminal = NativeTerminalInputView(frame: .zero)
                    // Test-only steady caret allows XCUITest idle detection.
                    terminal.terminal.feed(text: "\u{1b}[2 q")
                    terminal.terminal.terminalDelegate = recorder
                    nativeTerminal = terminal
                }
                let terminal = nativeTerminal!
                terminal.input.delegate = terminal
                next = terminal
            }
            activeView = next
            next.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(next)
            NSLayoutConstraint.activate([
                next.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                next.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                next.topAnchor.constraint(equalTo: surface.topAnchor),
                next.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
            ])
        }

        private func focusCurrentEditor() {
            switch mode {
            case .plain: plain.becomeFirstResponder()
            case .terminalTraits: withTerminalTraits.becomeFirstResponder()
            case .terminal: nativeTerminal?.focusInput()
            }
        }

        @objc private func saveResult() {
            let editor: UITextView?
            switch mode {
            case .plain: editor = plain
            case .terminalTraits: editor = withTerminalTraits
            case .terminal: editor = nativeTerminal?.input
            }
            let text = editor?.text ?? ""
            let inputLanguage = editor?.textInputMode?.primaryLanguage
            let outgoing = mode == .terminal ? recorder.bytes : nil
            let sample = Sample(mode: mode.title, text: text, inputLanguage: inputLanguage,
                                outgoingUTF8: outgoing.map { String(decoding: $0, as: UTF8.self) },
                                outgoingBytes: outgoing,
                                inlinePreedit: mode == .terminal ? nativeTerminal?.terminal.externalPreeditText : nil,
                                timestamp: Date())
            samples[mode.rawValue] = sample
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("clean-keyboard-comparison.json")
                let ordered = Mode.allCases.compactMap { samples[$0.rawValue] }
                try encoder.encode(ordered).write(to: url, options: .atomic)
                inputLanguageResult.text = "저장 시 입력 언어: \(inputLanguage ?? "--")"
                inputLanguageResult.accessibilityValue = inputLanguage ?? "--"
                let savedBytes = outgoing.map { String(describing: $0) } ?? "해당 없음"
                outgoingResult.text = "저장된 전송 바이트: \(savedBytes)"
                outgoingResult.accessibilityValue = savedBytes
                if let outgoingText = sample.outgoingUTF8 {
                    result.text = "저장됨 · \(mode.title)\n편집기 초안: \(text.debugDescription)\n터미널 전송: \(outgoingText.debugDescription)"
                } else {
                    result.text = "저장됨 · \(mode.title)\n편집기: \(text.debugDescription)"
                }
                // User-triggered, app-only screenshot: no keyboard observer or
                // continuous recording, and no unrelated device UI is captured.
                view.layoutIfNeeded()
                let screenshot = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                    view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                }
                try screenshot.pngData()?.write(to: url.deletingLastPathComponent()
                    .appendingPathComponent("clean-keyboard-comparison.png"), options: .atomic)
            } catch {
                result.text = "결과 저장 실패: \(error.localizedDescription)"
            }
        }

        func close() {
            nativeTerminal?.close()
            nativeTerminal = nil
        }
    }

    static func dismantleUIViewController(_ uiViewController: Controller, coordinator: ()) {
        uiViewController.close()
    }

    private final class Recorder: NSObject, TerminalViewDelegate {
        var bytes: [UInt8] = []
        private var echoedCellWidths: [Int] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // The saved sample is the exact outgoing stream, independent of
            // the line-discipline echo used solely for this local comparison.
            bytes.append(contentsOf: data)
            MainActor.assumeIsolated {
                for character in String(decoding: data, as: UTF8.self) {
                    if character == "\r" || character == "\n" || character == "\r\n" {
                        source.feed(text: "\r\n")
                        echoedCellWidths.removeAll()
                    } else if character == "\u{7f}" || character == "\u{08}" {
                        let width = echoedCellWidths.popLast() ?? 0
                        for _ in 0..<width { source.feed(text: "\u{08} \u{08}") }
                    } else {
                        // Show other controls as caret notation. Sending an
                        // outgoing escape sequence back as terminal output
                        // would move the cursor and create misleading overlap.
                        let display: String
                        if let scalar = character.unicodeScalars.first, scalar.value < 0x20 {
                            display = "^" + String(UnicodeScalar(scalar.value + 0x40)!)
                        } else {
                            display = String(character)
                        }
                        let terminal = source.getTerminal()
                        let before = terminal.getCursorLocation()
                        source.feed(text: display)
                        let after = terminal.getCursorLocation()
                        let advance = (after.x - before.x + terminal.cols) % terminal.cols
                        echoedCellWidths.append(min(2, advance))
                    }
                }
            }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }
}
#endif
