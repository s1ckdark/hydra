# macOS GUI Self-Reported Metrics — Design

**Date:** 2026-04-29
**Status:** Draft → User review pending
**Branch:** `claude/macos-self-metrics`

## Summary

The GUI's own host (the Mac running Hydra) shows blank metric charts in its device detail panel because the server's metric pipeline assumes "SSH from server into remote node and shell out commands" — a path that doesn't exist for the host running the server's HTTP client. This PR adds a Swift-side `MetricsReporter` that periodically samples local CPU/memory/disk/GPU-static via Foundation/Darwin/Metal APIs and POSTs to a new `/api/devices/{id}/metrics` endpoint. To avoid two IDs for the same Mac, a new `POST /api/devices/match` endpoint resolves a `{hostname,ip}` tuple to the canonical Tailscale device ID; both `CapabilityReporter` and the new `MetricsReporter` consume that resolved ID via a shared `DeviceIdentity` actor.

## Problem

Confirmed against the running app: when you click your own Mac in the device list, the CPU and memory ProgressView bars are empty and "0x" appears for GPU. The pipeline behind those views is `MonitorUseCase.GetDeviceMetrics` → SSH collector → remote shell commands (`top -l 2`, `vm_stat`, `nvidia-smi`). Local Macs don't expose SSH-to-self by default, and even if they did, the GUI host is the API caller, not its target.

The gap is not "macOS unsupported" — `internal/infra/ssh/collector.go` already has macOS fallbacks for CPU/memory/load/cores. The gap is "no path for self-reporting" + "GPU collector is nvidia-smi only."

## Goals

1. The Mac running the GUI reports its own CPU usage %, memory used/total, disk free, GPU presence/name/memory-budget every 5 seconds.
2. Both `CapabilityReporter` (existing) and `MetricsReporter` (new) use the device's Tailscale ID, not the Keychain UUID. The two reporters share one resolver.
3. iOS gets the same code path automatically (no iOS-specific handling).
4. The dashboard charts for the local device show non-empty values within ~5 seconds of GUI launch.

## Non-goals

- **Live GPU utilization %** on macOS. Apple does not expose a public API; `IOReport` and friends are private. v1 reports only static GPU info (name + memory budget + presence).
- **Linux/CUDA node behavior changes.** SSH+nvidia-smi path remains unchanged for those nodes.
- **Capability reporter UUID retirement.** The Keychain UUID stays in place but goes unused; a follow-up PR migrates existing per-device override data and removes the field.
- **Configurable cadence.** Hardcoded 5 s. Promote to config later if operations request it.
- **Metrics history retention.** Server keeps only the latest snapshot per device (existing `MonitorUseCase.latest` cache pattern). No DB persistence for self-reported metrics.
- **Auth on the new endpoints.** Same auth posture as existing `/api/devices/{id}/capabilities` (loopback-bound, dev/single-host scope).

## Architecture

```
┌────────────── macOS Hydra GUI ──────────────┐         ┌──────── Server ────────┐
│                                              │         │                         │
│ Boot:                                        │         │                         │
│   DeviceIdentity.current(apiClient) ─POST──►│         │ POST /api/devices/match │
│   { hostname, tailnet_ip }                   │         │   → Tailscale lookup    │
│                                          ◄──┘─response┤   → returns canonical   │
│   cache id in actor                          │         │     device ID           │
│                                              │         │                         │
│ CapabilityReporter.report() ─────POST───────►│         │ POST /api/devices/{id}/ │
│   uses DeviceIdentity.current()              │         │      capabilities       │
│                                              │         │   (existing handler)    │
│                                              │         │                         │
│ MetricsReporter.start() — 5s timer:         │         │ POST /api/devices/{id}/ │
│   sampleAll() → DeviceMetricsPayload ─POST──►│         │      metrics            │
│   uses DeviceIdentity.current()              │         │   → MonitorUC.latest    │
│                                              │         │     [id] = m            │
│                                              │         │   → m.Source = "self"   │
└──────────────────────────────────────────────┘         └─────────────────────────┘

GetDeviceMetrics(id):
  latest := MonitorUC.latest[id]
  if latest != nil && latest.Source == "self" &&
     time.Since(latest.CollectedAt) < freshSelfReport (30s):
       return latest    // self-reported, fresh
  if device.CanSSH():
       return collector.CollectMetrics(device)   // existing path
  return latest          // stale self-report or empty
```

