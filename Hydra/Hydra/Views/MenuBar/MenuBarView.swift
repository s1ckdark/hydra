import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @StateObject private var gpuVM = GPUMonitorViewModel()
    @Environment(\.openWindow) private var openWindow

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
                                }
                                // Line 2: bar + stats
                                HStack(spacing: 6) {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(.quaternary)
                                            RoundedRectangle(cornerRadius: 2)
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
                    await vm.load()
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
        .frame(width: 300)
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
        Task { @MainActor in
            // Yield one runloop tick so the popover finishes dismissing —
            // activation events fired during dismissal are sometimes dropped.
            try? await Task.sleep(for: .milliseconds(50))

            NSApp.setActivationPolicy(.regular)
            // macOS 14 deprecates `.activateIgnoringOtherApps`; the no-arg
            // call now performs the same activation when called from a
            // foregrounded process context.
            NSRunningApplication.current.activate()

            // Reuse an existing dashboard window if one is alive. Filter out
            // NSPanel (the menu-bar popover itself is one) and windows that
            // can't become key (status items, transient overlays).
            if let existing = NSApp.windows.first(where: {
                $0.canBecomeKey && !($0 is NSPanel) && $0.contentViewController != nil
            }) {
                if existing.isMiniaturized { existing.deminiaturize(nil) }
                existing.makeKeyAndOrderFront(nil)
                return
            }

            // No live window — request SwiftUI to materialise one. Even when
            // openWindow is honoured, the new NSWindow doesn't grab focus
            // automatically from this scene context, so we wait one more tick
            // and force makeKeyAndOrderFront on whichever real window appears.
            openWindow(id: "dashboard")
            try? await Task.sleep(for: .milliseconds(100))
            for window in NSApp.windows where window.canBecomeKey && !(window is NSPanel) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
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
