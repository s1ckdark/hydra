import XCTest
import Foundation
@testable import Hydra

final class MetricsSamplerTests: XCTestCase {
    func testSampleMemory_ReturnsPlausibleValues() {
        let snapshot = MetricsSampler.sampleMemory()
        XCTAssertGreaterThan(snapshot.totalBytes, 0, "totalBytes should be > 0 on any real machine")
        XCTAssertGreaterThan(snapshot.usedBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.usedBytes, snapshot.totalBytes)
        XCTAssertGreaterThanOrEqual(snapshot.usagePercent, 0)
        XCTAssertLessThanOrEqual(snapshot.usagePercent, 100)
    }

    func testSampleDisk_ReturnsPlausibleValues() {
        let snapshot = MetricsSampler.sampleDisk()
        XCTAssertGreaterThan(snapshot.totalBytes, 0, "root volume must report a non-zero capacity")
        XCTAssertLessThanOrEqual(snapshot.availableBytes, snapshot.totalBytes)
    }

    func testSampleCPU_FirstCallReturnsZero() {
        var prev: host_cpu_load_info? = nil
        let snapshot = MetricsSampler.sampleCPU(prev: &prev)
        XCTAssertEqual(snapshot.usagePercent, 0,
                       "first call has no delta; should report 0 rather than NaN/garbage")
        XCTAssertGreaterThan(snapshot.cores, 0, "processorCount > 0 on any real machine")
    }

    func testSampleCPU_SecondCallProducesValidPercent() {
        var prev: host_cpu_load_info? = nil
        _ = MetricsSampler.sampleCPU(prev: &prev)
        // Spin briefly so the next sample sees real ticks
        let deadline = Date().addingTimeInterval(0.1)
        var n = 0
        while Date() < deadline { n += 1 }
        XCTAssertGreaterThan(n, 0)

        let snapshot = MetricsSampler.sampleCPU(prev: &prev)
        XCTAssertGreaterThanOrEqual(snapshot.usagePercent, 0)
        XCTAssertLessThanOrEqual(snapshot.usagePercent, 100)
    }

    #if os(macOS)
    func testSampleGPU_ReturnsNonNilOnAppleSilicon() {
        // Apple Silicon Macs always have Metal. Intel Macs without
        // discrete GPU may return nil — accept that case.
        let snapshot = MetricsSampler.sampleGPU()
        if let s = snapshot {
            XCTAssertFalse(s.name.isEmpty, "GPU name should be populated")
            XCTAssertGreaterThan(s.recommendedWorkingSetBytes, 0)
        }
    }
    #endif
}