## Component design

### Server

#### `POST /api/devices/match` (new)

```go
// internal/web/handler/device_match.go (new)

type matchRequest struct {
    Hostname string `json:"hostname,omitempty"`
    IP       string `json:"ip,omitempty"`
}

type matchResponse struct {
    DeviceID string `json:"deviceId"`
}

func (h *Handler) APIDeviceMatch(c echo.Context) error {
    var req matchRequest
    if err := c.Bind(&req); err != nil {
        return c.JSON(400, errResp("invalid body"))
    }
    if req.Hostname == "" && req.IP == "" {
        return c.JSON(400, errResp("hostname or ip required"))
    }
    devices, err := h.deviceUC.ListDevices(c.Request().Context(), false)
    if err != nil {
        return internalError(c, "list devices", err)
    }
    for _, d := range devices {
        if matchHostname(d, req.Hostname) || matchIP(d, req.IP) {
            return c.JSON(200, matchResponse{DeviceID: d.ID})
        }
    }
    return c.JSON(404, errResp("device not found in tailnet"))
}
```

Match precedence: hostname exact match first, then any IP in `device.IPAddresses`. Tailscale stores devices with hostname `dave-mbp.tail-net.ts.net` and a list of IPs (`100.x.y.z` Tailnet IP plus possibly LAN IPs). Hostname is the strong key.

#### `POST /api/devices/{id}/metrics` (new)

```go
// internal/web/handler/handler.go (extend)

func (h *Handler) APIDeviceMetricsPush(c echo.Context) error {
    id := c.Param("id")
    device, err := h.deviceUC.GetDevice(c.Request().Context(), id)
    if err != nil {
        return c.JSON(404, errResp("device not found"))
    }
    var payload domain.DeviceMetrics
    if err := c.Bind(&payload); err != nil {
        return c.JSON(400, errResp("invalid metrics payload"))
    }
    payload.DeviceID = device.ID
    payload.CollectedAt = time.Now()
    payload.Source = domain.MetricsSourceSelfReport
    h.monitorUC.PushSelfMetrics(&payload)
    return c.JSON(200, map[string]bool{"ok": true})
}
```

Wired in handler init alongside other `/api/devices/:id/*` routes. PUT vs POST: POST chosen because each call is conceptually "submit a new sample" rather than "replace state."

#### `domain.DeviceMetrics.Source` (new field)

```go
// internal/domain/metrics.go (extend)

type MetricsSource string

const (
    MetricsSourceSSH        MetricsSource = "ssh"
    MetricsSourceSelfReport MetricsSource = "self"
)

type DeviceMetrics struct {
    DeviceID    string         `json:"deviceId"`
    CPU         CPUMetrics     `json:"cpu"`
    Memory      MemoryMetrics  `json:"memory"`
    Disk        DiskMetrics    `json:"disk"`
    GPU         *GPUMetrics    `json:"gpu,omitempty"`
    Network     *NetworkMetrics `json:"network,omitempty"`
    Source      MetricsSource  `json:"source,omitempty"`   // NEW
    CollectedAt time.Time      `json:"collectedAt"`
    Error       string         `json:"error,omitempty"`
}
```

Empty default keeps back-compat with rows that pre-date this PR (deserialize as `MetricsSource("")`, treated as SSH for purposes of `GetDeviceMetrics` precedence).

#### `MonitorUseCase` changes

```go
// internal/usecase/monitor_usecase.go (extend)

const freshSelfReport = 30 * time.Second

func (uc *MonitorUseCase) PushSelfMetrics(m *domain.DeviceMetrics) {
    uc.latestMu.Lock()
    defer uc.latestMu.Unlock()
    uc.latest[m.DeviceID] = m
}

func (uc *MonitorUseCase) GetDeviceMetrics(ctx context.Context, deviceNameOrID string) (*domain.DeviceMetrics, error) {
    device, err := uc.deviceUC.GetDevice(ctx, deviceNameOrID)
    if err != nil {
        return nil, err
    }

    // Self-reported metrics take precedence when fresh — they describe
    // the GUI host directly, which has no SSH path back to itself.
    if cached := uc.GetLatestCached(device.ID); cached != nil &&
        cached.Source == domain.MetricsSourceSelfReport &&
        time.Since(cached.CollectedAt) < freshSelfReport {
        return cached, nil
    }

    if !device.CanSSH() {
        return &domain.DeviceMetrics{
            DeviceID:    device.ID,
            CollectedAt: time.Now(),
            Error:       "device is offline or SSH is disabled",
        }, nil
    }

    return uc.collector.CollectMetrics(ctx, device)
}
```

