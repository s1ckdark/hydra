import XCTest
@testable import Hydra

final class AgentPlanCompactSummaryTests: XCTestCase {
    func testCompactActionLabel_singleAction() {
        let plan = AgentPlan(
            intent: "list devices",
            actions: [AgentAction(type: "list_devices", args: AnyCodable([String: Any]()))]
        )
        XCTAssertEqual(plan.compactActionLabel, "list_devices")
    }

    func testCompactActionLabel_multipleActions_appendsMoreCount() {
        let plan = AgentPlan(
            intent: "spin up batch",
            actions: [
                AgentAction(type: "create_orch", args: AnyCodable([String: Any]())),
                AgentAction(type: "execute_command", args: AnyCodable([String: Any]())),
                AgentAction(type: "execute_command", args: AnyCodable([String: Any]())),
            ]
        )
        XCTAssertEqual(plan.compactActionLabel, "create_orch (+2 more)")
    }

    func testCompactActionLabel_emptyActions_returnsEmpty() {
        let plan = AgentPlan(intent: "noop", actions: [])
        XCTAssertEqual(plan.compactActionLabel, "")
    }
}
