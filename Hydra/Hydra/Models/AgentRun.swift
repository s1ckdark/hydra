import Foundation

enum AgentNodeStatus: String, Codable, Sendable {
    case queued, running, waiting, completed, failed, skipped, cancelled, unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .waiting: return "Waiting for approval"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        case .unknown: return "Status unknown"
        }
    }
}

struct AgentRunNode: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var parentID: String? = nil
    var kind: String
    var title: String
    var status: AgentNodeStatus
    var order: Int
    var agentID: String? = nil
    var provider: String? = nil
    var model: String? = nil
    var actionType: String? = nil
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var message: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, title, status, order, provider, model, message
        case parentID = "parent_id"
        case agentID = "agent_id"
        case actionType = "action_type"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }
}

struct AgentRunEdge: Codable, Equatable, Hashable, Identifiable, Sendable {
    let from: String
    let to: String
    let kind: String
    var id: String { "\(from)|\(to)|\(kind)" }
}

struct AgentRunSnapshot: Codable, Equatable, Sendable {
    let runID: String
    var phase: String
    var updatedAt: Date? = nil
    var nodes: [AgentRunNode]
    var edges: [AgentRunEdge]

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case updatedAt = "updated_at"
        case phase, nodes, edges
    }

    var orderedNodes: [AgentRunNode] {
        nodes.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }

    var activeNodes: [AgentRunNode] {
        orderedNodes.filter { $0.kind != "root" && ($0.status == .running || $0.status == .waiting) }
    }

    var phaseLabel: String {
        switch phase {
        case "planning": return "Planning"
        case "awaiting_approval": return "Waiting for approval"
        case "executing": return "Executing"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        default: return "Status unknown"
        }
    }

    /// Only execution of the same run may retain planning history. A caller
    /// starting a new chat replaces the snapshot instead of merging it.
    func mergingExecution(_ next: AgentRunSnapshot) -> AgentRunSnapshot {
        guard next.runID == runID else { return next }
        var result = next
        let changed = Set(next.nodes.map(\.id))
        result.nodes += nodes.filter { !changed.contains($0.id) }
        let valid = Set(result.nodes.map(\.id))
        let replacements = Set(next.edges.map { "\($0.from)|\($0.to)" })
        result.edges += edges.filter {
            !replacements.contains("\($0.from)|\($0.to)") && valid.contains($0.from) && valid.contains($0.to)
        }
        result.nodes = result.orderedNodes
        return result
    }

    mutating func markDisconnected() {
        phase = "unknown"
        for index in nodes.indices where nodes[index].status == .running || nodes[index].status == .waiting {
            nodes[index].status = .unknown
        }
    }

    mutating func cancelApproval(at date: Date = Date()) {
        phase = "cancelled"
        updatedAt = date
        for index in nodes.indices {
            if nodes[index].kind == "approval" || nodes[index].kind == "root" || nodes[index].status == .waiting {
                nodes[index].status = .cancelled
                nodes[index].finishedAt = date
            } else if nodes[index].status == .queued {
                nodes[index].status = .skipped
            }
        }
    }
}

/// Deterministic layout of the server's actual directed graph. Sequence and
/// delegation edges determine columns; agent ancestry determines branch lanes.
/// The canvas size stays intrinsic so narrow windows can pan without shrinking
/// cards or hiding nodes. Unknown edge endpoints are ignored.
struct AgentTreeLayout {
    struct PlacedNode: Identifiable, Equatable {
        let id: String
        let frame: CGRect
        let displayStep: Int?
    }
    struct Connector: Identifiable, Equatable {
        let edge: AgentRunEdge
        let points: [CGPoint]
        var id: String { edge.id }
    }
    struct Branch: Identifiable, Equatable {
        let id: String
        let title: String
        let frame: CGRect
    }

    let nodes: [PlacedNode]
    let connectors: [Connector]
    let branches: [Branch]
    let size: CGSize

