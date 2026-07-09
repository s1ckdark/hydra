# 앱 내 SSH 터미널 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Naga/Hydra macOS 앱에 Terminal 탭을 추가해, Devices에서 고른 클러스터 노드에 Citadel(순수 Swift SSH)로 라이브 셸 세션을 연다 — SwiftTerm AppKit 뷰로 렌더, 자격은 `~/.clusterctl/config.yaml` 재사용, 호스트키는 TOFU.

**Architecture:** `iWorks/terminal`의 UI 독립적 SSH 모듈 3개(SSHTransport/SSHTransportCitadel/KnownHosts + FakeSSHSession)를 `Hydra/Packages/TerminalCore`로 벤더 복사하고 SwiftTerm은 git 의존으로 건다(둘 다 macOS-조건부 링크 — iOS 빌드 불변). 그 위에 hydra 고유의 얇은 조율 계층(`ClusterSSHConfig` 파서, `HostKeyDecision` 순수 함수, `TerminalSession`/`TerminalSessionStore`)을 얹고, `NSViewRepresentable`로 `TerminalView`를 감싼 Terminal 탭 UI로 잇는다. 순수 로직·세션 흐름은 `FakeSSHSession` 주입으로 실 SSH 없이 XCTest.

**Tech Stack:** Swift 5 / SwiftUI (macOS, SwiftPM `Hydra/`), XCTest, SwiftTerm(`s1ckdark/SwiftTerm` 포크), Citadel(swift-nio-ssh), 벤더 TerminalCore.

**스펙:** `docs/superpowers/specs/2026-07-09-in-app-ssh-terminal-design.md`

## Global Constraints

- 브랜치: `feature/in-app-ssh-terminal` (이미 체크아웃됨 — 스펙 커밋 존재)
- 커밋 메시지: 기존 스타일 + 마지막 줄 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Swift 빌드/테스트: `cd Hydra && swift build` / `cd Hydra && swift test` (XCTest, `@testable import Hydra`)
- 앱 번들: 리포 루트에서 `make hydra-app`
- **모든 터미널 UI/세션 코드는 `#if os(macOS)` 게이트** (기존 TasksView/ConsoleView/EmbeddedServer 관례)
- SSH 백엔드: **Citadel** 단일 (libssh2/Shout 배제)
- 자격: **`~/.clusterctl/config.yaml`의 `ssh.user`/`ssh.private_key_path`/`ssh.port`** (Go `SSHConfig`와 동일 필드) + 없으면 `SSHKeyLocator`(hydra 기존) 폴백
- host: **`Device.tailscaleIp`**
- 호스트키: **TOFU + `~/.ssh/known_hosts` 영속화** — Citadel transport는 `acceptAnything`이므로 검증은 **앱 레이어에서 connect 후·openShell 전** `session.remoteHostKey`를 `KnownHostsStore`와 대조
- 벤더 복사는 **단방향** — 복사 파일 상단에 `// vendored from iWorks/terminal @ <commit>, do not edit here`
- 파일 위치: 서비스 `Hydra/Hydra/Services/`, 뷰모델 `Hydra/Hydra/ViewModels/`(필요 시), 뷰 `Hydra/Hydra/Views/Terminal/`, 벤더 패키지 `Hydra/Packages/TerminalCore/`, 테스트 `Hydra/Tests/HydraTests/`

## 참고 — 확인된 외부 API (구현 시 그대로 사용)

- `SSHSession` 프로토콜(`SSHTransport`): `var output: AsyncStream<Data>`, `var state: AsyncStream<SSHState>`, `var remoteHostKey: HostKeyFingerprint?`, `func connect(host:port:user:auth:) async throws`, `func openShell(termType:cols:rows:) async throws`, `func write(_:) async throws`, `func resize(cols:rows:) async throws`, `func disconnect()`.
- `SSHState`: `.idle/.connecting/.connected/.disconnected(reason: String?)`. `SSHAuth`: `.privateKey(Data, passphrase: String?)`, `.password(String)`. `SSHError`: `.unreachable/.handshakeFailed/.authFailed/.channelFailed/.disconnected`.
- `HostKeyFingerprint`: `{ keyType: String, publicKeyBase64: String, sha256Hex: String }`.
- `KnownHostsEntry(hostPattern: String, keyType: String, publicKey: String)`. `KnownHostsStore(fileURL: URL)` → `check(_:) throws -> KnownHostsCheck` (`.unknown/.match/.mismatch`), `trust(_:) throws`.
- `FakeSSHSession()` conforms to `SSHSession` (connect yields .connecting→.connected; openShell yields `"fake$ "`; write echoes). remoteHostKey = ed25519 stub.
- `CitadelSession()`: `SSHSession` 구현, connect 시 `acceptAnything` transport.
- SwiftTerm: `open class TerminalView: NSView` (macOS). `public init(frame:font:)`. 사용자 입력·리사이즈는 `TerminalViewDelegate`(뷰의 `terminalDelegate` 프로퍼티)로 콜백; 데이터 주입은 뷰의 `feed(byteArray:)`. **정확한 delegate 메서드 시그니처(send/sizeChanged 등)는 벤더된 SwiftTerm 소스에서 확인**해 conform할 것(외부 라이브러리 — grep으로 확정).

