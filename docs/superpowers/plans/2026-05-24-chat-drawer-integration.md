# Chat-as-Drawer + Context-Aware AI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Chat dashboard tab with a right-side drawer toggleable from every operational tab, prepending active-tab + selection context to every chat request. macOS only. Server protocol unchanged.

**Architecture:** Drawer lives at the outermost layout level (HStack wrapping the TabView) to avoid nesting inside per-tab NavigationSplitViews. A pure `ChatContextProvider` composes a one-line preamble from active tab + lifted selection IDs in `AppState`. The drawer reuses `ChatViewModel` from app scope; the menu bar `ChatSection` is unchanged.

**Tech Stack:** SwiftUI (macOS 14+), Swift Concurrency, XCTest. No new dependencies.

**Spec:** [`docs/superpowers/specs/2026-05-24-chat-drawer-integration-design.md`](../specs/2026-05-24-chat-drawer-integration-design.md)

---

### Task 1: AppState foundation — drawer state + selection IDs + tab default

**Files:**
- Modify: `Hydra/Hydra/State/AppState.swift`

- [ ] **Step 1: Read current AppState**

Run: `cat Hydra/Hydra/State/AppState.swift`
Expected current contents:
```swift
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

- [ ] **Step 2: Rewrite AppState.swift**

Replace entire file with:
```swift
import Foundation

/// App-scope UI state shared by the menubar and the dashboard window.
/// Promoted out of view-local `@StateObject` so cross-surface signals
/// (menubar → drawer open, selection → chat context) stay in one place.
@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable {
        case dashboard
        case devices
        case orchs
        case tasks
        case settings
    }

    @Published var activeTab: Tab = .dashboard

    // Right-side chat drawer. Persisted across launches.
    @Published var isChatDrawerOpen: Bool = UserDefaults.standard.bool(forKey: "chatDrawerOpen") {
        didSet { UserDefaults.standard.set(isChatDrawerOpen, forKey: "chatDrawerOpen") }
    }
    @Published var chatDrawerWidth: Double = max(280, UserDefaults.standard.double(forKey: "chatDrawerWidth").nonZeroOr(350)) {
        didSet { UserDefaults.standard.set(chatDrawerWidth, forKey: "chatDrawerWidth") }
    }

    // Per-tab selection lifted from view-local @State so ChatContextProvider
    // can compose context without reaching into each view's internals.
    @Published var selectedDeviceId: String?
    @Published var selectedOrchId: String?
    @Published var selectedTaskId: UUID?
}

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double { self == 0 ? fallback : self }
}
```

> **Why `UUID` for `selectedTaskId`:** `SavedTask.id` in `SavedTaskStore` is a `UUID`. Devices/orchs use `String` IDs.

- [ ] **Step 3: Build to verify compile (expect errors elsewhere)**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "error:" | head -10`
Expected: errors in `ContentView.swift`, `MenuBarView.swift`, `ChatTabView.swift` referencing removed `.chat` case. These get fixed in Tasks 4–9.

- [ ] **Step 4: Commit**

```bash
git add Hydra/Hydra/State/AppState.swift
git commit -m "$(cat <<'EOF'
feat(agent): AppState drawer + selection foundation

Drops the .chat tab case in favor of .dashboard default and adds
drawer open/width state plus per-tab selection IDs that ChatContextProvider
can read when composing the per-request preamble. Subsequent tasks wire
up the references that this break.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: ChatContextProvider — pure module + TDD

**Files:**
- Create: `Hydra/Hydra/Services/ChatContextProvider.swift`
- Create: `Hydra/Tests/HydraTests/ChatContextProviderTests.swift`

- [ ] **Step 1: Write the failing tests first**

Create `Hydra/Tests/HydraTests/ChatContextProviderTests.swift`:
```swift
import XCTest
@testable import Hydra

@MainActor
final class ChatContextProviderTests: XCTestCase {

    private func makeVM(
        devices: [Device] = [],
        orchs: [Orch] = [],
        tasks: [NagaTask] = [],
        serverStatus: DashboardViewModel.ServerStatus = .connected,
        version: String = "1.2.3"
    ) -> DashboardViewModel {
        let vm = DashboardViewModel()
        vm.devices = devices
        vm.orchs = orchs
        vm.tasks = tasks
        vm.serverStatus = serverStatus
        vm.serverVersion = version
        return vm
    }

