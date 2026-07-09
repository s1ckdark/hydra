# Citadel 통일 + 다중키 인증 (하위 프로젝트 A) — 설계

> 상위 목표: Hydra 앱의 SSH 터미널을 iPad(iOS)에서 동작. 이 스펙은 그 **전제 작업(A)** 만 다룬다.
> iPad 이식(iOS 빌드 인프라 + UIKit 터미널 뷰)은 별도 스펙 **하위 B**.

**작성일:** 2026-07-09
**상태:** 설계 승인됨 (사용자 승인 2026-07-09)

---

## 1. 배경 / 문제

앱의 SSH 터미널은 현재 macOS 전용 백엔드 **libssh2(Shout 벤더링 + Homebrew C 라이브러리)** 로 동작한다. 이 백엔드는 macOS에서만 링크되어(`Package.swift`의 `.when(platforms: [.macOS])`) iPad로 갈 수 없다.

iPad 이식을 위해 순수 Swift SSH 라이브러리(**Citadel / swift-nio-ssh**)를 검토했고, 처음엔 "Citadel이 실 노드 인증에 실패한다"고 판단해 libssh2로 피벗했었다. 그러나 systematic-debugging(2026-07-08~09)으로 **근본 원인이 라이브러리 버그가 아님**을 확정했다:

- `ssh -vvv`로 확인: 실 노드 y-gpu-1의 `authorized_keys`에 내 `id_ed25519`가 **미등록**(다른 머신의 ed25519 2개 + 내 `id_rsa`만 존재). OpenSSH 클라이언트는 **모든 identity를 순차 제시**해서 ed25519 거부 → `id_rsa`(rsa-sha2)로 성공한다.
- 앱/Citadel은 `SSHKeyLocator`가 ed25519를 우선해 **키 하나만 제시**하고 폴백이 없어 실패(`allAuthenticationOptionsFailed`).
- 검증: y-gpu-1에 내 ed25519를 임시 등록하니 Citadel ed25519 `connect=OK`. (검증 후 서버 원복, 잔여 0.)

**결론:** (1) 실제 버그는 앱의 **단일키 제시**(폴백 없음)이며, 이는 현재 배포된 libssh2 mac 앱에도 잠재. (2) Citadel은 OpenSSH 9.6에 정상 인증하는 순수 Swift 백엔드로, **mac·iPad를 한 코드로** 커버한다.

## 2. 목표 / 비목표

**목표 (하위 A):**
- macOS SSH 백엔드를 libssh2 → **Citadel(순수 Swift)** 로 통일. `Shout`/`CSSH`/`SSHTransportMac` + Homebrew libssh2 의존 제거.
- **다중키 인증**: `~/.ssh`의 키를 OpenSSH처럼 우선순위대로 순차 시도, 첫 성공에서 멈춤 (단일키 버그 수정).
- macOS 앱이 실 클러스터(y-gpu-1 등)에 Citadel + 다중키로 연결됨을 검증.
- 기존 64개 Swift 테스트 유지 + 신규 테스트 추가.

**비목표 (하위 B 또는 별도):**
- iPad/iOS UI 뷰, iOS 앱 빌드 인프라(xcodeproj/서명) — **하위 B**.
- SSH 에이전트 연동, 암호화 키 패스프레이즈 프롬프트, rsa-sha2를 위한 nio-ssh 포크 — YAGNI, 범위 밖.
- 비밀번호 인증 UI — 기존 `.password` 경로는 프로토콜에 남기되 이번 작업 대상 아님.

## 3. 아키텍처

`SSHSession` 프로토콜은 **변경하지 않는다**(output/state 스트림, `remoteHostKey`, `connect(host:port:user:auth:)`, `openShell`/`write`/`resize`/`disconnect`/`exec`). `auth`는 단일 `SSHAuth`(`.privateKey(Data, passphrase:)`)를 받는 현재 시그니처를 유지한다.

### 3.1 CitadelSession (신규, 크로스플랫폼)
- 새 타깃 `SSHTransportCitadel`(순수 Swift, `#if os` 게이팅 없음, macOS·iOS 공통)에 `CitadelSession: SSHSession` 구현.
- Citadel `SSHClient`로 KEX·인증·PTY 셸을 수행. `output`/`state` AsyncStream, `remoteHostKey`(KEX 후 세팅, auth 실패 시에도 세팅됨 — libssh2와 동일 계약), `openShell(withPTY)`, `write`, `resize`(window-change), `disconnect`, `exec`(side-channel) 구현.
- 호스트키 검증은 앱 레이어(TOFU)가 담당하므로 Citadel의 hostKeyValidator는 `.acceptAnything()`를 쓰되, KEX에서 받은 호스트키를 `remoteHostKey`로 노출해 앱 TOFU 게이트가 판정한다(현행 libssh2와 동일 구조).

