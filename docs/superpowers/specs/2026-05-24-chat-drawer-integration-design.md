# Chat-as-Drawer + Context-Aware AI

**Date:** 2026-05-24
**Status:** Approved (pending implementation plan)
**Supersedes parts of:** [2026-05-23-chat-tab-relocation-design.md](./2026-05-23-chat-tab-relocation-design.md)

## Motivation

The previous design promoted chat to its own dashboard tab so the agent could have a full surface to breathe. In practice, work happens **inside the operational tabs** — Devices, Orchs, Tasks — and tab-switching to chat then back loses the user's mental context.

The user's goal: AI-augmented operation, where the chat sees what the user sees and acts on it. Linear's and Cursor's right-side AI panels are the reference. The Chat tab as a destination becomes redundant once the panel travels with you.

## Scope

**In scope (macOS dashboard window only):**
- Remove Chat as a dashboard tab.
- Add a right-side chat drawer toggleable from every tab.
- Default tab becomes Dashboard.
- Per-tab context payload prepended to every chat message, server-side unchanged.
- Selection state (selected device/orch/task) lifted to `AppState` so the drawer can read it.

**Out of scope:**
- Chat history persistence (still in-memory).
- Multi-session chat or saved threads.
- Drawer left-side placement.
- iOS surface changes.
- Server protocol changes.

## Architecture

### Tabs

| Before | After |
|---|---|
| Chat → Dashboard → Devices → Orchs → Tasks → Settings | Dashboard → Devices → Orchs → Tasks → Settings |
| `AppState.activeTab` default = `.chat` | default = `.dashboard` |
| `AppState.Tab` includes `.chat` | `.chat` case **removed** |

The menu bar's "Open Chat" action used to send `appState.activeTab = .chat`. It is rewired to:
1. Bring the dashboard window forward (existing behavior).
2. Set `appState.isChatDrawerOpen = true`.

### Layout

`ContentView` body changes from a bare `TabView` to:

```
HStack(spacing: 0) {
    TabView(selection: $appState.activeTab) { … existing tabs … }
        .frame(maxWidth: .infinity)
    if appState.isChatDrawerOpen {
        ChatDrawerView()
            .frame(width: appState.chatDrawerWidth)
            .transition(.move(edge: .trailing))
    }
}
```

- Drawer width: `@AppStorage("chatDrawerWidth") var width: Double = 350`. Drag handle on the left edge resizes it; min 280, max 600.
- Toggle entry points: ⌘/ shortcut, toolbar button (message bubble icon) added to every tab's `.toolbar`, menu bar "Open Chat" action.
- First-launch default: drawer closed. State persisted across launches via `@AppStorage("chatDrawerOpen")`.
- Expand button inside drawer header opens a separate `NSWindow` hosting the existing `ChatTabView` at full size, sharing the same `ChatViewModel`.

**Why HStack and not NavigationSplitView:** Several tabs (e.g. `DeviceListView`) already host their own `NavigationSplitView`. Nesting a second one for the drawer renders awkwardly on macOS (double-divider artifacts, sidebar drag conflicts). Keeping the drawer at the outermost level avoids this.

### Context Injection

New file: `Hydra/Hydra/Services/ChatContextProvider.swift`.

```swift
@MainActor
enum ChatContextProvider {
    static func snapshot(
        for tab: AppState.Tab,
        dashboardVM: DashboardViewModel,
        selection: ContextSelection
    ) -> String?
}

struct ContextSelection {
    var device: Device?
    var orch: Orch?
    var task: NagaTask?
}
```

Returns `nil` for tabs with no useful context (`.settings`). For others, returns a one-line preamble in the form `[Context: <tab>. <summary>.]`.

`ChatViewModel.send(_:)` is modified to:

```swift
let context = ChatContextProvider.snapshot(for: …, …, selection: …)
let composed = context.map { "\($0)\n\n\(trimmed)" } ?? trimmed
// existing flow with `composed` substituted for `trimmed`
```

The composed string goes into the `ChatRequest.message` field. The server is unchanged — it sees the preamble as part of the user message and the model interprets it naturally.

**Per-tab payload shape:**

| Tab | Preamble |
|---|---|
| Dashboard | `Server v{ver} {status}. Devices {online}/{total} online{offline list if any}. Orchs {running} running{names}. {totalGPUs} GPUs, avg {util}%. Tasks {running} running, {total} total.` |
| Devices, no selection | `Devices tab. {online}/{total} devices online.` |
| Devices, selection | `Devices tab. Selected '{shortName}' ({tailscaleIp}, {os}{, GPU model ×count}{, online/offline}{, SSH on/off}).` |
| Orchs, no selection | `Orchs tab. {running} of {total} running.` |
| Orchs, selection | `Orchs tab. Selected '{name}' ({status}, mode={mode}, head={headShortName}, {workerCount} workers).` |
| Tasks | `Tasks tab. {running} running, {completed} completed. Latest: {latestType} on {latestDevice} {relativeTime} ({status}).` |
| Settings | `nil` |

