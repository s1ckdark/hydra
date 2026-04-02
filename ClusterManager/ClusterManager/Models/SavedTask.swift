import Foundation

/// A user-defined reusable task template.
struct SavedTask: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var command: String
    var targetDeviceId: String?       // nil = ask at runtime
    var targetDeviceName: String?     // display only
    var timeout: Int = 30             // seconds
    var priority: Priority = .normal
    var requiredCapabilities: [String] = []
    var schedule: Schedule?
    var lastRunAt: Date?
    var lastRunStatus: String?        // "success", "failed"
    var createdAt: Date = Date()

    enum Priority: String, Codable, CaseIterable {
        case low, normal, high, urgent

        var icon: String {
            switch self {
            case .low: return "arrow.down"
            case .normal: return "minus"
            case .high: return "arrow.up"
            case .urgent: return "exclamationmark.2"
            }
        }
    }

    struct Schedule: Codable, Equatable {
        var enabled: Bool = false
        var intervalMinutes: Int = 60
        var type: ScheduleType = .interval

        enum ScheduleType: String, Codable, CaseIterable {
            case interval = "Every N minutes"
            case hourly = "Every hour"
            case daily = "Daily"
        }

        var displayText: String {
            guard enabled else { return "Off" }
            switch type {
            case .interval: return "Every \(intervalMinutes)m"
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            }
        }
    }
}
