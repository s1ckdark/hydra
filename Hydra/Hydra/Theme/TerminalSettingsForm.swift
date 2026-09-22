import SwiftUI

extension TerminalSettingsStore {
    var globalBinding: Binding<TerminalSettings> {
        Binding(get: { self.global }, set: { self.global = $0 })
    }

    /// 노드 설정 바인딩. 쓰면 그 노드만 바뀐다(따르기 상태였으면 자동으로 끈다).
    func binding(for deviceID: String) -> Binding<TerminalSettings> {
        Binding(get: { self.effective(for: deviceID) },
                set: { newValue in self.update(deviceID) { $0 = newValue } })
    }
}

/// 터미널 설정 섹션 묶음. 전체 설정과 노드 설정이 바인딩만 바꿔 같은 폼을 쓴다.
struct TerminalSettingsForm: View {
    @Binding var settings: TerminalSettings
    // availableFonts()는 시스템 폰트를 전부 훑는다 — iOS에서 이 폼이 다시 만들어질 때마다
    // 부르지 않도록 TerminalFontCatalog가 한 번만 계산해 둔 캐시를 읽는다.
    private var fonts: [TerminalFontOption] { TerminalFontCatalog.cachedAvailableFonts }

    init(settings: Binding<TerminalSettings>) { _settings = settings }

    var body: some View {
        Section {
            TerminalColorSchemeOptions(selectedID: $settings.colorSchemeID)
        } header: { Text("색상 테마") }

        Section {
            Picker("폰트", selection: $settings.fontName) {
                ForEach(fontChoices) { option in
                    Text(verbatim: option.displayName).tag(option.id)
                }
            }
            .accessibilityIdentifier("terminal-settings-font")
            Stepper(value: $settings.fontSize, in: TerminalSettings.fontSizeRange, step: 1) {
                Text(AppLocalization.format("크기 %lld pt", Int(settings.fontSize)))
            }
            .accessibilityIdentifier("terminal-settings-size")
            preview
        } header: { Text("폰트") }

        Section {
            Picker("커서", selection: $settings.cursor) {
                ForEach(TerminalCursor.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            Picker("스크롤백", selection: $settings.scrollback) {
                ForEach(TerminalSettings.scrollbackChoices, id: \.self) {
                    Text(AppLocalization.format("%lld줄", $0)).tag($0)
                }
            }
        } header: { Text("동작") }
    }

    /// 저장된 폰트가 목록에 없으면(삭제된 폰트 등) "(사용할 수 없음)"을 붙여 맨 뒤에 둔다.
    private var fontChoices: [TerminalFontOption] {
        guard !fonts.contains(where: { $0.id == settings.fontName }) else { return fonts }
        let missing = TerminalFontOption(id: settings.fontName,
            displayName: "\(settings.fontName) \(AppLocalization.string("(사용할 수 없음)"))")
        return fonts + [missing]
    }

    private var preview: some View {
        let resolved = TerminalFontCatalog.resolve(settings.fontName, size: CGFloat(settings.fontSize))
        let scheme = TerminalColorScheme.find(id: settings.colorSchemeID)
        return Text(verbatim: "$ ls -la  한글 가나다 0O1lI")
            .font(Font(resolved.font))
            .foregroundStyle(Self.color(scheme.foreground))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Self.color(scheme.background), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("terminal-settings-preview")
    }

    private static func color(_ hex: UInt32) -> Color {
        let c = TerminalColorScheme.rgbComponents(hex)
        return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}

/// 노드별 설정을 가진 노드 목록 + 개별 초기화. 전체 설정 화면에서 쓴다.
struct TerminalNodeOverridesSection: View {
    @ObservedObject var store: TerminalSettingsStore
    let nodeName: (String) -> String

    init(store: TerminalSettingsStore = .shared, nodeName: @escaping (String) -> String = { $0 }) {
        self.store = store
        self.nodeName = nodeName
    }

    var body: some View {
        Section {
            if store.overriddenDeviceIDs.isEmpty {
                Text("노드별 설정이 없습니다.").foregroundStyle(.secondary)
            } else {
                ForEach(store.overriddenDeviceIDs, id: \.self) { id in
                    HStack {
                        Text(verbatim: nodeName(id))
                        Spacer()
                        Button("초기화") { store.resetOverride(id) }
                            .accessibilityIdentifier("terminal-override-reset-\(id)")
                    }
                }
            }
        } header: {
            Text("노드별 설정")
        } footer: {
            Text("터미널 화면의 ⚙에서 '전체 설정 따르기'를 끄면 그 노드만의 설정을 쓸 수 있습니다.")
        }
    }
}

/// iOS 설정 → 터미널 설정 화면.
struct TerminalSettingsScreen: View {
    @ObservedObject private var store = TerminalSettingsStore.shared
    var nodeName: (String) -> String = { $0 }

    var body: some View {
        Form {
            TerminalSettingsForm(settings: store.globalBinding)
            TerminalNodeOverridesSection(store: store, nodeName: nodeName)
        }
        .localizedNavigationTitle("터미널 설정")
    }
}
