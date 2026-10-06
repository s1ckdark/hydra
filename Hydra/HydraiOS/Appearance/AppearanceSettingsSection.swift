import SwiftUI

struct AppearanceSettingsSection: View {
    @AppStorage(AppAppearancePreferences.languageKey) private var languageRaw = AppDisplayLanguage.deviceDefault().rawValue
    @AppStorage(AppAppearancePreferences.themeKey) private var themeRaw = AppTheme.system.rawValue

    private var language: Binding<AppDisplayLanguage> {
        Binding(
            get: { AppDisplayLanguage(rawValue: languageRaw) ?? .deviceDefault() },
            set: { languageRaw = $0.rawValue }
        )
    }

    private var theme: Binding<AppTheme> {
        Binding(
            get: { AppTheme(rawValue: themeRaw) ?? .system },
            set: { themeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            Picker("앱 언어", selection: language) {
                ForEach(AppDisplayLanguage.allCases) { choice in
                    Text(verbatim: choice.label).tag(choice)
                }
            }
            .accessibilityIdentifier("settings.appLanguage")

            Picker("테마", selection: theme) {
                ForEach(AppTheme.allCases) { choice in
                    Text(LocalizedStringKey(choice.label)).tag(choice)
                }
            }
            .accessibilityIdentifier("settings.appTheme")
        } header: {
            Text("언어 및 테마")
        } footer: {
            Text("선택하면 바로 적용됩니다.")
        }
    }
}
