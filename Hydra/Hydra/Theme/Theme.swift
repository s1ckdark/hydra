import SwiftUI

// MARK: - 스타일 토큰
//
// 프리셋(AppStyle)은 토큰 값 묶음이다. 뷰는 @Environment(\.theme)으로 토큰만
// 읽고 프리셋 이름으로 분기하지 않는다 — 프리셋 추가 = static 값 하나 추가.
// 스펙: docs/superpowers/specs/2026-07-15-style-presets-design.md

struct ShadowSpec: Equatable {
    var color: Color
    var radius: CGFloat
    var y: CGFloat
}

struct Theme: Equatable {
    var cardRadius: CGFloat      // 카드·패널·배너
    var controlRadius: CGFloat   // 버튼·입력창·소형 패널
    var chipRadius: CGFloat      // 뱃지·태그·게이지 바
    var cardShadow: ShadowSpec?  // nil = 그림자 없음
    var borderWidth: CGFloat     // 0 = 카드 외곽선 없음
    var borderColor: Color
    var fontDesign: Font.Design  // 프리셋의 기본 폰트 디자인
}

// MARK: - 프리셋

enum AppStyle: String, CaseIterable, Identifiable {
    case classic, round, modern, avantGarde

    static let storageKey = "appStyle"
    static let defaultStyle = AppStyle.round

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic:    return "Classic"
        case .round:      return "Round"
        case .modern:     return "Modern"
        case .avantGarde: return "Avant"
        }
    }

    /// 프리셋의 기본 폰트. 스타일 선택 시 Font 설정의 출발점이 된다.
    var font: AppFontDesign {
        switch self {
        case .classic, .modern: return .standard
        case .round:            return .rounded
        case .avantGarde:       return .monospaced
        }
    }

    var theme: Theme {
        switch self {
        case .classic:
            return Theme(cardRadius: 8, controlRadius: 6, chipRadius: 4,
                         cardShadow: ShadowSpec(color: .black.opacity(0.05), radius: 2, y: 1),
                         borderWidth: 0, borderColor: .clear,
                         fontDesign: font.design)
        case .round:
            return Theme(cardRadius: 14, controlRadius: 10, chipRadius: 8,
                         cardShadow: ShadowSpec(color: .black.opacity(0.06), radius: 6, y: 2),
                         borderWidth: 0, borderColor: .clear,
                         fontDesign: font.design)
        case .modern:
            return Theme(cardRadius: 10, controlRadius: 8, chipRadius: 6,
                         cardShadow: nil,
                         borderWidth: 0.5, borderColor: .primary.opacity(0.12),
                         fontDesign: font.design)
        case .avantGarde:
            return Theme(cardRadius: 0, controlRadius: 0, chipRadius: 0,
                         cardShadow: nil,
                         borderWidth: 1.5, borderColor: .primary,
                         fontDesign: font.design)
        }
    }
}

// MARK: - 폰트 결정 규칙
//
// 사용자가 Font를 명시 선택했으면(저장값 존재) 그 값, 아니면 프리셋 기본.
// 프리셋 = 출발점, Font 설정 = 최종 결정권.

func resolvedFontDesign(stored: String?, style: AppStyle) -> Font.Design {
    guard let stored, let explicit = AppFontDesign(rawValue: stored) else {
        return style.theme.fontDesign
    }
    return explicit.design
}

// MARK: - Environment 주입

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppStyle.defaultStyle.theme
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
