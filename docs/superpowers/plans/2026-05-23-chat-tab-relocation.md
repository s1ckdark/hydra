# Chat Tab Relocation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the full chat UI from the cramped 420pt menubar popover into a new first-position Chat tab in the dashboard window, and reduce the menubar to a status/result + pending-plan-approval surface backed by a shared ChatViewModel promoted to app scope.

**Architecture:** Promote `ChatViewModel` to `HydraApp` as `@StateObject` and inject it as `@EnvironmentObject` to both the menubar and the dashboard. Introduce an `AppState` that owns the active tab so the menubar can route to the Chat tab on "Open Chat". Add a compact mode to `PlanCardView` for the menubar. Build a new `ChatTabView` as the full chat surface. No backend changes.

**Tech Stack:** SwiftUI (macOS 14+), `MenuBarExtra(.window)`, XCTest, existing `APIClient` + `/api/agent/{chat,execute}` endpoints. Swift Package Manager via `Hydra/Package.swift`.

**Spec:** `docs/superpowers/specs/2026-05-23-chat-tab-relocation-design.md`

---

## File Structure

**New files:**
- `Hydra/Hydra/State/AppState.swift` — single source of truth for cross-surface UI state (active tab today, room to grow)
- `Hydra/Hydra/Views/Chat/ChatTabView.swift` — full-window chat: input, scroll history, full PlanCard, empty state
- `Hydra/Tests/HydraTests/AppStateTests.swift` — unit tests for AppState defaults and mutation
- `Hydra/Tests/HydraTests/AgentPlanCompactSummaryTests.swift` — unit tests for the compact-summary helper

**Modified files:**
- `Hydra/Hydra/Models/AgentPlan.swift` — add a small `compactSummary` extension used by the menubar PlanCard
- `Hydra/Hydra/Views/MenuBar/PlanCardView.swift` — add a `compact: Bool` init (default `false`) and a compact rendering branch
- `Hydra/Hydra/Views/MenuBar/ChatSection.swift` — rewrite as a passive status/result + compact PlanCard + "Open Chat →" view; consume `ChatViewModel` and `AppState` via env
- `Hydra/Hydra/Views/MenuBar/MenuBarView.swift` — add "Open Chat" action that sets `appState.activeTab = .chat` then calls the existing `openDashboardWindow()`
- `Hydra/Hydra/Views/ContentView.swift` — add Chat tab as position 1, bind `TabView` `selection:` to `appState.activeTab`
- `Hydra/Hydra/HydraApp.swift` — add `@StateObject` for `ChatViewModel` and `AppState`, inject both into `ContentView` and `MenuBarView`

---

## Task 1: AppState — shared tab selection

**Files:**
- Create: `Hydra/Hydra/State/AppState.swift`
- Test: `Hydra/Tests/HydraTests/AppStateTests.swift`

- [ ] **Step 1: Write the failing tests**

`Hydra/Tests/HydraTests/AppStateTests.swift`:

```swift
import XCTest
@testable import Hydra

@MainActor
final class AppStateTests: XCTestCase {
    func testActiveTab_defaultsToChat() {
        let s = AppState()
        XCTAssertEqual(s.activeTab, .chat)
    }

    func testActiveTab_isMutable() {
        let s = AppState()
        s.activeTab = .devices
        XCTAssertEqual(s.activeTab, .devices)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Hydra && swift test --filter AppStateTests`
Expected: compile error — `AppState` not defined.

- [ ] **Step 3: Create AppState**

`Hydra/Hydra/State/AppState.swift`:

```swift
import Foundation

/// App-scope UI state shared by the menubar and the dashboard window.
/// Promoted out of view-local `@StateObject` so cross-surface signals
/// (e.g. "menubar wants the dashboard to switch to the Chat tab") stay
/// in one place.
@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable {
        case chat
        case dashboard
        case devices
        case orchs
        case tasks
        case settings
    }

    @Published var activeTab: Tab = .chat
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Hydra && swift test --filter AppStateTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Hydra/Hydra/State/AppState.swift Hydra/Tests/HydraTests/AppStateTests.swift
git commit -m "feat(app): add AppState for cross-surface tab selection"
```

---

## Task 2: AgentPlan.compactSummary helper

