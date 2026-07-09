# B1 — Citadel 백엔드 복구 + macOS 검증 — 설계

> 상위 목표: Hydra SSH 터미널을 iPad(iOS)에서 동작(하위 B). B는 두 조각으로 분해:
> **B1(이 스펙): 순수 Swift Citadel 백엔드를 복구·재통합하고 macOS에서 인터랙티브 셸 전체 계약을 증명.**
> **B2(다음 스펙): iOS 앱 타깃 + 빌드/서명 인프라 + 디바이스목록/터미널 UIKit 뷰.**

**작성일:** 2026-07-09
**상태:** 설계 승인됨 (사용자 승인 2026-07-09)
**선행:** 하위 A(다중키 인증) 머지 완료 — B1은 A의 `TerminalSession` 다중키 순회를 그대로 재사용.

---

## 1. 배경 / 문제

하위 A로 다중키 인증 버그는 백엔드 무관하게 해결됐다. iPad로 가려면 **순수 Swift SSH 백엔드**가 필요하다(libssh2는 iOS 크로스컴파일이 어렵다). 사용자 결정(듀얼 백엔드): **mac은 libssh2 유지, iPad은 Citadel.**

Citadel 백엔드는 이미 이 저장소의 SSH 터미널 개발(S1~S5)에서 `CitadelSession`으로 구현·리뷰됐고, C1 리뷰에서 호스트키 캡처(TOFU 활성화)까지 고쳐졌다(`32d65d0`). 이후 S6에서 "Citadel이 실 노드 인증 실패"로 판단해 libssh2로 스왑하며 제거됐다(`31f8dd1`, `cada531`). 그러나 하위 A의 디버깅으로 그 인증 실패는 **라이브러리 결함이 아니라 앱의 단일키 제시** 때문이었음이 확정됐다 — Citadel의 ed25519 인증은 OpenSSH 9.6에 정상 동작한다(내 ed25519가 authorized된 노드에서 `connect=OK` 검증).

따라서 B1은 **새로 작성이 아니라 `32d65d0`의 리뷰된 `CitadelSession`을 복구·재통합**하고, 이번엔 **다중키 순회(A) 위에서** macOS에서 셸 왕복까지 증명한다.

## 2. 목표 / 비목표

**목표 (B1):**
- `32d65d0`의 `CitadelSession.swift`(+ 동일 타깃의 동반 파일들)와 `TerminalCore` 배선을 복구해 크로스플랫폼 타깃 `SSHTransportCitadel`을 되살린다. Citadel/NIO/Crypto 의존은 **명시적 target deps**로(S1의 transitive-import 지적 반영 — `32d65d0` 배선이 이미 그렇게 함).
- `TerminalSessionStore`에 env 기반 백엔드 선택(`HYDRA_SSH_BACKEND=citadel` → Citadel, 그 외 libssh2)을 추가. **기본은 libssh2 유지(회귀 0).**
- macOS에서 Citadel의 인터랙티브 셸 전체 계약(다중키 connect → openShell → 입출력 왕복 → resize → exec → disconnect + 호스트키 캡처/TOFU)을 **Docker OpenSSH(반복·CI-safe) + 실 노드 1회 수동 스모크**로 증명.
- `TerminalCore` 패키지에 `.iOS` 플랫폼을 선언(B2 준비). 기존 64+8 테스트 회귀 0.

**비목표 (B2 또는 별도):**
- iOS 앱 타깃, xcodeproj/서명, iOS UI, 실제 iOS 컴파일 검증 — **B2**. (B1은 `.iOS` 플랫폼만 선언; iOS 앱 타깃이 없어 iOS 컴파일은 B2에서 최초 검증.)
- Citadel을 mac 기본 백엔드로 승격 — 안 함(libssh2가 rsa-sha2/모든 키 커버, mac은 그대로).
- password/agent/rsa-sha2 인증 — YAGNI, 범위 밖.

## 3. 아키텍처

`SSHSession` 프로토콜(불변)과 하위 A의 `TerminalSession` 다중키 오케스트레이션(불변)을 그대로 쓴다. B1은 **전송 계층 하나(CitadelSession)를 되살리고 선택 가능하게** 만드는 것.

### 3.1 CitadelSession 복구 (`SSHTransportCitadel`, 크로스플랫폼)
- `git show 32d65d0:Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel/`의 파일 전체를 복구(주 파일 `CitadelSession.swift` + 동반 헬퍼 `HostKeyCapturingValidator`/`makeKeyAuth` 등이 있으면 함께). `#if os` 게이팅 없음(macOS+iOS).
- 계약: `connect(host:port:user:auth:)`(Citadel `SSHClient.connect`, `hostKeyValidator: .custom(HostKeyCapturingValidator)`로 호스트키 캡처 후 `remoteHostKey` 노출 — C1 픽스), `openShell`(PTY), `write`, `resize`(window-change), `disconnect`, `exec`(side-channel), `output`/`state` 스트림, `remoteHostKey`(연결 전 nil, handshake 후 세팅).
- `@unchecked Sendable` posture와 `.swiftLanguageMode(.v5)` 유지(Citadel API non-Sendable — 복구본과 동일).

### 3.2 TerminalCore 배선 복구 + iOS 플랫폼
- `Packages/TerminalCore/Package.swift`: 현재(libssh2: `SSHTransport`/`SSHTransportMac`/`Shout`/`CSSH`/`KnownHosts`)에 **`SSHTransportCitadel` 타깃·제품과 Citadel/swift-nio/swift-nio-ssh(Wellz26 포크)/swift-crypto 의존을 추가**(`32d65d0` 배선 그대로). `platforms`에 `.iOS(.v17)` 추가.
- `SSHTransportMac`(libssh2)는 macOS 전용으로 남는다(iOS는 이 타깃을 링크하지 않음 — 그 보장은 앱 Package의 `.when(platforms: [.macOS])`가 담당, B2에서 iOS 앱 타깃과 함께 최종 확인).

