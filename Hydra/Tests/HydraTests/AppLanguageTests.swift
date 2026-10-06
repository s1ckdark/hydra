import XCTest
@testable import Hydra

final class AppLanguageTests: XCTestCase {
    func testDeviceDefaultPicksFirstSupportedPreferredLanguage() {
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ko-KR", "en-US"]), .korean)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["fr-FR", "en-GB"]), .english)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ja-JP", "ko_KR"]), .korean)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(AppDisplayLanguage.deviceDefault(preferredLanguages: []), .english)
    }

    func testOnlyKoreanAndEnglishAreSelectable() {
        XCTAssertEqual(AppDisplayLanguage.allCases.map(\.rawValue), ["ko", "en"])
    }

    func testMigrationStoresDeviceLanguageWhenMissingOrLegacy() throws {
        try withDefaults { defaults in
            AppAppearancePreferences(defaults: defaults).migrateLanguageIfNeeded(preferredLanguages: ["ko-KR"])
            XCTAssertEqual(defaults.string(forKey: "appLanguage"), "ko")
        }
        try withDefaults { defaults in
            defaults.set("system", forKey: "appLanguage")
            AppAppearancePreferences(defaults: defaults).migrateLanguageIfNeeded(preferredLanguages: ["fr-FR"])
            XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        }
    }

    func testMigrationKeepsExplicitChoice() throws {
        try withDefaults { defaults in
            defaults.set("en", forKey: "appLanguage")
            AppAppearancePreferences(defaults: defaults).migrateLanguageIfNeeded(preferredLanguages: ["ko-KR"])
            XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "hydra.language.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
