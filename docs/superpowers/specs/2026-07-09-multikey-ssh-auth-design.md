# 다중키 SSH 인증 수정 (하위 프로젝트 A) — 설계

> 상위 목표: Hydra 앱의 SSH 터미널을 iPad(iOS)에서 동작. 이 스펙은 그 **선행·독립 버그 수정(A)** 만 다룬다.
> iPad 이식(순수 Swift Citadel 백엔드 + iOS 빌드 인프라 + UIKit 터미널 뷰)은 별도 스펙 **하위 B**.

**작성일:** 2026-07-09
**상태:** 설계 승인됨 (사용자 승인 2026-07-09, 듀얼 백엔드 방향)

---

## 1. 배경 / 문제

앱의 SSH 터미널 백엔드는 macOS 전용 **libssh2(Shout 벤더링 + Homebrew C 라이브러리)** 로 잘 동작한다. iPad 이식을 위해 순수 Swift(Citadel)를 검토하다가, systematic-debugging(2026-07-08~09)으로 원래 "Citadel 인증 실패"의 **근본 원인이 라이브러리 버그가 아니라 앱의 단일키 제시**임을 확정했다:

- `ssh -vvv`로 확인: 실 노드 y-gpu-1의 `authorized_keys`에 내 `id_ed25519`는 **미등록**(다른 머신의 ed25519 2개 + 내 `id_rsa`만). OpenSSH 클라이언트는 **모든 identity를 순차 제시**해서 ed25519 거부 → `id_rsa`(rsa-sha2)로 성공한다.
- 앱은 `SSHKeyLocator`가 ed25519를 우선해 **키 하나만 제시**하고 폴백이 없다. 노드가 그 키를 authorized하지 않으면 그대로 실패한다.

**이것은 현재 배포된 libssh2 mac 앱에도 잠재한 실제 버그다.** 지금은 `config.yaml`이 `id_rsa`를 명시해 우연히 authorized 키를 제시하므로 붙지만, 노드마다 authorized 키가 다르거나 config에 키 지정이 없으면 실패한다.

### 왜 백엔드는 안 바꾸나 (듀얼 백엔드 결정)
Citadel(순수 Swift)은 **rsa-sha2를 지원하지 않는다**. 실 클러스터는 내 `id_rsa`만 authorized하므로, mac을 Citadel로 통일하면 **ed25519를 전 노드에 배포하기 전까지 지금 잘 되던 연결이 깨진다**. 따라서:
- **mac은 libssh2 유지**(rsa-sha2 + 모든 키 커버, 회귀 없음).
- **iPad는 순수 Swift Citadel**(하위 B) — libssh2는 iOS 크로스컴파일이 어렵기 때문.
- **다중키 인증 수정은 백엔드에 무관**하게 `TerminalSession` 오케스트레이션 계층에 넣어, A에서 libssh2에 적용하고 B의 Citadel이 그대로 재사용한다.

## 2. 목표 / 비목표

**목표 (하위 A):**
- **다중키 인증**: `~/.ssh`의 키를 OpenSSH처럼 우선순위대로 순차 시도, 첫 성공에서 멈춤 (단일키 버그 수정). **기존 libssh2 백엔드에 적용**, 백엔드 코드는 건드리지 않음.
- 호스트키 TOFU를 인증 재시도와 올바르게 상호작용시킴(호스트 신뢰는 키와 무관, 한 번만).
- 오케스트레이션을 **백엔드 무관**(`SSHSession` 프로토콜만 사용)하게 작성해 하위 B의 Citadel이 재사용.
- 기존 64개 Swift 테스트 유지 + 다중키/키탐색 신규 테스트. mac 앱이 실 클러스터에 계속 붙음(회귀 0).

**비목표 (하위 B 또는 별도):**
- **Citadel(순수 Swift) 백엔드 추가, iPad/iOS UI 뷰, iOS 앱 빌드 인프라(xcodeproj/서명)** — 전부 **하위 B**.
- libssh2/Shout 제거 — 하지 않음(mac 백엔드로 유지).
- SSH 에이전트 연동, 암호화 키 패스프레이즈 프롬프트, 비밀번호 인증 UI — YAGNI, 범위 밖.

## 3. 아키텍처

`SSHSession` 프로토콜(output/state 스트림, `remoteHostKey`, `connect(host:port:user:auth:)`, `openShell`/`write`/`resize`/`disconnect`/`exec`)과 백엔드 `LibSSH2Session`은 **변경하지 않는다**. `auth`는 단일 `SSHAuth`(`.privateKey(Data, passphrase:)`)를 받는 현재 시그니처를 유지한다. 다중키 순회는 **`TerminalSession`이 오케스트레이션**한다(프로토콜 무변경, 최소 침습).

