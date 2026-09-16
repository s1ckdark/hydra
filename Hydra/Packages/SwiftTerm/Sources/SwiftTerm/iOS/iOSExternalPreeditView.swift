#if os(iOS) || os(visionOS)
import UIKit
import CoreText

extension TerminalView {
    /// The native editor's provisional text. This is never part of the terminal
    /// buffer, scrollback, accessibility transcript, or outgoing terminal bytes.
    public var externalPreeditText: String { externalPreeditStorage }

    /// Normal terminal cell metrics (double-width DEC lines are handled by the
    /// preview renderer itself).
    public var inputCellSize: CGSize {
        CGSize(width: cellDimension.width, height: cellDimension.height)
    }

    /// Restore the live iOS input viewport after the user scrolls through old
    /// output. UIScrollView's contentOffset can change independently of the
    /// emulator's yDisp, so the generic scroll(toPosition:) is insufficient.
    public func revealInputCursor() {
        ensureCaretIsVisible()
        updateExternalPreeditDisplay()
    }

    /// The terminal input cursor in this scroll view's local coordinate system,
    /// including the scrollable content offset. Convert with `convert(_:to:)`
    /// before placing an input surface in a host view. The rect may be offscreen.
    public var inputCursorRect: CGRect {
        guard let terminal else { return .null }
        let buffer = terminal.displayBuffer
        let row = buffer.yBase + buffer.y
        guard row >= 0, row < buffer.lines.count else { return .null }
        let multiplier: CGFloat = buffer.lines[row].renderMode == .single ? 1 : 2
        return CGRect(x: CGFloat(buffer.x) * cellDimension.width * multiplier,
                      y: CGFloat(row) * cellDimension.height,
                      width: cellDimension.width * multiplier,
                      height: cellDimension.height)
    }

    /// The provisional selection caret in the same coordinates as
    /// `inputCursorRect`, or `.null` when there is no visible preview.
    public var externalPreeditCaretRect: CGRect {
        guard let preview = externalPreeditView, !preview.isHidden else { return .null }
        return preview.layout.caret.offsetBy(dx: preview.frame.minX, dy: preview.frame.minY)
    }

    /// Displays a native editor's draft at the terminal cursor. `selectedRange`
    /// uses UTF-16 offsets into `text`, just like UITextView. No text is fed or
    /// sent to the terminal; the host remains responsible for committing input.
    ///
    /// Preview wraps at terminal columns. At the viewport bottom only the
    /// preview shifts upward to keep the selected caret visible, temporarily
    /// covering preceding output; the actual terminal and scroll position do
    /// not move. Long drafts draw only the visible rows. Scrolling away from
    /// the live cursor hides the preview rather than creating a shadow cursor.
    /// A remote application's hidden cursor does not hide native composition:
    /// the preview caret is local input feedback, independent of DECTCEM.
    public func setExternalPreedit(_ text: String, selectedRange: NSRange) {
        externalPreeditStorage = text
        let length = text.utf16.count
        let start = min(max(0, selectedRange.location), length)
        externalPreeditSelection = NSRange(location: start,
                                          length: min(max(0, selectedRange.length), length - start))
        updateExternalPreeditDisplay()
    }

    func updateExternalPreeditDisplay() {
        guard !updatingExternalPreedit, let terminal else { return }
        updatingExternalPreedit = true
        defer { updatingExternalPreedit = false }

        let anchor = inputCursorRect
        let hasDraft = !externalPreeditStorage.isEmpty
        // Metal paints its own cursor; the preview's anchor-cell background
        // also covers that cursor while a provisional draft is visible.
        #if canImport(MetalKit)
        caretView?.isHidden = hasDraft || isUsingMetalRenderer
        #else
        caretView?.isHidden = hasDraft
        #endif

        if !hasDraft {
            externalPreeditView?.removeFromSuperview()
            externalPreeditView = nil
        } else if anchor.isNull ||
                    anchor.maxY <= bounds.minY || anchor.minY >= bounds.maxY ||
                    bounds.width <= 0 || bounds.height < cellDimension.height {
            externalPreeditView?.isHidden = true
        } else {
            let preview: ExternalPreeditView
            if let existing = externalPreeditView {
                preview = existing
            } else {
                preview = ExternalPreeditView(frame: bounds)
                externalPreeditView = preview
                addSubview(preview)
            }
            preview.frame = bounds
            preview.isHidden = false
            let cell = CGSize(width: anchor.width, height: cellDimension.height)
            let columns = max(1, Int(floor(CGFloat(terminal.cols) * cellDimension.width / cell.width)))
            let localAnchor = anchor.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            preview.layout = ExternalPreeditLayout.make(
                text: externalPreeditStorage, selectedRange: externalPreeditSelection,
                columns: columns, cell: cell, anchor: localAnchor.origin,
                viewport: bounds.size)
            preview.anchor = localAnchor
            preview.font = font
            preview.horizontalScale = anchor.width / cellDimension.width
            preview.foreground = nativeForegroundColor
            // setup() moves the terminal background to its CALayer and changes
            // nativeBackgroundColor to .clear. A clear cell cannot cover a
            // previous glyph or a GPU cursor, so use that actual layer color.
            let configured = nativeBackgroundColor ?? .clear
            let background = configured.cgColor.alpha > 0 ? configured :
                layer.backgroundColor.map(UIColor.init(cgColor:)) ?? .black
            preview.cellBackground = background.withAlphaComponent(1)
            preview.caretColor = caretColor
            preview.setNeedsDisplay()
            bringSubviewToFront(preview)
        }

        let geometry = [anchor, externalPreeditCaretRect, bounds]
        if geometry != lastInputCursorGeometry {
            lastInputCursorGeometry = geometry
            // Hosts should weakly capture themselves and schedule layout, not
            // synchronously mutate the terminal from this notification.
            onInputCursorChanged?()
        }
    }
}