    init(snapshot: AgentRunSnapshot, minimumWidth: CGFloat = 0) {
        let ordered = snapshot.orderedNodes
        // Defensive deduplication avoids a crashing Dictionary initializer if
        // a malformed snapshot repeats an ID.
        var nodeMap: [String: AgentRunNode] = [:]
        for node in ordered where nodeMap[node.id] == nil { nodeMap[node.id] = node }
        let unique = ordered.filter { nodeMap.removeValue(forKey: $0.id) != nil }
        nodeMap = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        let edges = Array(Set(snapshot.edges)).filter { nodeMap[$0.from] != nil && nodeMap[$0.to] != nil && $0.from != $0.to }
            .sorted { $0.id < $1.id }
        let agents = unique.filter { $0.kind == "agent" }
        let agentLanes = Dictionary(uniqueKeysWithValues: agents.enumerated().map { ($0.element.id, $0.offset) })

        func lane(for node: AgentRunNode) -> Int {
            var current: AgentRunNode? = node
            var visited = Set<String>()
            while let item = current, visited.insert(item.id).inserted {
                if let lane = agentLanes[item.id] { return lane }
                current = item.parentID.flatMap { nodeMap[$0] }
            }
            return 0
        }

        var ranks: [String: Int] = [:]
        var remaining = unique
        while !remaining.isEmpty {
            let ready = remaining.filter { node in
                edges.filter { $0.to == node.id }.allSatisfy { ranks[$0.from] != nil }
            }
            // Cyclic or corrupt input gets a stable final column, not a loop.
            if ready.isEmpty {
                let last = (ranks.values.max() ?? -1) + 1
                for (offset, node) in remaining.enumerated() { ranks[node.id] = last + offset }
                break
            }
            for node in ready {
                let predecessors = edges.filter { $0.to == node.id }.compactMap { ranks[$0.from] }
                ranks[node.id] = predecessors.map { $0 + 1 }.max() ?? 0
            }
            let readyIDs = Set(ready.map(\.id))
            remaining.removeAll { readyIDs.contains($0.id) }
        }

        let card = CGSize(width: 220, height: 142)
        let columnGap: CGFloat = 64, rowGap: CGFloat = 60
        var occupied: [Int: Set<Int>] = [:]
        var placed: [PlacedNode] = []
        let steps = Dictionary(uniqueKeysWithValues: unique.filter { $0.kind != "root" }.enumerated().map { ($0.element.id, $0.offset + 1) })
        for node in unique {
            let column = ranks[node.id] ?? 0
            var row = lane(for: node)
            while occupied[column, default: []].contains(row) { row += 1 }
            occupied[column, default: []].insert(row)
            placed.append(.init(id: node.id, frame: CGRect(x: 24 + CGFloat(column) * (card.width + columnGap),
                                                         y: 48 + CGFloat(row) * (card.height + rowGap),
                                                         width: card.width, height: card.height), displayStep: steps[node.id]))
        }
        nodes = placed
        let frames = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.frame) })
        connectors = edges.enumerated().compactMap { index, edge in
            guard let from = frames[edge.from], let to = frames[edge.to] else { return nil }
            let start = CGPoint(x: from.maxX, y: from.midY)
            let end = CGPoint(x: to.minX, y: to.midY)
            let middle = (start.x + end.x) / 2
            let direct = [start, CGPoint(x: middle, y: start.y), CGPoint(x: middle, y: end.y), end]
            let crossesCard = placed.contains { placedNode in
                guard placedNode.id != edge.from && placedNode.id != edge.to else { return false }
                return zip(direct, direct.dropFirst()).contains {
                    Self.segment($0.0, $0.1, intersectsInteriorOf: placedNode.frame)
                }
            }
            if crossesCard {
                // Long delegation/sequence edges use a bounded top gutter.
                // Vertical legs stay inside column gaps, never through cards
                // in another branch. Three tracks avoid unbounded growth for
                // long plans while keeping sequence paths close to the cards.
                let gutterY: CGFloat = 18 + CGFloat(index % 3) * 6
                let exitX = start.x + 14
                let enterX = end.x - 14
                return Connector(edge: edge, points: [start, .init(x: exitX, y: start.y),
                                                      .init(x: exitX, y: gutterY), .init(x: enterX, y: gutterY),
                                                      .init(x: enterX, y: end.y), end])
            }
            return Connector(edge: edge, points: direct)
        }
        branches = agents.compactMap { agent in
            let members = unique.filter { node in
                node.id == agent.id || (node.parentID == agent.id)
            }.compactMap { frames[$0.id] }
            guard members.count > 1, let first = members.first else { return nil }
            let union = members.dropFirst().reduce(first) { $0.union($1) }
            return Branch(id: agent.id, title: agent.title,
                          frame: CGRect(x: union.minX - 12, y: union.minY - 30,
                                        width: union.width + 24, height: union.height + 42))
        }
        size = CGSize(width: max(minimumWidth, (placed.map { $0.frame.maxX }.max() ?? 0) + 24),
                      height: max(120, (placed.map { $0.frame.maxY }.max() ?? 0) + 24))
    }

    static func segment(_ start: CGPoint, _ end: CGPoint, intersectsInteriorOf rect: CGRect) -> Bool {
        if start.y == end.y {
            return start.y > rect.minY && start.y < rect.maxY && max(start.x, end.x) > rect.minX && min(start.x, end.x) < rect.maxX
        }
        if start.x == end.x {
            return start.x > rect.minX && start.x < rect.maxX && max(start.y, end.y) > rect.minY && min(start.y, end.y) < rect.maxY
        }
        return false // Layout connectors are orthogonal.
    }
}