    func testSettingsTabReturnsNil() {
        let snap = ChatContextProvider.snapshot(
            for: .settings,
            dashboardVM: makeVM(),
            selection: .init()
        )
        XCTAssertNil(snap)
    }

    func testDashboardWithNoData() {
        let snap = ChatContextProvider.snapshot(
            for: .dashboard,
            dashboardVM: makeVM(),
            selection: .init()
        )
        XCTAssertNotNil(snap)
        XCTAssertTrue(snap!.hasPrefix("[Context: Dashboard."))
        XCTAssertTrue(snap!.contains("0/0 online"))
    }

    func testDevicesTabNoSelection() {
        let online = Device.fixture(id: "a", hostname: "h1", isOnline: true)
        let offline = Device.fixture(id: "b", hostname: "h2", isOnline: false)
        let snap = ChatContextProvider.snapshot(
            for: .devices,
            dashboardVM: makeVM(devices: [online, offline]),
            selection: .init()
        )
        XCTAssertEqual(snap, "[Context: Devices tab. 1/2 devices online.]")
    }

    func testDevicesTabWithSelection() {
        let dev = Device.fixture(id: "a", hostname: "home-mac", isOnline: true)
        let snap = ChatContextProvider.snapshot(
            for: .devices,
            dashboardVM: makeVM(devices: [dev]),
            selection: .init(device: dev)
        )
        XCTAssertNotNil(snap)
        XCTAssertTrue(snap!.contains("Selected 'home-mac'"))
        XCTAssertTrue(snap!.contains("online"))
    }
}
```

> **Note:** `Device.fixture(...)` doesn't exist yet — Step 2 adds it.

- [ ] **Step 2: Add a test fixture helper for Device**

Append to `Hydra/Tests/HydraTests/ChatContextProviderTests.swift`:
```swift
extension Device {
    /// `Device` is a struct with `let` stored properties and uses the
    /// synthesized memberwise initializer. This helper supplies sane
    /// defaults for the fields ChatContextProvider doesn't read, so
    /// tests only have to specify what matters to them.
    static func fixture(
        id: String,
        hostname: String = "host",
        name: String = "",
        isOnline: Bool = true,
        tailscaleIp: String = "100.0.0.1",
        os: String = "macOS",
        sshEnabled: Bool = true,
        hasGpu: Bool = false,
        gpuModel: String? = nil,
        gpuCount: Int = 0
    ) -> Device {
        Device(
            id: id,
            name: name,
            hostname: hostname,
            ipAddresses: [tailscaleIp],
            tailscaleIp: tailscaleIp,
            os: os,
            status: isOnline ? "online" : "offline",
            isExternal: false,
            tags: nil,
            user: "u",
            lastSeen: Date(),
            sshEnabled: sshEnabled,
            hasGpu: hasGpu,
            gpuModel: gpuModel,
            gpuCount: gpuCount
        )
    }
}
```

> Source of truth: `Hydra/Hydra/Models/Device.swift` defines a struct with `let` properties — the synthesized memberwise init is used here directly. If the model gains/loses fields later, the fixture compile-breaks and the failure is local to this file.

- [ ] **Step 3: Run tests to confirm they fail to compile**

Run: `cd Hydra && swift test --filter ChatContextProviderTests 2>&1 | tail -20`
Expected: compile error `cannot find 'ChatContextProvider' in scope`.

- [ ] **Step 4: Write ChatContextProvider**

Create `Hydra/Hydra/Services/ChatContextProvider.swift`:
```swift
import Foundation

/// Composes the per-request context preamble that prepends every chat
/// message. The server treats the preamble as part of the user message
/// — no server-side change required.
@MainActor
enum ChatContextProvider {

    struct Selection {
        var device: Device?
        var orch: Orch?
        var task: SavedTask?
    }