/// A bounded display list, independent of the terminal buffer and input APIs.
struct ExternalPreeditLayout {
    struct Glyph {
        let text: String
        let rect: CGRect
    }
    var glyphs: [Glyph] = []
    var caret = CGRect.null

    static func columnWidth(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        var width = scalars.reduce(0) { max($0, UnicodeUtil.columnWidth(rune: $1)) }
        if let base = scalars.first, UnicodeUtil.isEmojiVs16Base(rune: base) {
            if scalars.contains(where: { $0.value == 0xFE0F }) { width = 2 }
            if scalars.contains(where: { $0.value == 0xFE0E }) { width = 1 }
        }
        // An isolated combining/control character still needs a visible cell;
        // normal combining sequences stay inside their grapheme's base cell.
        return max(1, width)
    }

    static func make(text: String, selectedRange: NSRange, columns: Int,
                     cell: CGSize, anchor: CGPoint, viewport: CGSize) -> Self {
        guard columns > 0, cell.width > 0, cell.height > 0 else { return Self() }
        let initialColumn = min(columns, max(0, Int(round(anchor.x / cell.width))))
        let target = min(text.utf16.count, selectedRange.location + selectedRange.length)

        // Walk twice: first locate the UTF-16 selection, then retain only glyphs
        // in the visible window. A very long draft cannot grow the display list
        // beyond the viewport's cell count.
        func walk(_ visit: (String, Int, Int, Int, Int, Int) -> Bool) {
            var row = 0
            var column = initialColumn
            var offset = 0
            for character in text {
                let value = String(character)
                let end = offset + value.utf16.count
                if character == "\n" || value == "\r\n" {
                    if !visit(value, row, column, 0, offset, end) { return }
                    row += 1
                    column = 0
                } else if character == "\r" {
                    if !visit(value, row, column, 0, offset, end) { return }
                    column = 0
                } else {
                    let width = min(columns, columnWidth(of: character))
                    if column + width > columns { row += 1; column = 0 }
                    if !visit(value, row, column, width, offset, end) { return }
                    column += width
                }
                offset = end
            }
            _ = visit("", row, column, 0, offset, offset)
        }

        var caretRow = 0
        var caretColumn = initialColumn
        walk { value, row, column, width, start, end in
            if target <= start {
                caretRow = row; caretColumn = column
                return false
            }
            if target <= end {
                if value == "\n" || value == "\r\n" {
                    caretRow = row + 1; caretColumn = 0
                } else if value == "\r" {
                    caretRow = row; caretColumn = 0
                } else {
                    caretRow = row; caretColumn = column + width
                }
                return false
            }
            return true
        }
        if caretColumn >= columns { caretRow += 1; caretColumn = 0 }
        let bottomRow = max(0, Int(floor((viewport.height - anchor.y) / cell.height)) - 1)
        let shift = max(0, caretRow - bottomRow)
        let top = anchor.y - CGFloat(shift) * cell.height
        var result = Self()
        result.caret = CGRect(x: CGFloat(caretColumn) * cell.width,
                              y: top + CGFloat(caretRow) * cell.height,
                              width: min(2, cell.width), height: cell.height)
        walk { value, row, column, width, _, _ in
            let y = top + CGFloat(row) * cell.height
            if y >= viewport.height { return false }
            if width > 0, y + cell.height > 0 {
                let printable = value.unicodeScalars.contains(where: {
                    UnicodeUtil.columnWidth(rune: $0) < 0
                }) ? "�" : value
                result.glyphs.append(Glyph(text: printable,
                    rect: CGRect(x: CGFloat(column) * cell.width, y: y,
                                 width: CGFloat(width) * cell.width, height: cell.height)))
            }
            return true
        }
        return result
    }
}

final class ExternalPreeditView: UIView {
    var layout = ExternalPreeditLayout()
    var anchor = CGRect.zero
    var font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var horizontalScale: CGFloat = 1
    var foreground = UIColor.label
    var cellBackground = UIColor.black
    var caretColor = UIColor.systemBlue

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // UIKit clears this transparent backing store before a full redraw;
        // shortening a draft therefore cannot leave glyphs in unused cells.
        context.setFillColor(cellBackground.cgColor)
        context.fill(anchor)
        for glyph in layout.glyphs { context.fill(glyph.rect) }
        let yOffset = ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
        for glyph in layout.glyphs {
            context.saveGState()
            context.clip(to: glyph.rect)
            context.translateBy(x: glyph.rect.minX, y: glyph.rect.maxY - yOffset)
            context.scaleBy(x: horizontalScale, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            let text = NSAttributedString(string: glyph.text,
                attributes: [.font: font, .foregroundColor: foreground])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.restoreGState()
            context.setFillColor(caretColor.withAlphaComponent(0.55).cgColor)
            context.fill(CGRect(x: glyph.rect.minX, y: glyph.rect.maxY - 1,
                                width: glyph.rect.width, height: 1))
        }
        if !layout.caret.isNull {
            context.setFillColor(caretColor.cgColor)
            context.fill(layout.caret)
        }
    }
}
#endif
