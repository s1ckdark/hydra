import XCTest
@testable import Hydra

@MainActor
final class ChatContextProviderTests: XCTestCase {

    private func makeVM(
        devices: [Device] = [],
        orchs: [Orch] = [],
        tasks: [NagaTask] = [],
        serverStatus: DashboardViewModel.ServerStatus = .connected,
        version: String = "1.2.3"
    ) -> DashboardViewModel {
        let vm = DashboardViewModel()
        vm.devices = devices
        vm.orchs = orchs
        vm.tasks = tasks
        vm.serverStatus = serverStatus
        vm.serverVersion = version
        return vm
    }

    func testSettingsTabReturnsNil() {
        let snap = ChatContextProvider.snapshot(
            for: .settings,
            dashboardVM: makeVM(),
            selection: .init()
        )
        XCTAssertNil(snap)
    }

    func testDashboardWithNoData() {
        let snap = ChatContextProvider.snapshot(
            for: .dashboard,
            dashboardVM: makeVM(),
            selection: .init()
        )
        XCTAssertNotNil(snap)
        XCTAssertTrue(snap!.hasPrefix("[Context: Dashboard."))
        XCTAssertTrue(snap!.contains("0/0 online"))
    }

    func testDevicesTabNoSelection() {
        let online = Device.fixture(id: "a", hostname: "h1", isOnline: true)
        let offline = Device.fixture(id: "b", hostname: "h2", isOnline: false)
        let snap = ChatContextProvider.snapshot(
            for: .devices,
            dashboardVM: makeVM(devices: [online, offline]),
            selection: .init()
        )
        XCTAssertEqual(snap, "[Context: Devices tab. 1/2 devices online.]")
    }

    func testDevicesTabWithSelection() {
        let dev = Device.fixture(id: "a", hostname: "home-mac", isOnline: true)
        let snap = ChatContextProvider.snapshot(
            for: .devices,
            dashboardVM: makeVM(devices: [dev]),
            selection: .init(device: dev)
        )
        XCTAssertNotNil(snap)
        XCTAssertTrue(snap!.contains("Selected 'home-mac'"))
        XCTAssertTrue(snap!.contains("online"))
    }
}

extension Device {
    /// `Device` is a struct with `let` stored properties and uses the
    /// synthesized memberwise initializer. This helper supplies sane
    /// defaults for the fields ChatContextProvider doesn't read, so
    /// tests only have to specify what matters to them.
    static func fixture(
        id: String,
        hostname: String = "host",
        name: String = "",
        isOnline: Bool = true,
        tailscaleIp: String = "100.0.0.1",
        os: String = "macOS",
        sshEnabled: Bool = true,
        hasGpu: Bool = false,
        gpuModel: String? = nil,
        gpuCount: Int = 0
    ) -> Device {
        Device(
            id: id,
            name: name,
            hostname: hostname,
            ipAddresses: [tailscaleIp],
            tailscaleIp: tailscaleIp,
            os: os,
            status: isOnline ? "online" : "offline",
            isExternal: false,
            tags: nil,
            user: "u",
            lastSeen: Date(),
            sshEnabled: sshEnabled,
            hasGpu: hasGpu,
            gpuModel: gpuModel,
            gpuCount: gpuCount
        )
    }
}