### 3.2 백엔드 교체 배선
- `TerminalSessionStore`의 `sessionFactory` 기본값을 `{ _ in LibSSH2Session() }` → `{ _ in CitadelSession() }` 로 교체.
- `Package.swift`(앱): SSH 트랜스포트 제품을 **크로스플랫폼**으로 링크(`.when(platforms: [.macOS])` 제거). 단, **터미널 UI 뷰**(`SwiftTerm` `NSViewRepresentable`)는 여전히 macOS 전용 — iOS UI는 하위 B. 즉 이번 A에서 iOS 타깃은 백엔드까지만 컴파일되고 UI는 안 붙는다(빌드는 통과, 화면은 B에서).
- `TerminalCore` 패키지: `SSHTransportMac`/`Shout`/`CSSH` 타깃과 BlueSocket 의존 제거, `SSHTransportCitadel` 타깃 추가, Citadel 원격 의존 추가, `platforms`에 `.iOS` 추가.

### 3.3 다중키 오케스트레이션 (TerminalSession)
프로토콜을 바꾸지 않으므로 다중키 순회는 `TerminalSession.connect`가 담당한다:

1. **키 목록 해석** (우선순위 순):
   - `ClusterSSHConfig.load()`에 키가 있으면 그 키를 **맨 앞**에.
   - 그 뒤에 `SSHKeyLocator.orderedKeyPairs()` (아래 3.4) 결과를 이어 붙이되 중복 경로 제거.
   - 결과가 비면 기존 "키 없음" 에러.
2. **순차 시도**: 목록의 각 키에 대해 **새 `SSHSession`을 mint**(팩토리)하여 `connect(host:port:user:auth:.privateKey(pem))`.
   - **호스트키 TOFU는 한 번만, 인증 재시도보다 먼저**: 첫 시도에서 handshake가 되면(=`remoteHostKey`가 채워지면) `HostKeyGate.evaluate`를 실행.
     - `needsTrust` → TOFU 프롬프트 노출하고 **순회 중단**(신뢰는 키와 무관한 호스트 단위 결정). 사용자가 신뢰 후 재연결하면 게이트 통과 → 정상적으로 인증 순회 진행.
     - `blocked` → 즉시 실패(fail-closed).
     - `proceed` → 인증 결과 판정으로 진행.
   - `connect`가 인증 성공으로 반환 → **연결 완료, 순회 종료**.
   - `connect`가 `SSHError.authFailed` → 세션 disconnect 후 **다음 키 시도**.
   - `connect`가 그 외 에러(`unreachable`/`handshakeFailed`) → 즉시 실패(키를 더 시도해도 무의미).
3. **전부 실패**: `authFailed`를 실행가능 메시지로 표면화(§5).

> 재연결/키별 재시도마다 세션을 새로 mint하는 이유: 현행대로 세션의 AsyncStream은 `disconnect()` 후 영구 종료되어 재사용 불가.

### 3.4 SSHKeyLocator 다중키 API
- 신규 `struct KeyPair { let privatePath: String; let publicURL: URL; let algorithmName: String }`.
- 신규 `static func orderedKeyPairs(in sshDir: URL = <~/.ssh>) throws -> [KeyPair]`:
  - `~/.ssh`의 `.pub` 후보를 스캔, **매칭되는 개인키 파일이 실제 존재하는 것만** 포함.
  - `preferenceOrder`(`id_ed25519` → `id_ecdsa` → `id_rsa` → `id_dsa`) 순으로 정렬, 그 외 키는 파일명 사전순으로 뒤에.
  - 하나도 없으면 `LocateError.noKeysFound`.
- `sshDir` 파라미터 주입으로 테스트가 실제 `~/.ssh`를 건드리지 않게 함(임시 디렉토리).
- 기존 `defaultPublicKey()`/`defaultPrivateKeyPath()`는 **유지**하되 내부적으로 `orderedKeyPairs()`의 첫 항목을 쓰도록 리팩터(호출부 호환, 단일 진실원).

## 4. 데이터 흐름