    static func snapshot(
        for tab: AppState.Tab,
        dashboardVM: DashboardViewModel,
        selection: Selection
    ) -> String? {
        let body: String
        switch tab {
        case .settings:
            return nil
        case .dashboard:
            body = dashboardBody(dashboardVM)
        case .devices:
            body = devicesBody(dashboardVM, selected: selection.device)
        case .orchs:
            body = orchsBody(dashboardVM, selected: selection.orch)
        case .tasks:
            body = tasksBody(dashboardVM, selected: selection.task)
        }
        return "[Context: \(body)]"
    }

    // MARK: - Per-tab composers

    private static func dashboardBody(_ vm: DashboardViewModel) -> String {
        var parts: [String] = ["Dashboard."]
        let statusWord: String = {
            switch vm.serverStatus {
            case .connected: return "connected"
            case .disconnected: return "disconnected"
            case .unknown: return "unknown"
            }
        }()
        if !vm.serverVersion.isEmpty {
            parts.append("Server v\(vm.serverVersion) \(statusWord).")
        } else {
            parts.append("Server \(statusWord).")
        }
        parts.append("Devices \(vm.onlineDevices.count)/\(vm.devices.count) online.")
        if !vm.offlineDevices.isEmpty {
            let names = vm.offlineDevices.prefix(3).map(\.shortName).joined(separator: ", ")
            parts.append("Offline: \(names).")
        }
        if !vm.runningOrchs.isEmpty {
            let names = vm.runningOrchs.prefix(3).map(\.name).joined(separator: ", ")
            parts.append("Orchs running: \(names).")
        }
        if vm.totalGPUs > 0 {
            parts.append("\(vm.totalGPUs) GPUs avg \(Int(vm.avgGPUUtilization))% util.")
        }
        if !vm.tasks.isEmpty {
            parts.append("Tasks: \(vm.runningTasks.count) running, \(vm.tasks.count) total.")
        }
        return parts.joined(separator: " ")
    }

    private static func devicesBody(_ vm: DashboardViewModel, selected: Device?) -> String {
        guard let d = selected else {
            return "Devices tab. \(vm.onlineDevices.count)/\(vm.devices.count) devices online."
        }
        var attrs: [String] = [d.tailscaleIp, d.os]
        if d.hasGpu, let model = d.gpuModel {
            attrs.append("\(d.gpuCount)× \(model)")
        }
        attrs.append(d.isOnline ? "online" : "offline")
        attrs.append("SSH \(d.sshEnabled ? "on" : "off")")
        return "Devices tab. Selected '\(d.shortName)' (\(attrs.joined(separator: ", "))). \(vm.devices.count - 1) other devices visible."
    }

    private static func orchsBody(_ vm: DashboardViewModel, selected: Orch?) -> String {
        guard let o = selected else {
            return "Orchs tab. \(vm.runningOrchs.count) of \(vm.orchs.count) running."
        }
        let head = vm.devices.first { $0.id == o.coordinatorId }?.shortName ?? String(o.coordinatorId.prefix(8))
        let status = o.isRunning ? "running" : "stopped"
        return "Orchs tab. Selected '\(o.name)' (\(status), mode=\(o.mode), head=\(head), \(o.workerCount) workers)."
    }

    private static func tasksBody(_ vm: DashboardViewModel, selected: SavedTask?) -> String {
        let store = SavedTaskStore.shared
        let savedCount = store.tasks.count
        let runningCount = store.runningTaskIds.count
        guard let t = selected else {
            return "Tasks tab. \(savedCount) saved tasks, \(runningCount) running."
        }
        let cmdPreview = t.command.prefix(60)
        let target: String = {
            if t.deviceIds.isEmpty { return "no target" }
            let names = t.deviceIds.prefix(3).compactMap { id in
                vm.devices.first { $0.id == id }?.shortName
            }.joined(separator: ", ")
            return "target: \(names)"
        }()
        return "Tasks tab. Selected '\(t.name)' (\(target)). Command: \(cmdPreview)."
    }
}
```

- [ ] **Step 5: Run tests — expect them to pass**

Run: `cd Hydra && swift test --filter ChatContextProviderTests 2>&1 | tail -20`
Expected: all 4 tests pass.

> If the `Device.fixture` helper compile-fails on missing fields, open `Hydra/Hydra/Models/Device.swift`, copy the actual init signature, and adapt the fixture in `ChatContextProviderTests.swift` accordingly. Do the same for the `SavedTask`/`Orch`/`NagaTask` fixtures when extending tests later.

- [ ] **Step 6: Commit**

```bash
git add Hydra/Hydra/Services/ChatContextProvider.swift \
        Hydra/Tests/HydraTests/ChatContextProviderTests.swift