`PushSelfMetrics` reuses `latestMu` rather than introducing a parallel lock; the cache shape is identical.

### Swift

#### `DeviceIdentity.swift` (new — shared by both reporters)

```swift
actor DeviceIdentity {
    static let shared = DeviceIdentity()
    private var cached: String?

    func current(via apiClient: APIClient) async -> String? {
        if let id = cached { return id }
        let hostname = ProcessInfo.processInfo.hostName
        let ip = await TailscaleIP.current()      // helper described below
        do {
            let id = try await apiClient.matchDevice(hostname: hostname, ip: ip)
            cached = id
            return id
        } catch {
            // log once and let caller retry on next reporter tick
            return nil
        }
    }
}
```

Single `actor` provides serial access to `cached`. Both `CapabilityReporter` and `MetricsReporter` await it; whoever wins the race POSTs `/match` once, the loser reuses the cached result.

#### `TailscaleIP.swift` helper

Existing Tailscale extension to obtain the device's Tailnet IP. Uses `NWPathMonitor` interfaces filtered by interface name `utun*` matching Tailscale's tun device. Falls back to nil if the Tailscale daemon isn't running. (If this helper already exists in the codebase, reuse it; the spec assumes it's a small new addition if missing.)

#### `MetricsSampler.swift` (new)

```swift
struct CPUSnapshot { let usagePercent: Double; let cores: Int; let loadAvg1: Double; let loadAvg5: Double; let loadAvg15: Double }
struct MemorySnapshot { let totalBytes: UInt64; let usedBytes: UInt64; let freeBytes: UInt64; let usagePercent: Double }
struct DiskSnapshot { let totalBytes: UInt64; let availableBytes: UInt64; let usagePercent: Double }
struct GPUSnapshot { let name: String; let recommendedWorkingSetBytes: UInt64; let isLowPower: Bool }

enum MetricsSampler {
    static func sampleCPU(prev: inout host_cpu_load_info?) -> CPUSnapshot { /* host_statistics64 HOST_CPU_LOAD_INFO */ }
    static func sampleMemory() -> MemorySnapshot { /* host_statistics64 HOST_VM_INFO64 + sysctl hw.memsize */ }
    static func sampleDisk() -> DiskSnapshot { /* URLResourceKey on root volume */ }
    static func sampleGPU() -> GPUSnapshot? { /* MTLCreateSystemDefaultDevice properties */ }
}
```

CPU usage requires a delta between two reads. The reporter holds the previous `host_cpu_load_info` and computes `(user+system+nice) / total` over the delta.

#### `MetricsReporter.swift` (new)

```swift
@MainActor
final class MetricsReporter: ObservableObject {
    static let shared = MetricsReporter()
    private var task: Task<Void, Never>?
    private var prevCPU: host_cpu_load_info?

    func start(via apiClient: APIClient) {
        task?.cancel()
        task = Task.detached { [weak self] in
            guard let self else { return }
            // First read — discard, just seeds prevCPU
            _ = MetricsSampler.sampleCPU(prev: &self.prevCPU)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                await self.tick(via: apiClient)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func tick(via apiClient: APIClient) async {
        guard let id = await DeviceIdentity.shared.current(via: apiClient) else {
            return  // identity not yet resolved; try again next tick
        }
        let payload = DeviceMetricsPayload(
            cpu: MetricsSampler.sampleCPU(prev: &prevCPU),
            memory: MetricsSampler.sampleMemory(),
            disk: MetricsSampler.sampleDisk(),
            gpu: MetricsSampler.sampleGPU()
        )
        try? await apiClient.postMetrics(deviceID: id, payload: payload)
    }
}
```

#### `APIClient.swift` extensions

