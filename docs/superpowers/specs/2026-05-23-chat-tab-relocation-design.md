# Chat Relocation: Menubar → Dashboard Chat Tab

**Date:** 2026-05-23
**Status:** Draft
**Related:** `2026-05-22-menubar-chat-agent-design.md` (predecessor — established the agent itself; this spec relocates its surface)

## Problem

The current menubar popover (`MenuBarView`, 420pt wide) hosts the full chat experience: input field, scrolling history, plan card, Run/Cancel. The popover is too cramped for sustained chat use — typing, reading multi-turn history, and reviewing multi-action plans all feel constricted. The popover also dismisses on outside-click, which interrupts longer interactions.

The user wants the menubar reduced to a **status/result surface**: see what's happening with the chat agent at a glance, approve pending plans without context-switching, but do the actual conversation elsewhere.

## Goals

- Move full chat UI (input, scrollable history, full plan card) out of the menubar
- Keep the menubar as a passive surface — status, latest result, pending-plan approval — with one CTA to open the real chat
- Share a single `ChatViewModel` across menubar and chat tab so state survives popover dismiss and matches between surfaces
- Reuse existing data flow (`/api/agent/chat`, `/api/agent/execute`) and the validated `openDashboardWindow()` activation pattern — no new backend, no new activation code

## Non-Goals

- Separate chat window (own `WindowGroup`)
- Detachable popover
- Sending new messages from the menubar
- Push/sound notifications when results arrive
- Streaming token-level updates (existing chat is request/response)

## Architecture

### Ownership

`ChatViewModel` is promoted from `ChatSection`'s `@StateObject` to `HydraApp`'s `@StateObject` and injected as `@EnvironmentObject` to both `MenuBarView` and `ContentView`. This is the only ownership change.

A new lightweight `AppState` holds tab selection so the menubar can route to the chat tab when opening the dashboard:

```swift
@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable { case chat, dashboard, devices, orchs, tasks, settings }
    @Published var activeTab: Tab = .chat
}
```

`AppState` is owned by `HydraApp` and injected as `EnvironmentObject` alongside `ChatViewModel`.

### Component map

| File | Change |
|---|---|
| `HydraApp.swift` | Add `@StateObject` for `ChatViewModel` and `AppState`; inject both via `.environmentObject` on `ContentView` and `MenuBarView` |
| `Views/ContentView.swift` | Add `selection: $appState.activeTab` to `TabView`; add **Chat tab as position 1** (before Dashboard); use the shared `ChatViewModel` |
| `Views/Chat/ChatTabView.swift` *(new)* | Full chat UI: input + scroll history + full `PlanCardView` + auto-focus + auto-scroll-to-bottom. Adapted from the existing `ChatSection` logic |
| `Views/MenuBar/ChatSection.swift` *(rewritten — smaller)* | Always-visible status line + last-result line + (when `pendingPlan != nil`) compact `PlanCardView` + "Open Chat →" button. No input, no scroll |
| `Views/MenuBar/PlanCardView.swift` | Add `compact: Bool` initializer parameter. Compact mode shows intent + first action's type + `(+N more)` suffix when actions > 1, plus Cancel/Run. Full mode unchanged |
| `Views/MenuBar/MenuBarView.swift` | Add "Open Chat" action: set `appState.activeTab = .chat`, then call existing `openDashboardWindow()` |

### Menubar chat section layout (final)

```
Chat
● <status>                ← always visible
✓ <last result/turn>      ← only when a relevant turn exists
┌ <intent> ───────────┐   ← only when pendingPlan != nil
│ create_orch (+1 more)│
│  [Cancel]    [Run]   │
└──────────────────────┘
[Open Chat →]
```

#### Status line rules

- Always rendered (per UX decision — even "Idle" is informative)
- Precedence: `pendingPlan != nil` → "Plan pending (N actions)" (orange dot) > `isThinking` → "Thinking…" (accent dot) > `error != nil` → "Error" (red dot) > "Idle" (secondary dot)
- Dot is a 6pt `Circle().fill(...)`

#### Last-result line rules

- Source: `turns.last(where: { ["assistant_ask", "assistant_plan", "system_result"].contains($0.role) })?.content`
- `.lineLimit(1)`, `.truncationMode(.tail)`
- Prefixed by a small role glyph (`✓` for system_result, `?` for assistant_ask, `▶` for assistant_plan) — reusing the existing `roleSymbol` mapping
- Hidden when no qualifying turn exists yet (fresh launch)

#### Compact PlanCard rules

