import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var isThinking = false
    @Published var pendingPlan: AgentPlan?
    @Published var pendingPlanMessage: String?
    @Published var lastResults: [ActionResult]?
    @Published var error: String?

    /// History sent to the server is capped at the last 20 turns. The
    /// UI keeps the full list so the user can scroll back.
    private let serverHistoryCap = 20

    private let api = APIClient.shared

    func send(_ message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(ChatTurn(role: "user", content: trimmed, plan: nil, results: nil))
        isThinking = true
        error = nil
        defer { isThinking = false }
        let history = Array(turns.suffix(serverHistoryCap))
        let req = ChatRequest(history: history, message: trimmed)
        do {
            let resp = try await api.chat(req)
            let role = resp.type == "plan" ? "assistant_plan" : "assistant_ask"
            turns.append(ChatTurn(role: role, content: resp.message, plan: resp.plan, results: nil))
            if resp.type == "plan" {
                pendingPlan = resp.plan
                pendingPlanMessage = resp.message
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runPendingPlan() async {
        guard let plan = pendingPlan else { return }
        isThinking = true
        defer { isThinking = false }
        do {
            let resp = try await api.executePlan(plan)
            lastResults = resp.results
            turns.append(ChatTurn(
                role: "system_result",
                content: summary(of: resp.results),
                plan: nil,
                results: resp.results
            ))
            pendingPlan = nil
            pendingPlanMessage = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelPendingPlan() {
        pendingPlan = nil
        pendingPlanMessage = nil
    }

    private func summary(of results: [ActionResult]) -> String {
        let ok = results.filter { $0.status == "ok" }.count
        let fail = results.count - ok
        if fail == 0 { return "✓ all \(ok) action(s) completed" }
        return "ran \(results.count) action(s) — \(ok) ok, \(fail) failed"
    }
}