---

### Task 1: TerminalCore 벤더링 + 패키지 의존 배선

**Files:**
- Create: `Hydra/Packages/TerminalCore/Package.swift`
- Create (복사): `Hydra/Packages/TerminalCore/Sources/{SSHTransport,SSHTransportCitadel,KnownHosts}/**` (terminal 레포에서 verbatim cp)
- Modify: `Hydra/Package.swift` (SwiftTerm git + 로컬 TerminalCore 의존, macOS 조건부)
- Test: `Hydra/Tests/HydraTests/VendoredTerminalCoreTests.swift`

**Interfaces:**
- Produces: `import SSHTransport`, `import SSHTransportCitadel`, `import KnownHosts`, `import SwiftTerm`가 macOS 빌드에서 링크됨. `FakeSSHSession`, `KnownHostsStore`, `CitadelSession`, `SSHSession`, `SSHState`, `HostKeyFingerprint`, `KnownHostsEntry` 사용 가능.

- [ ] **Step 1: 벤더 소스 복사 + 출처 스탬프**

```bash
cd /Users/dave/iWorks/hydra
SRC=/Users/dave/iWorks/terminal/Packages/TerminalCore/Sources
DST=Hydra/Packages/TerminalCore/Sources
mkdir -p "$DST"
cp -R "$SRC/SSHTransport" "$SRC/SSHTransportCitadel" "$SRC/KnownHosts" "$DST/"
# 출처 커밋 스탬프
TCOMMIT=$(git -C /Users/dave/iWorks/terminal rev-parse --short HEAD)
find "$DST" -name '*.swift' -print0 | while IFS= read -r -d '' f; do
  printf '// vendored from iWorks/terminal @ %s, do not edit here\n%s\n' "$TCOMMIT" "$(cat "$f")" > "$f"
done
```

- [ ] **Step 2: 벤더 패키지 Package.swift 작성 (macOS 전용, Citadel만)**

```swift
// Hydra/Packages/TerminalCore/Package.swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SSHTransport",        targets: ["SSHTransport"]),
        .library(name: "SSHTransportCitadel",  targets: ["SSHTransportCitadel"]),
        .library(name: "KnownHosts",           targets: ["KnownHosts"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.9.2"),
    ],
    targets: [
        .target(name: "SSHTransport"),
        .target(
            name: "SSHTransportCitadel",
            dependencies: ["SSHTransport", .product(name: "Citadel", package: "Citadel")],
            swiftSettings: [ .swiftLanguageMode(.v5) ]   // Citadel API는 non-Sendable — 원본과 동일 posture
        ),
        .target(name: "KnownHosts"),
    ]
)
```

**주의 (플랫폼 결정):** Citadel/swift-nio-ssh가 `.macOS(.v14)`에서 빌드 실패하고 "requires macOS 15"를 요구하면, 이 파일과 `Hydra/Package.swift`의 macOS 플로어를 **둘 다 `.macOS(.v15)`로 올린다** (수용된 배포 플로어 변경 — 커밋 메시지에 명시). 먼저 v14로 시도하고, SwiftPM이 강제할 때만 올릴 것.

- [ ] **Step 3: hydra Package.swift에 의존 추가 (macOS 조건부 링크)**

```swift
// Hydra/Package.swift — dependencies/targets 교체
let package = Package(
    name: "Hydra",
    platforms: [ .macOS(.v14), .iOS(.v17) ],
    products: [ .executable(name: "Hydra", targets: ["Hydra"]) ],
    dependencies: [
        .package(url: "https://github.com/s1ckdark/SwiftTerm", revision: "54b436a6231976fa64d7c3859d0b197a6ccfcb91"),
        .package(path: "Packages/TerminalCore"),
    ],
    targets: [
        .executableTarget(
            name: "Hydra",
            dependencies: [
                // 터미널 기능은 macOS 전용 — iOS 빌드에는 링크하지 않음
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
                .product(name: "SSHTransport", package: "TerminalCore", condition: .when(platforms: [.macOS])),
                .product(name: "SSHTransportCitadel", package: "TerminalCore", condition: .when(platforms: [.macOS])),
                .product(name: "KnownHosts", package: "TerminalCore", condition: .when(platforms: [.macOS])),
            ],
            path: "Hydra",
            resources: [ .process("Assets.xcassets") ]
        ),
        .testTarget(
            name: "HydraTests",
            dependencies: ["Hydra"],
            path: "Tests/HydraTests"
        ),
    ]
)
```

