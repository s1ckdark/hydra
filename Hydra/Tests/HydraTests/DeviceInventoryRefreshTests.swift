import XCTest
@testable import Hydra

@MainActor
final class DeviceInventoryRefreshTests: XCTestCase {
    func testManualRefreshPublishesNewDeviceAndTimestamp() async {
        let expected = fixtureDevice()
        let model = DashboardViewModel(deviceInventoryLoader: { [expected] }, deviceInventorySource: { "fixture" })
        await model.refreshDeviceInventory()
        XCTAssertEqual(model.devices.map(\.hostname), ["intlmac"])
        XCTAssertNotNil(model.lastDeviceRefresh)
        XCTAssertNil(model.deviceRefreshError)
        XCTAssertFalse(model.isRefreshingDevices)
    }

    func testFailureKeepsExistingInventoryAndDoesNotClaimSuccess() async {
        let model = DashboardViewModel(deviceInventoryLoader: { throw APIError.tailscaleRefreshUnsupported }, deviceInventorySource: { "fixture" })
        model.devices = [fixtureDevice()]
        await model.refreshDeviceInventory()
        XCTAssertEqual(model.devices.count, 1)
        XCTAssertNil(model.lastDeviceRefresh)
        XCTAssertTrue(model.deviceRefreshError?.contains("서버를 업데이트") ?? false)
        XCTAssertFalse(model.isRefreshingDevices)
    }

    func testConcurrentRequestsAreNotDuplicatedAndOldServerResultIsIgnored() async {
        var continuation: CheckedContinuation<[Device], Error>?
        var calls = 0
        let model = DashboardViewModel(deviceInventoryLoader: {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, deviceInventorySource: { "fixture" })
        let first = Task { await model.refreshDeviceInventory() }
        for _ in 0..<1_000 { if continuation != nil { break }; await Task.yield() }
        XCTAssertNotNil(continuation)
        await model.refreshDeviceInventory()
        XCTAssertEqual(calls, 1)
        model.invalidateDeviceInventory()
        continuation?.resume(returning: [fixtureDevice()])
        await first.value
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertNil(model.lastDeviceRefresh)
        XCTAssertFalse(model.isRefreshingDevices)
    }

    private func fixtureDevice() -> Device {
        Device(id: "fixture", name: "intlmac", hostname: "intlmac", ipAddresses: [], tailscaleIp: "100.64.0.2",
               os: "macOS", status: "online", isExternal: false, tags: nil, user: "fixture", lastSeen: Date(),
               sshEnabled: true, hasGpu: false, gpuModel: nil, gpuCount: 0)
    }
}
