import XCTest
@testable import Hydra

final class AgentRunTests: XCTestCase {
    func testSSEHandlesSplitUTF8CRLFCommentsAndMultipleEvents() throws {
        let payload = "\u{FEFF}: heartbeat\r\nevent: progress\r\ndata: {\"title\":\"검토\"}\r\n\r\nevent: chat_result\ndata: {\"type\":\"ask\"}\n\n"
        var decoder = AgentSSEDecoder()
        var events: [AgentServerEvent] = []
        for byte in payload.utf8 {
            events += try decoder.feed(Data([byte]))
        }
        XCTAssertEqual(events.map(\.name), ["progress", "chat_result"])
        XCTAssertEqual(String(data: events[0].data, encoding: .utf8), "{\"title\":\"검토\"}")
        XCTAssertTrue(decoder.finish().isEmpty)
    }

    func testSSEJoinsDataLinesIgnoresUnknownFieldsAndDefaultsEventName() throws {
        var decoder = AgentSSEDecoder()
        let events = try decoder.feed(Data("id: 12\rretry: 30\rdata: first\rdata:second\r\revent: error\ndata: {\"error\":\"safe error\"}\n\n".utf8))
        XCTAssertEqual(events.map(\.name), ["message", "error"])
        XCTAssertEqual(String(data: events[0].data, encoding: .utf8), "first\nsecond")
        XCTAssertEqual(String(data: events[1].data, encoding: .utf8), #"{"error":"safe error"}"#)
    }

    func testSSEEOFDoesNotDispatchAnUnterminatedFinalFrame() throws {
        for value in ["event: execute_result\ndata: {}", "event: execute_result\ndata: {}\n"] {
            var decoder = AgentSSEDecoder()
            XCTAssertTrue(try decoder.feed(Data(value.utf8)).isEmpty)
            XCTAssertTrue(decoder.finish().isEmpty)
        }
    }

    func testSSERejectsAnUnboundedEvent() throws {
        var decoder = AgentSSEDecoder()
        XCTAssertThrowsError(try decoder.feed(Data(repeating: 65, count: 2 * 1024 * 1024 + 1))) { error in
            guard case AgentStreamError.tooLarge = error else { return XCTFail("Expected size bound") }
        }
    }

    func testExecutionMergeRetainsHeadHistoryAndReplacesNodeStates() {
        let planning = Self.planning
        var execution = Self.executing
        execution.edges = [.init(from: "agent", to: "approval", kind: "sequence"),
                           .init(from: "approval", to: "action-0", kind: "sequence")]
        let merged = planning.mergingExecution(execution)
        XCTAssertEqual(merged.runID, planning.runID)
        XCTAssertEqual(merged.nodes.first { $0.id == "head" }?.status, .completed)
        XCTAssertEqual(merged.nodes.first { $0.id == "approval" }?.status, .completed)
        XCTAssertEqual(merged.nodes.first { $0.id == "action-0" }?.status, .running)
        XCTAssertTrue(merged.edges.contains(.init(from: "head", to: "agent", kind: "sequence")))
        XCTAssertEqual(merged.edges.filter { $0.from == "agent" && $0.to == "approval" }.count, 1)
        let other = AgentRunSnapshot(runID: "other", phase: "planning", nodes: [], edges: [])
        XCTAssertEqual(planning.mergingExecution(other), other)
    }

    func testCancelAndDisconnectNeverInventCompletedActions() {
        var cancelled = Self.planning
        cancelled.cancelApproval(at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(cancelled.phase, "cancelled")
        XCTAssertEqual(cancelled.nodes.first { $0.id == "approval" }?.status, .cancelled)
        XCTAssertEqual(cancelled.nodes.first { $0.id == "action-0" }?.status, .skipped)
        XCTAssertEqual(cancelled.nodes.first { $0.id == "head" }?.status, .completed)
        var disconnected = Self.executing
        disconnected.markDisconnected()
        XCTAssertEqual(disconnected.phase, "unknown")
        XCTAssertEqual(disconnected.nodes.first { $0.id == "action-0" }?.status, .unknown)
        XCTAssertEqual(disconnected.nodes.first { $0.id == "approval" }?.status, .completed)
    }

    func testLayoutFollowsActualEdgesAndIsStableInNarrowWindows() {
        let snapshot = Self.planning
        let layout = AgentTreeLayout(snapshot: snapshot, minimumWidth: 280)
        let frames = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.frame) })
        XCTAssertEqual(layout.nodes.map(\.id), snapshot.orderedNodes.map(\.id))
        XCTAssertNil(layout.nodes.first { $0.id == "root" }?.displayStep)
        XCTAssertEqual(layout.nodes.first { $0.id == "head" }?.displayStep, 1)
        XCTAssertEqual(layout.nodes.first { $0.id == "action-0" }?.displayStep, 4)
        XCTAssertGreaterThan(layout.size.width, 280)
        XCTAssertEqual(frames["head"]?.width, 220)
        XCTAssertLessThan(frames["head"]!.maxX, frames["agent"]!.minX)
        XCTAssertLessThan(frames["approval"]!.maxX, frames["action-0"]!.minX)
        XCTAssertEqual(layout.connectors.count, snapshot.edges.count)
        for connector in layout.connectors {
            XCTAssertEqual(connector.points.first?.x, frames[connector.edge.from]?.maxX)
            XCTAssertEqual(connector.points.last?.x, frames[connector.edge.to]?.minX)
        }
        let reversed = AgentRunSnapshot(runID: snapshot.runID, phase: snapshot.phase,
                                        nodes: snapshot.nodes.reversed(), edges: snapshot.edges.reversed())
        let second = AgentTreeLayout(snapshot: reversed, minimumWidth: 280)
        XCTAssertEqual(layout.nodes, second.nodes)
        XCTAssertEqual(layout.connectors, second.connectors)
        XCTAssertEqual(layout.branches.count, 1)
    }

    func testLayoutEmptyBranchesAndMalformedEdgesRemainFiniteWithoutOverlap() {
        let empty = AgentTreeLayout(snapshot: .init(runID: "empty", phase: "planning", nodes: [], edges: []), minimumWidth: 280)
        XCTAssertEqual(empty.size.width, 280)
        XCTAssertEqual(empty.nodes.count, 0)
        var branch = Self.planning
        branch.nodes.append(.init(id: "agent-2", parentID: "root", kind: "agent", title: "Second", status: .queued, order: 2))
        branch.edges.append(.init(from: "head", to: "agent-2", kind: "delegation"))
        branch.edges.append(.init(from: "missing", to: "agent-2", kind: "sequence"))
        let layout = AgentTreeLayout(snapshot: branch)
        for (index, node) in layout.nodes.enumerated() {
            for other in layout.nodes.dropFirst(index + 1) { XCTAssertFalse(node.frame.intersects(other.frame)) }
        }
        XCTAssertFalse(layout.connectors.contains { $0.edge.from == "missing" })
        let first = layout.nodes.first { $0.id == "agent" }!
        let second = layout.nodes.first { $0.id == "agent-2" }!
        XCTAssertEqual(first.frame.minX, second.frame.minX)
        XCTAssertLessThan(first.frame.maxY, second.frame.minY)
        branch.edges.append(.init(from: "action-0", to: "head", kind: "sequence"))
        XCTAssertTrue(AgentTreeLayout(snapshot: branch).size.width.isFinite)
    }

    func testLongDelegationEdgesUseGuttersWithoutCrossingUnrelatedCards() {
        var snapshot = Self.planning
        snapshot.nodes.append(.init(id: "action-1", parentID: "agent", kind: "action", title: "Inspect again", status: .queued, order: 5))
        snapshot.nodes.append(.init(id: "summary", parentID: "agent", kind: "summary", title: "Summary", status: .queued, order: 6))
        snapshot.edges += [.init(from: "root", to: "agent", kind: "delegation"),
                           .init(from: "agent", to: "action-0", kind: "delegation"),
                           .init(from: "agent", to: "action-1", kind: "delegation"),
                           .init(from: "agent", to: "summary", kind: "delegation"),
                           .init(from: "action-0", to: "action-1", kind: "sequence"),
                           .init(from: "action-1", to: "summary", kind: "sequence")]
        let layout = AgentTreeLayout(snapshot: snapshot)
        for connector in layout.connectors {
            for card in layout.nodes where card.id != connector.edge.from && card.id != connector.edge.to {
                for segment in zip(connector.points, connector.points.dropFirst()) {
                    XCTAssertFalse(AgentTreeLayout.segment(segment.0, segment.1, intersectsInteriorOf: card.frame),
                                   "\(connector.edge.id) crosses \(card.id)")
                }
            }
        }
        XCTAssertGreaterThan(layout.connectors.first { $0.edge.from == "agent" && $0.edge.to == "summary" }!.points.count, 4)
        XCTAssertEqual(layout.connectors.first { $0.edge.from == "action-0" && $0.edge.to == "action-1" }!.points.count, 4)
        XCTAssertLessThan(layout.size.height, 250)
    }

    static let planning = AgentRunSnapshot(runID: "run-1", phase: "awaiting_approval", nodes: [
        .init(id: "root", kind: "root", title: "Request", status: .waiting, order: 0),
        .init(id: "head", parentID: "root", kind: "head", title: "Head", status: .completed, order: 1),
        .init(id: "agent", parentID: "root", kind: "agent", title: "Reviewer", status: .completed, order: 2, agentID: "agent", provider: "openai", model: "exact"),
        .init(id: "approval", parentID: "agent", kind: "approval", title: "Approval", status: .waiting, order: 3),
        .init(id: "action-0", parentID: "agent", kind: "action", title: "Inspect", status: .queued, order: 4, actionType: "list_devices")
    ], edges: [
        .init(from: "root", to: "head", kind: "delegation"),
        .init(from: "head", to: "agent", kind: "sequence"),
        .init(from: "agent", to: "approval", kind: "sequence"),
        .init(from: "approval", to: "action-0", kind: "sequence")
    ])

    static let executing = AgentRunSnapshot(runID: "run-1", phase: "executing", nodes: [
        .init(id: "root", kind: "root", title: "Request", status: .running, order: 0),
        .init(id: "agent", parentID: "root", kind: "agent", title: "Reviewer", status: .completed, order: 2),
        .init(id: "approval", parentID: "agent", kind: "approval", title: "Approval", status: .completed, order: 3),
        .init(id: "action-0", parentID: "agent", kind: "action", title: "Inspect", status: .running, order: 4, actionType: "list_devices")
    ], edges: [.init(from: "approval", to: "action-0", kind: "sequence")])
}
