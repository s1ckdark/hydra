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

enum AppFontSize: String, CaseIterable, Identifiable {
    case small, medium, large, xlarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Default"
        case .large:  return "Large"
        case .xlarge: return "X-Large"
        }
    }
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small:  return .small
        case .medium: return .medium
        case .large:  return .large
        case .xlarge: return .xLarge
        }
    }
}

// MARK: - Appearance modifier (applied to every scene root)

/// Applies the user's theme, font design, and text size app-wide. Font design
/// uses SwiftUI's built-in system designs (no font files); text size leans on
/// dynamic type, which scales the app's semantic text styles.
struct AppearanceModifier: ViewModifier {
    @AppStorage("appTheme") private var theme = AppTheme.system.rawValue
    @AppStorage("appFontDesign") private var fontDesign = AppFontDesign.standard.rawValue
    @AppStorage("appFontSize") private var fontSize = AppFontSize.medium.rawValue

    func body(content: Content) -> some View {
        content
            .fontDesign((AppFontDesign(rawValue: fontDesign) ?? .standard).design)
            .dynamicTypeSize((AppFontSize(rawValue: fontSize) ?? .medium).dynamicTypeSize)
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
    @AppStorage("appFontSize") private var fontSize = AppFontSize.medium.rawValue

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
                Picker("Text size", selection: $fontSize) {
                    ForEach(AppFontSize.allCases) { Text($0.label).tag($0.rawValue) }
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