### 3.1 SSHKeyLocator 다중키 API (순수, 크로스플랫폼)
- 신규 `struct KeyPair: Equatable { let privatePath: String; let publicURL: URL; let algorithmName: String }`.
- 신규 `static func orderedKeyPairs(in sshDir: URL = <~/.ssh>) throws -> [KeyPair]`:
  - `~/.ssh`의 `.pub` 후보 스캔, **매칭되는 개인키 파일이 실제 존재하는 것만** 포함.
  - `preferenceOrder`(`id_ed25519` → `id_ecdsa` → `id_rsa` → `id_dsa`) 순 정렬, 그 외 키는 파일명 사전순으로 뒤에.
  - 하나도 없으면 `LocateError.noKeysFound`.
  - `algorithmName`은 파일명 기반(예: `id_ed25519`→"ed25519") — 에러 메시지 표시용.
- `sshDir` 파라미터 주입으로 테스트가 실제 `~/.ssh`를 안 건드림(임시 디렉토리).
- 기존 `defaultPublicKey()`/`defaultPrivateKeyPath()`는 **유지**하되 내부적으로 `orderedKeyPairs()`의 첫 항목을 쓰도록 리팩터(단일 진실원, 호출부 호환).
- `#if os(macOS)` 게이팅 없이 순수 Foundation으로 작성(B가 iOS에서 재사용).

### 3.2 다중키 오케스트레이션 (TerminalSession)
현재 `TerminalSession.connect`는 키 하나를 해석해 1회 connect 후 TOFU를 본다. 이를 다음으로 재구성한다:

1. **키 목록 해석** (우선순위 순):
   - `ClusterSSHConfig.load()`에 키가 있으면 그 키를 **맨 앞**.
   - 그 뒤에 `SSHKeyLocator.orderedKeyPairs()`를 이어 붙이되 **중복 경로 제거**.
   - 결과가 비면 기존 "키 없음/읽기 실패" 에러 경로.
2. **순차 시도**: 목록의 각 키에 대해 **새 `SSHSession`을 mint**(팩토리)하여 `connect(host:port:user:auth:.privateKey(pem))`.
   - `connect`가 `SSHError.authFailed` → 세션 `disconnect()` 후 **다음 키**.
   - `connect`가 그 외 에러(`unreachable`/`handshakeFailed`/…) → **즉시 실패**(키를 더 시도해도 무의미, 호스트키 판정도 하지 않음 — remoteHostKey가 없어 오판 방지).
   - `connect`가 성공(인증 OK) → **호스트키 TOFU 판정**(§3.3) 후 성공 처리.
3. **호스트키 TOFU (인증 성공 후, 호스트 단위 1회)**: `connect` 성공 시 `HostKeyGate.evaluate`:
   - `proceed` → `openShellNow()`, 순회 종료.
   - `needsTrust(sha)` → TOFU 프롬프트 노출, 순회 중단(사용자 신뢰 대기). 신뢰 후에는 **이미 인증된 현재 세션으로 `openShellNow()`** (재연결 불필요 — auth가 이미 성공한 키다).
   - `blocked` → fail-closed 차단.
4. **전부 인증 실패**: 실행가능 메시지로 표면화(§5).

> 설계 근거: 인증이 성공한 뒤에만 TOFU를 보므로 "authFailed 세션의 host key로 오판"할 여지가 없다. authFailed는 조용히 다음 키로 넘어가고, host key 결정은 실제로 붙은(=신뢰할 근거가 있는) 연결에서만 내린다. `unreachable`/`handshakeFailed`는 호스트 자체 문제라 키 순회 없이 즉시 표면화한다.

> 세션을 시도마다 새로 mint하는 이유: 세션의 AsyncStream은 `disconnect()` 후 영구 종료되어 재사용 불가(기존 I1 픽스와 동일 계약).

### 3.3 호스트키 TOFU
기존 `KnownHostsStore`/`HostKeyGate`(`evaluate(host:fingerprint:store:) -> .proceed/.needsTrust/.blocked`)와 `trustPendingHostKey()`/`cancelPendingHostKey()` 흐름 유지. 다중키에서는 위 3.2-3처럼 **인증 성공한 세션에 대해서만** 호출된다. `trustPendingHostKey()`는 기존대로 신뢰 등록 후 `openShellNow()`(현재 세션이 이미 인증됨).

## 4. 데이터 흐름