git commit -m "$(cat <<'EOF'
feat(agent): ChatContextProvider — per-tab preamble composer

Pure module that turns active tab + selection into a one-line preamble
prepended to each chat request. Server is unchanged; preamble travels
inside ChatRequest.message and the model interprets it as user context.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: ChatViewModel — accept optional contextPreamble

**Files:**
- Modify: `Hydra/Hydra/ViewModels/ChatViewModel.swift`

- [ ] **Step 1: Update `send` signature**

Open `Hydra/Hydra/ViewModels/ChatViewModel.swift` and replace the existing `send(_:)` with:

```swift
func send(_ message: String, contextPreamble: String? = nil) async {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    turns.append(ChatTurn(role: "user", content: trimmed, plan: nil, results: nil))
    isThinking = true
    error = nil
    defer { isThinking = false }
    let history = Array(turns.suffix(serverHistoryCap))
    // Preamble is composed by the caller from active tab + selection;
    // we attach it only to the outbound message, never to the on-screen
    // turn text — the user shouldn't see their own boilerplate echoed.
    let outbound: String
    if let preamble = contextPreamble, !preamble.isEmpty {
        outbound = "\(preamble)\n\n\(trimmed)"
    } else {
        outbound = trimmed
    }
    let req = ChatRequest(history: history, message: outbound)
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
```

- [ ] **Step 2: Build to verify no regressions**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "(error|warning):" | grep ChatViewModel | head -5`
Expected: no output (no errors specific to ChatViewModel).

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/ViewModels/ChatViewModel.swift
git commit -m "$(cat <<'EOF'
feat(agent): ChatViewModel.send accepts optional contextPreamble

Caller composes the preamble (via ChatContextProvider). The on-screen
user turn stays clean — only the outbound request body carries the
preamble so the model sees current tab/selection context.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: ChatDrawerView — new narrow chat surface

**Files:**
- Create: `Hydra/Hydra/Views/Chat/ChatDrawerView.swift`

- [ ] **Step 1: Create ChatDrawerView**

Create `Hydra/Hydra/Views/Chat/ChatDrawerView.swift`:
```swift
import SwiftUI

