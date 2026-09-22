import SwiftUI

/// 터미널 색상 프리셋 선택 행 목록. Form/Section 안에 넣어 쓴다 (macOS 설정 탭, iOS 테마 화면 공용).
struct TerminalColorSchemeOptions: View {
    @Binding var selectedID: String

    var body: some View {
        ForEach(TerminalColorScheme.presets) { scheme in
            Button { selectedID = scheme.id } label: {
                TerminalColorSchemeRow(scheme: scheme,
                                       isSelected: TerminalColorScheme.find(id: selectedID) == scheme)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("terminal-scheme-\(scheme.id)")
        }
    }
}

private struct TerminalColorSchemeRow: View {
    let scheme: TerminalColorScheme
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            preview
            Text(scheme.displayName)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scheme.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 테마 배경 위에 전경색 "Aa" + ANSI normal 8색 칩.
    private var preview: some View {
        HStack(spacing: 3) {
            Text("Aa")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(Self.color(scheme.foreground))
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.color(scheme.ansi[i]))
                    .frame(width: 8, height: 12)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Self.color(scheme.background), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
    }

    private static func color(_ hex: UInt32) -> Color {
        let c = TerminalColorScheme.rgbComponents(hex)
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}
