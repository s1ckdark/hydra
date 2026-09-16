import Foundation
import SSHTransport

extension SSHKeyRegistrationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "서버 주소와 SSH 계정 형식을 확인해 주세요."
        case .invalidPassword:
            return "서버 로그인 비밀번호를 입력해 주세요."
        case .invalidPublicKey:
            return "저장된 SSH 개인키를 읽을 수 없습니다. SSH 키 관리에서 지원되는 Ed25519 또는 RSA 키인지 확인하세요. 암호화된 개인키는 현재 등록 화면에서 사용할 수 없습니다."
        case .hostRejected:
            return "서버 신원 확인을 취소해 등록을 중단했습니다."
        case .hostMismatch:
            return "서버의 호스트 키가 이전 기록과 달라 연결을 중단했습니다. 서버 재설치나 키 변경 여부를 관리자에게 확인하세요."
        case .trustStoreUnavailable:
            return "이 기기의 서버 신뢰 기록을 읽거나 저장할 수 없어 연결을 중단했습니다. 앱 저장 공간과 접근 권한을 확인하세요."
        case .connectionFailed(let cause):
            return Self.explain(cause)
        case .remoteCommandFailed(let status):
            return Self.explainRemoteExit(status)
        case .registrationInterrupted(let cause):
            return "공개키 등록 명령을 보냈지만 완료 여부를 확인하지 못했습니다. 공개키가 추가되었을 수 있으므로 터미널 연결을 확인하세요.\n" + Self.explain(cause)
        case .keyLoginFailed(let cause):
            return "서버의 공개키 등록은 확인했지만 새 키로 로그인하지 못했습니다.\n" + Self.explain(cause, keyLogin: true)
        case .keyLoginHostMismatch:
            return "서버의 공개키 등록은 확인했지만 재접속한 서버의 호스트 키가 달라 키 로그인 확인을 중단했습니다. 서버의 키 변경 여부를 관리자에게 확인하세요."
        case .registrationFailed:
            return "공개키 등록을 시작하지 못했지만 원인을 특정할 수 없습니다. 다시 시도하고, 반복되면 서버의 SSH 로그를 확인하세요."
        case .verificationFailed(let mayHaveRegistered):
            return mayHaveRegistered
                ? "서버의 등록 완료 응답을 확인하지 못했습니다. 공개키가 추가되었을 수 있으므로 터미널에서 키 로그인을 확인하세요."
                : "공개키 로그인을 확인하지 못했습니다. 서버의 공개키 인증 설정을 확인하세요."
        case .cancelled(let mayHaveRegistered):
            return mayHaveRegistered
                ? "등록을 중단했습니다. 공개키가 이미 추가되었을 수 있으므로 터미널 연결을 확인하세요."
                : "공개키 등록을 취소했습니다."
        }
    }

    private static func explain(_ cause: SSHFailure, keyLogin: Bool = false) -> String {
        switch cause {
        case .nameResolutionFailed:
            return "서버 주소를 찾지 못했습니다. 호스트 주소와 DNS 설정을 확인하거나 IP 주소로 연결하세요."
        case .connectionRefused:
            return "서버가 연결을 거부했습니다. SSH 서비스가 실행 중인지와 지정한 SSH 포트의 접근 허용 여부를 확인하세요."
        case .timedOut:
            return "서버 응답을 기다리다 시간이 초과되었습니다. 네트워크·VPN 연결과 서버의 SSH 상태를 확인하고 다시 시도하세요."
        case .networkUnavailable:
            return "서버에 도달할 네트워크 경로가 없습니다. Wi-Fi와 VPN 또는 Tailscale 연결 상태를 확인하세요."
        case .connectionLost:
            return "서버와의 연결이 도중에 끊겼습니다. 네트워크와 서버의 SSH 상태를 확인하고 다시 연결하세요."
        case .authenticationRejected:
            return keyLogin
                ? "서버가 공개키 인증을 거부했습니다. 해당 계정의 authorized_keys, 공개키 로그인 허용 정책과 기존 키의 제한 옵션을 확인하세요."
                : "서버가 로그인을 거부했습니다. 계정·비밀번호 또는 서버 로그인 정책이 원인일 수 있습니다. 입력값과 해당 계정의 SSH 로그인 허용 여부를 확인하세요."
        case .passwordAuthenticationUnsupported:
            return "서버가 SSH 비밀번호 인증을 허용하지 않습니다. ‘서버 등록 명령 복사’로 명령을 복사해 이미 접속할 수 있는 터미널에서 실행하세요."
        case .privateKeyAuthenticationUnsupported:
            return "서버가 공개키 인증을 허용하지 않습니다. 서버의 공개키 로그인 설정을 관리자에게 확인하세요."
        case .handshakeFailed:
            return "SSH 보안 연결 협상에 실패했습니다. 서버의 SSH 버전과 지원 암호화 방식이 호환되는지 확인하세요."
        case .channelUnavailable:
            return "서버에서 명령 실행 채널을 열지 못했습니다. 해당 계정의 SSH 명령 실행 권한과 서버의 동시 세션 제한을 확인하세요."
        case .commandFailed(let status):
            return "서버 명령이 종료 코드 \(status)로 실패했습니다. 서버의 명령 실행 허용 여부를 확인하세요."
        case .commandOutputTooLarge:
            return "서버의 명령 응답이 허용 크기를 초과했습니다. 서버 시작 스크립트나 강제 실행 명령이 추가 출력을 만드는지 확인하세요."
        case .unknown:
            return "원인을 특정할 수 없는 SSH 오류가 발생했습니다. 다시 시도하고, 반복되면 서버의 SSH 로그를 확인하세요."
        }
    }

    private static func explainRemoteExit(_ status: Int) -> String {
        let reason: String
        switch status {
        case 20:
            reason = "현재 로그인된 서버 계정이 등록할 계정과 일치하지 않아 등록을 중단했습니다. 등록 대상 계정과 서버의 강제 실행 설정을 확인하세요."
        case 21:
            reason = "서버 계정의 홈 디렉터리 경로가 올바르지 않습니다. 해당 계정의 홈 디렉터리 설정을 확인하세요."
        case 22:
            reason = "서버의 .ssh 경로가 디렉터리가 아니거나 심볼릭 링크여서 등록을 중단했습니다. 해당 경로를 확인하세요."
        case 23:
            reason = "서버에서 등록 작업용 잠금을 얻지 못했습니다. 다른 등록 작업이 끝난 뒤 다시 시도하고 .ssh 디렉터리의 쓰기 권한을 확인하세요."
        case 25:
            reason = "서버의 authorized_keys가 일반 파일이 아니거나 심볼릭 링크여서 등록을 중단했습니다. 해당 파일 경로를 확인하세요."
        case 26:
            reason = "서버의 .ssh 또는 authorized_keys 접근 권한을 설정하거나 확인하지 못했습니다. 등록 계정의 파일 소유권과 읽기·쓰기 권한을 확인하세요."
        case 27:
            reason = "서버의 기존 authorized_keys 내용을 확인하지 못했습니다. 파일 읽기 권한과 서버의 기본 셸 도구를 확인하세요."
        case 28:
            reason = "공개키를 기록하는 중 실패했습니다. 서버의 디스크 여유 공간·할당량과 파일 쓰기 권한을 확인하세요."
        case 30:
            reason = "서버 계정의 홈 디렉터리에 .ssh 디렉터리를 만들지 못했습니다. 홈 디렉터리 쓰기 권한과 디스크 여유 공간을 확인하세요."
        case 31:
            reason = "서버에 authorized_keys 파일을 만들지 못했습니다. .ssh 디렉터리 쓰기 권한과 디스크 여유 공간을 확인하세요."
        case 24:
            reason = "서버에서 공개키 등록 명령이 중단되었습니다. 서버 상태를 확인하세요."
        default:
            reason = "서버의 공개키 등록 명령이 실패했습니다. 서버의 명령 실행 허용 여부와 기본 셸 설정을 확인하세요."
        }
        let uncertain = [20, 21, 22, 23, 25, 26, 27, 30, 31].contains(status)
            ? "" : "\n공개키가 추가되었을 수 있으므로 터미널에서 연결을 확인하세요."
        return reason + " (서버 종료 코드: \(status))" + uncertain
    }
}
