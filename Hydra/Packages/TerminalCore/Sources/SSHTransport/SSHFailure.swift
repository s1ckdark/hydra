import Foundation

/// Transport failures with stable meanings and safe, actionable display text.
/// Raw diagnostics may contain credentials or server-controlled strings, so
/// these cases deliberately retain only a cause and, for commands, an exit code.
public enum SSHFailure: Error, Equatable, Sendable, LocalizedError {
    case nameResolutionFailed
    case connectionRefused
    case timedOut
    case networkUnavailable
    case connectionLost
    case authenticationRejected
    case passwordAuthenticationUnsupported
    case privateKeyAuthenticationUnsupported
    case handshakeFailed
    case channelUnavailable
    case commandFailed(exitStatus: Int)
    case commandOutputTooLarge
    case unknown

    public var errorDescription: String? {
        switch self {
        case .nameResolutionFailed:
            return "서버 주소를 찾을 수 없습니다. 주소가 맞는지와 DNS·VPN 연결 상태를 확인하세요."
        case .connectionRefused:
            return "서버가 SSH 연결을 거부했습니다. SSH 서비스가 실행 중인지와 포트·방화벽 설정을 확인하세요."
        case .timedOut:
            return "서버 응답 대기 시간이 초과되었습니다. 네트워크와 서버 상태를 확인한 뒤 다시 시도하세요."
        case .networkUnavailable:
            return "서버에 연결할 수 없습니다. 기기의 네트워크와 VPN 또는 Tailscale 연결 상태를 확인하세요."
        case .connectionLost:
            return "SSH 연결이 도중에 끊겼습니다. 네트워크와 서버 상태를 확인한 뒤 다시 연결하세요."
        case .authenticationRejected:
            return "서버가 인증 정보를 받아들이지 않았습니다. 계정·비밀번호 또는 등록된 공개키와 서버의 로그인 허용 설정을 확인하세요."
        case .passwordAuthenticationUnsupported:
            return "서버가 비밀번호 인증을 허용하지 않습니다. 서버의 인증 설정을 확인하거나 공개키 인증을 사용하세요."
        case .privateKeyAuthenticationUnsupported:
            return "서버가 공개키 인증을 허용하지 않습니다. 서버의 공개키 로그인 허용 설정을 확인하세요."
        case .handshakeFailed:
            return "SSH 보안 연결을 설정하지 못했습니다. 대상 포트가 SSH 서비스인지와 서버의 SSH 설정을 확인하세요."
        case .channelUnavailable:
            return "서버가 SSH 작업 채널을 열지 못했습니다. 서버의 세션 수 제한과 원격 명령 실행 권한을 확인하세요."
        case .commandFailed(let exitStatus):
            return "서버 명령이 실패했습니다(종료 코드: \(exitStatus)). 대상 계정의 권한과 서버 설정을 확인하세요."
        case .commandOutputTooLarge:
            return "서버 응답이 허용 크기를 초과해 작업을 중단했습니다. 서버의 로그인 스크립트와 명령 출력을 확인하세요."
        case .unknown:
            return "SSH 작업을 완료하지 못했습니다. 서버와 네트워크 상태를 확인한 뒤 다시 시도하세요."
        }
    }
}