/// Right-side chat drawer hosted by ContentView. Reuses the app-scope
/// ChatViewModel so the menubar's passive ChatSection reflects the same
/// state. The drawer composes a context preamble via ChatContextProvider
/// at send time, scoped to whichever tab/selection is active.
struct ChatDrawerView: View {
    @EnvironmentObject var vm: ChatViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesArea
            Divider()
            inputBar
        }
        .frame(maxHeight: .infinity)
        .background(.background)
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            Text("Chat")
                .font(.headline)
            Spacer()
            Button {
                openWindow(id: "chat-expanded")
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Expand to full window")
            Button {
                appState.isChatDrawerOpen = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close drawer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var messagesArea: some View {
        Group {
            if vm.turns.isEmpty && vm.pendingPlan == nil {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(vm.turns) { turn in
                                DrawerTurnRow(turn: turn).id(turn.id)
                            }
                            if let plan = vm.pendingPlan {
                                PlanCardView(
                                    plan: plan,
                                    message: vm.pendingPlanMessage,
                                    isThinking: vm.isThinking,
                                    compact: true,
                                    onRun:    { Task { await vm.runPendingPlan() } },
                                    onCancel: { vm.cancelPendingPlan() }
                                ).id("pendingPlan")
                            }
                            if let err = vm.error {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: vm.turns.count) { _, _ in
                        if let last = vm.turns.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Ask Hydra")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Active tab is auto-included as context.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Ask…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { submit() }
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.isThinking)
            if vm.isThinking { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func submit() {
        let msg = draft
        draft = ""
        let preamble = ChatContextProvider.snapshot(
            for: appState.activeTab,
            dashboardVM: dashboardVM,
            selection: currentSelection()
        )
        Task { await vm.send(msg, contextPreamble: preamble) }
    }

    private func currentSelection() -> ChatContextProvider.Selection {
        ChatContextProvider.Selection(
            device: appState.selectedDeviceId.flatMap { id in
                dashboardVM.devices.first { $0.id == id }
            },
            orch: appState.selectedOrchId.flatMap { id in
                dashboardVM.orchs.first { $0.id == id }
            },
            task: appState.selectedTaskId.flatMap { id in
                SavedTaskStore.shared.tasks.first { $0.id == id }
            }
        )
    }
}

/// Narrow-width row variant. Same content as ChatTabView's row but
/// stacked vertically so the role badge doesn't steal width from the
/// message text in a 350-px drawer.
private struct DrawerTurnRow: View {
    let turn: ChatTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(roleLabel)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(turn.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout)
        }
    }
    private var roleLabel: String {
        switch turn.role {
        case "user":            return "YOU"
        case "assistant_ask":   return "ASK"
        case "assistant_plan":  return "PLAN"
        case "system_result":   return "RESULT"
        default:                return turn.role.uppercased()
        }
    }
}
```

- [ ] **Step 2: Build to verify ChatDrawerView compiles**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "error:" | grep -i "chatdrawer\|ChatDrawer" | head -5`
Expected: no errors (ContentView errors from Task 1 still exist but unrelated).

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Views/Chat/ChatDrawerView.swift
git commit -m "$(cat <<'EOF'
feat(agent): ChatDrawerView — narrow chat surface for the dashboard

Reuses the app-scope ChatViewModel + PlanCardView. Composes context via
ChatContextProvider at send time. Includes header with expand-window
and close affordances, stacked turn rows tailored for ~350px width.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: ContentView restructure — HStack + drawer + Chat tab removal

**Files:**
- Modify: `Hydra/Hydra/Views/ContentView.swift`

- [ ] **Step 1: Replace ContentView body**

Open `Hydra/Hydra/Views/ContentView.swift` and replace entire file with:

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            TabView(selection: $appState.activeTab) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if appState.isChatDrawerOpen {
                DrawerResizeHandle(width: $appState.chatDrawerWidth)
                ChatDrawerView()
                    .frame(width: appState.chatDrawerWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appState.isChatDrawerOpen)
        .task {
            await dashboardVM.load()
        }
    }
}

/// 4-px wide vertical drag handle between the TabView and the drawer.
/// Constrains drawer width to [280, 600].
private struct DrawerResizeHandle: View {
    @Binding var width: Double

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.001))   // invisible but hit-testable
            .frame(width: 4)
            .overlay(Divider())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let next = width - value.translation.width
                        width = min(max(next, 280), 600)
                    }
            )
    }
}
```

- [ ] **Step 2: Build to verify ContentView compiles**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "error:" | head -10`
Expected: only MenuBarView.swift and ChatTabView.swift errors referencing `.chat` remain.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Views/ContentView.swift
git commit -m "$(cat <<'EOF'
feat(agent): ContentView wraps TabView in HStack + drawer

Removes the Chat tab entry. Defaults to Dashboard. Adds an HStack-level
right-side drawer with a 4-px drag handle that resizes between 280–600
px, persisted to AppStorage via AppState.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Lift Device selection to AppState

**Files:**
- Modify: `Hydra/Hydra/Views/Devices/DeviceListView.swift`

- [ ] **Step 1: Update DeviceListView to bind selection through AppState**

In `Hydra/Hydra/Views/Devices/DeviceListView.swift`, find the existing struct header:

```swift
struct DeviceListView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @ObservedObject private var prefs = DevicePreferences.shared
    @State private var selectedDevice: Device?
```

Replace with:

```swift
struct DeviceListView: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @EnvironmentObject var appState: AppState
    @ObservedObject private var prefs = DevicePreferences.shared

    private var selectedDevice: Binding<Device?> {
        Binding(
            get: { appState.selectedDeviceId.flatMap { id in
                dashboardVM.devices.first { $0.id == id }
            }},
            set: { appState.selectedDeviceId = $0?.id }
        )
    }
```

- [ ] **Step 2: Update the List's selection binding**

Find the line in the same file:

```swift
List(filteredDevices, selection: $selectedDevice) { device in
```

