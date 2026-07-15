import XCTest
import SwiftUI
@testable import Hydra

final class ThemeTests: XCTestCase {

    // MARK: 프리셋 → 토큰 매핑 (스펙 표의 값)

    func testClassic_keepsCurrentLook() {
        let t = AppStyle.classic.theme
        XCTAssertEqual(t.cardRadius, 8)
        XCTAssertEqual(t.controlRadius, 6)
        XCTAssertEqual(t.chipRadius, 4)
        XCTAssertEqual(t.cardShadow, ShadowSpec(color: .black.opacity(0.05), radius: 2, y: 1))
        XCTAssertEqual(t.borderWidth, 0)
        XCTAssertEqual(t.fontDesign, .default)
    }

    func testRound_isSoft() {
        let t = AppStyle.round.theme
        XCTAssertEqual(t.cardRadius, 14)
        XCTAssertEqual(t.controlRadius, 10)
        XCTAssertEqual(t.chipRadius, 8)
        XCTAssertEqual(t.cardShadow, ShadowSpec(color: .black.opacity(0.06), radius: 6, y: 2))
        XCTAssertEqual(t.borderWidth, 0)
        XCTAssertEqual(t.fontDesign, .rounded)
    }

    func testModern_isFlatWithHairline() {
        let t = AppStyle.modern.theme
        XCTAssertEqual(t.cardRadius, 10)
        XCTAssertEqual(t.controlRadius, 8)
        XCTAssertEqual(t.chipRadius, 6)
        XCTAssertNil(t.cardShadow)
        XCTAssertEqual(t.borderWidth, 0.5)
        XCTAssertEqual(t.fontDesign, .default)
    }

    func testAvantGarde_isSquareMonoBordered() {
        let t = AppStyle.avantGarde.theme
        XCTAssertEqual(t.cardRadius, 0)
        XCTAssertEqual(t.controlRadius, 0)
        XCTAssertEqual(t.chipRadius, 0)
        XCTAssertNil(t.cardShadow)
        XCTAssertEqual(t.borderWidth, 1.5)
        XCTAssertEqual(t.fontDesign, .monospaced)
    }

    // MARK: 기본값·저장 키

    func testDefaultStyle_isRound() {
        XCTAssertEqual(AppStyle.defaultStyle, .round)
        XCTAssertEqual(AppStyle.storageKey, "appStyle")
    }

    func testRawValues_areStable() {
        // @AppStorage에 저장되는 문자열 — 바뀌면 사용자 설정이 유실된다.
        XCTAssertEqual(AppStyle.classic.rawValue, "classic")
        XCTAssertEqual(AppStyle.round.rawValue, "round")
        XCTAssertEqual(AppStyle.modern.rawValue, "modern")
        XCTAssertEqual(AppStyle.avantGarde.rawValue, "avantGarde")
    }

    // MARK: 프리셋 기본 폰트 (Font 피커 연동용)

    func testPresetFonts() {
        XCTAssertEqual(AppStyle.classic.font, .standard)
        XCTAssertEqual(AppStyle.round.font, .rounded)
        XCTAssertEqual(AppStyle.modern.font, .standard)
        XCTAssertEqual(AppStyle.avantGarde.font, .monospaced)
    }

    // MARK: 폰트 결정 규칙 — 저장값 있으면 저장값, 없으면 프리셋 기본

    func testResolvedFontDesign_unset_usesPresetDefault() {
        XCTAssertEqual(resolvedFontDesign(stored: nil, style: .round), .rounded)
        XCTAssertEqual(resolvedFontDesign(stored: nil, style: .classic), .default)
    }

    func testResolvedFontDesign_stored_winsOverPreset() {
        XCTAssertEqual(resolvedFontDesign(stored: "serif", style: .round), .serif)
        XCTAssertEqual(resolvedFontDesign(stored: "standard", style: .avantGarde), .default)
    }

    func testResolvedFontDesign_garbage_fallsBackToPreset() {
        XCTAssertEqual(resolvedFontDesign(stored: "comic-sans", style: .round), .rounded)
    }
}
