import Foundation

/// SwiftTerm `CursorStyle`과 1:1. 저장은 rawValue 문자열.
enum TerminalCursor: String, CaseIterable, Codable, Identifiable {
    case blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar

    var id: String { rawValue }

    /// 공유 번역 테이블 키 (한국어 원문).
    var label: String {
        switch self {
        case .blinkBlock: return "블록 (깜빡임)"
        case .steadyBlock: return "블록"
        case .blinkUnderline: return "밑줄 (깜빡임)"
        case .steadyUnderline: return "밑줄"
        case .blinkBar: return "세로줄 (깜빡임)"
        case .steadyBar: return "세로줄"
        }
    }
}

/// 터미널 한 개에 적용되는 설정 묶음. 전체 설정과 노드별 설정이 같은 타입을 쓴다.
struct TerminalSettings: Codable, Equatable {
    static let scrollbackChoices = [1_000, 5_000, 10_000, 50_000]
    static let fontSizeRange: ClosedRange<Double> = 8...32
    #if os(macOS)
    static let defaultFontSize: Double = 13
    #else
    static let defaultFontSize: Double = 14
    #endif

    var colorSchemeID: String = TerminalColorScheme.defaultDark.id
    var fontName: String = "D2Coding"
    var fontSize: Double = TerminalSettings.defaultFontSize
    var cursor: TerminalCursor = .blinkBlock
    var scrollback: Int = 10_000

    /// 범위를 벗어난 값을 허용 범위로 맞춘다. 저장·조회 경계에서 항상 거친다.
    func normalized() -> TerminalSettings {
        var s = self
        s.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        if !Self.scrollbackChoices.contains(scrollback) { s.scrollback = 10_000 }
        s.colorSchemeID = TerminalColorScheme.find(id: colorSchemeID).id
        if s.fontName.isEmpty { s.fontName = "D2Coding" }
        return s
    }
}
