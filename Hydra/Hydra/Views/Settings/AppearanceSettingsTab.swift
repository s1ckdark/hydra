import SwiftUI

// MARK: - Appearance options (persisted via @AppStorage)

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum AppFontDesign: String, CaseIterable, Identifiable {
    case standard, rounded, serif, monospaced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard:   return "Default"
        case .rounded:    return "Rounded"
        case .serif:      return "Serif"
        case .monospaced: return "Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .standard:   return .default
        case .rounded:    return .rounded
        case .serif:      return .serif
        case .monospaced: return .monospaced
        }
    }
}

/// Global text-scale percentages. The app's text uses Dynamic Type styles,
/// which scale app-wide via `dynamicTypeSize`. SwiftUI takes size categories
/// (not arbitrary floats), so each percent maps to the nearest category — a
/// percentage feel without touching every `.font(...)` call.
let appFontScaleOptions = [80, 90, 100, 110, 125, 150]
let appFontScaleDefault = 100

func appDynamicTypeSize(forScalePercent p: Int) -> DynamicTypeSize {
    switch p {
    case ..<85:     return .xSmall
    case 85..<95:   return .small
    case 95..<107:  return .medium
    case 107..<118: return .large
    case 118..<138: return .xLarge
    case 138..<170: return .xxLarge
    default:        return .xxxLarge
    }
}

// MARK: - Appearance modifier (applied to every scene root)

/// Applies the user's theme, font design, and text size app-wide. Font design
/// uses SwiftUI's built-in system designs (no font files); text size leans on
/// dynamic type, which scales the app's semantic text styles.
struct AppearanceModifier: ViewModifier {
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage(AppStyle.storageKey) private var style = AppStyle.defaultStyle.rawValue
    // 옵셔널: nil = 사용자가 Font를 명시 선택한 적 없음 → 프리셋 기본 폰트 사용.
    @AppStorage("appFontDesign") private var fontDesign: String?
    @AppStorage("appFontScale") private var fontScale = appFontScaleDefault

    private var appStyle: AppStyle { AppStyle(rawValue: style) ?? .defaultStyle }

    func body(content: Content) -> some View {
        content
            .environment(\.theme, appStyle.theme)
            .fontDesign(resolvedFontDesign(stored: fontDesign, style: appStyle))
            .dynamicTypeSize(appDynamicTypeSize(forScalePercent: fontScale))
            .preferredColorScheme((AppTheme(rawValue: theme) ?? .system).colorScheme)
    }
}

extension View {
    /// Applies the user's appearance settings (theme + font + size).
    func appAppearance() -> some View { modifier(AppearanceModifier()) }
}

// MARK: - Appearance settings tab

#if os(macOS)
struct AppearanceSettingsTab: View {
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage("appFontDesign") private var fontDesign = AppFontDesign.standard.rawValue
    @AppStorage("appFontScale") private var fontScale = appFontScaleDefault

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            }

            Section {
                Picker("Font", selection: $fontDesign) {
                    ForEach(AppFontDesign.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Text size", selection: $fontScale) {
                    ForEach(appFontScaleOptions, id: \.self) { Text("\($0)%").tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Font")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The quick brown fox jumps over the lazy dog")
                        .font(.headline)
                    Text("Devices 12/12 online · 6 GPUs")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("$ nvidia-smi --query-gpu=utilization.gpu --format=csv")
                        .font(.system(.caption, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
    }
}
#endif
