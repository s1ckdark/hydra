import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var appState: AppState
    @StateObject private var gpuVM = GPUMonitorViewModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GPU Orch Manager")
                .font(.headline)

            Divider()

            // GPU Summary
            HStack {
                Image(systemName: "gpu")
                    .foregroundStyle(.purple)
                Text(gpuVM.summaryText)
                    .font(.system(.caption, design: .monospaced))
            }

            // Per-node GPU status
            if !gpuVM.nodes.isEmpty {
                ForEach(gpuVM.nodes) { node in
                    if let gpus = node.gpus, !gpus.isEmpty {
                        ForEach(gpus) { gpu in
                            VStack(alignment: .leading, spacing: 2) {
                                // Line 1: node name
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(utilizationColor(gpu.utilizationPercent))
                                        .frame(width: 6, height: 6)
                                    Text(node.deviceName.components(separatedBy: ".").first ?? node.deviceName)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    if let staleAt = gpuVM.staleSince[node.deviceId] {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                        Text(staleAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                // Line 2: bar + stats
                                HStack(spacing: 6) {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: theme.chipRadius)
                                                .fill(.quaternary)
                                            RoundedRectangle(cornerRadius: theme.chipRadius)
                                                .fill(utilizationColor(gpu.utilizationPercent))
                                                .frame(width: geo.size.width * gpu.utilizationPercent / 100)
                                        }
                                    }
                                    .frame(height: 6)

                                    Text(String(format: "%.0f%%", gpu.utilizationPercent))
                                        .font(.system(.caption2, design: .monospaced))
                                        .frame(width: 30, alignment: .trailing)
                                    Text("\(gpu.memoryUsedMB/1024)G/\(gpu.memoryTotalMB/1024)G")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 52, alignment: .trailing)
                                    Text("\(gpu.temperatureC)°C")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(tempColor(gpu.temperatureC))
                                        .frame(width: 30, alignment: .trailing)
                                }
                                .padding(.leading, 10)
                            }
                            .padding(.vertical, 1)
                        }
                    } else if node.hasError {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                                    .font(.caption2)
                                Text(node.deviceName.components(separatedBy: ".").first ?? node.deviceName)
                                    .font(.caption)
                            }
                            Text("connection error")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .padding(.leading, 10)
                        }
                    }
                }
            }

            Divider()

            ChatSection(onOpenChat: openChat)

            Divider()

            HStack {
                Image(systemName: "desktopcomputer")
                Text("\(vm.onlineDevices.count)/\(vm.devices.count) online")
                    .font(.caption)
            }

            HStack {
                Image(systemName: "server.rack")
                Text("\(vm.orchs.count) orchs")
                    .font(.caption)
            }

            if let lastUpdate = gpuVM.lastUpdate {
                Text("Updated: \(lastUpdate.formatted(.dateTime.hour().minute().second()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open Dashboard") {
                openDashboardWindow()
            }

            Button("Refresh Now") {
                Task {
                    await vm.load(force: true)
                    await gpuVM.refresh()
                }
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 420)
        .onAppear {
            Task { await vm.load() }
            gpuVM.startPolling(interval: 10)
        }
        .onDisappear {
            gpuVM.stopPolling()
        }
    }

    /// Surfaces the dashboard window from the menu-bar popover. The previous
    /// implementation called `openWindow(id:)` synchronously from inside the
    /// `MenuBarExtra` Button action; on macOS 14 that combination silently
    /// no-ops in the closed-window case (the popover scene's openWindow proxy
    /// can't reliably reach a sibling `WindowGroup`). We instead defer the
    /// work onto the next runloop tick so the popover dismissal completes
    /// first, then prefer reusing any live AppKit window we can see directly,
    /// and finally fall through to `openWindow` for the cold-start case —
    /// followed by a second async tick to force focus on the just-created
    /// window since SwiftUI doesn't reliably activate it from this context.
    private func openDashboardWindow() {
        // Set policy synchronously here, before any Task — calling it from
        // inside a Task races macOS internals on some Sonoma builds and
        // silently no-ops.
        NSApp.setActivationPolicy(.regular)
        print("[menubar] open dashboard: policy \(NSApp.activationPolicy().rawValue)")

        Task { @MainActor in
            // Yield so the popover finishes dismissing — activation events
            // fired during dismissal are sometimes dropped.
            try? await Task.sleep(for: .milliseconds(50))

            // Activate via NSWorkspace.openApplication on our own bundle.
            // This routes through the same OS code path as user double-
            // clicking the .app in Finder — explicitly designed to launch
            // OR activate (config.activates = true) and not subject to
            // the focus-stealing-prevention policy that blocks
            // NSApp.activate / NSRunningApplication.activate when called
            // from a non-foreground (menu-bar popover) context on
            // Sonoma+.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: config) { app, error in
                if let error = error {
                    print("[menubar] NSWorkspace.openApplication error: \(error)")
                } else if let app = app {
                    print("[menubar] activated pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "?")")
                }
            }

            // Belt-and-suspenders: also call AppKit-side activation in
            // case the workspace call is async and the next steps need
            // the app to already be foreground.
            NSRunningApplication.current.activate()
            NSApp.activate()

            let candidates = NSApp.windows.filter {
                $0.canBecomeKey && !($0 is NSPanel)
            }
            print("[menubar] candidate windows: \(candidates.map { "\($0.title)/\($0.identifier?.rawValue ?? "nil")" })")

            if let existing = candidates.first {
                if existing.isMiniaturized { existing.deminiaturize(nil) }
                existing.collectionBehavior.insert(.canJoinAllSpaces)
                existing.orderFrontRegardless()
                existing.makeKeyAndOrderFront(nil)
                return
            }

            // No live window — ask SwiftUI to materialise one, then surface
            // whatever appears on the next tick.
            openWindow(id: "dashboard")
            try? await Task.sleep(for: .milliseconds(150))
            let next = NSApp.windows.filter {
                $0.canBecomeKey && !($0 is NSPanel)
            }
            print("[menubar] candidate windows after openWindow: \(next.map { $0.title })")
            for window in next {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.collectionBehavior.insert(.canJoinAllSpaces)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Routes the menubar's "Open Chat" tap to the dashboard's Chat
    /// tab. Sets the shared activeTab first so the TabView's selection
    /// binding picks it up the moment SwiftUI materialises the window.
    private func openChat() {
        appState.isChatDrawerOpen = true
        openDashboardWindow()
    }

    func utilizationColor(_ percent: Double) -> Color {
        if percent > 80 { return .red }
        if percent > 50 { return .yellow }
        return .green
    }

    func tempColor(_ temp: Int) -> Color {
        if temp > 80 { return .red }
        if temp > 60 { return .orange }
        return .secondary
    }
}
