import Foundation
import SwiftUI

enum AppDisplayLanguage: String, CaseIterable, Identifiable {
    case system
    case korean = "ko"
    case english = "en"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .korean: return "한국어"
        case .english: return "English"
        }
    }

    func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .korean: return "ko"
        case .english: return "en"
        case .system:
            for identifier in preferredLanguages {
                let code = identifier.replacingOccurrences(of: "_", with: "-")
                    .split(separator: "-").first?.lowercased()
                if let code, code == "ko" || code == "en" { return code }
            }
            return "en"
        }
    }
}

/// Only Hydra's display preferences are changed; keyboard and system language stay untouched.
struct AppAppearancePreferences {
    static let languageKey = "appLanguage"
    static let themeKey = "appTheme"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var language: AppDisplayLanguage {
        get { AppDisplayLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.languageKey) }
    }

    var theme: AppTheme {
        get { AppTheme(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.themeKey) }
    }
}

enum AppLocalization {
    /// Use for locally generated messages outside SwiftUI's localized string-literal API.
    /// Unknown keys are preserved, so device names and server-provided values are not rewritten.
    static func string(
        _ key: String,
        language: AppDisplayLanguage? = nil,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> String {
        let identifier = (language ?? AppAppearancePreferences(defaults: defaults).language).resolvedIdentifier()
        guard let path = bundle.path(forResource: identifier, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else { return key }
        let localized = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        if localized != key { return localized }
        // Compound, locally generated errors join a summary and a cause with a newline.
        // Prefer a whole-message translation; otherwise preserve line breaks and unknown lines.
        return key.components(separatedBy: "\n").map { line in
            let translated = localizedBundle.localizedString(forKey: line, value: line, table: nil)
            guard translated == line, line.hasSuffix(")"),
                  let range = line.range(of: " (서버 종료 코드: ", options: .backwards) else { return translated }
            let code = String(line[range.upperBound..<line.index(before: line.endIndex)])
            guard Int(code) != nil else { return line }
            let prefix = String(line[..<range.lowerBound])
            let translatedPrefix = localizedBundle.localizedString(forKey: prefix, value: prefix, table: nil)
            // Only app-authored, known messages are reformatted; unknown text
            // (including device names) must retain its original bytes.
            guard translatedPrefix != prefix else { return line }
            let template = " (서버 종료 코드: %d)"
            let suffix = localizedBundle.localizedString(forKey: template, value: template, table: nil)
            return translatedPrefix + suffix.replacingOccurrences(of: "%d", with: code)
        }.joined(separator: "\n")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let language = AppAppearancePreferences().language
        return String(
            format: string(key, language: language),
            locale: Locale(identifier: language.resolvedIdentifier()),
            arguments: arguments
        )
    }
}

/// Localized dynamic app copy that also updates when the selected display language changes.
struct AppLocalizedText: View {
    @Environment(\.locale) private var locale
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        let language = AppDisplayLanguage(rawValue: locale.language.languageCode?.identifier ?? "") ?? .system
        Text(AppLocalization.string(key, language: language))
    }
}

private struct HydraAppearancePreferencesModifier: ViewModifier {
    @AppStorage(AppAppearancePreferences.languageKey) private var languageRaw = AppDisplayLanguage.system.rawValue
    @AppStorage(AppAppearancePreferences.themeKey) private var themeRaw = AppTheme.system.rawValue

    func body(content: Content) -> some View {
        let language = AppDisplayLanguage(rawValue: languageRaw) ?? .system
        let theme = AppTheme(rawValue: themeRaw) ?? .system
        content
            .environment(\.locale, Locale(identifier: language.resolvedIdentifier()))
            .preferredColorScheme(theme.colorScheme)
    }
}

extension View {
    func hydraAppearancePreferences() -> some View {
        modifier(HydraAppearancePreferencesModifier())
    }
}
