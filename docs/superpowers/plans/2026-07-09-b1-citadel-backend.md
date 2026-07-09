# B1 — Citadel 백엔드 복구 + macOS 검증 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 리뷰됐던 순수 Swift `CitadelSession`(`32d65d0`)을 크로스플랫폼 `SSHTransportCitadel` 타깃으로 복구하고, env 스위치로 선택 가능하게 만들어, macOS에서 인터랙티브 셸 전체 계약을 Docker OpenSSH 스모크로 증명한다. libssh2 기본값은 불변.

**Architecture:** `SSHSession` 프로토콜과 하위 A의 `TerminalSession` 다중키 순회는 불변. `CitadelSession`(Citadel/NIOSSH 기반, C1 호스트키 캡처 포함)을 복구해 전송 계층으로 되살리고, `TerminalSessionStore`가 `HYDRA_SSH_BACKEND` env로 libssh2/Citadel을 고른다. 검증은 macOS 전용(Docker + 실노드 1회).

**Tech Stack:** Swift 6 tools / Swift 5 language mode, Citadel 0.9.2 + swift-nio-ssh(Wellz26 포크 0.3.4), XCTest, Docker(linuxserver/openssh-server) 스모크.

## Global Constraints
- **불변 파일**: `SSHSession.swift`, `LibSSH2Session.swift`, `Shout`/`CSSH`/`SSHTransportMac`, `TerminalSession.swift`(A의 다중키 그대로), `SSHKeyLocator.swift`, `FakeSSHSession.swift`.
- 기본 백엔드(env 없음)는 **libssh2** — 기존 `TerminalSessionTests` 및 전체 스위트가 그대로 통과해야 한다(회귀 0).
- `CitadelSession`은 `32d65d0`의 파일을 **바이트 그대로 복구**한다(재작성 금지). 복구 후 컴파일 위한 최소 조정만 허용하며, 그런 조정이 필요하면 리뷰에 명시한다.
- Citadel/NIO/Crypto는 **명시적 target 의존**으로 선언(transitive import 금지) — `32d65d0` 배선을 따른다.
- 스모크/실노드 테스트는 env 미설정 시 `XCTSkip` → CI green. 실제 `~/.ssh`는 읽기 전용.
- Citadel은 rsa-sha2 미지원 → 검증은 **ed25519** 키·ed25519 authorized 노드로만.

---

### Task 1: CitadelSession 복구 + TerminalCore 배선 (패키지 빌드 green)

**Files:**
- Recover: `Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel/CitadelSession.swift` (from `32d65d0`)
- Modify: `Hydra/Packages/TerminalCore/Package.swift`

**Interfaces:**
- Produces: `SSHTransportCitadel` 라이브러리 제품 + `public final class CitadelSession: SSHSession, @unchecked Sendable` (connect/openShell/write/resize/exec/disconnect, `remoteHostKey`, `output`/`state`).

- [ ] **Step 1: 복구 — git에서 파일 되살리기**

```bash
cd /Users/dave/iWorks/hydra
mkdir -p Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel
git show 32d65d0:Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel/CitadelSession.swift \
  > Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel/CitadelSession.swift
wc -l Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel/CitadelSession.swift   # ~230 lines 기대
```