- [ ] **Step 4: 링크 검증 테스트 작성 (벤더 모듈이 실제로 붙는지)**

```swift
// Hydra/Tests/HydraTests/VendoredTerminalCoreTests.swift
#if os(macOS)
import XCTest
import SSHTransport
import KnownHosts
@testable import Hydra

final class VendoredTerminalCoreTests: XCTestCase {
    func testFakeSessionLinksAndConnects() async throws {
        let s = FakeSSHSession()
        try await s.connect(host: "h", port: 22, user: "u", auth: .password("x"))
        // remoteHostKey 스텁이 노출된다 (모듈 링크 확인)
        XCTAssertEqual(s.remoteHostKey?.keyType, "ssh-ed25519")
    }

    func testKnownHostsStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kh-\(UUID().uuidString)")
        let store = KnownHostsStore(fileURL: url)
        let e = KnownHostsEntry(hostPattern: "1.2.3.4", keyType: "ssh-ed25519", publicKey: "AAAAKEY")
        XCTAssertEqual(try store.check(e), .unknown)
        try store.trust(e)
        XCTAssertEqual(try store.check(e), .match)
        let e2 = KnownHostsEntry(hostPattern: "1.2.3.4", keyType: "ssh-ed25519", publicKey: "DIFFERENT")
        XCTAssertEqual(try store.check(e2), .mismatch)
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
```

- [ ] **Step 5: 빌드 + 테스트 확인**

Run: `cd Hydra && swift build 2>&1 | tail -5 && swift test --filter VendoredTerminalCoreTests 2>&1 | tail -8`
Expected: Build complete; 2 tests passed. (Citadel가 macOS 15를 강제하면 Step 2 주의대로 플로어 상향 후 재빌드.)

- [ ] **Step 6: 커밋**

```bash
git add Hydra/Packages/TerminalCore Hydra/Package.swift Hydra/Tests/HydraTests/VendoredTerminalCoreTests.swift
git commit -m "build(app): TerminalCore 벤더링(SSHTransport/Citadel/KnownHosts) + SwiftTerm 의존 (macOS 조건부)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: ClusterSSHConfig — config.yaml 자격 파서

**Files:**
- Create: `Hydra/Hydra/Services/ClusterSSHConfig.swift`
- Test: `Hydra/Tests/HydraTests/ClusterSSHConfigTests.swift`

**Interfaces:**
- Produces:
  - `struct ClusterSSHConfig { struct Resolved { let user: String; let privateKeyPath: String; let port: Int } }`
  - `static func load(from yaml: String) -> Resolved?` (순수 함수 — 테스트)
  - `static func load() -> Resolved?` (`~/.clusterctl/config.yaml` 읽어 위 호출; 없으면 nil)

주의: 외부 YAML 라이브러리 없이 필요한 세 키만 라인 스캔으로 추출한다(전체 YAML 파싱 아님). `ssh:` 블록 안의 `user:`, `private_key_path:`, `port:`를 찾는다. `~`는 홈 디렉터리로 확장한다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Hydra/Tests/HydraTests/ClusterSSHConfigTests.swift
import XCTest
@testable import Hydra

final class ClusterSSHConfigTests: XCTestCase {
    func testParsesSSHBlock() {
        let yaml = """
        agent:
          ai:
            always_consult: false
        ssh:
          user: dave
          private_key_path: ~/.ssh/id_ed25519
          port: 22
          timeout: 10
        """
        let r = ClusterSSHConfig.load(from: yaml)
        XCTAssertEqual(r?.user, "dave")
        XCTAssertEqual(r?.privateKeyPath, NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath)
        XCTAssertEqual(r?.port, 22)
    }

    func testDefaultsPortTo22WhenMissing() {
        let yaml = "ssh:\n  user: bob\n  private_key_path: /home/bob/.ssh/id_rsa\n"
        let r = ClusterSSHConfig.load(from: yaml)
        XCTAssertEqual(r?.port, 22)
        XCTAssertEqual(r?.user, "bob")
    }

    func testReturnsNilWhenNoUser() {
        XCTAssertNil(ClusterSSHConfig.load(from: "devices: []\n"))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter ClusterSSHConfigTests 2>&1 | tail -8`
Expected: 컴파일 실패 — `cannot find 'ClusterSSHConfig'`

- [ ] **Step 3: 구현**