Change to (drop the `$` since `selectedDevice` is now a computed `Binding`, and pass it directly):

```swift
List(filteredDevices, selection: selectedDevice) { device in
```

Find the detail section:

```swift
} detail: {
    if let device = selectedDevice {
        DeviceDetailView(device: device)
```

Change to:

```swift
} detail: {
    if let device = selectedDevice.wrappedValue {
        DeviceDetailView(device: device)
```

- [ ] **Step 3: Build to verify**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "error:" | grep DeviceListView | head -5`
Expected: no errors specific to DeviceListView.

- [ ] **Step 4: Commit**

```bash
git add Hydra/Hydra/Views/Devices/DeviceListView.swift
git commit -m "$(cat <<'EOF'
refactor(devices): lift selection to AppState

Selection now lives on the shared AppState so ChatContextProvider can
read the currently-focused device when composing the per-request
context preamble.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Lift Orch selection to AppState

**Files:**
- Modify: `Hydra/Hydra/Views/Orchs/OrchListView.swift`

- [ ] **Step 1: Update OrchListView**

In `Hydra/Hydra/Views/Orchs/OrchListView.swift`, replace:

```swift
struct OrchListView: View {
    @StateObject private var vm = OrchViewModel()
    @State private var selectedOrch: Orch?
    @State private var command = ""
```

With:

```swift
struct OrchListView: View {
    @StateObject private var vm = OrchViewModel()
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @State private var command = ""

    private var selectedOrch: Binding<Orch?> {
        Binding(
            get: { appState.selectedOrchId.flatMap { id in
                vm.orchs.first { $0.id == id } ?? dashboardVM.orchs.first { $0.id == id }
            }},
            set: { appState.selectedOrchId = $0?.id }
        )
    }
```

Update the `List(...)` line in the same file:

```swift
List(vm.orchs, selection: $selectedOrch) { orch in
```

becomes:

```swift
List(vm.orchs, selection: selectedOrch) { orch in
```

Update `onChange(of: selectedOrch)`:

```swift
.onChange(of: selectedOrch) { _, newValue in
    if let orch = newValue {
        Task { await vm.selectOrch(orch) }
    }
}
```

becomes:

```swift
.onChange(of: selectedOrch.wrappedValue) { _, newValue in
    if let orch = newValue {
        Task { await vm.selectOrch(orch) }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "error:" | grep OrchListView | head -5`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Views/Orchs/OrchListView.swift
git commit -m "$(cat <<'EOF'
refactor(orchs): lift selection to AppState

Selection now lives on the shared AppState so the chat drawer's
ChatContextProvider can report the currently-focused orchestration.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Lift Task selection to AppState

**Files:**
- Modify: `Hydra/Hydra/Views/Tasks/TasksView.swift`

- [ ] **Step 1: Update TasksView**

In `Hydra/Hydra/Views/Tasks/TasksView.swift`, replace:

```swift
struct TasksView: View {
    @ObservedObject private var store = SavedTaskStore.shared
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @State private var showingEditor = false
    @State private var editingTask: SavedTask?
    @State private var selectedTask: SavedTask?
```

With:

```swift
struct TasksView: View {
    @ObservedObject private var store = SavedTaskStore.shared
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @EnvironmentObject var appState: AppState
    @State private var showingEditor = false
    @State private var editingTask: SavedTask?

    private var selectedTask: Binding<SavedTask?> {
        Binding(
            get: { appState.selectedTaskId.flatMap { id in
                store.tasks.first { $0.id == id }
            }},
            set: { appState.selectedTaskId = $0?.id }
        )
    }
```

In the same file, change:

```swift
List(store.tasks, selection: $selectedTask) { task in
```

to:

```swift
List(store.tasks, selection: selectedTask) { task in
```

And the detail section:

```swift
} detail: {
    if let task = selectedTask {
        TaskDetailView(task: task, store: store, devices: dashboardVM.onlineDevices)
```

to:

```swift
} detail: {
    if let task = selectedTask.wrappedValue {
        TaskDetailView(task: task, store: store, devices: dashboardVM.onlineDevices)
```

