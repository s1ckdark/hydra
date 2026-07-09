# 다중키 SSH 인증 수정 (하위 A) 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SSH 터미널이 `~/.ssh`의 키를 OpenSSH처럼 우선순위대로 순차 시도(첫 성공에서 멈춤)하도록 고쳐, 단일키 제시 버그를 없앤다. 백엔드(libssh2)는 건드리지 않는다.

**Architecture:** `SSHSession` 프로토콜과 `LibSSH2Session` 백엔드는 불변. 다중키 순회는 `TerminalSession`이 오케스트레이션한다. 자격 해석(user/port/키 목록)을 주입 가능한 `credentialResolver`로 분리해 디스크 의존 없이 테스트한다. 키 목록의 순수 부분은 `SSHKeyLocator.orderedKeyPairs()`가 담당(크로스플랫폼, 하위 B 재사용).

**Tech Stack:** Swift 6 (Hydra 앱 타깃, `.swiftLanguageMode(.v5)` 유지), XCTest, SwiftPM. macOS 전용 UI 계층(`#if os(macOS)`).

## Global Constraints
- `SSHSession.swift`, `LibSSH2Session.swift`, `Shout`/`CSSH`/`SSHTransportMac`, `FakeSSHSession.swift`(“do not edit”), `Package.swift`(양쪽)는 **수정 금지**. 이 작업은 앱 서비스 계층(`Hydra/Hydra/Services/`)과 테스트만 건드린다.
- 다중키 순회는 **인증이 성공한 세션에 대해서만** 호스트키 TOFU를 판정한다(authFailed 세션의 host key로 오판 금지).
- `authFailed`만 다음 키로 폴백한다. `unreachable`/`handshakeFailed` 등은 키 순회 없이 즉시 표면화한다.
- 키 우선순위: `id_ed25519` → `id_ecdsa` → `id_rsa` → `id_dsa`, 그 외는 파일명 사전순으로 뒤에. `config.yaml`이 지정한 키가 있으면 **맨 앞**, 이후 `orderedKeyPairs()`를 절대경로 dedup으로 append.
- 기존 5개 `TerminalSessionTests` + 전체 스위트가 그대로 통과해야 한다(회귀 0).
- 테스트는 실제 `~/.ssh`/`~/.hydra`를 **변경**하지 않는다(임시 디렉토리 주입). 읽기 전용 접근만 허용하며, 키 부재 시 `XCTSkip`.

---

### Task 1: SSHKeyLocator 다중키 API

**Files:**
- Modify: `Hydra/Hydra/Services/SSHKeyLocator.swift`
- Test: `Hydra/Tests/HydraTests/SSHKeyLocatorTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct SSHKeyLocator.KeyPair: Equatable { let privatePath: String; let publicURL: URL; let algorithmName: String }`
  - `static func orderedKeyPairs(in sshDir: URL = <~/.ssh>) throws -> [KeyPair]` — 우선순위 정렬, 개인키 존재하는 것만, 없으면 `LocateError.noKeysFound`.
  - `defaultPublicKey()` / `defaultPrivateKeyPath()` 는 시그니처 유지하되 내부적으로 `orderedKeyPairs().first`를 사용.

- [ ] **Step 1: 실패 테스트 작성** — `Hydra/Tests/HydraTests/SSHKeyLocatorTests.swift`

