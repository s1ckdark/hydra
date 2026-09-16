import XCTest
import UIKit
@testable import SwiftTerm

@MainActor
final class TerminalRenderingTests: XCTestCase {
    func testDeletedLatinThenKoreanMatchesFreshRendering() async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 240))
        let reference = TerminalView(frame: view.frame)
        defer { view.updateUiClosed(); reference.updateUiClosed() }
        print("RENDER_CONFIGURATION opaque=\(view.isOpaque) clears=\(view.clearsContextBeforeDrawing) background=\(String(describing: view.nativeBackgroundColor))")
        view.feed(text: "\u{1b}[?25l")
        reference.feed(text: "\u{1b}[?25l")
        let empty = try await snapshot(view, name: "empty")
        let emptyData = try XCTUnwrap(empty.pngData())
        view.feed(text: "dj")
        let latin = try await snapshot(view, name: "latin-before-delete")
        XCTAssertNotEqual(try XCTUnwrap(latin.pngData()), emptyData)
        view.feed(text: "\u{08} \u{08}\u{08} \u{08}")
        let erased = try await snapshot(view, name: "erased-latin")
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true).trimmingCharacters(in: .whitespaces), "")
        XCTAssertEqual(try XCTUnwrap(erased.pngData()), emptyData, "Deleting the two Latin cells must also erase their pixels.")

        let text = "어떨까? English ER?"
        view.feed(text: text)
        reference.feed(text: text)
        let actual = try await snapshot(view, name: "korean-after-latin-delete")
        let expected = try await snapshot(reference, name: "fresh-korean-reference")
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true), text)
        let expectedData = try XCTUnwrap(expected.pngData())
        XCTAssertNotEqual(expectedData, emptyData, "A blank renderer must not pass this comparison.")
        XCTAssertEqual(try XCTUnwrap(actual.pngData()), expectedData, "The final pixels must not retain previously deleted Latin glyphs.")
    }

    func testEraseLineAndRedrawDoesNotRestoreEarlierFrames() async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 240))
        let reference = TerminalView(frame: view.frame)
        defer { view.updateUiClosed(); reference.updateUiClosed() }
        view.feed(text: "\u{1b}[?25l")
        reference.feed(text: "\u{1b}[?25l")
        _ = try await snapshot(view, name: "line-erase-empty")
        for text in ["dj", "어떨까? English ER?", "x", "돼 왜 의"] {
            // A shell redraw uses CR + EL, unlike the local comparison's
            // backspace/space echo. Both paths share the same UIKit renderer.
            view.feed(text: "\r\u{1b}[2K" + text)
            reference.feed(text: "\r\u{1b}[2K" + text)
            let actual = try await snapshot(view, name: "line-redraw-\(text)")
            // Force a fresh reference backing store so retained old pixels
            // cannot make both sides fail in the same way.
            reference.layer.contents = nil
            let expected = try await snapshot(reference, name: "line-reference-\(text)")
            XCTAssertEqual(try XCTUnwrap(actual.pngData()), try XCTUnwrap(expected.pngData()), "CR/EL redraw must clear every older frame: \(text)")
        }
    }

    private func snapshot(_ view: TerminalView, name: String) async throws -> UIImage {
        view.layoutIfNeeded()
        view.setNeedsDisplay()
        try await Task.sleep(nanoseconds: 50_000_000)
        view.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}
