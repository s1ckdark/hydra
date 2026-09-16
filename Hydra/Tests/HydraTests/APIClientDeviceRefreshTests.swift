import XCTest
@testable import Hydra

final class APIClientDeviceRefreshTests: XCTestCase {
    func testRequestsForcedTailscaleInventoryWithAuthenticationAndNoLocalCache() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        RefreshURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/devices")
            XCTAssertEqual(request.url?.query, "refresh=tailscale")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            return (200, ["X-Hydra-Tailscale-Refresh": "fresh"], Data("[]".utf8))
        }
        let api = APIClient(baseURL: URL(string: "http://fixture.invalid")!, session: session, apiKeyProvider: { "fixture-only" })
        let devices = try await api.refreshTailscaleDevices()
        XCTAssertTrue(devices.isEmpty)
    }

    func testOlderServerCannotBeReportedAsFresh() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        RefreshURLProtocol.handler = { _ in (200, [:], Data("[]".utf8)) }
        let api = APIClient(baseURL: URL(string: "http://fixture.invalid")!, session: session, apiKeyProvider: { "" })
        do {
            _ = try await api.refreshTailscaleDevices()
            XCTFail("An old server silently ignoring the refresh flag must not count as success")
        } catch APIError.tailscaleRefreshUnsupported { }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class RefreshURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