```
Terminal 탭 → TerminalSessionStore.session(for: device)
  → TerminalSession.connect(cols,rows)
      1) creds = ClusterSSHConfig.load()  (user/port; 키가 있으면 우선키)
      2) keys  = [configKey?] + SSHKeyLocator.orderedKeyPairs()  (중복 제거)
      3) for key in keys:
           s = sessionFactory()            // fresh CitadelSession
           try s.connect(host,port,user, .privateKey(pem(key)))
           if first handshake & host key unknown → HostKeyGate → (needsTrust? 중단/프롬프트)
           auth 성공 → openShell → output/state 스트림 구독 → 종료
           authFailed → s.disconnect(); continue
      4) 전부 실패 → authFailed(실행가능 메시지)
```

## 5. 에러 처리
- **모든 키 거부**: 사용자 메시지 — “제시한 키(ed25519/ecdsa/rsa)가 이 노드에 등록돼 있지 않습니다. `ssh-copy-id`로 공개키를 등록하거나 ed25519 키를 배포하세요.” (Citadel은 rsa-sha2 미지원이라 **RSA만 authorized된 노드**는 실패할 수 있음 — 메시지에 ed25519 권장 힌트 포함.)
- **호스트키 불일치(blocked)**: 기존 fail-closed 메시지 유지(MITM 경고).
- **unreachable/handshakeFailed**: 키 순회하지 않고 즉시 해당 원인 표면화.
- 키 순회 중 마지막 `authFailed`의 원본 사유를 로그로 남기되, 사용자 노출은 위 종합 메시지.

## 6. 테스트 전략
- **다중키 순회 (FakeSSHSession 기반, 신규)**: 팩토리가 시도별로 스크립트된 결과를 내도록 확장.
  - 1번 키 `authFailed` → 2번 키 성공 → `connected` 도달, 정확히 2회 시도.
  - 모든 키 `authFailed` → 최종 `authFailed`, 목록 길이만큼 시도.
  - 1번 키 handshake에서 호스트키 unknown → TOFU `needsTrust`로 **중단**, 추가 키 시도 없음.
  - `unreachable` → 1회만 시도하고 즉시 실패.
- **SSHKeyLocator.orderedKeyPairs (신규)**: 임시 `.ssh` 디렉토리 주입.
  - ed25519+rsa 존재 → ed25519 먼저.
  - `.pub`만 있고 개인키 없는 항목 제외.
  - 키 없음 → `noKeysFound`.
  - `defaultPrivateKeyPath()`가 `orderedKeyPairs().first`와 일치.
- **CitadelSession 계약(신규, 로컬 가능한 범위)**: `remoteHostKey`가 auth 실패 후에도 채워짐(TOFU 순서 계약), `disconnect` 후 스트림 종료.
- **실 노드 스모크(opt-in, `HYDRA_SMOKE=1`)**: Citadel ed25519 → y-gpu-1 `connect=OK` + `exec("echo hydra-smoke")` 왕복. CI 기본 skip.
- **회귀**: 기존 64개 테스트 그대로 통과(libssh2 제거로 삭제되는 `SSHTransportMac` 전용 테스트가 있으면 CitadelSession 등가 테스트로 대체하고 그 사실을 명시).

## 7. 파일 영향 (개략)
- **신규**: `Packages/TerminalCore/Sources/SSHTransportCitadel/CitadelSession.swift`, 관련 테스트.
- **수정**: `SSHKeyLocator.swift`(orderedKeyPairs), `TerminalSession.swift`(다중키 순회 + TOFU 순서), `TerminalSessionStore.swift`(팩토리 기본값), `Hydra/Package.swift`(크로스플랫폼 링크), `Packages/TerminalCore/Package.swift`(타깃 교체 + iOS + Citadel 의존), `FakeSSHSession.swift`(시도별 스크립트).
- **삭제**: `Sources/Shout/**`, `Sources/CSSH/**`, `Sources/SSHTransportMac/**`, BlueSocket 의존.

## 8. 리스크 / 완화
- **Citadel rsa-sha2 미지원**: ed25519가 authorized된 노드에서만 완전 동작. 사용자가 클러스터 소유자라 ed25519 배포로 해소 가능. 에러 메시지가 이 상황을 안내.
- **키별 재핸드셰이크 비용**: 연결은 hot path가 아니며 실패 폴백에서만 발생. 허용.
- **Citadel PTY/resize API 차이**: libssh2와 세부 동작이 다를 수 있어 실 노드 스모크로 셸 왕복·리사이즈를 검증.
- **iOS 링크 표면**: A에서 iOS는 백엔드만 컴파일(UI 없음). iOS 빌드가 깨지지 않는지 CI에서 `swift build`로 확인.
