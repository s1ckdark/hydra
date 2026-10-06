import Foundation
import Combine

/// 터미널 설정 저장소. 전체 설정은 개별 키(기존 terminalColorScheme 키와 호환),
/// 노드별 설정은 `terminalNodeOverrides`에 [deviceID: TerminalSettings] JSON으로 둔다.
/// 딕셔너리에 없는 노드는 전체 설정을 따른다.
final class TerminalSettingsStore: ObservableObject {
    static let shared = TerminalSettingsStore()

    enum Key {
        static let colorScheme = TerminalColorScheme.storageKey
        static let fontName = "terminalFontName"
        static let fontSize = "terminalFontSize"
        static let cursor = "terminalCursor"
        static let scrollback = "terminalScrollback"
        static let overrides = "terminalNodeOverrides"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var global: TerminalSettings {
        get {
            var s = TerminalSettings()
            if let v = defaults.string(forKey: Key.colorScheme) { s.colorSchemeID = v }
            if let v = defaults.string(forKey: Key.fontName) { s.fontName = v }
            if defaults.object(forKey: Key.fontSize) != nil { s.fontSize = defaults.double(forKey: Key.fontSize) }
            if let v = defaults.string(forKey: Key.cursor), let c = TerminalCursor(rawValue: v) { s.cursor = c }
            if defaults.object(forKey: Key.scrollback) != nil { s.scrollback = defaults.integer(forKey: Key.scrollback) }
            return s.normalized()
        }
        set {
            objectWillChange.send()
            let s = newValue.normalized()
            defaults.set(s.colorSchemeID, forKey: Key.colorScheme)
            defaults.set(s.fontName, forKey: Key.fontName)
            defaults.set(s.fontSize, forKey: Key.fontSize)
            defaults.set(s.cursor.rawValue, forKey: Key.cursor)
            defaults.set(s.scrollback, forKey: Key.scrollback)
        }
    }

    func effective(for deviceID: String) -> TerminalSettings {
        overrides[deviceID] ?? global
    }

    func isFollowingGlobal(_ deviceID: String) -> Bool {
        overrides[deviceID] == nil
    }

    /// false: 현재 전체 설정을 복사해 노드 설정을 만든다. true: 노드 설정을 지운다.
    func setFollowingGlobal(_ follow: Bool, for deviceID: String) {
        var o = overrides
        if follow {
            o[deviceID] = nil
        } else if o[deviceID] == nil {
            o[deviceID] = global
        }
        overrides = o
    }

    /// 노드 설정만 바꾼다. 전체 설정을 따르던 노드면 전체 설정을 복사한 뒤 바꾼다.
    func update(_ deviceID: String, _ change: (inout TerminalSettings) -> Void) {
        var o = overrides
        var s = o[deviceID] ?? global
        change(&s)
        o[deviceID] = s.normalized()
        overrides = o
    }

    var overriddenDeviceIDs: [String] { overrides.keys.sorted() }

    func resetOverride(_ deviceID: String) {
        setFollowingGlobal(true, for: deviceID)
    }

    /// 항목 단위로 디코딩한다. 깨진 항목만 버리고 나머지는 살린다.
    private var overrides: [String: TerminalSettings] {
        get {
            guard let data = defaults.data(forKey: Key.overrides),
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
            var result: [String: TerminalSettings] = [:]
            for (id, value) in raw {
                guard JSONSerialization.isValidJSONObject(value),
                      let entry = try? JSONSerialization.data(withJSONObject: value),
                      let s = try? JSONDecoder().decode(TerminalSettings.self, from: entry) else { continue }
                result[id] = s.normalized()
            }
            return result
        }
        set {
            objectWillChange.send()
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.overrides)
        }
    }
}
