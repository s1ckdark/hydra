import Foundation

/// TCP-connect speed test result returned by `POST /api/devices/{id}/ping`.
/// `loss` is samples that failed (timeout / refused / unreachable); statistics
/// are computed only over successful samples so a single survivor still gives
/// usable min/avg/max instead of zeros.
struct PingResult: Decodable {
    let deviceId: String
    let target: String
    let port: Int
    let samples: Int
    let success: Int
    let loss: Int
    let minMs: Double
    let avgMs: Double
    let maxMs: Double
    let p50Ms: Double
    /// Per-attempt RTT in attempt order. A `0` slot is a failed probe so the
    /// chart can show a gap at that index instead of compressing time.
    let samplesMs: [Double]?
    let errors: [String]?
    let startedAt: Date

    var allFailed: Bool { success == 0 }
    var lossPercent: Double {
        guard samples > 0 else { return 0 }
        return Double(loss) / Double(samples) * 100
    }
}