struct AgentServerEvent: Equatable {
    let name: String
    let data: Data
}

enum AgentStreamError: LocalizedError {
    case incomplete
    case tooLarge
    case server(String)

    var errorDescription: String? {
        switch self {
        case .incomplete: return AppLocalization.string("The progress connection ended before the final result arrived.")
        case .tooLarge: return AppLocalization.string("The progress response exceeded the supported size.")
        case .server(let message): return message
        }
    }
}

/// Incremental SSE framing. Bytes can split UTF-8 characters, line endings, or
/// event boundaries. An unterminated event at EOF is never dispatched.
struct AgentSSEDecoder {
    private var line = Data()
    private var eventName = ""
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var skipLF = false
    private var isFirstLine = true
    private let maximumEventBytes = 2 * 1024 * 1024

    mutating func feed(_ data: Data) throws -> [AgentServerEvent] {
        var events: [AgentServerEvent] = []
        for byte in data {
            if let event = try feed(byte) { events.append(event) }
        }
        return events
    }

    mutating func feed(_ byte: UInt8) throws -> AgentServerEvent? {
        if skipLF {
            skipLF = false
            if byte == 10 { return nil }
        }
        if byte == 10 || byte == 13 {
            skipLF = byte == 13
            return processLine()
        }
        line.append(byte)
        eventBytes += 1
        guard eventBytes <= maximumEventBytes else { throw AgentStreamError.tooLarge }
        return nil
    }

    mutating func finish() -> [AgentServerEvent] {
        // SSE dispatch requires the blank line. Do not turn a partial final
        // response into success when a socket closes mid-frame.
        line.removeAll()
        dataLines.removeAll()
        eventName = ""
        return []
    }

    private mutating func processLine() -> AgentServerEvent? {
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); eventName = ""; eventBytes = 0 }
            guard !dataLines.isEmpty else { return nil }
            return AgentServerEvent(name: eventName.isEmpty ? "message" : eventName,
                                    data: Data(dataLines.joined(separator: "\n").utf8))
        }
        guard !text.hasPrefix(":") else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "event" { eventName = value }
        if field == "data" { dataLines.append(value) }
        return nil
    }
}
