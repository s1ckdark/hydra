import SwiftUI

/// 카드 패턴 공용 모디파이어: 배경 + 코너 클립 + (프리셋에 따라) 그림자·보더.
/// 반복되던 `background + clipShape + shadow` 조합을 토큰 기반으로 통합한다.
/// 패딩은 카드마다 달라 호출부에 남긴다.
struct CardStyleModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius)
        content
            .background(.background)
            .clipShape(shape)
            .overlay {
                if theme.borderWidth > 0 {
                    shape.strokeBorder(theme.borderColor, lineWidth: theme.borderWidth)
                }
            }
            .shadow(color: theme.cardShadow?.color ?? .clear,
                    radius: theme.cardShadow?.radius ?? 0,
                    y: theme.cardShadow?.y ?? 0)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyleModifier()) }
}
