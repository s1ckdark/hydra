import Foundation

/// Task as returned by the server's /api/tasks endpoint.
struct NagaTask: Codable, Identifiable {
    let id: String
    let type: String
    let status: String
    let priority: String
    let assignedDeviceId: String?
    let error: String?
    let createdAt: Date
    let completedAt: Date?
    let retryCount: Int

    var isRunning: Bool { status == "running" }
    var isCompleted: Bool { status == "completed" }
    var isFailed: Bool { status == "failed" }
    var isPending: Bool { status == "pending" || status == "queued" || status == "assigned" }

    var statusIcon: String {
        switch status {
        case "running": return "play.circle.fill"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "queued", "assigned": return "clock.fill"
        case "cancelled": return "minus.circle.fill"
        default: return "questionmark.circle"
        }
    }

    var statusColor: String {
        switch status {
        case "running": return "blue"
        case "completed": return "green"
        case "failed": return "red"
        case "queued", "assigned": return "orange"
        default: return "gray"
        }
    }
}
