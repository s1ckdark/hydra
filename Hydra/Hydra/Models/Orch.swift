import Foundation

struct Orch: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let mode: String
    let status: String
    let coordinatorId: String
    let workerIds: [String]
    let dashboardUrl: String
    let createdAt: Date
    let updatedAt: Date

    var workerCount: Int { workerIds.count }
    var isRunning: Bool { status == "running" }
}

struct OrchHealth: Codable {
    let orchId: String
    let name: String
    let status: String
    let nodes: [NodeStatus]

    struct NodeStatus: Codable, Identifiable {
        let nodeId: String
        let role: String
        let healthy: Bool
        let error: String?
        var id: String { nodeId }
    }
}

struct CreateOrchRequest: Encodable {
    let name: String
    let head_id: String
    let worker_ids: [String]
}