```swift
// Hydra/Hydra/Services/ClusterSSHConfig.swift
import Foundation

/// Reads SSH credentials from ~/.clusterctl/config.yaml — the SAME source the
/// Go server uses (ssh.user / ssh.private_key_path / ssh.port), so a node the
/// server can reach, the terminal can reach with identical creds. Minimal
/// line-scan of the `ssh:` block (no YAML dependency).
struct ClusterSSHConfig {
    struct Resolved {
        let user: String
        let privateKeyPath: String
        let port: Int
    }

    static func load() -> Resolved? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clusterctl/config.yaml")
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return load(from: yaml)
    }

    static func load(from yaml: String) -> Resolved? {
        // Find the `ssh:` block and scan its indented children until dedent.
        let lines = yaml.components(separatedBy: "\n")
        var inSSH = false
        var user: String?
        var keyPath: String?
        var port = 22
        for line in lines {
            if !inSSH {
                if line.trimmingCharacters(in: .whitespaces) == "ssh:" { inSSH = true }
                continue
            }
            // Dedent (a non-indented, non-empty line) ends the ssh block.
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            if let v = value(t, key: "user") { user = v }
            else if let v = value(t, key: "private_key_path") { keyPath = expand(v) }
            else if let v = value(t, key: "port"), let p = Int(v) { port = p }
        }
        guard let u = user, let k = keyPath else { return nil }
        return Resolved(user: u, privateKeyPath: k, port: port)
    }

    private static func value(_ line: String, key: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    private static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
```

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd Hydra && swift test --filter ClusterSSHConfigTests 2>&1 | tail -8`
Expected: 3 tests passed

```bash
git add Hydra/Hydra/Services/ClusterSSHConfig.swift Hydra/Tests/HydraTests/ClusterSSHConfigTests.swift
git commit -m "feat(app): ClusterSSHConfig — config.yaml에서 ssh user/key/port 추출 (Go 서버와 동일 소스)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: HostKeyDecision — TOFU 판정 순수 함수

**Files:**
- Create: `Hydra/Hydra/Services/HostKeyDecision.swift`
- Test: `Hydra/Tests/HydraTests/HostKeyDecisionTests.swift`

**Interfaces:**
- Consumes: `KnownHosts.KnownHostsStore`, `SSHTransport.HostKeyFingerprint`
- Produces:
  - `enum HostKeyDecision: Equatable { case proceed; case needsTrust(sha256: String); case blocked }`
  - `enum HostKeyGate { static func evaluate(host: String, fingerprint: HostKeyFingerprint?, store: KnownHostsStore) -> HostKeyDecision; static func entry(host: String, fingerprint: HostKeyFingerprint) -> KnownHostsEntry }`
  - 규칙: fingerprint nil → `.blocked`(호스트키 못 받음); store.check == .match → `.proceed`; .unknown → `.needsTrust(sha256)`; .mismatch → `.blocked`. check가 throw하면 `.needsTrust`로 취급(파일 못 읽음 = 미지).

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Hydra/Tests/HydraTests/HostKeyDecisionTests.swift
#if os(macOS)
import XCTest
import SSHTransport
import KnownHosts
@testable import Hydra

final class HostKeyDecisionTests: XCTestCase {
    private func tempStore() -> (KnownHostsStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("khd-\(UUID().uuidString)")
        return (KnownHostsStore(fileURL: url), url)
    }
    private func fp(_ pub: String) -> HostKeyFingerprint {
        HostKeyFingerprint(keyType: "ssh-ed25519", publicKeyBase64: pub, sha256Hex: "ab12")
    }

    func testUnknownHostNeedsTrust() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.1.1.1", fingerprint: fp("K1"), store: store),
                       .needsTrust(sha256: "ab12"))
    }

    func testTrustedHostProceeds() throws {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        try store.trust(HostKeyGate.entry(host: "1.1.1.1", fingerprint: fp("K1")))
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.1.1.1", fingerprint: fp("K1"), store: store), .proceed)
    }

    func testChangedKeyBlocked() throws {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        try store.trust(HostKeyGate.entry(host: "1.1.1.1", fingerprint: fp("K1")))
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.1.1.1", fingerprint: fp("K2"), store: store), .blocked)
    }

    func testNilFingerprintBlocked() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(HostKeyGate.evaluate(host: "1.1.1.1", fingerprint: nil, store: store), .blocked)
    }
}
#endif
```

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter HostKeyDecisionTests 2>&1 | tail -8`
Expected: 컴파일 실패 — `cannot find 'HostKeyGate'`

- [ ] **Step 3: 구현**

