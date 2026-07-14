#if os(macOS)
import Foundation
import SSHTransport

/// Terminal 탭 사이드바의 행 모델. 대시보드 디바이스 목록과 열린 SSH 세션을
/// 병합하는 규칙(스펙: docs/superpowers/specs/2026-07-14-terminal-sidebar-design.md)을
/// 순수 함수로 분리해 뷰는 렌더링만 담당한다.
struct TerminalSidebarRow: Identifiable, Equatable {
    /// `Device`는 서버 응답 필드가 많아 테스트에서 만들기 무겁다 — 사이드바가
    /// 실제로 쓰는 필드만 투영한 경량 스냅샷을 입력으로 받는다.
    struct DeviceInfo: Equatable {
        let id: String
        let name: String
        let online: Bool
        let sshEnabled: Bool
    }

    /// `TerminalSession`(@MainActor class)의 스냅샷.
    struct SessionInfo: Equatable {
        let id: String
        let deviceId: String
        let deviceName: String
        let state: SSHState
    }

    let id: String
    let name: String
    let deviceId: String?     // nil이면 고아 세션 행 (디바이스가 목록에서 사라짐)
    let sessionId: String?
    let state: SSHState?      // nil이면 세션 없음
    let isEnabled: Bool

    /// 디바이스 순서는 호출자가 정한 순서(DevicePreferences 적용 후)를 그대로 따르고,
    /// 디바이스 목록에 없는 세션(고아)은 닫을 수단을 보존하기 위해 하단에 붙인다.
    static func rows(devices: [DeviceInfo], sessions: [SessionInfo]) -> [TerminalSidebarRow] {
        var sessionByDevice: [String: SessionInfo] = [:]
        for s in sessions where sessionByDevice[s.deviceId] == nil {
            sessionByDevice[s.deviceId] = s
        }

        var rows = devices.map { d -> TerminalSidebarRow in
            let session = sessionByDevice[d.id]
            return TerminalSidebarRow(
                id: d.id,
                name: d.name,
                deviceId: d.id,
                sessionId: session?.id,
                state: session?.state,
                // 세션이 이미 있으면 디바이스가 오프라인으로 떨어져도 포커스/닫기는
                // 가능해야 한다. 새 세션은 온라인 + SSH 가능일 때만.
                isEnabled: session != nil || (d.online && d.sshEnabled)
            )
        }

        let knownDeviceIds = Set(devices.map(\.id))
        for s in sessions where !knownDeviceIds.contains(s.deviceId) {
            rows.append(TerminalSidebarRow(
                id: "session:\(s.id)",   // 디바이스 행 id(디바이스 id)와 충돌 방지
                name: s.deviceName,
                deviceId: nil,
                sessionId: s.id,
                state: s.state,
                isEnabled: true
            ))
        }
        return rows
    }
}
#endif
