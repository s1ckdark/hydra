#if os(macOS)
import SwiftUI
import Combine
import SSHTransport   // SSHState (세션 상태 → 목록 점 색)

// MARK: - macOS 26 격리-체크 크래시 완화
//
// macOS 26.5.2에서 SwiftUI의 메인 액터 격리 체크(`swift_task_isCurrentExecutor`)가
// 터미널 탭의 AppKit 이벤트/레이아웃 사이클 중 크래시한다(메인 스레드인데도 "MainActor
// executor 아님" 판정 — legacy override로도 못 막음). 관측된 두 크래시 지점을 회피한다:
//   1) SwiftUI `Button`(`_ButtonGesture` → assumeIsolated) → `.onTapGesture`(다른 제스처
//      프리미티브)로 대체. 아래 `TapLabel`.
//   2) `.task { }`(내부적으로 `Task.immediate` → executor 체크) → `.onAppear { Task { } }`
//      (즉시-체크 없이 메인 액터에 큐잉)로 대체.
// TOFU 프롬프트는 NSButton 기반 `.alert`를 써서 `_ButtonGesture` 경로 자체를 피한다.
private struct TapLabel<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    var body: some View {
        label()
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// Terminal 탭 루트. Named `TerminalTabView` (not `TerminalView`) because
/// SwiftTerm's AppKit NSView class is itself called `TerminalView` — see
/// SwiftTermRepresentable.swift for the disambiguation note.
struct TerminalTabView: View {
    // dashboardVM은 관찰하지 않는다(plain let). 대시보드는 10초마다 metrics/devices를
    // 재발행하는데, 그때마다 터미널 탭이 재렌더되면 SwiftUI 트랜잭션이 반복되고 macOS 26
    // 격리-체크 렌더 크래시(`swift_task_isCurrentExecutor`, 시스템 크롬 HStack) 확률이
    // 올라간다. 대신 device 목록을 @State로 들고, 터미널에 실제로 필요한 필드(id/이름/
    // 온라인/ssh)가 바뀔 때만 갱신한다(lastSeen 등 매 폴링 churn은 무시).
    let dashboardVM: DashboardViewModel
    @ObservedObject private var store = TerminalSessionStore.shared
    @ObservedObject private var prefs = DevicePreferences.shared
    @State private var devices: [Device] = []

    /// 사이드바가 실제로 쓰는 필드만 투영 — dedup 비교용(lastSeen/metrics 무시).
    private static func terminalProjection(_ ds: [Device]) -> [TerminalSidebarRow.DeviceInfo] {
        ds.map { .init(id: $0.id, name: $0.shortName, online: $0.isOnline, sshEnabled: $0.sshEnabled) }
    }

    // 노드 리스트 + 열린 세션 병합 — 규칙은 TerminalSidebarModel.swift 참고.
    private var rows: [TerminalSidebarRow] {
        let ordered = prefs.apply(to: devices, id: \.id)
        return TerminalSidebarRow.rows(
            devices: ordered.map {
                .init(id: $0.id, name: $0.shortName, online: $0.isOnline, sshEnabled: $0.sshEnabled)
            },
            sessions: store.sessions.map {
                .init(id: $0.id, deviceId: $0.deviceId, deviceName: $0.deviceName, state: $0.state)
            }
        )
    }