```swift
// Hydra/Hydra/Services/HostKeyDecision.swift
#if os(macOS)
import Foundation
import SSHTransport
import KnownHosts

enum HostKeyDecision: Equatable {
    case proceed
    case needsTrust(sha256: String)
    case blocked
}

/// TOFU gate: Citadel's transport uses acceptAnything, so host-key enforcement
/// happens here at the app layer after connect() and before openShell().
enum HostKeyGate {
    static func entry(host: String, fingerprint: HostKeyFingerprint) -> KnownHostsEntry {
        KnownHostsEntry(hostPattern: host,
                        keyType: fingerprint.keyType,
                        publicKey: fingerprint.publicKeyBase64)
    }

    static func evaluate(host: String, fingerprint: HostKeyFingerprint?, store: KnownHostsStore) -> HostKeyDecision {
        guard let fp = fingerprint else { return .blocked }
        let e = entry(host: host, fingerprint: fp)
        let check = (try? store.check(e)) ?? .unknown
        switch check {
        case .match:    return .proceed
        case .unknown:  return .needsTrust(sha256: fp.sha256Hex)
        case .mismatch: return .blocked
        }
    }
}
#endif
```

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd Hydra && swift test --filter HostKeyDecisionTests 2>&1 | tail -8`
Expected: 4 tests passed

```bash
git add Hydra/Hydra/Services/HostKeyDecision.swift Hydra/Tests/HydraTests/HostKeyDecisionTests.swift
git commit -m "feat(app): HostKeyGate — TOFU 판정 순수 함수 (proceed/needsTrust/blocked)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: TerminalSession + TerminalSessionStore

**Files:**
- Create: `Hydra/Hydra/Services/TerminalSession.swift`
- Create: `Hydra/Hydra/Services/TerminalSessionStore.swift`
- Test: `Hydra/Tests/HydraTests/TerminalSessionTests.swift`

**Interfaces:**
- Consumes: `SSHSession`/`SSHState`/`SSHAuth`/`FakeSSHSession` (SSHTransport), `ClusterSSHConfig`, `SSHKeyLocator`(기존), `Device`(기존)
- Produces:
  - `@MainActor final class TerminalSession: ObservableObject, Identifiable`
    - `let id: String`, `let deviceId: String`, `let deviceName: String`, `let host: String`
    - `@Published var state: SSHState`, `@Published var lines: [String]` (테스트 관찰용 — 수신 출력 누적; 실제 렌더는 뷰가 feed)
    - `init(device: Device, session: SSHSession)` (session 주입)
    - `func connect(cols: Int, rows: Int) async` / `func send(_ data: Data)` / `func resize(cols: Int, rows: Int)` / `func close()`
    - `var onOutput: ((Data) -> Void)?` — 뷰가 SwiftTerm feed 하려고 구독
  - `@MainActor final class TerminalSessionStore: ObservableObject`
    - `static let shared`, `@Published var sessions: [TerminalSession]`, `@Published var activeSessionId: String?`
    - `init(sessionFactory: @escaping (Device) -> SSHSession = { _ in CitadelSession() })` (테스트는 Fake 팩토리)
    - `func open(device: Device)` (같은 deviceId 세션 재사용), `func close(id: String)`, `func closeAll()`

주의: connect의 자격 해석은 `ClusterSSHConfig.load()` → nil이면 `SSHKeyLocator`로 개인키 경로 유추. 개인키 파일을 `Data`로 읽어 `SSHAuth.privateKey(data, passphrase: nil)`. 호스트키 게이트(Task 3)는 이 태스크에서 connect 흐름에 끼우되, 실제 TOFU 시트(UI)는 Task 5 — 여기서는 `.needsTrust`면 `pendingHostKey`를 세팅하고 openShell을 보류, `.blocked`면 `state=.disconnected`, `.proceed`면 openShell. Fake의 remoteHostKey는 항상 stub이라 첫 연결은 `.needsTrust` 경로를 태운다(테스트가 이를 검증).

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
// Hydra/Tests/HydraTests/TerminalSessionTests.swift
#if os(macOS)
import XCTest
import SSHTransport
@testable import Hydra

@MainActor
final class TerminalSessionTests: XCTestCase {
    private func device(_ id: String) -> Device {
        Device(id: id, name: id, hostname: id, ipAddresses: [], tailscaleIp: "100.0.0.1",
               os: "Linux", status: "online", isExternal: false, tags: nil, user: "dave",
               lastSeen: Date(), sshEnabled: true, hasGpu: true, gpuModel: "RTX", gpuCount: 1)
    }

    func testStoreOpenReusesSessionForSameDevice() {
        let store = TerminalSessionStore(sessionFactory: { _ in FakeSSHSession() })
        store.open(device: device("gpu1"))
        store.open(device: device("gpu1"))
        XCTAssertEqual(store.sessions.count, 1)      // 중복 생성 안 함
        store.open(device: device("gpu2"))
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.activeSessionId, store.sessions.last?.id)
    }

    func testCloseAllDisconnects() {
        let store = TerminalSessionStore(sessionFactory: { _ in FakeSSHSession() })
        store.open(device: device("gpu1"))
        store.closeAll()
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testConnectReachesConnectedAndStreamsOutput() async {
        let session = TerminalSession(device: device("gpu1"), session: FakeSSHSession())
        var got = Data()
        session.onOutput = { got.append($0) }
        await session.connect(cols: 80, rows: 24)
        // Fake는 connect→.connected, openShell→"fake$ " 출력. 단, 첫 연결은
        // 호스트키 미지(TOFU) 경로라 openShell 보류될 수 있음 → trustPendingHostKey 후 진행.
        if case .needsTrust = session.hostKeyPrompt { await session.trustPendingHostKey() }
        // 출력 스트림이 흐르는지(약간 대기)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(session.state, .connected)
        XCTAssertTrue(String(data: got, encoding: .utf8)?.contains("fake$") ?? false)
    }
}
#endif
```

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter TerminalSessionTests 2>&1 | tail -10`
Expected: 컴파일 실패 — `cannot find 'TerminalSession'`

