import XCTest
@testable import Hydra

final class DeviceIdentityTests: XCTestCase {
    func testCurrent_CachesAfterFirstResolve() async {
        let stub = StubMatchClient()
        stub.canned = "dev-A"
        let identity = DeviceIdentity()

        let id1 = await identity.current(via: stub)
        let id2 = await identity.current(via: stub)
        XCTAssertEqual(id1, "dev-A")
        XCTAssertEqual(id2, "dev-A")
        XCTAssertEqual(stub.calls, 1, "second call should be served from cache")
    }

    func testCurrent_ReturnsNilWhenMatchFails_DoesNotCache() async {
        let stub = StubMatchClient()
        stub.shouldFail = true
        let identity = DeviceIdentity()

        let id1 = await identity.current(via: stub)
        XCTAssertNil(id1, "failed match should not return an ID")

        // Recover and try again — should hit the network again, not stay nil.
        stub.shouldFail = false
        stub.canned = "dev-A"
        let id2 = await identity.current(via: stub)
        XCTAssertEqual(id2, "dev-A")
        XCTAssertEqual(stub.calls, 2, "failure should not be cached; second call must hit network")
    }
}

/// StubMatchClient implements only the surface DeviceIdentity needs.
final class StubMatchClient: DeviceMatchClient {
    var canned: String = ""
    var shouldFail = false
    var calls = 0
    func matchDevice(hostname: String, ip: String?) async throws -> String {
        calls += 1
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return canned
    }
}