**Files:**
- Modify: `Hydra/Hydra/Models/AgentPlan.swift` (append extension at end of file)
- Test: `Hydra/Tests/HydraTests/AgentPlanCompactSummaryTests.swift`

This helper produces the one-line action label used by the compact PlanCard in the menubar.

- [ ] **Step 1: Write the failing tests**

`Hydra/Tests/HydraTests/AgentPlanCompactSummaryTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Hydra && swift test --filter AgentPlanCompactSummaryTests`
Expected: compile error — `compactActionLabel` not a member.

- [ ] **Step 3: Add the extension**

Append to `Hydra/Hydra/Models/AgentPlan.swift`:

```swift
extension AgentPlan {
    /// One-line action label for the menubar's compact PlanCard:
    /// the first action's `type`, with `(+N more)` appended when the
    /// plan has more than one action.
    var compactActionLabel: String {
        guard let first = actions.first else { return "" }
        if actions.count == 1 { return first.type }
        return "\(first.type) (+\(actions.count - 1) more)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Hydra && swift test --filter AgentPlanCompactSummaryTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Hydra/Hydra/Models/AgentPlan.swift Hydra/Tests/HydraTests/AgentPlanCompactSummaryTests.swift
git commit -m "feat(agent): AgentPlan.compactActionLabel helper for menubar"
```

---

## Task 3: PlanCardView compact mode

**Files:**
- Modify: `Hydra/Hydra/Views/MenuBar/PlanCardView.swift`

Add a `compact: Bool` parameter (default `false`). In compact mode show intent + `compactActionLabel` + Run/Cancel; in full mode keep today's per-action list.

- [ ] **Step 1: Rewrite PlanCardView with a compact branch**

Replace the entire contents of `Hydra/Hydra/Views/MenuBar/PlanCardView.swift`:

```swift
import SwiftUI

/// Renders an LLM-proposed plan with Run / Cancel buttons. Two modes:
/// - full (default): per-action list with args, used in the Chat tab
/// - compact: intent + first action label only, used in the menubar
struct PlanCardView: View {
    let plan: AgentPlan
    let message: String?
    let isThinking: Bool
    let compact: Bool
    let onRun: () -> Void
    let onCancel: () -> Void

    init(
        plan: AgentPlan,
        message: String?,
        isThinking: Bool,
        compact: Bool = false,
        onRun: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.plan = plan
        self.message = message
        self.isThinking = isThinking
        self.compact = compact
        self.onRun = onRun
        self.onCancel = onCancel
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.intent)
                    .font(.caption.bold())
                    .lineLimit(compact ? 1 : nil)
                    .truncationMode(.tail)

                if !compact, let message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if compact {
                    Text(plan.compactActionLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Divider()
                    ForEach(plan.actions) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(action.type)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 4)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(argsSummary(action.args))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Run", action: onRun)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isThinking)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// One-line summary of an action's args for the full-mode row label.
    private func argsSummary(_ args: AnyCodable) -> String {
        guard let dict = args.value as? [String: Any] else { return "" }
        return dict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    }
}
```

- [ ] **Step 2: Build to verify nothing breaks (callers default to full mode)**

Run: `cd Hydra && swift build`
Expected: build succeeds; the existing `ChatSection` caller still works because `compact` defaults to `false`.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Views/MenuBar/PlanCardView.swift
git commit -m "feat(agent): add compact mode to PlanCardView for menubar"
```

---

## Task 4: Promote ChatViewModel + AppState to app scope

**Files:**
- Modify: `Hydra/Hydra/HydraApp.swift`

`ChatViewModel` becomes a `@StateObject` on `HydraApp`. Both `ContentView` and `MenuBarView` receive it (and `AppState`) via `.environmentObject`. `ChatSection` keeps its local `@StateObject` for now — Task 5 swaps it. No behavior change yet, just plumbing.

- [ ] **Step 1: Add app-scope state objects and inject them**

In `Hydra/Hydra/HydraApp.swift`, find the existing `@StateObject private var dashboardVM` line and add two more state objects right after it:

```swift
    @StateObject private var dashboardVM = DashboardViewModel()
    @StateObject private var chatVM = ChatViewModel()
    @StateObject private var appState = AppState()
