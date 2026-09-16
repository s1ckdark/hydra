#if os(macOS)
import XCTest
import Foundation
import Darwin
import NIOCore
@testable import NIOSSH
import SSHTransport
@testable import Citadel
@testable import SSHTransportCitadel

final class SSHFailureTests: XCTestCase {
    func testAuthenticationRejectionIsDistinctFromUnsupportedMethod() {
        XCTAssertEqual(CitadelSession.classify(error: SSHClientError.allAuthenticationOptionsFailed),
                       .authenticationRejected)
        XCTAssertEqual(CitadelSession.classify(error: AuthenticationFailed()), .authenticationRejected)
        XCTAssertEqual(CitadelSession.classify(error: SSHClientError.unsupportedPasswordAuthentication),
                       .passwordAuthenticationUnsupported)
        XCTAssertEqual(CitadelSession.classify(error: SSHClientError.unsupportedPrivateKeyAuthentication),
                       .privateKeyAuthenticationUnsupported)
        // The old enum also wraps local key parsing and libssh2 network errors;
        // its case name alone cannot prove the server rejected credentials.
        XCTAssertEqual(CitadelSession.classify(error: SSHError.authFailed("legacy failure")), .unknown)
    }

    func testPOSIXTransportErrorsKeepTheirActualCause() {
        let cases: [(Int32, SSHFailure)] = [
            (ECONNREFUSED, .connectionRefused), (ETIMEDOUT, .timedOut),
            (ENETUNREACH, .networkUnavailable), (EHOSTUNREACH, .networkUnavailable),
            (ENETDOWN, .networkUnavailable), (ECONNRESET, .connectionLost),
            (EPIPE, .connectionLost), (ENOTCONN, .connectionLost)
        ]
        for (code, expected) in cases {
            XCTAssertEqual(CitadelSession.classify(error: IOError(errnoCode: code, reason: "sensitive raw diagnostic")),
                           expected)
            XCTAssertEqual(CitadelSession.classify(error: NSError(domain: NSPOSIXErrorDomain, code: Int(code))),
                           expected)
        }
    }

    func testNameResolutionAndChannelFailuresAreNotAuthenticationFailures() {
        XCTAssertEqual(CitadelSession.classify(error: SocketAddressError.unknown(host: "test.invalid", port: 22)),
                       .nameResolutionFailed)
        XCTAssertEqual(CitadelSession.classify(error: ChannelError.connectTimeout(.seconds(3))), .timedOut)
        XCTAssertEqual(CitadelSession.classify(error: ChannelError.ioOnClosedChannel), .connectionLost)
        XCTAssertEqual(CitadelSession.classify(error: ChannelError.eof), .connectionLost)
        XCTAssertEqual(CitadelSession.classify(error: ChannelError.writeHostUnreachable), .networkUnavailable)
    }

    func testCommandFailurePreservesExitStatusAndOutputLimit() {
        XCTAssertEqual(CitadelSession.classify(error: SSHClient.CommandFailed(exitCode: 76)), .commandFailed(exitStatus: 76))
        XCTAssertEqual(CitadelSession.classify(error: CitadelError.commandOutputTooLarge), .commandOutputTooLarge)
        XCTAssertEqual(CitadelSession.classify(error: CitadelError.invalidSignature), .handshakeFailed)
        XCTAssertEqual(CitadelSession.classify(error: SSHClientError.channelCreationFailed), .channelUnavailable)
        XCTAssertEqual(CitadelSession.classify(error: CitadelError.channelCreationFailed), .channelUnavailable)
        XCTAssertEqual(CitadelSession.classify(error: CitadelError.channelFailure), .channelUnavailable)
    }

    func testKnownNSErrorDomainsAndBoundedUnderlyingErrors() {
        XCTAssertEqual(CitadelSession.classify(error: URLError(.cannotFindHost)), .nameResolutionFailed)
        XCTAssertEqual(CitadelSession.classify(error: URLError(.timedOut)), .timedOut)
        XCTAssertEqual(CitadelSession.classify(error: URLError(.notConnectedToInternet)), .networkUnavailable)
        XCTAssertEqual(CitadelSession.classify(error: URLError(.networkConnectionLost)), .connectionLost)
        let wrapped = NSError(domain: "app.wrapper", code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)),
            NSLocalizedDescriptionKey: "private diagnostic"
        ])
        XCTAssertEqual(CitadelSession.classify(error: wrapped), .connectionRefused)
        var deep: NSError = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        for _ in 0..<20 { deep = NSError(domain: "wrapper", code: 0, userInfo: [NSUnderlyingErrorKey: deep]) }
        XCTAssertEqual(CitadelSession.classify(error: deep), .unknown)
    }

    func testSSHProtocolFailuresDoNotInventAHandshakeStage() {
        XCTAssertEqual(CitadelSession.classify(error: NIOSSHError.keyExchangeNegotiationFailure), .handshakeFailed)
        XCTAssertEqual(CitadelSession.classify(error: NIOSSHError.unsupportedVersion("test")), .handshakeFailed)
        XCTAssertEqual(CitadelSession.classify(error: NIOSSHError.tcpShutdown), .connectionLost)
        XCTAssertEqual(CitadelSession.classify(error: NIOSSHError.channelSetupRejected(reasonCode: 1, reason: "private server text")),
                       .channelUnavailable)
        // Protocol anomalies can occur after authentication while a command runs.
        XCTAssertEqual(CitadelSession.classify(error: NIOSSHError.protocolViolation(protocolName: "test", violation: "private server text")),
                       .unknown)
    }

    func testDescriptionsCannotClassifyOrLeakArbitraryServerText() {
        let secret = "password=example-private-material ECONNREFUSED authentication failed"
        let arbitrary = NSError(domain: "untrusted.server", code: Int(ECONNREFUSED),
                                userInfo: [NSLocalizedDescriptionKey: secret])
        let failure = CitadelSession.classify(error: arbitrary)
        XCTAssertEqual(failure, .unknown)
        XCTAssertFalse(failure.localizedDescription.contains(secret))
        XCTAssertFalse(failure.localizedDescription.contains("ECONNREFUSED"))
    }

    func testTypedFailuresRemainStableWhenReclassified() {
        let cases: [SSHFailure] = [.nameResolutionFailed, .connectionRefused, .timedOut, .networkUnavailable,
                                  .connectionLost, .authenticationRejected, .passwordAuthenticationUnsupported,
                                  .privateKeyAuthenticationUnsupported, .handshakeFailed,
                                  .channelUnavailable,
                                  .commandFailed(exitStatus: 71), .commandOutputTooLarge, .unknown]
        for failure in cases {
            XCTAssertEqual(CitadelSession.classify(error: failure), failure)
            XCTAssertFalse(failure.localizedDescription.isEmpty)
            XCTAssertTrue(failure.localizedDescription.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) })
        }
    }
}
#endif