- [ ] **Step 2: TerminalCore Package.swift 갱신** — 현재(libssh2) 패키지에 Citadel 타깃/제품/의존과 `.iOS` 플랫폼을 추가. 파일 전체를 아래로 교체:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "SSHTransport",         targets: ["SSHTransport"]),
        .library(name: "SSHTransportMac",      targets: ["SSHTransportMac"]),
        .library(name: "SSHTransportCitadel",  targets: ["SSHTransportCitadel"]),
        .library(name: "KnownHosts",           targets: ["KnownHosts"]),
    ],
    dependencies: [
        // libssh2 (macOS backend) — 벤더링된 Shout의 소켓 의존
        .package(url: "https://github.com/IBM-Swift/BlueSocket", from: "1.0.200"),
        // Citadel (pure-Swift backend) — CitadelSession의 C1 호스트키 캡처 패치가
        // NIOCore/NIOSSH/Crypto를 직접 import 하므로 명시적 직접 의존으로 선언.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.9.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "SSHTransport"),
        .systemLibrary(name: "CSSH", pkgConfig: "libssh2", providers: [.brew(["libssh2", "openssl"])]),
        .target(
            name: "Shout",
            dependencies: [
                "CSSH",
                .product(name: "Socket", package: "BlueSocket"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
        .target(
            name: "SSHTransportMac",
            dependencies: [
                "SSHTransport",
                "Shout",
            ],
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
        .target(
            name: "SSHTransportCitadel",
            dependencies: [
                "SSHTransport",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
        .target(name: "KnownHosts"),
    ]
)
```

- [ ] **Step 3: TerminalCore 패키지 빌드 (의존성 해석 + Citadel 컴파일 게이트)**

Run: `cd /Users/dave/iWorks/hydra/Hydra/Packages/TerminalCore && swift build 2>&1 | tail -25`
Expected: 의존성(Citadel/nio-ssh 포크 등) 해석 성공 + 모든 타깃(특히 `SSHTransportCitadel`) 컴파일 성공. 에러 없이 `Compiling`/`Build complete!`.
- 만약 버전 해석이 실패하면(포크 태그 드리프트 등) 실패 로그를 리뷰에 남기고, `32d65d0`의 `Package.resolved`를 참고해 핀을 맞춘 뒤 재시도. 임의 버전 상향 금지.

- [ ] **Step 4: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Packages/TerminalCore/Sources/SSHTransportCitadel/CitadelSession.swift \
        Hydra/Packages/TerminalCore/Package.swift
git commit -m "build(terminal): recover SSHTransportCitadel target + CitadelSession (32d65d0)

Restore the reviewed pure-Swift Citadel backend (incl. C1 host-key capture)
removed during the S6 libssh2 swap, now that sub-project A proved the original
auth failure was a single-key bug, not a Citadel defect. Explicit NIO/Crypto
deps; adds .iOS platform (compile verified in B2). libssh2 targets unchanged."
```

---

### Task 2: 앱 링크 + env 백엔드 스위치 + 계약 테스트

**Files:**
- Modify: `Hydra/Package.swift`
- Modify: `Hydra/Hydra/Services/TerminalSessionStore.swift`
- Test: `Hydra/Tests/HydraTests/CitadelSessionContractTests.swift` (create)

**Interfaces:**
- Consumes: `SSHTransportCitadel.CitadelSession` (Task 1).
- Produces: `TerminalSessionStore.defaultBackend() -> SSHSession` (env `HYDRA_SSH_BACKEND=citadel` → Citadel, else libssh2).

- [ ] **Step 1: 앱 타깃에 SSHTransportCitadel 링크** — `Hydra/Package.swift`의 `Hydra` executableTarget `dependencies`에 한 줄 추가(기존 macOS 조건부 제품들과 동일 스타일):

```swift
                .product(name: "SSHTransport", package: "TerminalCore", condition: .when(platforms: [.macOS])),
                .product(name: "SSHTransportMac", package: "TerminalCore", condition: .when(platforms: [.macOS])),
                .product(name: "SSHTransportCitadel", package: "TerminalCore", condition: .when(platforms: [.macOS])),
                .product(name: "KnownHosts", package: "TerminalCore", condition: .when(platforms: [.macOS])),
```

> B1은 macOS 검증만 하므로 `.when(platforms: [.macOS])`로 링크한다. iOS 링크(및 SSHTransportMac을 iOS에서 빼는 최종 구성)는 B2에서 iOS 앱 타깃과 함께 처리한다.

- [ ] **Step 2: 실패 테스트 작성** — `Hydra/Tests/HydraTests/CitadelSessionContractTests.swift`

```swift
#if os(macOS)
import XCTest
import SSHTransport
import SSHTransportCitadel
@testable import Hydra

final class CitadelSessionContractTests: XCTestCase {
    func testRemoteHostKeyNilBeforeConnect() {
        let s = CitadelSession()
        XCTAssertNil(s.remoteHostKey)
    }

    func testDisconnectBeforeConnectFinishesStreams() async {
        let s = CitadelSession()
        s.disconnect()
        // disconnect() finishes both streams (outC/stC .finish()); draining a
        // finished stream must return promptly (test times out if it hangs).
        for await _ in s.state {}
        for await _ in s.output {}
        XCTAssertNil(s.remoteHostKey)   // never connected
    }

    func testDefaultBackendIsLibssh2WithoutEnv() {
        // Guard: default must NOT be Citadel (env unset in CI). Type-name check
        // avoids importing SSHTransportMac just to `is` LibSSH2Session.
        setenv("HYDRA_SSH_BACKEND", "", 1); defer { unsetenv("HYDRA_SSH_BACKEND") }
        let backend = TerminalSessionStore.defaultBackend()
        XCTAssertFalse(String(describing: type(of: backend)).contains("Citadel"))
    }

    func testEnvSelectsCitadelBackend() {
        setenv("HYDRA_SSH_BACKEND", "citadel", 1); defer { unsetenv("HYDRA_SSH_BACKEND") }
        let backend = TerminalSessionStore.defaultBackend()
        XCTAssertTrue(backend is CitadelSession)
    }
}
#endif
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift test --filter CitadelSessionContractTests 2>&1 | tail -20`
Expected: 컴파일 실패 (`TerminalSessionStore.defaultBackend` 미정의).

- [ ] **Step 4: 구현** — `TerminalSessionStore.swift` 수정.

(4a) import 추가:
```swift
import SSHTransport
import SSHTransportMac
import SSHTransportCitadel
```

(4b) 기본 팩토리를 env 스위치로 교체:
```swift
    init(sessionFactory: @escaping (Device) -> SSHSession = { _ in TerminalSessionStore.defaultBackend() }) {
        self.sessionFactory = sessionFactory
    }

    /// libssh2 by default (macOS: rsa-sha2 + every key). `HYDRA_SSH_BACKEND=citadel`
    /// selects the pure-Swift Citadel backend — used to verify the iOS path on macOS
    /// without changing the shipped default.
    static func defaultBackend() -> SSHSession {
        if ProcessInfo.processInfo.environment["HYDRA_SSH_BACKEND"]?.lowercased() == "citadel" {
            return CitadelSession()
        }
        return LibSSH2Session()
    }
```

- [ ] **Step 5: 계약 테스트 통과 확인**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift test --filter CitadelSessionContractTests 2>&1 | tail -20`
Expected: 4 테스트 PASS.

- [ ] **Step 6: 전체 스위트 회귀 확인 (기본 libssh2)**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift test 2>&1 | tail -8`
Expected: 전체 PASS (기존 72 + 신규 4 = 76). 기본 백엔드 libssh2 불변.

- [ ] **Step 7: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Package.swift Hydra/Hydra/Services/TerminalSessionStore.swift \
        Hydra/Tests/HydraTests/CitadelSessionContractTests.swift
git commit -m "feat(terminal): env-selectable Citadel backend (HYDRA_SSH_BACKEND=citadel)

Link SSHTransportCitadel (macOS) and let TerminalSessionStore pick Citadel via
env, defaulting to libssh2 (no behavior change). Contract tests: remoteHostKey
nil pre-connect, disconnect finishes streams, env switch selects the backend."
```

---

### Task 3: Docker OpenSSH 스모크 하네스 + 실행 (Citadel 셸 왕복 증명)

**Files:**
- Create: `Hydra/Tests/smoke/citadel-openssh-docker.sh`
- Test: `Hydra/Tests/HydraTests/CitadelSessionSmokeTests.swift` (create)
- Doc: append a "Citadel smoke" section to `Hydra/Tests/smoke/README.md` (create if absent)

**Interfaces:**
- Consumes: `CitadelSession` (Task 1), env `HYDRA_CITADEL_SMOKE_HOST/_PORT/_USER/_KEY`.

- [ ] **Step 1: Docker 하네스 스크립트** — `Hydra/Tests/smoke/citadel-openssh-docker.sh`

```bash
#!/usr/bin/env bash
# Launch a throwaway OpenSSH container authorizing the current user's ed25519
# public key, for the Citadel backend smoke. Prints the HOST/PORT/USER to export.
#   Usage: citadel-openssh-docker.sh [host_port]   (default 2222)
#   Teardown: docker rm -f hydra-citadel-smoke
set -euo pipefail
PORT="${1:-2222}"
PUB="${HYDRA_CITADEL_SMOKE_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
NAME="hydra-citadel-smoke"
[ -f "$PUB" ] || { echo "no ed25519 pubkey at $PUB" >&2; exit 1; }
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "${PORT}:2222" \
  -e PUBLIC_KEY="$(cat "$PUB")" -e USER_NAME=smoke -e SUDO_ACCESS=false \
  lscr.io/linuxserver/openssh-server:latest >/dev/null
# wait for sshd to accept connections
for i in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.5
done
echo "READY host=127.0.0.1 port=${PORT} user=smoke"
echo "run: HYDRA_CITADEL_SMOKE_HOST=127.0.0.1 HYDRA_CITADEL_SMOKE_PORT=${PORT} HYDRA_CITADEL_SMOKE_USER=smoke swift test --filter CitadelSessionSmokeTests"
```

Then: `chmod +x Hydra/Tests/smoke/citadel-openssh-docker.sh`

- [ ] **Step 2: 스모크 테스트 작성** — `Hydra/Tests/HydraTests/CitadelSessionSmokeTests.swift`

```swift
#if os(macOS)
import XCTest
import SSHTransport
import SSHTransportCitadel

/// Opt-in real-SSH smoke for the Citadel backend. Skips unless
/// HYDRA_CITADEL_SMOKE_HOST is set (Docker via Tests/smoke/citadel-openssh-docker.sh,
/// or a real ed25519-authorized node). Env: _HOST, _PORT(=2222), _USER(=smoke),
/// _KEY(=~/.ssh/id_ed25519).
final class CitadelSessionSmokeTests: XCTestCase {
    func testInteractiveShellRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["HYDRA_CITADEL_SMOKE_HOST"] else {
            throw XCTSkip("set HYDRA_CITADEL_SMOKE_HOST to run the Citadel smoke")
        }
        let port = Int(env["HYDRA_CITADEL_SMOKE_PORT"] ?? "2222") ?? 2222
        let user = env["HYDRA_CITADEL_SMOKE_USER"] ?? "smoke"
        let keyPath = env["HYDRA_CITADEL_SMOKE_KEY"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
        let pem = try XCTUnwrap(FileManager.default.contents(atPath: keyPath), "no key at \(keyPath)")

        let s = CitadelSession()
        var received = Data()
        let collector = Task { for await chunk in s.output { received.append(chunk) } }
        defer { collector.cancel() }

        try await s.connect(host: host, port: port, user: user,
                            auth: .privateKey(pem, passphrase: nil))
        XCTAssertNotNil(s.remoteHostKey, "host key must be captured (TOFU)")

        try await s.openShell(termType: "xterm-256color", cols: 80, rows: 24)
        try await s.write(Data("echo hydra-b1-ok\n".utf8))

        let deadline = Date().addingTimeInterval(8)
        func got() -> Bool { String(decoding: received, as: UTF8.self).contains("hydra-b1-ok") }
        while Date() < deadline && !got() { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(got(), "shell echo did not round-trip; buffer: \(String(decoding: received, as: UTF8.self))")

        try await s.resize(cols: 100, rows: 30)                 // must not throw
        let uname = try await s.exec("uname")
        XCTAssertFalse(uname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "exec(uname) empty")

        s.disconnect()
    }
}
#endif
```

- [ ] **Step 3: 스킵 확인 (env 없이 CI-safe)**

Run: `cd /Users/dave/iWorks/hydra/Hydra && swift test --filter CitadelSessionSmokeTests 2>&1 | tail -10`
Expected: 1 test skipped (env 미설정) — 실패 아님.

- [ ] **Step 4: Docker 스모크 실제 실행 — Citadel 셸 왕복 증명 (B1 핵심 산출물)**

```bash
cd /Users/dave/iWorks/hydra
Hydra/Tests/smoke/citadel-openssh-docker.sh 2222        # READY host=... port=2222 출력
HYDRA_CITADEL_SMOKE_HOST=127.0.0.1 HYDRA_CITADEL_SMOKE_PORT=2222 HYDRA_CITADEL_SMOKE_USER=smoke \
  swift test --package-path Hydra --filter CitadelSessionSmokeTests 2>&1 | tail -20
docker rm -f hydra-citadel-smoke
```
Expected: `testInteractiveShellRoundTrip` PASS — connect(ed25519)+host key 캡처+`hydra-b1-ok` 에코 왕복+resize+`uname` exec 전부 성공. **이 PASS 출력을 리포트에 그대로 붙일 것.**
- Docker가 이 환경에 없으면: 그 사실을 리포트에 명시하고 컨트롤러에게 에스컬레이션(BLOCKED 대신 DONE_WITH_CONCERNS) — 컨트롤러가 직접 실행한다.

- [ ] **Step 5: 실노드 절차 문서화** — `Hydra/Tests/smoke/README.md`에 섹션 추가:

```markdown
## Citadel backend smoke (B1)

Repeatable (Docker):
    Hydra/Tests/smoke/citadel-openssh-docker.sh 2222
    HYDRA_CITADEL_SMOKE_HOST=127.0.0.1 HYDRA_CITADEL_SMOKE_PORT=2222 HYDRA_CITADEL_SMOKE_USER=smoke \
      swift test --package-path Hydra --filter CitadelSessionSmokeTests
    docker rm -f hydra-citadel-smoke

Real node (one-off — Citadel needs your ed25519 authorized there):
    ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<node>
    HYDRA_CITADEL_SMOKE_HOST=<node> HYDRA_CITADEL_SMOKE_USER=<user> \
      swift test --package-path Hydra --filter CitadelSessionSmokeTests

Or eyeball it in the app:
    HYDRA_SSH_BACKEND=citadel <launch the mac app>   # terminal tab now uses Citadel
```

- [ ] **Step 6: 커밋**

```bash
cd /Users/dave/iWorks/hydra
git add Hydra/Tests/smoke/citadel-openssh-docker.sh \
        Hydra/Tests/HydraTests/CitadelSessionSmokeTests.swift \
        Hydra/Tests/smoke/README.md
git commit -m "test(terminal): Docker OpenSSH smoke proving Citadel interactive shell

Opt-in CitadelSessionSmokeTests (skips without HYDRA_CITADEL_SMOKE_HOST) drives
connect(ed25519)/host-key capture/echo round-trip/resize/exec/disconnect against
a linuxserver/openssh-server container. Proves the pure-Swift backend end-to-end
on macOS before the B2 iOS port."
```

---

## Self-Review 체크

- **스펙 커버리지**: CitadelSession 복구+배선(T1) / env 스위치+링크+계약(T2) / Docker 스모크 셸왕복+실노드 문서(T3) / iOS 플랫폼 선언(T1) — 스펙 §3~§4 전부 태스크로 커버. 다중키-over-Citadel은 A의 순회가 팩토리만 바꾸면 그대로 동작하므로 별 태스크 불필요(스펙 §3.4); 앱에서 `HYDRA_SSH_BACKEND=citadel`로 눈확인은 T3 문서 절차로 커버.
- **Placeholder**: 없음. 복구는 git show 명령, 배선/코드/스크립트/테스트 전부 구체.
- **타입 일관성**: `CitadelSession()`(T1 복구) ↔ `defaultBackend()`(T2) ↔ 스모크(T3) 사용 일치. `SSHSession` 계약(connect/openShell/write/resize/exec/disconnect/remoteHostKey/output/state)은 복구본과 프로토콜에 이미 존재.
- **리스크**: T1 Step3의 의존성 해석이 유일한 실질 리스크 — 실패 시 `32d65d0`의 `Package.resolved` 핀 참조 지시 포함.

## Execution Handoff
계획 저장 완료. 사용자 글로벌 기본값([[plan-execution-default]])에 따라 **subagent-driven-development**로 바로 실행한다.
