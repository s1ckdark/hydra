#if os(macOS)
import SwiftUI
import SSHTransport   // SSHState (세션 상태 → 목록 점 색)

/// Terminal 탭 루트. Named `TerminalTabView` (not `TerminalView`) because
/// SwiftTerm's AppKit NSView class is itself called `TerminalView` — see
/// SwiftTermRepresentable.swift for the disambiguation note.
struct TerminalTabView: View {
    @ObservedObject private var store = TerminalSessionStore.shared

    var body: some View {
        HSplitView {
            // 세션 목록
            List(selection: Binding(get: { store.activeSessionId },
                                    set: { store.activeSessionId = $0 })) {
                ForEach(store.sessions) { s in
                    HStack {
                        Circle().fill(color(for: s.state)).frame(width: 8, height: 8)
                        Text(s.deviceName).lineLimit(1)
                        Spacer()
                        Button { store.close(id: s.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }.tag(s.id)
                }
            }
            .frame(minWidth: 160, maxWidth: 240)

            // 활성 세션
            if let active = store.sessions.first(where: { $0.id == store.activeSessionId }) {
                TerminalSessionPane(session: active)
            } else {
                Text("Devices 탭에서 노드의 '터미널 열기'를 누르세요.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
