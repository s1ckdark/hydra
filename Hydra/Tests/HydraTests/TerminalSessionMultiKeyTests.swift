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
