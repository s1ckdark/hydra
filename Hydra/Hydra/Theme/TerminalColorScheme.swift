import Foundation

/// SwiftTerm 그리드 색상 프리셋. 색은 플랫폼 무관하게 `0xRRGGBB`로 보관하고,
/// UIKit/AppKit/SwiftTerm 변환은 `TerminalColorScheme+SwiftTerm.swift`에서 한다.
/// 앱 외관(`AppTheme`)과는 독립 — 터미널만 칠한다.
struct TerminalColorScheme: Identifiable, Equatable {
    static let storageKey = "terminalColorScheme"

    let id: String
    let displayName: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    /// 16개, SwiftTerm 순서: 0–7 normal(black, red, green, yellow, blue, magenta, cyan, white), 8–15 bright.
    let ansi: [UInt32]

    static let presets: [TerminalColorScheme] = [defaultDark, solarizedDark, solarizedLight, dracula, nord]

    static func find(id: String) -> TerminalColorScheme {
        presets.first { $0.id == id } ?? defaultDark
    }

    static func rgbComponents(_ hex: UInt32) -> (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }
}

// MARK: - Presets (terminal/App/TerminalTheme.swift에서 이식)

extension TerminalColorScheme {
    static let defaultDark = TerminalColorScheme(
        id: "default-dark", displayName: "Default Dark",
        background: 0x000000, foreground: 0xD7D7CF, cursor: 0x0A84FF,
        ansi: [0x2E3436, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
               0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC])

    static let solarizedDark = TerminalColorScheme(
        id: "solarized-dark", displayName: "Solarized Dark",
        background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])

    static let solarizedLight = TerminalColorScheme(
        id: "solarized-light", displayName: "Solarized Light",
        background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x586E75,
        ansi: [0xEEE8D5, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0x073642,
               0xFDF6E3, 0xCB4B16, 0x93A1A1, 0x839496, 0x657B83, 0x6C71C4, 0x586E75, 0x002B36])

    static let dracula = TerminalColorScheme(
        id: "dracula", displayName: "Dracula",
        background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xFF79C6,
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])

    static let nord = TerminalColorScheme(
        id: "nord", displayName: "Nord",
        background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0x88C0D0,
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])
}