```swift
extension APIClient {
    func matchDevice(hostname: String, ip: String?) async throws -> String { /* POST /api/devices/match */ }
    func postMetrics(deviceID: String, payload: DeviceMetricsPayload) async throws { /* POST /api/devices/{id}/metrics */ }
}
```

#### `CapabilityReporter.swift` change

Replace its current `deviceUUID` resolution path with `DeviceIdentity.shared.current(via:)`. The Keychain UUID code path is left in place but flagged with a one-line `TODO(uuid-retirement)` for the follow-up PR. The `register()` method stays untouched.

#### `HydraApp.swift` wire-up

After existing `CapabilityReporter.shared.report(via: APIClient.shared)` call, add:

```swift
MetricsReporter.shared.start(via: APIClient.shared)
```

Order: capability report fires once at launch; metric reporter starts a perpetual 5s loop. Both use `DeviceIdentity.shared` so `/match` is called at most once per app launch.

## Data flow (life of a sample)

1. App launches, `HydraApp.init` starts `CapabilityReporter.shared.report` and `MetricsReporter.shared.start`.
2. First reporter to call `DeviceIdentity.shared.current()` triggers `POST /api/devices/match` with hostname + Tailnet IP.
3. Server's `APIDeviceMatch` calls `DeviceUseCase.ListDevices(false)`, walks the cached Tailscale device set, returns the matching device ID.
4. Both reporters now have the same `tailscaleID`.
5. `CapabilityReporter` does its single `POST /api/devices/{tailscaleID}/capabilities`.
6. `MetricsReporter` enters its 5s loop. First tick samples and POSTs.
7. Server's `APIDeviceMetricsPush` validates the device ID, sets `Source = self`, stores in `MonitorUseCase.latest[tailscaleID]`.
8. Dashboard's polling on `GET /api/devices/{tailscaleID}/metrics` calls `MonitorUseCase.GetDeviceMetrics`, which sees fresh self-reported data and returns it without attempting SSH.

## Error handling

| Where | Failure | Behavior |
|---|---|---|
| `DeviceIdentity.current` | `/match` returns 404 | Log once, return nil; reporter ticks become no-ops; UI shows static fallback (existing "device offline" path) |
| `DeviceIdentity.current` | network error | Same as 404; retry next call (no exponential backoff at the actor level — reporter cadence handles backoff naturally) |
| `MetricsSampler.sample*` | syscall failure | Field is set to zero; payload still POSTed (partial > nothing) |
| `APIClient.postMetrics` | server 5xx | Skip this tick; log; next tick proceeds |
| `MetricsSampler.sampleGPU()` | nil (Intel Mac without Metal) | Payload `gpu: null`; server stores without GPU field |
| Multiple Hydra GUIs on same Mac | both POST same ID | Last write wins; no correctness issue (both report same data anyway) |

## Testing

### Server-side unit tests

- `internal/web/handler/device_match_test.go` (new):
  - matches by hostname → returns ID
  - matches by IP when hostname blank → returns ID
  - both blank → 400
  - no match → 404
  - Tailscale list error → 500
- `internal/web/handler/handler_test.go` extension:
  - `APIDeviceMetricsPush` validates device exists, sets Source/CollectedAt server-side, calls `PushSelfMetrics`
- `internal/usecase/monitor_usecase_test.go`:
  - `GetDeviceMetrics` returns self-reported value when fresh
  - `GetDeviceMetrics` falls through to SSH when self-report is stale (>30s)
  - `GetDeviceMetrics` falls through to SSH when no self-report exists
  - `PushSelfMetrics` updates cache under lock

### Swift-side unit tests

- `MetricsSamplerTests.swift`:
  - `sampleMemory().totalBytes > 0`
  - `sampleDisk().totalBytes > sampleDisk().availableBytes` (sanity)
  - `sampleCPU` first call (no prev) → usagePercent = 0
  - `sampleCPU` second call after compute load → usagePercent > 0
- `DeviceIdentityTests.swift`:
  - first `.current()` calls match endpoint
  - second `.current()` returns cached without re-calling
  - on failure, cached stays nil; next call retries
- `APIClientTests.swift`:
  - `matchDevice` shapes request correctly
  - `postMetrics` includes Source field

### Manual smoke test

