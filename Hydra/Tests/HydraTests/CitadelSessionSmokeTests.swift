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
