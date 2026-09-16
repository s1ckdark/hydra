import XCTest
import UIKit
@testable import HydraiOS

@MainActor
final class CleanKeyboardLayoutTests: XCTestCase {
    func testCompactHeightKeepsModeAndSaveUsableAfterTerminalResultsExpand() throws {
        let controller = CleanKeyboardComparisonScreen.Controller()
        controller.loadViewIfNeeded()
        // Available content above a landscape software keyboard. This test
        // deliberately does not create a keyboard or synthesize input events.
        controller.view.frame = CGRect(x: 0, y: 0, width: 1080, height: 300)
        defer { controller.close() }
        // A detached UIKeyboardLayoutGuide has no actual window/keyboard
        // geometry. Bind the existing content bottom, with its original inset,
        // to this fixture's already-available viewport instead. Physical UI
        // rotation tests separately exercise the real keyboard layout guide.
        let keyboardGuide = controller.view.keyboardLayoutGuide
        let keyboardBottomConstraints = controller.view.constraints.filter {
            ($0.secondItem as? UILayoutGuide) === keyboardGuide
                && $0.firstAttribute == .bottom && $0.secondAttribute == .top
        }
        XCTAssertEqual(keyboardBottomConstraints.count, 1)
        let keyboardBottom = try XCTUnwrap(keyboardBottomConstraints.first)
        let content = try XCTUnwrap(keyboardBottom.firstItem as? UIView)
        keyboardBottom.isActive = false
        content.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor,
                                        constant: keyboardBottom.constant).isActive = true

        let selector = try XCTUnwrap(find("cleanKeyboardModeSelector", in: controller.view) as? UISegmentedControl)
        selector.selectedSegmentIndex = 2
        selector.sendActions(for: .valueChanged)
        let terminal = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? NativeTerminalInputView }.first)
        let save = try XCTUnwrap(find("cleanKeyboardSave", in: controller.view) as? UIButton)
        terminal.input.text = String(repeating: "어떨까? English ER? ", count: 12)
        terminal.commitPending()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(content.frame.maxY, controller.view.bounds.maxY + keyboardBottom.constant, accuracy: 0.5)
        save.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()

        let result = try XCTUnwrap(find("cleanKeyboardResult", in: controller.view) as? UILabel)
        XCTAssertTrue(result.text?.hasPrefix("저장됨") == true)
        assertUsable(selector, in: controller.view, minimumHeight: 28)
        assertUsable(save, in: controller.view, minimumHeight: 24)
        assertUsable(terminal, in: controller.view, minimumHeight: 100)
        let details = try XCTUnwrap(find("cleanKeyboardDetails", in: controller.view) as? UIScrollView)
        assertUsable(details, in: controller.view, minimumHeight: 1)
        XCTAssertGreaterThan(details.contentSize.height, details.bounds.height,
                             "The expanded result must remain available by scrolling.")

        // The original failure appeared on the second Save, after the first
        // result grew from one line to multiple lines of draft/byte details.
        save.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        assertUsable(save, in: controller.view, minimumHeight: 24)
    }

    private func assertUsable(_ child: UIView, in root: UIView, minimumHeight: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) {
        let frame = child.convert(child.bounds, to: root)
        XCTAssertFalse(child.isHidden, file: file, line: line)
        XCTAssertGreaterThan(child.alpha, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.width, 40, "Control collapsed: \(frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, minimumHeight, "Control collapsed: \(frame)", file: file, line: line)
        XCTAssertTrue(root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                      "Control left the available area: \(frame), bounds: \(root.bounds)", file: file, line: line)
    }

    private func find(_ identifier: String, in root: UIView) -> UIView? {
        descendants(of: root).first { $0.accessibilityIdentifier == identifier }
    }

    private func descendants(of root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { descendants(of: $0) }
    }
}