- Visible only when `vm.pendingPlan != nil`
- Renders `plan.intent` (1 line, truncate) + first action's `type` + `(+N more)` when `plan.actions.count > 1`
- Cancel/Run buttons preserved — same handlers as before (`vm.cancelPendingPlan()`, `Task { await vm.runPendingPlan() }`)
- Run button disabled while `vm.isThinking`

### Chat tab layout (full)

- Reuses `ChatViewModel` from environment
- Uses `ScrollViewReader` + `.onChange(of: vm.turns.count)` to auto-scroll to the last row on each new turn
- `@FocusState` on the `TextField` — focused when the tab becomes active (`.onAppear`)
- No `maxHeight` cap — list grows to fill window
- Full `PlanCardView` (compact: false) for pending plans, rendered inline at the bottom of history just like today
- Error label preserved
- **Empty state:** when `vm.turns.isEmpty`, render a centered placeholder ("Ask Hydra anything — e.g. *list devices*") instead of an empty scroll view

### Open-Chat flow

```
MenuBarView "Open Chat" tap
  → appState.activeTab = .chat
  → openDashboardWindow()   // existing NSWorkspace.openApplication pattern
  → ContentView's TabView observes activeTab binding, shows ChatTabView
  → ChatTabView.onAppear focuses the TextField
```

No new activation code. The existing `openDashboardWindow()` already handles popover-context activation correctly.

### Data flow (unchanged)

- `ChatViewModel.send(_:)` → `APIClient.chat(req)` → appends turn(s), sets `pendingPlan`
- `ChatViewModel.runPendingPlan()` → `APIClient.executePlan(plan)` → appends `system_result` turn, clears `pendingPlan`
- `ChatViewModel.cancelPendingPlan()` → clears `pendingPlan`

API signatures, request shape, history cap (20), all unchanged.

## Edge cases

- **Pending plan + recent result coexist:** A prior run finished with a result, then a new user message produced a new plan. Both the last-result line and the compact plan card render; status line says "Plan pending".
- **Error after a successful turn:** `vm.error` set, but `turns` still has the success. Status line shows "Error", error label appears in chat tab, but the menubar last-result line still shows the success — the error surfaces via the status line color/text.
- **Popover closed mid-`Thinking…`:** ViewModel moved up to App scope, so `isThinking` and the eventual response/plan persist; reopening the popover shows the updated state.
- **Cold launch, dashboard closed:** Clicking Open Chat sets tab to `.chat` *before* calling `openDashboardWindow()`, so when SwiftUI materializes `ContentView`, it picks up the selection immediately.
- **User clicks Run in menubar, popover dismisses on action:** `runPendingPlan()` runs on the ViewModel which lives at App scope — popover closure doesn't cancel the in-flight request.

## Testing

- Unit: `ChatViewModel` already covered by existing tests (state transitions); no behavior change, just owner change. Add one test asserting `AppState.activeTab` defaults to `.chat`.
- Manual:
  1. Fresh launch → menubar shows "Idle" status, no result line, no plan card, Open Chat button — verify Chat tab opens as the **active** tab
  2. Send a message from Chat tab → menubar status flips to Thinking… then to Plan pending — verify result line populates with assistant message
  3. Click Run in menubar — verify execution proceeds, system_result turn appears in both surfaces, status returns to Idle
  4. Click Cancel in menubar — pending plan clears in both surfaces
  5. Leave a pending plan, close the dashboard window, reopen via menubar Open Chat — plan card and history still visible in Chat tab (shared ViewModel survived window close)
  6. Trigger a chat error (server down) → menubar status shows "Error" in red, error label visible in Chat tab
  7. Empty state: clean install / no turns → Chat tab shows a placeholder hint ("Ask Hydra anything — e.g. *list devices*"), menubar shows status "Idle" with no result line

## Risks

- **TabView selection binding interaction:** SwiftUI `TabView` with a `selection:` binding has historically had quirks on macOS when tabs are conditionally compiled. The `#if os(macOS)` guards in `ContentView` (Tasks/Settings) need to stay outside the selection set or be included in the enum. Mitigation: include all tabs unconditionally in the `AppState.Tab` enum but only render conditionally — selection of a hidden tab falls back to the default.
- **AppState in EnvironmentObject vs. observation on macOS 14:** standard pattern, no known gotchas, but worth a smoke test in the build.

## Migration

Single commit (or stacked: model promotion → compact PlanCard → MenuBar rewrite → Chat tab). Pure UI/state-ownership change — no API, no persistence, no schema.
