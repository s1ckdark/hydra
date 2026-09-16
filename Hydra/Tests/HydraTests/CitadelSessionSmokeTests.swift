#if os(macOS)
import XCTest
import SSHTransport
import SSHTransportCitadel
@testable import Hydra

/// Opt-in real-SSH smoke for the Citadel backend. Skips unless
/// HYDRA_CITADEL_SMOKE_HOST is set (Docker via Tests/smoke/citadel-openssh-docker.sh,
/// or a real ed25519-authorized node). Env: _HOST, _PORT(=2222), _USER(=smoke),
/// _KEY(=~/.ssh/id_ed25519).
final class CitadelSessionSmokeTests: XCTestCase {
    @MainActor
    func testTerminalSessionKoreanRoundTripAfterResizeAndReconnect() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["HYDRA_CITADEL_SMOKE_HOST"],
              let keyPath = env["HYDRA_CITADEL_SMOKE_KEY"] else {
            throw XCTSkip("set HYDRA_CITADEL_SMOKE_HOST and _KEY for the isolated SSH integration")
        }
        let key = try XCTUnwrap(FileManager.default.contents(atPath: keyPath))
        let user = env["HYDRA_CITADEL_SMOKE_USER"] ?? "smoke"
        let port = Int(env["HYDRA_CITADEL_SMOKE_PORT"] ?? "2222") ?? 2222
        let knownHosts = FileManager.default.temporaryDirectory
            .appendingPathComponent("hydra-citadel-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: knownHosts) }
        let device = Device(id: "citadel-roundtrip", name: "citadel-roundtrip", hostname: host,
            ipAddresses: [], tailscaleIp: host, os: "Linux", status: "online", isExternal: false,
            tags: nil, user: user, lastSeen: Date(), sshEnabled: true, hasGpu: false,
            gpuModel: nil, gpuCount: 0)
        let terminal = TerminalSession(device: device, sessionFactory: { CitadelSession() },
            knownHostsURL: knownHosts, credentialResolver: {
                SSHCredentials(user: user, port: port,
                    keys: [.init(path: keyPath, pem: key, algorithm: "ed25519")])
            }, persistenceEnabled: { false })
        defer { terminal.close() }
        var received = Data()
        terminal.onOutput = { received.append($0) }
        func outputContains(_ text: String) -> Bool {
            String(decoding: received, as: UTF8.self).contains(text)
        }
        func remoteSizeRows() -> [String] {
            // Interactive shells can surround replies with bracketed-paste
            // toggles and use a leading CR rather than a whole CRLF. Inspect
            // the computed numeric line, not an assumed line-ending envelope.
            String(decoding: received, as: UTF8.self)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.range(of: #"^\d+\s+\d+$"#, options: .regularExpression) != nil }
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        }
        func waitForOutput(_ text: String) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !outputContains(text), Date() < deadline {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertTrue(outputContains(text), "Expected computed remote output: \(text)")
        }

        for round in 1...2 {
            received.removeAll(keepingCapacity: true)
            await terminal.connect(cols: 80, rows: 24)
            if case .needsTrust = terminal.hostKeyPrompt { await terminal.trustPendingHostKey() }
            // The command line contains Hangul but not its computed hex bytes
            // or round marker, so local PTY echo cannot satisfy either check.
            terminal.send(Data("printf '%s' '어떨까?' | od -An -tx1; echo HYDRAROUND$((\(round)*7))".utf8))
            terminal.send(Data([13]))
            try await waitForOutput("ec 96 b4 eb 96 a8 ea b9 8c 3f")
            try await waitForOutput("HYDRAROUND\(round * 7)")
            XCTAssertEqual(terminal.state, .connected)

            let rows = 25 + round, cols = 91 + round
            terminal.resize(cols: cols, rows: rows)
            let sizeLine = "\(rows) \(cols)"
            // resize() is intentionally async/fire-and-forget. Observe its
            // remote effect with a bounded retry, not an assumed wire delay.
            let deadline = Date().addingTimeInterval(5)
            while !remoteSizeRows().contains(sizeLine), Date() < deadline {
                terminal.send(Data("stty size\r".utf8))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(remoteSizeRows().contains(sizeLine),
                          "Remote PTY did not resize to \(rows)x\(cols); observed rows: \(Set(remoteSizeRows()))")
            terminal.close()
        }
    }

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
        // The typed input line itself is echoed back by the PTY (line-echo), so it must
        // NOT contain the marker we assert on — otherwise the assertion could pass on
        // input echo alone, without bash ever executing anything. Instead the command
        // asks the shell to compute the marker (HYDRAMARK42 via 6*7): only real command
        // execution can produce that string in the output stream.
        try await s.write(Data("echo HYDRAMARK$((6*7))\n".utf8))

        let deadline = Date().addingTimeInterval(8)
        func got() -> Bool { String(decoding: received, as: UTF8.self).contains("HYDRAMARK42") }
        while Date() < deadline && !got() { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(got(), "shell did not execute command (computed marker HYDRAMARK42 missing, so this is not just input echo); buffer: \(String(decoding: received, as: UTF8.self))")

        try await s.resize(cols: 100, rows: 30)                 // must not throw
        let uname = try await s.exec("uname")
        XCTAssertFalse(uname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "exec(uname) empty")

        s.disconnect()
    }
}
#endif