    var body: some View {
        HSplitView {
            // 노드 목록 — 세션이 없어도 여기서 바로 열 수 있다.
            List {
                ForEach(rows) { row in
                    SidebarRowView(
                        row: row,
                        session: row.sessionId.flatMap { sid in store.sessions.first { $0.id == sid } },
                        isActive: row.sessionId != nil && row.sessionId == store.activeSessionId,
                        onSelect: { activate(row) },
                        onClose: { if let sid = row.sessionId { store.close(id: sid) } }
                    )
                }
            }
            .frame(minWidth: 160, maxWidth: 240)

            // 활성 세션
            if let active = store.sessions.first(where: { $0.id == store.activeSessionId }) {
                TerminalSessionPane(session: active)
                    .id(active.id)
            } else {
                Text("왼쪽에서 노드를 선택하세요.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // device 목록의 터미널-관련 투영이 바뀔 때만 로컬 스냅샷 갱신 →
        // 10초 폴링(metrics/lastSeen churn)에는 재렌더하지 않는다.
        .onReceive(dashboardVM.$devices) { newDevices in
            if Self.terminalProjection(newDevices) != Self.terminalProjection(devices) {
                devices = newDevices
            }
        }
        // `.task` 대신 `.onAppear { Task { } }` — 위 완화 주석(2) 참고.
        .onAppear {
            // 최초 진입 시 현재 목록으로 시드(폴링 발행 전 빈 화면 방지).
            if devices.isEmpty { devices = dashboardVM.devices }
            Task {
                if dashboardVM.devices.isEmpty { await dashboardVM.load() }
                // ContentView가 이미 복원했으면 no-op (런치당 1회 가드).
                store.restoreIfNeeded(devices: dashboardVM.devices)
            }
        }
    }

    private func activate(_ row: TerminalSidebarRow) {
        guard row.isEnabled else { return }
        if let sid = row.sessionId {
            // ✕ 닫기와 행 탭이 같은 클릭에서 겹치면 row 스냅샷의 세션은 이미 닫혀
            // 있을 수 있다 — 죽은 id로 포커스를 옮기거나 새 세션을 열지 않는다.
            if store.sessions.contains(where: { $0.id == sid }) {
                store.activeSessionId = sid
            }
        } else if let deviceId = row.deviceId,
                  let device = dashboardVM.devices.first(where: { $0.id == deviceId }) {
            store.open(device: device)
        }
    }
}

/// 사이드바 한 행. 세션 상태 점을 라이브로 갱신하기 위해 세션이 있으면
/// TerminalSession을 직접 관찰한다 (rows 스냅샷은 store 변경 시점의 상태만 담는다).
private struct SidebarRowView: View {
    let row: TerminalSidebarRow
    let session: TerminalSession?
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack {
            if let session {
                SessionStateDot(session: session)
            } else {
                Circle()
                    .strokeBorder(Color.gray, lineWidth: 1)
                    .frame(width: 8, height: 8)
            }
            Text(row.name).lineLimit(1)
            Spacer()
            if row.sessionId != nil {
                // Button 대신 TapLabel — _ButtonGesture 크래시 회피(파일 상단 주석).
                // 행 전체의 onSelect와 겹쳐도 activate()가 죽은 id를 걸러낸다.
                TapLabel(action: onClose) {
                    Image(systemName: "xmark").foregroundColor(.secondary).padding(2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .opacity(row.isEnabled ? 1 : 0.4)
        .listRowBackground(isActive ? Color.accentColor.opacity(0.18) : nil)
        .help(row.isEnabled
              ? (row.sessionId == nil ? "\(row.name)에 SSH 터미널 세션 열기" : "세션으로 이동")
              : "오프라인이거나 SSH를 사용할 수 없는 노드")
    }
}

private struct SessionStateDot: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Circle().fill(color(for: session.state)).frame(width: 8, height: 8)
    }

    private func color(for state: SSHState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .idle: return .gray
        case .disconnected: return .red
        }
    }
}

private struct TerminalSessionPane: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        VStack(spacing: 0) {
            if case .disconnected(let reason) = session.state {
                HStack {
                    Text(reason ?? "연결 끊김").foregroundColor(.red).font(.caption)
                    Spacer()
                    // Button 대신 TapLabel — _ButtonGesture 크래시 회피(파일 상단 주석).
                    TapLabel(action: { Task { await session.connect(cols: 80, rows: 24) } }) {
                        Text("재연결")
                            .font(.caption).bold()
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }.padding(6).background(Color.red.opacity(0.08))
            }
            SwiftTermRepresentable(session: session)
                // `.task` 대신 `.onAppear { Task { } }` — 완화 주석(2) 참고.
                .onAppear {
                    Task { if case .idle = session.state { await session.connect(cols: 80, rows: 24) } }
                }
        }
        // 호스트키 TOFU 프롬프트 — NSButton 기반 `.alert`(SwiftUI `.sheet`+`Button` 아님).
        // 시트 안 Button은 macOS 26에서 `_ButtonGesture` 경로로 크래시하므로 회피한다.
        // 세터는 정상 바인딩으로: 사용자가 Esc로 닫으면 취소로 처리(시트의 no-op set 대신).
        .alert("새 호스트키", isPresented: Binding(
            get: { if case .needsTrust = session.hostKeyPrompt { return true } else { return false } },
            set: { if !$0, case .needsTrust = session.hostKeyPrompt { session.cancelPendingHostKey() } }
        )) {
            Button("취소", role: .cancel) { session.cancelPendingHostKey() }
            Button("신뢰") { Task { await session.trustPendingHostKey() } }
        } message: {
            if case .needsTrust(let sha) = session.hostKeyPrompt {
                Text("\(session.deviceName) (\(session.host))\nSHA256: \(sha)")
            }
        }
    }
}
#endif