```swift
#if os(macOS)
import XCTest
@testable import Hydra

final class SSHKeyLocatorTests: XCTestCase {
    private func tempSSHDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hydra-ssh-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func write(_ dir: URL, _ name: String, _ contents: String = "x") {
        try? contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testOrdersEd25519BeforeRsa() throws {
        let dir = tempSSHDir(); defer { try? FileManager.default.removeItem(at: dir) }
        write(dir, "id_rsa"); write(dir, "id_rsa.pub")
        write(dir, "id_ed25519"); write(dir, "id_ed25519.pub")
        let pairs = try SSHKeyLocator.orderedKeyPairs(in: dir)
        XCTAssertEqual(pairs.map { $0.publicURL.deletingPathExtension().lastPathComponent },
                       ["id_ed25519", "id_rsa"])
        XCTAssertEqual(pairs.first?.algorithmName, "ed25519")
    }

    func testExcludesPubWithoutPrivate() throws {
        let dir = tempSSHDir(); defer { try? FileManager.default.removeItem(at: dir) }
        write(dir, "id_ed25519"); write(dir, "id_ed25519.pub")
        write(dir, "id_ecdsa.pub")  // 개인키 없음 → 제외
        let pairs = try SSHKeyLocator.orderedKeyPairs(in: dir)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.privatePath.hasSuffix("id_ed25519"), true)
    }

    func testEmptyThrowsNoKeysFound() {
        let dir = tempSSHDir(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try SSHKeyLocator.orderedKeyPairs(in: dir)) { err in
            guard case SSHKeyLocator.LocateError.noKeysFound = err else {
                return XCTFail("expected noKeysFound, got \(err)")
            }
        }
    }

    func testDefaultPrivateKeyMatchesFirst() throws {
        // 실제 ~/.ssh 를 읽기 전용으로만 사용. 키 없으면 skip.
        guard let pairs = try? SSHKeyLocator.orderedKeyPairs(), let first = pairs.first else {
            throw XCTSkip("no ~/.ssh keys on this machine")
        }
        XCTAssertEqual(try SSHKeyLocator.defaultPrivateKeyPath(), first.privatePath)
    }
}
#endif
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `cd Hydra && swift test --filter SSHKeyLocatorTests 2>&1 | tail -20`
Expected: 컴파일 실패 (`orderedKeyPairs`/`KeyPair` 미정의).

- [ ] **Step 3: 구현** — `SSHKeyLocator.swift`의 `defaultPublicKey()`/`preferred(among:)`/`defaultPrivateKeyPath()`를 아래로 교체(나머지 `LocateError`/`Located`/`copyToClipboard`/`preferenceOrder`는 유지).

```swift
    struct KeyPair: Equatable {
        let privatePath: String
        let publicURL: URL
        let algorithmName: String
    }

    private static func defaultSSHDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    /// All `~/.ssh` keypairs that have BOTH a `.pub` and a matching private key,
    /// ordered like OpenSSH would offer identities: preferenceOrder first, then
    /// any other keys by filename. Empty dir throws `.noKeysFound`.
    static func orderedKeyPairs(in sshDir: URL = defaultSSHDir()) throws -> [KeyPair] {
        let pubs = (try? FileManager.default.contentsOfDirectory(at: sshDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "pub" } ?? []

        var pairs: [KeyPair] = []
        for pub in pubs {
            let priv = pub.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: priv.path) else { continue }
            let base = priv.lastPathComponent
            pairs.append(KeyPair(privatePath: priv.path,
                                 publicURL: pub,
                                 algorithmName: algorithmName(forBasename: base)))
        }
        guard !pairs.isEmpty else { throw LocateError.noKeysFound }

        return pairs.sorted { a, b in
            let ra = rank(a.publicURL.deletingPathExtension().lastPathComponent)
            let rb = rank(b.publicURL.deletingPathExtension().lastPathComponent)
            if ra != rb { return ra < rb }
            return a.privatePath < b.privatePath
        }
    }

    private static func rank(_ basename: String) -> Int {
        preferenceOrder.firstIndex(of: basename) ?? preferenceOrder.count
    }

    static func algorithmName(forBasename base: String) -> String {
        base.hasPrefix("id_") ? String(base.dropFirst(3)) : base
    }

    static func defaultPublicKey() throws -> Located {
        guard let first = try orderedKeyPairs().first else { throw LocateError.noKeysFound }
        do {
            let raw = try String(contentsOf: first.publicURL, encoding: .utf8)
            return Located(url: first.publicURL, contents: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw LocateError.readFailed(error.localizedDescription)
        }
    }

    static func defaultPrivateKeyPath() throws -> String {
        guard let first = try orderedKeyPairs().first else { throw LocateError.noKeysFound }
        return first.privatePath
    }
```

> 삭제: 기존 `defaultPublicKey()` 본문, `private static func preferred(among:)`. `preferenceOrder`는 그대로 둔다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `cd Hydra && swift test --filter SSHKeyLocatorTests 2>&1 | tail -20`
Expected: 4 테스트 PASS (키 없는 머신이면 `testDefaultPrivateKeyMatchesFirst`는 skip).

- [ ] **Step 5: 커밋**

```bash
git add Hydra/Hydra/Services/SSHKeyLocator.swift Hydra/Tests/HydraTests/SSHKeyLocatorTests.swift
git commit -m "feat(ssh): SSHKeyLocator.orderedKeyPairs for OpenSSH-style multi-key ordering"
```

---

### Task 2: TerminalSession 다중키 오케스트레이션

**Files:**
- Modify: `Hydra/Hydra/Services/TerminalSession.swift`
- Test: `Hydra/Tests/HydraTests/ScriptedSSHSession.swift` (create), `Hydra/Tests/HydraTests/TerminalSessionMultiKeyTests.swift` (create)

**Interfaces:**
- Consumes: `SSHKeyLocator.orderedKeyPairs()`, `SSHKeyLocator.algorithmName(forBasename:)` (Task 1).
- Produces (internal, `#if os(macOS)`):
  - `struct ResolvedKey: Equatable { let path: String; let pem: Data; let algorithm: String }`
  - `struct SSHCredentials { let user: String; let port: Int; let keys: [ResolvedKey] }`
  - `TerminalSession.init(device:sessionFactory:knownHostsURL:credentialResolver:)` — 새 파라미터 `credentialResolver: @escaping () -> SSHCredentials = TerminalSession.defaultCredentials`.
  - `static func defaultCredentials() -> SSHCredentials`.

- [ ] **Step 1: 테스트 더블 작성** — `Hydra/Tests/HydraTests/ScriptedSSHSession.swift`

```swift
#if os(macOS)
import Foundation
import SSHTransport

/// Test double whose connect() outcome is scripted per instance, so a factory
/// can hand TerminalSession a fresh scripted session per key attempt. (Vendored
/// FakeSSHSession is "do not edit" and always auth-succeeds, so it can't drive
/// the fallback loop.)
final class ScriptedSSHSession: SSHSession {
    enum Outcome { case authFail; case succeed(HostKeyFingerprint?); case unreachable }
    let outcome: Outcome
    private(set) var connectCalled = false
    private(set) var openShellCalled = false

    let output: AsyncStream<Data>
    let state: AsyncStream<SSHState>
    private let oc: AsyncStream<Data>.Continuation
    private let sc: AsyncStream<SSHState>.Continuation
    private(set) var remoteHostKey: HostKeyFingerprint?

    init(_ outcome: Outcome) {
        self.outcome = outcome
        var o: AsyncStream<Data>.Continuation!; output = AsyncStream { o = $0 }; oc = o
        var s: AsyncStream<SSHState>.Continuation!; state = AsyncStream { s = $0 }; sc = s
    }
    func connect(host: String, port: Int, user: String, auth: SSHAuth) async throws {
        connectCalled = true
        sc.yield(.connecting)
        switch outcome {
        case .authFail:    throw SSHError.authFailed("scripted-auth-fail")
        case .unreachable: throw SSHError.unreachable("scripted-unreachable")
        case .succeed(let hk): remoteHostKey = hk; sc.yield(.connected)
        }
    }
    func openShell(termType: String, cols: Int, rows: Int) async throws {
        openShellCalled = true
        oc.yield(Data("scripted$ ".utf8))
    }
    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func exec(_ command: String) async throws -> String { "" }
    func disconnect() { sc.yield(.disconnected(reason: nil)); oc.finish(); sc.finish() }
}
#endif
```

- [ ] **Step 2: 실패 테스트 작성** — `Hydra/Tests/HydraTests/TerminalSessionMultiKeyTests.swift`

```swift
#if os(macOS)
import XCTest
import SSHTransport
import KnownHosts
@testable import Hydra

@MainActor
final class TerminalSessionMultiKeyTests: XCTestCase {
    private func device() -> Device {
        Device(id: "gpu1", name: "gpu1", hostname: "gpu1", ipAddresses: [], tailscaleIp: "100.0.0.1",
               os: "Linux", status: "online", isExternal: false, tags: nil, user: "dave",
               lastSeen: Date(), sshEnabled: true, hasGpu: true, gpuModel: "RTX", gpuCount: 1)
    }
    private func tempKH() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hydra-kh-\(UUID().uuidString)")
    }
    private func creds(_ algos: [String]) -> SSHCredentials {
        SSHCredentials(user: "dave", port: 22,
                       keys: algos.map { ResolvedKey(path: "/k/id_\($0)", pem: Data(), algorithm: $0) })
    }
    private let fakeFp = HostKeyFingerprint(keyType: "ssh-ed25519",
                                            publicKeyBase64: "AAAAFAKE",
                                            sha256Hex: String(repeating: "00", count: 32))

    func testFallsBackToSecondKey() async {
        let kh = tempKH(); defer { try? FileManager.default.removeItem(at: kh) }
        try? KnownHostsStore(fileURL: kh).trust(
            KnownHostsEntry(hostPattern: "100.0.0.1", keyType: "ssh-ed25519", publicKey: "AAAAFAKE"))
        var outcomes: [ScriptedSSHSession.Outcome] = [.authFail, .succeed(fakeFp)]
        var minted: [ScriptedSSHSession] = []
        let session = TerminalSession(device: device(),
            sessionFactory: { let s = ScriptedSSHSession(outcomes.removeFirst()); minted.append(s); return s },
            knownHostsURL: kh,
            credentialResolver: { self.creds(["ed25519", "rsa"]) })
        await session.connect(cols: 80, rows: 24)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(minted.count, 2)
        XCTAssertTrue(minted[0].connectCalled)
        XCTAssertTrue(minted[1].openShellCalled)
        XCTAssertEqual(session.state, .connected)
    }

    func testAllKeysRejected() async {
        let kh = tempKH(); defer { try? FileManager.default.removeItem(at: kh) }
        var outcomes: [ScriptedSSHSession.Outcome] = [.authFail, .authFail]
        var minted = 0
        let session = TerminalSession(device: device(),
            sessionFactory: { minted += 1; return ScriptedSSHSession(outcomes.removeFirst()) },
            knownHostsURL: kh,
            credentialResolver: { self.creds(["ed25519", "rsa"]) })
        await session.connect(cols: 80, rows: 24)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(minted, 2)
        guard case .disconnected(let r) = session.state else {
            return XCTFail("expected disconnected, got \(session.state)")
        }
        XCTAssertTrue(r?.contains("ed25519, rsa") ?? false)
        XCTAssertTrue(r?.contains("ssh-copy-id") ?? false)
    }

    func testUnknownHostStopsAndPrompts() async {
        let kh = tempKH(); defer { try? FileManager.default.removeItem(at: kh) }
        var outcomes: [ScriptedSSHSession.Outcome] = [.succeed(fakeFp), .succeed(fakeFp)]
        var minted = 0
        let session = TerminalSession(device: device(),
            sessionFactory: { minted += 1; return ScriptedSSHSession(outcomes.removeFirst()) },
            knownHostsURL: kh,
            credentialResolver: { self.creds(["ed25519", "rsa"]) })
        await session.connect(cols: 80, rows: 24)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(minted, 1)   // 첫 성공 후 신뢰 대기로 중단
        guard case .needsTrust = session.hostKeyPrompt else {
            return XCTFail("expected needsTrust, got \(String(describing: session.hostKeyPrompt))")
        }
    }

    func testUnreachableStopsImmediately() async {
        let kh = tempKH(); defer { try? FileManager.default.removeItem(at: kh) }
        var minted = 0
        let session = TerminalSession(device: device(),
            sessionFactory: { minted += 1; return ScriptedSSHSession(.unreachable) },
            knownHostsURL: kh,
            credentialResolver: { self.creds(["ed25519", "rsa"]) })
        await session.connect(cols: 80, rows: 24)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(minted, 1)   // 두 번째 키 시도 안 함
        guard case .disconnected(let r) = session.state else {
            return XCTFail("expected disconnected, got \(session.state)")
        }
        XCTAssertTrue(r?.contains("도달 불가") ?? false)
    }
}
#endif
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `cd Hydra && swift test --filter TerminalSessionMultiKeyTests 2>&1 | tail -20`
Expected: 컴파일 실패 (`SSHCredentials`/`ResolvedKey`/`credentialResolver` 미정의).

- [ ] **Step 4: 구현** — `TerminalSession.swift` 편집.

(4a) 파일 상단 `import KnownHosts` 아래(여전히 `#if os(macOS)` 블록 안)에 자격 타입 추가:

```swift
struct ResolvedKey: Equatable {
    let path: String
    let pem: Data
    let algorithm: String
}

struct SSHCredentials {
    let user: String
    let port: Int
    let keys: [ResolvedKey]   // OpenSSH-style ordered offer list
}
```

(4b) `init`에 `credentialResolver` 파라미터 추가 + 저장:

```swift
    private let sessionFactory: () -> SSHSession
    private let credentialResolver: () -> SSHCredentials
    private var session: SSHSession
    // ...

    init(device: Device,
         sessionFactory: @escaping () -> SSHSession,
         knownHostsURL: URL? = nil,
         credentialResolver: @escaping () -> SSHCredentials = TerminalSession.defaultCredentials) {
        self.id = device.id
        self.deviceId = device.id
        self.deviceName = device.displayName
        self.host = device.tailscaleIp
        self.sessionFactory = sessionFactory
        self.credentialResolver = credentialResolver
        self.session = sessionFactory()
        let khURL = knownHostsURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
        self.knownHosts = KnownHostsStore(fileURL: khURL)
    }
```

(4c) `connect(cols:rows:)` 본문 전체를 아래로 교체:

```swift
    func connect(cols: Int, rows: Int) async {
        isTerminalStateLocked = false
        pumpTask?.cancel()
        statePumpTask?.cancel()
        session.disconnect()
        pendingShell = (cols, rows)

        let creds = credentialResolver()
        guard !creds.keys.isEmpty else {
            state = .disconnected(reason: "SSH 개인키를 찾을 수 없습니다. ~/.ssh 에 키를 만들어주세요.")
            return
        }

        state = .connecting
        var lastAuthError: String?

        // OpenSSH-style: offer each key in order until one authenticates.
        for key in creds.keys {
            let s = sessionFactory()
            self.session = s
            do {
                try await s.connect(host: host, port: creds.port, user: creds.user,
                                    auth: .privateKey(key.pem, passphrase: nil))
            } catch let e as SSHError {
                if case .authFailed(let m) = e {
                    lastAuthError = m
                    s.disconnect()
                    continue                      // 다음 키로 폴백
                }
                state = .disconnected(reason: describe(e))   // unreachable/handshake 등 즉시 실패
                return
            } catch {
                state = .disconnected(reason: "\(error)")
                return
            }
            // 인증 성공 세션에 대해서만 호스트키 TOFU 판정
            switch HostKeyGate.evaluate(host: host, fingerprint: s.remoteHostKey, store: knownHosts) {
            case .proceed:
                startStatePump()
                await openShellNow()
                return
            case .needsTrust(let sha):
                startStatePump()
                hostKeyPrompt = .needsTrust(sha256: sha)
                return
            case .blocked:
                isTerminalStateLocked = true
                state = .disconnected(reason: "호스트키 불일치 — 연결 차단")
                s.disconnect()
                return
            }
        }

        // 모든 키 인증 실패
        if let m = lastAuthError { NSLog("[terminal] all offered keys rejected; last: \(m)") }
        let algos = creds.keys.map(\.algorithm).joined(separator: ", ")
        state = .disconnected(reason:
            "제시한 키(\(algos))가 \(host)에 등록돼 있지 않습니다. ssh-copy-id로 공개키를 등록하세요.")
    }
```

(4d) 파일 하단(클래스 안, `describe` 근처)에 기본 자격 해석기 추가:

```swift
    /// Default credential resolution: config.yaml (user/port + its key first),
    /// then `~/.ssh` keys in OpenSSH preference order, deduped by absolute path.
    static func defaultCredentials() -> SSHCredentials {
        let user: String
        let port: Int
        var paths: [String] = []
        if let r = ClusterSSHConfig.load() {
            user = r.user; port = r.port
            paths.append(r.privateKeyPath)
        } else {
            user = NSUserName(); port = 22
        }
        if let pairs = try? SSHKeyLocator.orderedKeyPairs() {
            for kp in pairs where !paths.contains(kp.privatePath) {
                paths.append(kp.privatePath)
            }
        }
        let keys: [ResolvedKey] = paths.compactMap { p in
            guard let pem = FileManager.default.contents(atPath: p) else { return nil }
            let base = (p as NSString).lastPathComponent
            return ResolvedKey(path: p, pem: pem,
                               algorithm: SSHKeyLocator.algorithmName(forBasename: base))
        }
        return SSHCredentials(user: user, port: port, keys: keys)
    }
```

> `trustPendingHostKey()`/`cancelPendingHostKey()`/`openShellNow()`/`startStatePump()`/`startOutputPump()`/`describe()`는 **변경하지 않는다** — 승리한(인증된) `session`을 그대로 사용한다.

- [ ] **Step 5: 신규 테스트 통과 확인**

Run: `cd Hydra && swift test --filter TerminalSessionMultiKeyTests 2>&1 | tail -30`
Expected: 4 테스트 PASS.

- [ ] **Step 6: 회귀 — 기존 TerminalSession 테스트 통과 확인**

Run: `cd Hydra && swift test --filter TerminalSessionTests 2>&1 | tail -30`
Expected: 기존 5 테스트 PASS (FakeSSHSession은 첫 키에서 인증 성공하므로 단일 시도 동작 유지).

- [ ] **Step 7: 전체 스위트 통과 확인**

Run: `cd Hydra && swift test 2>&1 | tail -15`
Expected: 전체 PASS (기존 64 + 신규 8).

- [ ] **Step 8: 커밋**

```bash
git add Hydra/Hydra/Services/TerminalSession.swift \
        Hydra/Tests/HydraTests/ScriptedSSHSession.swift \
        Hydra/Tests/HydraTests/TerminalSessionMultiKeyTests.swift
git commit -m "feat(ssh): OpenSSH-style multi-key auth fallback in TerminalSession

Try ~/.ssh keys in preference order until one authenticates; TOFU only on
the authenticated session; non-auth errors surface immediately. Fixes the
single-key-offering bug (a key not authorized on a node previously failed
with no fallback)."
```

---

## Self-Review 체크

- **스펙 커버리지**: 다중키 순회(Task 2) / orderedKeyPairs(Task 1) / TOFU-후-인증 순서(Task 2 step4c + testUnknownHostStopsAndPrompts) / 실행가능 에러(testAllKeysRejected) / config 우선키+dedup(defaultCredentials) / unreachable 즉시실패(testUnreachableStopsImmediately) — 모두 태스크로 커버. 실 노드 스모크는 기존 `SSHDiagnosisTests`/수동 검증으로 남김(스펙 §6, opt-in, 신설 선택).
- **Placeholder**: 없음. 모든 코드 블록 완전.
- **타입 일관성**: `SSHKeyLocator.KeyPair`/`algorithmName(forBasename:)`(Task 1) ↔ `defaultCredentials`(Task 2)에서 사용 일치. `ResolvedKey`/`SSHCredentials`는 Task 2에서 정의·소비. `HostKeyDecision.needsTrust(sha256:)`/`SSHError.authFailed(_)`/`describe(_:)` 기존 시그니처와 일치.

## Execution Handoff
계획 저장 완료. 사용자 글로벌 기본값([[plan-execution-default]])에 따라 **subagent-driven-development**로 바로 실행한다.
