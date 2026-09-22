#if canImport(SwiftTerm)
import CoreGraphics
import SwiftTerm

extension TerminalSettings {
    var swiftTermCursor: CursorStyle {
        switch cursor {
        case .blinkBlock: return .blinkBlock
        case .steadyBlock: return .steadyBlock
        case .blinkUnderline: return .blinkUnderline
        case .steadyUnderline: return .steadyUnderline
        case .blinkBar: return .blinkBar
        case .steadyBar: return .steadyBar
        }
    }

    /// `previous`와 비교해 바뀐 항목만 적용한다. 폰트 교체는 SwiftTerm의 cols/rows 재계산과
    /// sizeChanged(→ 원격 PTY resize)를 일으키므로 같은 값이면 건드리지 않는다.
    func apply(to view: SwiftTerm.TerminalView, previous: TerminalSettings?) {
        if previous?.colorSchemeID != colorSchemeID {
            TerminalColorScheme.find(id: colorSchemeID).apply(to: view)
        }
        if previous?.fontName != fontName || previous?.fontSize != fontSize {
            view.font = TerminalFontCatalog.resolve(fontName, size: CGFloat(fontSize)).font
        }
        if previous?.cursor != cursor {
            view.getTerminal().setCursorStyle(swiftTermCursor)
        }
        if previous?.scrollback != scrollback {
            view.changeScrollback(scrollback)
        }
    }
}
#endif