- [ ] **Step 3: 구현**

```swift
// Hydra/Hydra/Services/TerminalSession.swift
#if os(macOS)
import Foundation
import SSHTransport
import KnownHosts

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: String
    let deviceId: String
    let deviceName: String
    let host: String

    @Published var state: SSHState = .idle
    /// TOFU: set when the host key is unknown and awaiting user trust.
    @Published var hostKeyPrompt: HostKeyDecision?

    /// The view subscribes to feed bytes into SwiftTerm.
    var onOutput: ((Data) -> Void)?

    private let session: SSHSession
    private let knownHosts: KnownHostsStore
    private var pumpTask: Task<Void, Never>?
    private var pendingShell: (cols: Int, rows: Int)?

    init(device: Device, session: SSHSession) {
        self.id = device.id
        self.deviceId = device.id
        self.deviceName = device.displayName
        self.host = device.tailscaleIp
        self.session = session
        let khURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/known_hosts")
        self.knownHosts = KnownHostsStore(fileURL: khURL)
    }

    func connect(cols: Int, rows: Int) async {
        pendingShell = (cols, rows)
        // Resolve credentials: config.yaml → SSHKeyLocator fallback.
        let user: String
        let keyPath: String
        let port: Int
        if let r = ClusterSSHConfig.load() {
            user = r.user; keyPath = r.privateKeyPath; port = r.port
        } else {
            user = NSUserName()
            keyPath = (try? SSHKeyLocator.defaultPrivateKeyPath()) ?? ""
            port = 22
        }
        guard let pem = FileManager.default.contents(atPath: keyPath) else {
            state = .disconnected(reason: "개인키를 읽을 수 없습니다: \(keyPath)")
            return
        }
        startStatePump()
        do {
            try await session.connect(host: host, port: port, user: user,
                                      auth: .privateKey(pem, passphrase: nil))
        } catch {
            state = .disconnected(reason: (error as? SSHError).map(describe) ?? "\(error)")
            return
        }
        // Host-key TOFU gate (Citadel transport already acceptAnything).
        switch HostKeyGate.evaluate(host: host, fingerprint: session.remoteHostKey, store: knownHosts) {
        case .proceed:
            await openShellNow()
        case .needsTrust(let sha):
            hostKeyPrompt = .needsTrust(sha256: sha)   // 뷰가 시트로 물음
        case .blocked:
            state = .disconnected(reason: "호스트키 불일치 — 연결 차단")
            session.disconnect()
        }
    }

    /// Called by the TOFU sheet's "Trust" action.
    func trustPendingHostKey() async {
        guard let fp = session.remoteHostKey else { return }
        try? knownHosts.trust(HostKeyGate.entry(host: host, fingerprint: fp))
        hostKeyPrompt = nil
        await openShellNow()
    }

    func cancelPendingHostKey() {
        hostKeyPrompt = nil
        state = .disconnected(reason: "호스트키 신뢰 취소")
        session.disconnect()
    }

    private func openShellNow() async {
        guard let s = pendingShell else { return }
        startOutputPump()
        do { try await session.openShell(termType: "xterm-256color", cols: s.cols, rows: s.rows) }
        catch { state = .disconnected(reason: "셸 열기 실패: \(error)") }
    }

    func send(_ data: Data) { Task { try? await session.write(data) } }
    func resize(cols: Int, rows: Int) { Task { try? await session.resize(cols: cols, rows: rows) } }
    func close() { pumpTask?.cancel(); session.disconnect() }

    private func startStatePump() {
        Task { [weak self] in
            guard let self else { return }
            for await st in self.session.state { self.state = st }
        }
    }
    private func startOutputPump() {
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await chunk in self.session.output { self.onOutput?(chunk) }
        }
    }

    private func describe(_ e: SSHError) -> String {
        switch e {
        case .unreachable(let m): return "도달 불가: \(m)"
        case .handshakeFailed(let m): return "핸드셰이크 실패: \(m)"
        case .authFailed(let m): return "인증 실패: \(m)"
        case .channelFailed(let m): return "채널 실패: \(m)"
        case .disconnected: return "연결 끊김"
        }
    }
}
#endif
```