- [ ] **Step 2: Build**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "error:" | grep TasksView | head -5`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Hydra/Hydra/Views/Tasks/TasksView.swift
git commit -m "$(cat <<'EOF'
refactor(tasks): lift selection to AppState

Selection now lives on the shared AppState. ChatContextProvider reads
the selected SavedTask when composing Tasks-tab context.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Rewire menubar "Open Chat" + remove stale .chat reference in ChatTabView

**Files:**
- Modify: `Hydra/Hydra/Views/MenuBar/MenuBarView.swift`
- Modify: `Hydra/Hydra/Views/Chat/ChatTabView.swift`

- [ ] **Step 1: Update MenuBarView.openChat**

In `Hydra/Hydra/Views/MenuBar/MenuBarView.swift`, find:

```swift
private func openChat() {
    appState.activeTab = .chat
    openDashboardWindow()
}
```

Replace with:

```swift
private func openChat() {
    appState.isChatDrawerOpen = true
    openDashboardWindow()
}
```

- [ ] **Step 2: Update ChatTabView's onChange — chat tab no longer exists**

In `Hydra/Hydra/Views/Chat/ChatTabView.swift`, find:

```swift
.onChange(of: appState.activeTab) { _, tab in
    if tab == .chat { inputFocused = true }
}
```

Remove the entire `.onChange(of: appState.activeTab) { ... }` modifier — the focus handling will now happen via the expand-window's `.onAppear` set in Task 10. The remaining `.onAppear { inputFocused = true }` already covers initial focus.

- [ ] **Step 3: Update ChatSection comment referencing "Chat tab"**

In `Hydra/Hydra/Views/MenuBar/ChatSection.swift`, find this doc comment near the top (line 5):

```swift
/// the dashboard's Chat tab; the "Open Chat →" button routes there.
```

Replace with:

```swift
/// the dashboard's chat drawer; the "Open Chat →" button opens it.
```

- [ ] **Step 4: Build — should now compile cleanly**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "error:" | head -10`
Expected: no errors.

- [ ] **Step 5: Run all tests**

Run: `cd Hydra && swift test 2>&1 | tail -20`
Expected: all tests pass (including new ChatContextProviderTests).

- [ ] **Step 6: Commit**

