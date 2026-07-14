#if os(macOS)
import SwiftUI
import SSHTransport   // SSHState (세션 상태 → 목록 점 색)

/// Terminal 탭 루트. Named `TerminalTabView` (not `TerminalView`) because
/// SwiftTerm's AppKit NSView class is itself called `TerminalView` — see
/// SwiftTermRepresentable.swift for the disambiguation note.
struct TerminalTabView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @ObservedObject private var store = TerminalSessionStore.shared
    @ObservedObject private var prefs = DevicePreferences.shared

    // 노드 리스트 + 열린 세션 병합 — 규칙은 TerminalSidebarModel.swift 참고.
    private var rows: [TerminalSidebarRow] {
        let ordered = prefs.apply(to: dashboardVM.devices, id: \.id)
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
        .task {
            // Terminal 탭에 먼저 진입한 경우에도 노드 목록이 비어 보이지 않도록.
            if dashboardVM.devices.isEmpty { await dashboardVM.load() }
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
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
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
                    Button("재연결") { Task { await session.connect(cols: 80, rows: 24) } }
                }.padding(6).background(Color.red.opacity(0.08))
            }
            SwiftTermRepresentable(session: session)
                .task { if case .idle = session.state { await session.connect(cols: 80, rows: 24) } }
        }
        // 호스트키 TOFU 시트
        .sheet(isPresented: Binding(
            get: { if case .needsTrust = session.hostKeyPrompt { return true } else { return false } },
            set: { if !$0 { } })) {
            if case .needsTrust(let sha) = session.hostKeyPrompt {
                VStack(spacing: 12) {
                    Text("새 호스트키").font(.headline)
                    Text("\(session.deviceName) (\(session.host))")
                    Text("SHA256: \(sha)").font(.system(.caption, design: .monospaced))
                    HStack {
                        Button("취소") { session.cancelPendingHostKey() }
                        Button("신뢰") { Task { await session.trustPendingHostKey() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 420)
            }
        }
    }
}
#endif