```
Terminal 탭 → TerminalSessionStore.session(for: device)
  → TerminalSession.connect(cols,rows)
      1) creds = ClusterSSHConfig.load()   (user/port; 키 있으면 우선키)
      2) keys  = [configKey?] + SSHKeyLocator.orderedKeyPairs()   (중복 제거)
      3) for key in keys:
           s = sessionFactory()             // fresh LibSSH2Session
           do { try s.connect(host,port,user, .privateKey(pem(key))) }
           catch authFailed { s.disconnect(); continue }     // 다음 키
           catch other      { state=.disconnected(describe); return }  // 즉시 실패
           // auth 성공 → host key 판정
           switch HostKeyGate.evaluate(host, s.remoteHostKey, knownHosts):
             proceed   → openShellNow(); return
             needsTrust→ hostKeyPrompt=.needsTrust; return   // 신뢰 후 openShellNow
             blocked   → 차단; return
      4) 전부 실패 → state=.disconnected("모든 키 인증 실패 — ssh-copy-id ...")
```

## 5. 에러 처리
- **모든 키 거부**: 사용자 메시지 — “제시한 키(<시도한 알고리즘 나열>)가 이 노드(<host>)에 등록돼 있지 않습니다. `ssh-copy-id`로 공개키를 등록하세요.” 마지막 `authFailed`의 원본 사유는 로그로.
- **호스트키 불일치(blocked)**: 기존 fail-closed 메시지 유지(MITM 경고).
- **unreachable/handshakeFailed**: 키 순회 없이 해당 원인 즉시 표면화(기존 `describe`).
- **키 파일 읽기 실패**: 해당 키를 건너뛰고 다음 키 시도(전부 실패 시 위 종합 메시지). 목록 자체가 비면 기존 "개인키를 읽을 수 없습니다" 경로.

## 6. 테스트 전략
- **다중키 순회 (신규, 백엔드 무관)**: 팩토리가 **시도별 스크립트 결과**를 내는 새 테스트 더블 `ScriptedSSHSession`(HydraTests, 벤더링된 `FakeSSHSession`은 "do not edit"라 손대지 않음)로 검증.
  - 1번 키 `authFailed` → 2번 키 성공 → `.connected`+openShell 도달, 정확히 2회 시도.
  - 모든 키 `authFailed` → 최종 `.disconnected(모든 키 인증 실패 메시지)`, 목록 길이만큼 시도.
  - 1번 키 인증 성공 + host key unknown → TOFU `needsTrust`로 중단, 추가 키 시도 없음; `trustPendingHostKey()`가 재연결 없이 openShell.
  - 1번 시도 `unreachable` → 1회만 시도하고 즉시 실패(호스트키 판정 안 함).
- **SSHKeyLocator.orderedKeyPairs (신규)**: 임시 `.ssh` 디렉토리 주입.
  - ed25519+rsa 존재 → ed25519 먼저.
  - `.pub`만 있고 개인키 없는 항목 제외.
  - 키 없음 → `noKeysFound`.
  - `defaultPrivateKeyPath()`가 `orderedKeyPairs().first`와 일치.
- **회귀**: 기존 64개 테스트 그대로 통과. 기존 단일키 경로 테스트가 있으면 다중키 리팩터 후에도 동등 동작 유지.
- **실 노드 스모크(opt-in, `HYDRA_SMOKE=1`)**: 기존 libssh2 스모크가 있으면 다중키 경로로도 `id_rsa`(config 우선키) → y-gpu-1 `connect=OK` 유지 확인. 없으면 신설은 선택(회귀 방지가 목적).

## 7. 파일 영향
- **수정**: `Hydra/Hydra/Services/SSHKeyLocator.swift`(orderedKeyPairs + default* 리팩터), `Hydra/Hydra/Services/TerminalSession.swift`(다중키 순회 + TOFU 순서).
- **신규(테스트)**: `Hydra/HydraTests/ScriptedSSHSession.swift`(시도별 스크립트 더블), `.../SSHKeyLocatorMultiKeyTests.swift`, `.../TerminalSessionMultiKeyTests.swift`(또는 기존 테스트 파일에 케이스 추가).
- **불변**: `SSHSession.swift`, `LibSSH2Session.swift`, `Shout`/`CSSH`/`SSHTransportMac`, `FakeSSHSession.swift`, `Package.swift`(양쪽), `ClusterSSHConfig.swift`, `HostKeyDecision.swift`.

## 8. 리스크 / 완화
- **다중키 순회로 인한 연결 지연**: 실패 폴백에서만 재핸드셰이크 발생, connect는 hot path 아님. 허용.
- **TOFU × 다중키 상호작용 오류**: 인증 성공 세션에만 TOFU를 걸어 authFailed 세션 host key 오판을 원천 차단(§3.2 근거). 단위 테스트로 4개 경로 커버.
- **config 우선키와 orderedKeyPairs 중복**: 경로 정규화 후 dedup(심링크/상대경로 주의는 절대경로 비교로 완화).
- **하위 B 전제**: 오케스트레이션을 백엔드 무관하게 두어 B의 Citadel이 재사용. B에서 Citadel의 rsa-sha2 미지원·ed25519 배포 이슈를 별도로 다룬다(A 범위 아님).