```bash
git add Hydra/Hydra/Views/MenuBar/MenuBarView.swift \
        Hydra/Hydra/Views/Chat/ChatTabView.swift \
        Hydra/Hydra/Views/MenuBar/ChatSection.swift
git commit -m "$(cat <<'EOF'
feat(agent): menubar Open Chat opens the drawer

Replaces the legacy 'switch to Chat tab' wiring with toggling
appState.isChatDrawerOpen. ChatTabView drops its now-dead activeTab
listener (chat is no longer a tab).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Expand-to-window — second WindowGroup hosting ChatTabView

**Files:**
- Modify: `Hydra/Hydra/HydraApp.swift`

- [ ] **Step 1: Add the expanded chat window scene**

In `Hydra/Hydra/HydraApp.swift`, find the existing `WindowGroup(id: "dashboard") { ... }` Scene and add a second `WindowGroup` immediately after it, before `Settings { ... }`:

```swift
WindowGroup(id: "chat-expanded") {
    ChatTabView()
        .environmentObject(dashboardVM)
        .environmentObject(chatVM)
        .environmentObject(appState)
        .frame(minWidth: 600, minHeight: 500)
}
.defaultSize(width: 720, height: 600)
```

- [ ] **Step 2: Add ⌘/ keyboard shortcut to toggle the drawer**

In the same file, find the existing `.commands { CommandMenu("Edit") { ... } }` block. Add a new CommandMenu after the Edit one (still inside `.commands`):

```swift
CommandMenu("Chat") {
    Button("Toggle Chat Drawer") {
        appState.isChatDrawerOpen.toggle()
    }
    .keyboardShortcut("/", modifiers: .command)
}
```

> The expand-to-window action lives in the drawer header (Task 4) where `@Environment(\.openWindow)` is available. We don't mirror it in the menu — adding a menu entry for it would require either a private selector or a global window-opener, both of which would be carrying weight just to populate a menu the user already has the affordance for.

- [ ] **Step 3: Build**

Run: `cd Hydra && swift build -c debug 2>&1 | grep -E "error:" | head -5`
Expected: no errors.

- [ ] **Step 4: Run all tests**

Run: `cd Hydra && swift test 2>&1 | tail -10`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Hydra/Hydra/HydraApp.swift
git commit -m "$(cat <<'EOF'
feat(agent): expand-to-window + ⌘/ drawer toggle

Adds a second WindowGroup hosting ChatTabView for the full-screen
expanded chat view (opened from the drawer's expand button via
openWindow). ⌘/ toggles the drawer from the main menu.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: End-to-end build + manual verification

**Files:** none

- [ ] **Step 1: Clean build via project Makefile**

Run: `make hydra-app 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` or `[7/7] done`.

- [ ] **Step 2: Kill any running Hydra**

Run:
```bash
pgrep -f "/Hydra.app/Contents/MacOS/Hydra" | xargs -I{} kill {} 2>/dev/null; sleep 1
```

- [ ] **Step 3: Launch the new build**

Run: `make hydra-app-run 2>&1 | tail -3`
Expected: launches without error; `pgrep -lf "/Hydra.app/Contents/MacOS/Hydra"` shows a fresh PID.

- [ ] **Step 4: Manual checklist (perform via the GUI)**

Open the dashboard window and verify:

- Default tab is **Dashboard** (not Chat).
- The Chat tab is **gone** from the tab bar.
- ⌘/ opens the chat drawer on the right. Press again to close.
- The drawer's close (X) button works.
- Drag the drawer's left edge — width changes smoothly between 280–600 px. Close and reopen the app: the width persists.
- Open the drawer and send a message like "what tab am I on?" while on **Devices** → response should reflect Devices context. Switch to **Orchs**, send "what about now?" → response should reflect Orchs context.
- Select a device, send "summarize this device" → response should reference that specific device by name.
- Click the drawer's expand (↗) button → a separate window opens with `ChatTabView` at full size and shares the same conversation.
- Menu bar icon → click "Open Chat" → dashboard window comes forward AND the drawer opens.

- [ ] **Step 5: If any checklist item fails**

Stop. Report exactly which item failed and what was observed (e.g. "drawer width does not persist after relaunch — width reverts to 350"). Do not patch over the symptom in this plan — open a follow-up fix once the root cause is identified via systematic-debugging.

- [ ] **Step 6: No final commit needed**

Tasks 1–10 already shipped the working surface. If the manual checklist surfaces a small polish item that is in-scope and unambiguous (e.g. a typo in a label), commit it as a discrete `style:` commit; otherwise close out the plan.

---

## What's intentionally NOT in this plan (YAGNI)

- Chat history persistence across launches — still in-memory.
- Per-tab chat threads.
- Drawer left-side placement.
- Multi-session chat.
- iOS surface changes.
- Server protocol changes (preamble travels inside `ChatRequest.message`).
- Resizable expanded window beyond `defaultSize` (uses the SwiftUI default behavior).

## Coverage check against spec

- §Tabs default + remove `.chat` case: **Task 1**.
- §Layout HStack + drawer + resize: **Tasks 1, 5**.
- §Context injection per tab: **Task 2** (provider) + **Task 4** (drawer call site).
- §Selection state lifting: **Tasks 6, 7, 8**.
- §Menu bar Open Chat rewire: **Task 9**.
- §Keyboard shortcut ⌘/: **Task 10**.
- §Expand window: **Task 10**.
- §Files Touched in spec: all listed files have a corresponding task above.
- §Open Risks → AppState growth: documented; split deferred.
- §Open Risks → expand window lifecycle: Task 10 uses SwiftUI's `WindowGroup` so SwiftUI manages the window lifecycle natively.

### Spec/plan deltas (intentional)

Reality of the codebase forced two type corrections from the spec:

- Tasks tab uses `SavedTask` (from `SavedTaskStore`), not `NagaTask` (which is the runtime task model surfaced on the Dashboard). `ChatContextProvider.Selection.task` is `SavedTask?` and `AppState.selectedTaskId` is `UUID?` (matching `SavedTask.id`). The Dashboard preamble still reports `NagaTask` runtime counts via `dashboardVM.tasks` — so both task surfaces are represented, just from their respective views.
- Spec said `selectedTaskId: String?`; plan uses `UUID?` to match the actual type.
