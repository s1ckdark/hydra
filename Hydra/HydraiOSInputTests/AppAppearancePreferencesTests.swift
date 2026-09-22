import XCTest
import SwiftUI
@testable import HydraiOS

final class AppAppearancePreferencesTests: XCTestCase {
    func testNumericDiagnosticCodeDoesNotPreventMessageTranslation() {
        let text = "서버의 .ssh 또는 authorized_keys 접근 권한을 설정하거나 확인하지 못했습니다. 등록 계정의 파일 소유권과 읽기·쓰기 권한을 확인하세요. (서버 종료 코드: 26)"
        let translated = AppLocalization.string(text, language: .english)
        XCTAssertTrue(translated.lowercased().contains("permission"))
        XCTAssertTrue(translated.contains("26"))
        XCTAssertFalse(translated.contains("서버 종료 코드"))
        XCTAssertEqual(AppLocalization.string("intlmac", language: .english), "intlmac")
    }
    func testPreferencesPersistAcrossInstancesWithoutChangingSystemLanguage() throws {
        let suite = "hydra.appearance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["fr-FR"], forKey: "AppleLanguages")
        let preferences = AppAppearancePreferences(defaults: defaults)
        preferences.language = .korean
        preferences.theme = .dark

        let reopened = AppAppearancePreferences(defaults: defaults)
        XCTAssertEqual(reopened.language, .korean)
        XCTAssertEqual(reopened.theme, .dark)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "ko")
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "dark")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr-FR"])
    }

    func testInvalidStoredValuesFallBackToSystem() throws {
        let suite = "hydra.appearance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unknown-language", forKey: "appLanguage")
        defaults.set("unknown-theme", forKey: "appTheme")
        let preferences = AppAppearancePreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, .deviceDefault())
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertNil(preferences.theme.colorScheme)
    }

    func testLanguageSelectionResolvesSupportedPreferredLanguages() {
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ko-KR", "en-US"]), .korean)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["fr-FR", "en-GB"]), .english)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ja-JP", "ko_KR"]), .korean)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(AppDisplayLanguage.english.rawValue, "en")
        XCTAssertEqual(AppDisplayLanguage.korean.rawValue, "ko")
    }

    func testBundledTranslationsAndDynamicMessagesUseTheSelectedLanguage() {
        let bundle = Bundle.main
        XCTAssertEqual(AppLocalization.string("설정", language: .english, bundle: bundle), "Settings")
        XCTAssertEqual(AppLocalization.string("Settings", language: .korean, bundle: bundle), "설정")
        XCTAssertEqual(AppLocalization.string("서버에 공개키 등록", language: .english, bundle: bundle), "Register public key on server")
        XCTAssertEqual(AppLocalization.string("intlmac", language: .english, bundle: bundle), "intlmac")
        XCTAssertEqual(AppLocalization.string("기기 정보 업데이트", language: .english, bundle: bundle), "Update device information")
    }

    func testCompoundMessagesTranslateKnownLinesAndPreserveUnknownValuesAndSpacing() {
        let compound = "공개키 등록\n\n서버 로그인 비밀번호를 입력해 주세요.\nintlmac"
        XCTAssertEqual(
            AppLocalization.string(compound, language: .english),
            "Register public key\n\nEnter the server login password.\nintlmac"
        )
        XCTAssertEqual(AppLocalization.string(compound, language: .korean), compound)
    }
}