```swift
// Hydra/Hydra/Services/TerminalSessionStore.swift
#if os(macOS)
import Foundation
import SSHTransport

@MainActor
final class TerminalSessionStore: ObservableObject {
    static let shared = TerminalSessionStore()

    @Published var sessions: [TerminalSession] = []
    @Published var activeSessionId: String?

    private let sessionFactory: (Device) -> SSHSession

    init(sessionFactory: @escaping (Device) -> SSHSession = { _ in CitadelSession() }) {
        self.sessionFactory = sessionFactory
    }

    func open(device: Device) {
        if let existing = sessions.first(where: { $0.deviceId == device.id }) {
            activeSessionId = existing.id       // 중복 생성 금지 — 포커스만
            return
        }
        let s = TerminalSession(device: device, session: sessionFactory(device))
        sessions.append(s)
        activeSessionId = s.id
    }

    func close(id: String) {
        sessions.first(where: { $0.id == id })?.close()
        sessions.removeAll { $0.id == id }
        if activeSessionId == id { activeSessionId = sessions.last?.id }
    }

    func closeAll() {
        for s in sessions { s.close() }
        sessions.removeAll()
        activeSessionId = nil
    }
}
#endif
```

주의: `SSHKeyLocator`에 `defaultPrivateKeyPath()`가 없으면 추가한다 — 기존 `defaultPublicKey()` 옆에, `.pub`을 제거한 개인키 경로를 반환하는 형제 메서드(파일 존재 확인). 없을 때만 이 태스크에서 최소 추가하고 커밋에 포함.

- [ ] **Step 4: 통과 확인 후 커밋**

Run: `cd Hydra && swift build 2>&1 | tail -5 && swift test --filter TerminalSessionTests 2>&1 | tail -10`
Expected: 빌드 성공; 3 tests passed