Token budget: each preamble stays well under 100 tokens. With `serverHistoryCap = 20`, total per-request overhead is bounded.

### Selection State

`DeviceListView`, `OrchListView`, `TasksView` currently hold selection in local `@State`. Lifted to `AppState`:

```swift
@Published var selectedDeviceId: String?
@Published var selectedOrchId: String?
@Published var selectedTaskId: String?
```

The views convert these IDs to objects via lookups against `dashboardVM.devices` / `.orchs` / `.tasks`. `ChatContextProvider` reads the same `AppState` to know what's selected when composing context.

This generalizes the pattern we just used for the per-device ping cache (commit on `feature/chat-tab-relocation`): cross-cutting state lives on the shared model, not view-local `@State`.

### Menu Bar Surfaces

- `ChatSection` (menu bar popover): unchanged. It remains a passive status surface showing the latest chat result/plan from `ChatViewModel`.
- "Open Chat" menu item in the menu bar: behavior changes from "switch dashboard to Chat tab" to "open dashboard + open chat drawer."

### Files Touched

| File | Change |
|---|---|
| `State/AppState.swift` | remove `.chat` case; add `isChatDrawerOpen`, `chatDrawerWidth`, `selectedDeviceId`, `selectedOrchId`, `selectedTaskId`; default `activeTab = .dashboard` |
| `Views/ContentView.swift` | wrap `TabView` in `HStack` with `ChatDrawerView`; remove `ChatTabView` tab entry |
| `Views/Chat/ChatDrawerView.swift` | **new**; reuses `ChatTabView`'s subviews (`ChatTurnRow`, `PlanCardView`) |
| `Views/Chat/ChatTabView.swift` | kept, repurposed as the full-screen expanded mode hosted in a child `NSWindow` |
| `ViewModels/ChatViewModel.swift` | `send(_:contextPreamble:)` — new optional `String?` parameter; caller composes via `ChatContextProvider`. Keeps `ChatViewModel` free of `AppState` / `DashboardViewModel` dependencies. |
| `Services/ChatContextProvider.swift` | **new**; pure function module |
| `Views/Devices/DeviceListView.swift` | bind selection to `appState.selectedDeviceId` instead of local `@State` |
| `Views/Orchs/OrchListView.swift` | same pattern |
| `Views/Tasks/TasksView.swift` | same pattern |
| `HydraApp.swift` | menu bar "Open Chat" rewires to drawer open |
| `Views/MenuBar/*` | menu bar `ChatSection` itself **unchanged**; only the "Open Chat" wiring is updated |

## Data Flow

```
User types in ChatDrawerView
    → preamble = ChatContextProvider.snapshot(appState.activeTab,
                                              dashboardVM, selection)
    → ChatViewModel.send(message, contextPreamble: preamble)
        → preamble + "\n\n" + message → ChatRequest.message
        → APIClient.chat(req)
        → server (unchanged) returns plan or ask
    → drawer renders response
    → menu bar ChatSection reflects same state (shared VM)
```

## Error Handling

No new failure modes. Context composition is a pure function over already-loaded `dashboardVM` state — if the data isn't loaded yet, the preamble degrades to the tab name only (e.g. `"Devices tab."`).

If `ChatContextProvider.snapshot` returns `nil` (settings tab, or unsupported tab), `send` falls back to current behavior (no preamble).

## Testing

- Unit: `ChatContextProvider` snapshot rendering for each tab × selection combination. Pure function, easy to fixture.
- Manual: drawer toggle, resize, persistence across app restart, expand-to-window, ⌘/ shortcut, menu bar "Open Chat" routing.
- Visual regression: tab switching while drawer open should not flicker; selection in Devices tab persists when drawer is toggled.

## Open Risks

- **`AppState` growth.** Lifting selection IDs adds three published properties. Acceptable now; if `AppState` outgrows its file, split per-domain (e.g. `SelectionState`) later.
- **Token cost on long conversations.** Each request now carries a ~50-token preamble. With history cap of 20, marginal cost is small; we measure if anyone complains.
- **Expand window lifecycle.** A child `NSWindow` for the expand mode needs to handle close gracefully (drawer remains independent). Use `NSWindowDelegate` to nil out the reference on close.