```

Then, in the macOS `WindowGroup(id: "dashboard")` block, find the `.environmentObject(dashboardVM)` line and add two more right under it:

```swift
            ContentView()
                .environmentObject(dashboardVM)
                .environmentObject(chatVM)
                .environmentObject(appState)
                .onAppear {
```

Same in the `MenuBarExtra` block — find the existing `.environmentObject(dashboardVM)` and extend:

```swift
        MenuBarExtra("GPU Orch", systemImage: "server.rack") {
            MenuBarView()
                .environmentObject(dashboardVM)
                .environmentObject(chatVM)
                .environmentObject(appState)
        }
```

- [ ] **Step 2: Build to verify**

Run: `cd Hydra && swift build`
Expected: build succeeds; ChatSection still owns its own `@StateObject` (untouched), the new env objects are present but unused.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/HydraApp.swift
git commit -m "feat(app): promote ChatViewModel and AppState to app scope"
```

---

## Task 5: Rewrite menubar ChatSection as passive surface

**Files:**
- Modify: `Hydra/Hydra/Views/MenuBar/ChatSection.swift`

Strip input + scroll history. Consume the shared `ChatViewModel` and `AppState` from env. Show: always-visible status line, last-result line (when a qualifying turn exists), compact PlanCard (when pending), and an "Open Chat →" button.

- [ ] **Step 1: Rewrite ChatSection**

Replace the entire contents of `Hydra/Hydra/Views/MenuBar/ChatSection.swift`:

```swift
import SwiftUI

/// Menubar chat surface. Read-only: status, last result, and a compact
/// PlanCard for pending-plan approval. The actual conversation lives in
/// the dashboard's Chat tab; the "Open Chat →" button routes there.
struct ChatSection: View {
    @EnvironmentObject var vm: ChatViewModel
    @EnvironmentObject var appState: AppState

    /// Called when the user wants to open the dashboard window with the
    /// Chat tab active. Hosted by `MenuBarView`, which owns the AppKit
    /// activation dance.
    var onOpenChat: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chat")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            statusLine

            if let last = lastRelevantTurn {
                resultLine(turn: last)
            }

            if let plan = vm.pendingPlan {
                PlanCardView(
                    plan: plan,
                    message: vm.pendingPlanMessage,
                    isThinking: vm.isThinking,
                    compact: true,
                    onRun:    { Task { await vm.runPendingPlan() } },
                    onCancel: { vm.cancelPendingPlan() }
                )
            }

            if let err = vm.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Button(action: onOpenChat) {
                HStack(spacing: 4) {
                    Text("Open Chat")
                    Image(systemName: "arrow.right")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if let plan = vm.pendingPlan {
            return "Plan pending (\(plan.actions.count) action\(plan.actions.count == 1 ? "" : "s"))"
        }
        if vm.isThinking { return "Thinking…" }
        if vm.error != nil { return "Error" }
        return "Idle"
    }

    private var statusColor: Color {
        if vm.pendingPlan != nil { return .orange }
        if vm.isThinking { return .accentColor }
        if vm.error != nil { return .red }
        return .secondary
    }

    private var lastRelevantTurn: ChatTurn? {
        vm.turns.last { ["assistant_ask", "assistant_plan", "system_result"].contains($0.role) }
    }

    private func resultLine(turn: ChatTurn) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(roleGlyph(for: turn.role))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(turn.content)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func roleGlyph(for role: String) -> String {
        switch role {
        case "assistant_ask":  return "?"
        case "assistant_plan": return "▶"
        case "system_result":  return "✓"
        default:               return "•"
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd Hydra && swift build`
Expected: build succeeds. The old in-popover input field, scroll history, and full PlanCard are gone; menubar will visually render the new passive surface but `onOpenChat` is a no-op until Task 7 wires it.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Views/MenuBar/ChatSection.swift
git commit -m "feat(agent): menubar ChatSection -> passive status/result surface"
```

---

## Task 6: ChatTabView — full chat surface

**Files:**
- Create: `Hydra/Hydra/Views/Chat/ChatTabView.swift`

Full-window chat consuming `ChatViewModel` from env. Auto-scroll to bottom on new turn, auto-focus the input on tab appear, empty-state hint, full `PlanCardView`.

- [ ] **Step 1: Create ChatTabView**

`Hydra/Hydra/Views/Chat/ChatTabView.swift`:

```swift
import SwiftUI

/// Full chat surface, hosted in the dashboard window's Chat tab.
/// Mirrors the agent flow the menubar used to host inline, with room
/// to breathe and a focused input.
struct ChatTabView: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            if vm.turns.isEmpty && vm.pendingPlan == nil {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(vm.turns) { turn in
                                ChatTurnRow(turn: turn)
                                    .id(turn.id)
                            }
                            if let plan = vm.pendingPlan {
                                PlanCardView(
                                    plan: plan,
                                    message: vm.pendingPlanMessage,
                                    isThinking: vm.isThinking,
                                    compact: false,
                                    onRun:    { Task { await vm.runPendingPlan() } },
                                    onCancel: { vm.cancelPendingPlan() }
                                )
                                .id("pendingPlan")
                            }
                            if let err = vm.error {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onChange(of: vm.turns.count) { _, _ in
                        scrollToBottom(proxy)
                    }
                    .onChange(of: vm.pendingPlan == nil) { _, _ in
                        scrollToBottom(proxy)
                    }
                }
            }

            inputBar
        }
        .padding(.bottom, 8)
        .onAppear { inputFocused = true }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Ask Hydra anything")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("e.g. \"list devices\" or \"create an orch on home-mac\"")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var inputBar: some View {
        HStack {
            TextField("Ask Hydra…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { submit() }
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.isThinking)
            if vm.isThinking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal)
    }

    private func submit() {
        let msg = draft
        draft = ""
        Task { await vm.send(msg) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if vm.pendingPlan != nil {
            withAnimation { proxy.scrollTo("pendingPlan", anchor: .bottom) }
            return
        }
        if let last = vm.turns.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

private struct ChatTurnRow: View {
    let turn: ChatTurn
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(roleSymbol)
                .font(.caption.bold())
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(turn.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var roleSymbol: String {
        switch turn.role {
        case "user":            return "›"
        case "assistant_ask":   return "?"
        case "assistant_plan":  return "▶"
        case "system_result":   return "✓"
        default:                return "•"
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd Hydra && swift build`
Expected: build succeeds. View is defined but not yet wired into `ContentView`.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Views/Chat/ChatTabView.swift
git commit -m "feat(agent): ChatTabView - full chat surface for dashboard"
```

---

## Task 7: Wire Chat tab + MenuBar "Open Chat"

**Files:**
- Modify: `Hydra/Hydra/Views/ContentView.swift`
- Modify: `Hydra/Hydra/Views/MenuBar/MenuBarView.swift`

Add the Chat tab at position 1 with selection bound to `AppState.activeTab`. Wire the menubar's `ChatSection.onOpenChat` to set the tab and open the dashboard.

- [ ] **Step 1: Update ContentView**

Replace the entire contents of `Hydra/Hydra/Views/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.activeTab) {
            ChatTabView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppState.Tab.chat)

            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge") }
                .tag(AppState.Tab.dashboard)

            DeviceListView()
                .tabItem { Label("Devices", systemImage: "desktopcomputer") }
                .tag(AppState.Tab.devices)

            OrchListView()
                .tabItem { Label("Orchs", systemImage: "server.rack") }
                .tag(AppState.Tab.orchs)

            #if os(macOS)
            TasksView()
                .tabItem { Label("Tasks", systemImage: "list.bullet.clipboard") }
                .tag(AppState.Tab.tasks)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppState.Tab.settings)
            #endif
        }
        .task {
            await dashboardVM.load()
        }
    }
}
```

- [ ] **Step 2: Update MenuBarView**

In `Hydra/Hydra/Views/MenuBar/MenuBarView.swift`:

1. Add `@EnvironmentObject var appState: AppState` near the top of the struct alongside the existing `@EnvironmentObject var vm: DashboardViewModel`.

2. Replace the line `ChatSection()` with:

```swift
            ChatSection(onOpenChat: openChat)
```

3. Add a new private method right after `openDashboardWindow()`:

```swift
    /// Routes the menubar's "Open Chat" tap to the dashboard's Chat
    /// tab. Sets the shared activeTab first so the TabView's selection
    /// binding picks it up the moment SwiftUI materialises the window.
    private func openChat() {
        appState.activeTab = .chat
        openDashboardWindow()
    }
```

- [ ] **Step 3: Build to verify**

Run: `cd Hydra && swift build`
Expected: build succeeds.

- [ ] **Step 4: Run full test suite**

Run: `cd Hydra && swift test`
Expected: all tests pass — AppStateTests (2), AgentPlanCompactSummaryTests (3), plus the pre-existing Device/SSH/Metrics tests.

- [ ] **Step 5: Commit**

```bash
git add Hydra/Hydra/Views/ContentView.swift Hydra/Hydra/Views/MenuBar/MenuBarView.swift
git commit -m "feat(agent): wire Chat tab + menubar Open Chat routing"
```

---

## Task 8: Manual smoke verification

The chat agent's runtime path (API → plan → execute) is unchanged, but UI plumbing is heavily rearranged. Verify by hand against the spec's testing checklist.

- [ ] **Step 1: Start the backend**

Run in one terminal: `make run-server`
Expected: server listens on :8080.

- [ ] **Step 2: Launch the app**

In another terminal:

```bash
cd Hydra && swift build -c release
open .build/release/Hydra.app 2>/dev/null || swift run Hydra
```

Or if a prebuilt `.app` bundle exists at `Hydra/.build/Hydra.app`:

```bash
open Hydra/.build/Hydra.app
```

- [ ] **Step 3: Verify fresh-launch state**

- Menubar popover (click the rack icon): status line shows "● Idle" (secondary dot). No last-result line. No PlanCard. "Open Chat →" button visible.
- Click "Open Chat →": dashboard window opens AND Chat tab is the active tab (first position). Empty-state hint visible. TextField is focused.

- [ ] **Step 4: Verify send → plan → menubar reflection**

In the Chat tab, type `list devices` and hit Return.
Expected: a `›` user turn appears, then `Thinking…` indicator briefly, then either an `?` ask turn or a `▶` plan turn + full `PlanCardView` below the history. Now open the menubar:
- Status line shows "● Plan pending (N actions)" (orange dot) if a plan landed, OR the assistant message in the result line if it was an ask
- Compact PlanCard visible only if there's a pending plan, with `[Cancel] [Run]`

- [ ] **Step 5: Verify Run from menubar**

With a pending plan in the menubar, click `Run`. Expected: popover stays open, `isThinking` flips on, then a `system_result` turn appears in the Chat tab. Menubar status returns to "● Idle" with last-result line `✓ all N action(s) completed` (or the partial-failure summary).

- [ ] **Step 6: Verify Cancel from menubar**

Send another message that produces a plan. Open the menubar, click `Cancel`. Expected: pending plan clears in both surfaces; menubar status returns to Idle.

- [ ] **Step 7: Verify state survives window close**

With turns in history, close the dashboard window (red close button — does NOT quit the app). Reopen via menubar `Open Chat →`. Expected: previous turns still present in Chat tab (proves `ChatViewModel` is app-scoped now).

- [ ] **Step 8: Verify error path**

Stop the backend (Ctrl-C). Send a chat message from the Chat tab. Expected: `vm.error` populates; Chat tab shows the error label; menubar status line shows "● Error" (red dot).

- [ ] **Step 9: Commit any small fixes**

If verification surfaces small UI tweaks (spacing, copy), make them and commit individually. If nothing needs fixing, skip.

- [ ] **Step 10: Final overall commit (if any small fixes landed)**

If no fixes, the relocation work ends with Task 7's commit. Otherwise commit each tweak.

---

## Definition of Done

- [ ] All 8 tasks above completed
- [ ] `swift test` is green
- [ ] `swift build` succeeds with no warnings introduced
- [ ] Manual smoke checklist (Steps 3–8 of Task 8) all pass
- [ ] No remaining references in the codebase to a `ChatSection`-owned `ChatViewModel` (`grep -r "ChatViewModel()" Hydra/Hydra/Views` returns only HydraApp's `@StateObject` declaration site — and that line is in `HydraApp.swift`, not under `Views/`)