### 3.3 앱 백엔드 선택 심 (검증용)
- `Hydra/Package.swift`: `SSHTransportCitadel` 제품을 앱 타깃에 링크(현재는 미링크). macOS 검증용이므로 최소한 macOS에 링크; iOS 링크는 B2.
- `TerminalSessionStore`(`#if os(macOS)`): `SSHTransportCitadel` import 추가, 기본 팩토리를 env 스위치로:
  ```
  init(sessionFactory: ... = { _ in TerminalSessionStore.defaultBackend() })
  static func defaultBackend() -> SSHSession {
      ProcessInfo.processInfo.environment["HYDRA_SSH_BACKEND"]?.lowercased() == "citadel"
          ? CitadelSession() : LibSSH2Session()
  }
  ```
  기본(env 없음)은 **libssh2**. `HYDRA_SSH_BACKEND=citadel`로 앱/스모크가 Citadel을 선택. 주입 팩토리를 넘기는 기존 테스트는 영향 없음.

### 3.4 다중키 재사용
A의 `TerminalSession.connect`가 이미 키 목록을 순회하며 세션을 mint한다. 팩토리가 `CitadelSession`을 반환하면 **Citadel 위에서 다중키가 그대로 동작**한다 — 별도 코드 없음. B1 스모크가 이 경로(다중키 → Citadel)를 함께 증명.

## 4. 검증 전략

### 4.1 Docker OpenSSH 스모크 (반복·CI-safe, opt-in)
- 헬퍼 스크립트가 OpenSSH 컨테이너를 기동: authorized_keys에 사용자의 `~/.ssh/id_ed25519.pub`, 매핑 포트 노출. (하위 A 디버깅의 `sshdiag` 하네스와 동형.)
- XCTest `CitadelSessionSmokeTests`(env gate, 예: `HYDRA_CITADEL_SMOKE_HOST`/`_PORT` 설정 시에만 실행, 없으면 skip):
  1. `CitadelSession.connect`(ed25519) → `.connected`, `remoteHostKey != nil`.
  2. `openShell` 후 `write("echo hydra-b1\n")` → `output`에 `hydra-b1` 포함(타임아웃 내).
  3. `resize(cols:rows:)` throw 없음.
  4. `exec("uname")` 비어있지 않은 문자열.
  5. `disconnect()` 후 `state`가 `.disconnected`로 종료, 스트림 finish.
- Docker/포트 env 없으면 전부 skip → CI green 유지. 스크립트+실행 방법을 스펙/README에 문서화.

### 4.2 계약 유닛 테스트 (네트워크 불필요)
- `CitadelSession()` 직후 `remoteHostKey == nil`.
- `disconnect()`가 `output`/`state` 스트림을 finish(연결 없이 호출해도 안전).
- (연결이 필요한 계약은 4.1로.)

### 4.3 실 노드 1회 수동 스모크
- 사용자가 대상 노드에 ed25519 배포(`ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<node>`) 후, 문서화된 명령으로 `HYDRA_CITADEL_SMOKE_HOST=<node>`를 걸어 4.1 흐름을 실 노드에 1회 실행(실 네트워크·실 OpenSSH 확인). 자동 게이트 아님(클러스터 상태 의존).
- 또는 `HYDRA_SSH_BACKEND=citadel`로 mac 앱을 띄워 실제 터미널 탭에서 눈으로 확인.

### 4.4 회귀
- 기본 백엔드(env 없음)는 libssh2 → 기존 `TerminalSessionTests`/전체 스위트 그대로 통과. Citadel 추가로 삭제되는 테스트 없음.

## 5. 파일 영향
- **복구(신규)**: `Packages/TerminalCore/Sources/SSHTransportCitadel/**`(`32d65d0`에서), 관련 계약/스모크 테스트, Docker 스모크 스크립트.
- **수정**: `Packages/TerminalCore/Package.swift`(Citadel 타깃·의존·`.iOS` 추가), `Hydra/Package.swift`(`SSHTransportCitadel` 링크), `Hydra/Hydra/Services/TerminalSessionStore.swift`(env 백엔드 심).
- **불변**: `SSHSession.swift`, `LibSSH2Session.swift`/`Shout`/`CSSH`/`SSHTransportMac`, `TerminalSession.swift`(A의 다중키 그대로), `SSHKeyLocator.swift`, `FakeSSHSession.swift`.

## 6. 리스크 / 완화
- **Citadel PTY/셸 세부 동작 미검증**: 정확히 이걸 4.1 Docker 스모크로 증명(입출력 왕복·resize·exec). mac에서 실패하면 B2 이전에 조기 발견.
- **Citadel rsa-sha2 미지원**: ed25519 authorized 노드에서만 인증. 검증은 ed25519 노드(Docker/실노드)로. 사용자 클러스터는 ed25519 배포로 해소(B2 운영 전제).
- **의존성 그래프 재도입(nio-ssh Wellz26 포크 등)**: `32d65d0` 배선을 그대로 복구해 버전 드리프트 최소화. 해석 실패 시 그때 핀 조정.
- **iOS 실컴파일 미검증(B1 범위 밖)**: `.iOS` 플랫폼만 선언; SSHTransportMac이 iOS로 새지 않는지는 B2의 iOS 앱 타깃에서 최종 확인. B1은 macOS 빌드/테스트 green만 보증.
- **env 심의 사이드이펙트**: 기본이 libssh2라 회귀 없음. 주입 팩토리 테스트 경로 불변.
