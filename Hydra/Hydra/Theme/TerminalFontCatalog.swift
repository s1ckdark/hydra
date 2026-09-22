import Foundation
import CoreText
#if canImport(UIKit)
import UIKit
typealias TerminalPlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias TerminalPlatformFont = NSFont
#endif

struct TerminalFontOption: Identifiable, Hashable {
    let id: String          // PostScript 이름, 또는 TerminalFontCatalog.systemID
    let displayName: String
}

/// 터미널 폰트 목록과 해석. 번들 폰트(D2Coding)는 앱 시작 시 process 범위로 등록한다.
enum TerminalFontCatalog {
    static let systemID = "system"
    static let bundledFonts = ["D2Coding"]

    struct Resolved {
        let font: TerminalPlatformFont
        let isFallback: Bool
    }

    static func registerBundledFonts(bundle: Bundle = .main) {
        for name in bundledFonts {
            // iOS(XcodeGen)는 번들 루트, macOS(bundle-app.sh)는 Resources/Fonts에 들어간다.
            if let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? bundle.url(forResource: name, withExtension: "ttf") {
                registerFont(at: url)
            }
        }
    }

    /// 이미 등록된 폰트면 CoreText가 오류를 돌려주는데, 결과는 같으므로 무시한다.
    static func registerFont(at url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func availableFonts() -> [TerminalFontOption] {
        var result = [TerminalFontOption(id: systemID, displayName: "System Monospaced")]
        var seen: Set<String> = [systemID]
        func add(_ postscriptName: String) {
            guard !seen.contains(postscriptName),
                  let font = TerminalPlatformFont(name: postscriptName, size: 12) else { return }
            seen.insert(postscriptName)
            result.append(TerminalFontOption(id: postscriptName, displayName: displayName(of: font)))
        }
        bundledFonts.forEach(add)
        #if canImport(UIKit)
        for family in UIFont.familyNames.sorted() {
            for name in UIFont.fontNames(forFamilyName: family) {
                if let f = UIFont(name: name, size: 12), f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) { add(name) }
            }
        }
        #else
        (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []).sorted().forEach(add)
        #endif
        return result
    }

    /// availableFonts()는 시스템 폰트를 전부 훑는다 — 폼이 다시 만들어질 때마다 부르지 않도록 한 번만 계산한다.
    /// 다운로드 폰트(후속 작업)를 설치한 뒤에는 refreshAvailableFonts()로 갱신한다.
    private(set) static var cachedAvailableFonts: [TerminalFontOption] = availableFonts()
    static func refreshAvailableFonts() { cachedAvailableFonts = availableFonts() }

    static func resolve(_ name: String, size: CGFloat) -> Resolved {
        if name != systemID, let font = TerminalPlatformFont(name: name, size: size) {
            return Resolved(font: font, isFallback: false)
        }
        return Resolved(font: .monospacedSystemFont(ofSize: size, weight: .regular), isFallback: name != systemID)
    }

    private static func displayName(of font: TerminalPlatformFont) -> String {
        #if canImport(UIKit)
        return font.fontName
        #else
        return font.displayName ?? font.fontName
        #endif
    }
}

#if canImport(UIKit)
extension UIFont {
    /// NSFont.isFixedPitch와 같은 이름으로 테스트·UI에서 쓴다.
    var isFixedPitch: Bool { fontDescriptor.symbolicTraits.contains(.traitMonoSpace) }
}
#endif
