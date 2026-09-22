#if canImport(SwiftTerm)
import SwiftTerm
#if canImport(UIKit)
import UIKit
typealias TerminalPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias TerminalPlatformColor = NSColor
#endif

extension TerminalColorScheme {
    /// SwiftTerm 채널은 16비트 — 8비트 값에 257을 곱해 0xFF → 0xFFFF로 맞춘다.
    static func swiftTermColor(_ hex: UInt32) -> SwiftTerm.Color {
        let c = rgbComponents(hex)
        return SwiftTerm.Color(red: UInt16(c.r) * 257, green: UInt16(c.g) * 257, blue: UInt16(c.b) * 257)
    }

    func swiftTermPalette() -> [SwiftTerm.Color] { ansi.map(Self.swiftTermColor) }

    static func platformColor(_ hex: UInt32) -> TerminalPlatformColor {
        let c = rgbComponents(hex)
        return TerminalPlatformColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                                     blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// ANSI 팔레트 + 기본 전경/배경 + 커서. 이미 출력된 셀도 SwiftTerm이 다시 그린다.
    func apply(to view: SwiftTerm.TerminalView) {
        view.installColors(swiftTermPalette())
        view.nativeForegroundColor = Self.platformColor(foreground)
        view.nativeBackgroundColor = Self.platformColor(background)
        view.caretColor = Self.platformColor(cursor)
    }
}
#endif
