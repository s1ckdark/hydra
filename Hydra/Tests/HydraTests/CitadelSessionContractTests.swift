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