1. Build: `cd Hydra && swift build && swift run` (or open .app via Xcode).
2. Start server: `make build && ./bin/server` on the same Mac.
3. Tailscale must be active (`tailscale status` shows the local device).
4. Open the GUI's device list. Find own Mac.
5. Click into detail. Within ~10s the CPU bar, RAM bar, and disk bar should all show non-zero values, GPU row should show "Apple M1 Max" (or your model) plus memory budget.
6. Open another tab/run `stress -c 4` to spike CPU. On the next 5s tick the CPU bar should rise.
7. Check server log: 5s-interval lines `[handler] POST /api/devices/<id>/metrics` (verbosity allowing).
8. Curl directly: `curl http://localhost:8080/api/devices/<id>/metrics | jq .source` should print `"self"`.
9. Disconnect Tailscale → next reporter tick logs identity-resolve failure; UI bars freeze on last value (acceptable degradation).
10. Reconnect Tailscale, restart Hydra → resolve works on first tick again.

## File map

**New (server):**
- `internal/web/handler/device_match.go` (handler)
- `internal/web/handler/device_match_test.go` (test)

**New (Swift):**
- `Hydra/Hydra/Services/DeviceIdentity.swift`
- `Hydra/Hydra/Services/MetricsReporter.swift`
- `Hydra/Hydra/Services/MetricsSampler.swift`
- `Hydra/Tests/MetricsSamplerTests.swift`
- `Hydra/Tests/DeviceIdentityTests.swift`

**Modified (server):**
- `internal/domain/metrics.go` — add `MetricsSource`, `Source` field on `DeviceMetrics`
- `internal/usecase/monitor_usecase.go` — `PushSelfMetrics`, `GetDeviceMetrics` self-report precedence
- `internal/usecase/monitor_usecase_test.go` — coverage for the new branch
- `internal/web/handler/handler.go` — `APIDeviceMetricsPush`, route registration, plus `APIDeviceMatch` route
- `internal/web/handler/handler_test.go` — coverage

**Modified (Swift):**
- `Hydra/Hydra/Services/APIClient.swift` — `matchDevice`, `postMetrics`
- `Hydra/Hydra/Services/CapabilityReporter.swift` — use `DeviceIdentity.shared` instead of Keychain UUID
- `Hydra/Hydra/HydraApp.swift` — start `MetricsReporter` after capability report

## Risks

1. **Tailnet IP discovery on Swift side.** If `TailscaleIP.current()` doesn't already exist, finding the Tailnet IP requires walking interfaces and matching. A naive walk gets the LAN IP first and gets matched against a Tailscale device that doesn't have the LAN IP recorded. Mitigation: hostname is the primary match key; IP is a backup. Match endpoint returns 404 if both fail and the reporter logs and stops — explicit failure mode, not silent.

2. **CPU usage delta math.** Apple's `host_cpu_load_info` returns cumulative ticks since boot. The first sample has no prev; if reporter computes `(now-prev)/(now-prev)` blindly it produces `0/0 = NaN`. Spec'd above to seed `prevCPU` once on start before the first tick.

3. **`Source` field migration.** Existing `DeviceMetrics` rows on disk (from SSH collection) don't carry `Source`. After the `omitempty` JSON encoder, deserialization fills `Source = ""`. The `==` check in `GetDeviceMetrics` against `MetricsSourceSelfReport` still returns false → falls through to SSH. Safe.

4. **iOS battery field.** `DeviceInfoCapability` already collects `batteryLevel`/`batteryState`. They're not currently surfaced in `DeviceMetrics`. Spec leaves this alone for v1 — surface them in a follow-up if useful for ops.

5. **Auth.** Loopback `Server.Host: 127.0.0.1` keeps the new endpoints unreachable from off-host. If the server later binds 0.0.0.0, `/api/devices/match` becomes a low-value enumeration leak (anyone can ask "which device has hostname X" and get the canonical ID). Document and revisit if/when binding changes.

## Out of scope (follow-ups)

- Capability reporter UUID retirement + migration of existing per-device override map
- iOS battery/thermal surfaced through `DeviceMetrics`
- Linux/CUDA self-report (workers could push too, reducing SSH frequency — but a different shape: SSH already works there, no urgency)
- Configurable reporter cadence
- GPU live utilization (blocked by Apple API)
- Network metrics for self-report (Apple equivalents to Linux `/proc/net/dev` exist but are scope creep)