```bash
git add Hydra/Hydra/Services/TerminalSession.swift Hydra/Hydra/Services/TerminalSessionStore.swift Hydra/Hydra/Services/SSHKeyLocator.swift Hydra/Tests/HydraTests/TerminalSessionTests.swift
git commit -m "feat(app): TerminalSession/Store — Citadel 세션 조율 + TOFU 게이트 (Fake 주입 테스트)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Terminal 탭 UI + Devices 진입 + 배선

**Files:**
- Modify: `Hydra/Hydra/State/AppState.swift` (`Tab.terminal`)
- Modify: `Hydra/Hydra/Views/ContentView.swift` (탭 추가)
- Modify: `Hydra/Hydra/Services/ChatContextProvider.swift` (`.terminal` 케이스 — Console 때처럼)
- Create: `Hydra/Hydra/Views/Terminal/TerminalView.swift` (탭 루트 — 세션 목록 + 상세)
- Create: `Hydra/Hydra/Views/Terminal/SwiftTermRepresentable.swift` (NSViewRepresentable)
- Modify: Devices 뷰(진입 버튼) — 실제 파일은 구현 중 확인(`Hydra/Hydra/Views/Devices/*`에서 디바이스 행/상세)
- Test: `Hydra/Tests/HydraTests/AppStateTests.swift` (`.terminal` 케이스 추가)

**Interfaces:**
- Consumes: Task 4 `TerminalSessionStore`/`TerminalSession`, SwiftTerm `TerminalView`/`TerminalViewDelegate`
- Produces: `AppState.Tab.terminal`; Terminal 탭이 세션 목록 + SwiftTerm 뷰 렌더; Devices에서 "터미널 열기" → 세션 오픈 + 탭 전환

- [ ] **Step 1: 실패하는 테스트 작성 (AppState 케이스)**

`AppStateTests.swift`에 추가:
```swift
    func testActiveTab_supportsTerminal() {
        let s = AppState()
        s.activeTab = .terminal
        XCTAssertEqual(s.activeTab, .terminal)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `cd Hydra && swift test --filter AppStateTests 2>&1 | tail -8`
Expected: 컴파일 실패 — `.terminal` 없음

- [ ] **Step 3: 구현 — AppState + ChatContextProvider + ContentView**

`AppState.swift` `Tab` enum에 `case terminal` 추가 (`console` 다음).

`ChatContextProvider.swift`의 `AppState.Tab` switch에 `.terminal`을 기존 `.console`/`.settings`와 같은 그룹(`return nil` — 채팅 컨텍스트 없음)에 추가. (정확한 위치는 파일의 switch를 grep해 확인.)

`ContentView.swift` `#if os(macOS)` 블록, ConsoleView 다음:
```swift
                TerminalView()
                    .tabItem { Label("Terminal", systemImage: "apple.terminal") }
                    .tag(AppState.Tab.terminal)
```

- [ ] **Step 4: SwiftTerm NSViewRepresentable + Terminal 탭 뷰 구현**

```swift
// Hydra/Hydra/Views/Terminal/SwiftTermRepresentable.swift
#if os(macOS)
import SwiftUI
import AppKit
import SwiftTerm

/// Wraps SwiftTerm's AppKit TerminalView. User input/resize → session; session
/// output → terminal.feed. Verify the exact TerminalViewDelegate method
/// signatures against the vendored SwiftTerm source and conform accordingly.
struct SwiftTermRepresentable: NSViewRepresentable {
    let session: TerminalSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400), font: nil)
        view.terminalDelegate = context.coordinator
        // Feed session output into the terminal.
        session.onOutput = { [weak view] data in
            guard let view else { return }
            view.feed(byteArray: [UInt8](data)[...])
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        init(session: TerminalSession) { self.session = session }

        // User typed → forward bytes to SSH. (Confirm exact signature in SwiftTerm.)
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(Data(data))
        }
        // Terminal resized → tell the remote PTY. (Confirm exact signature.)
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: newCols, rows: newRows)
        }
        // Remaining TerminalViewDelegate requirements: provide minimal no-op
        // conformances (setTerminalTitle, hostCurrentDirectoryUpdate, scrolled,
        // requestOpenLink, bell, clipboardCopy, rangeChanged, ...) as required
        // by the protocol — implement empty bodies; verify the full required set
        // against the vendored SwiftTerm TerminalViewDelegate.
    }
}
#endif
```

```swift
// Hydra/Hydra/Views/Terminal/TerminalView.swift
#if os(macOS)
import SwiftUI
import SSHTransport   // SSHState (세션 상태 → 목록 점 색)

struct TerminalView: View {
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
```

- [ ] **Step 5: Devices 진입 버튼**

`Hydra/Hydra/Views/Devices/`에서 디바이스 행 또는 상세 뷰를 찾아, SSH 가능 디바이스에 "터미널 열기" 버튼을 추가:
```swift
// (해당 Devices 뷰에서 @EnvironmentObject var appState: AppState 이미 있거나 추가)
if device.sshEnabled {
    Button {
        TerminalSessionStore.shared.open(device: device)
        appState.activeTab = .terminal
    } label: { Label("터미널 열기", systemImage: "apple.terminal") }
}
```
정확한 파일·삽입 위치는 Devices 뷰 구조를 grep해 기존 액션 버튼 옆에 맞춰 넣을 것.

- [ ] **Step 6: 빌드 + 테스트 + 앱 종료 배선**

앱 종료 시 `TerminalSessionStore.shared.closeAll()`을 호출하도록 `applicationWillTerminate` 경로(HydraApp/AppDelegate에서 `EmbeddedServer.stop()` 부르는 곳 옆)에 추가.

Run: `cd Hydra && swift build 2>&1 | tail -8 && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:" | tail -3`
Expected: 빌드 성공(SwiftTerm delegate conform 포함), 전체 테스트 통과

- [ ] **Step 7: 커밋**

```bash
git add Hydra/Hydra/State/AppState.swift Hydra/Hydra/Views/ContentView.swift Hydra/Hydra/Services/ChatContextProvider.swift Hydra/Hydra/Views/Terminal/ Hydra/Tests/HydraTests/AppStateTests.swift Hydra/Hydra/Views/Devices Hydra/Hydra/HydraApp.swift
git commit -m "feat(app): Terminal 탭 — SwiftTerm 뷰 + 세션 목록 + TOFU 시트 + Devices 진입

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## 최종 검증 (수동 스모크 — CI 스킵)

실 노드/SSH 의존이라 수동으로:

1. `make hydra-app` 후 재배포(오늘 절차 — `/Applications/Hydra.app` 교체 시 nested 서명, GUI+hydra-server 재시작). 개발 중이면 빌드된 `.app`을 `open`.
2. Devices 탭 → 실 GPU 노드(y-gpu-1 등, sshEnabled) → **터미널 열기** → Terminal 탭 전환.
3. 첫 연결 시 **호스트키 TOFU 시트** → SHA256 확인 후 **신뢰**.
4. 라이브 셸에서 `nvidia-smi` 실행 → 출력 정상 렌더. 키 입력·리사이즈·스크롤 확인.
5. 다중 세션(다른 노드도 열기), 세션 닫기, 재연결(끊었다 다시).
6. 호스트키 불일치 스모크(선택): known_hosts의 해당 라인을 조작 후 재연결 → 빨간 차단 확인.

## 계획 외 참고

- 실 SSH 통합 테스트는 노드 의존이라 XCTest 제외 — 순수 로직(Task 2·3)·세션 흐름(Task 4, Fake 주입)·링크(Task 1)·탭(Task 5)이 자동 커버, 실 셸 왕복은 위 수동 스모크.
- SwiftTerm `TerminalViewDelegate`의 정확한 필수 메서드 집합은 벤더 소스에서 확정(외부 API) — Coordinator가 전부 conform해야 빌드됨.
- 후속(YAGNI, 이번 제외): 스크롤백 영속화, scp/sftp, 폰트/테마, passphrase Keychain, iOS 지원, libssh2 백엔드.
