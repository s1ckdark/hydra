# Hydra Android Client (v1) — Design

## Context

Hydra ships two Apple clients: a macOS GUI and an iOS app (`Hydra/HydraiOS`). Both are SwiftUI front-ends over the Go backend's REST + WebSocket API on `:8080`. There is no Android client, and no web UI to wrap — `internal/web` contains only `handler/`, `middleware/`, and `ws/`, with no static assets or templates.

The iOS app is ~2,165 lines of screens on top of ~4,445 lines of `Models/`, `State/`, `ViewModels/`, and `Services/` shared with macOS (`Hydra/project.yml` excludes only the macOS-only service files). None of that is reusable on Android: `CredentialStore` is Keychain, `APIClient` is `URLSession`, the terminal is SwiftTerm + Citadel. So this is not a port of code — it is a **second native client against the same HTTP contract**.

That contract is Android-friendly as-is: the Go server emits camelCase JSON (`internal/domain/device.go:16-38`), RFC3339 timestamps, and authenticates with `Authorization: Bearer <key>` (`Hydra/Hydra/Services/APIClient.swift:329`).

## Goals

- A native Kotlin + Jetpack Compose Android app in `android/`, independent of the Go and Swift build systems.
- v1 scope: **설정 · 대시보드 · Chat** — three of the iOS app's six tabs.
- Multi-module + Hilt from the start, so the deferred tabs (디바이스/터미널, Orchs, Tasks) drop in without restructuring.
- Behavioural parity with iOS where iOS is right; deliberate divergence where an Android idiom is better, documented at each such point.
- Test-first: serialization, interceptors, repository partial-failure semantics, and ViewModel state transitions all have tests before implementation.

## Non-Goals

- **SSH terminal.** The hardest subsystem (terminal emulator + SSH client + host-key trust) and the largest single risk. Deferred to v2, along with the 디바이스 tab that launches it.
- **Orchs and Tasks tabs.** The dashboard already surfaces running orchs and recent tasks read-only; the dedicated tabs (create/edit/delete) are v2.
- **Quick Command section on the dashboard.** iOS bundles an Allow/Ask/Auto execution gate plus a unified activity log into `DashboardScreen` (`ExecPolicy`, `ActivityEntry`, ~380 lines of `DashboardViewModel`). Chat already provides plan-approval execution, so v1 routes all command execution through the Chat tab.
- **`sshUsername` and SSH key management in Settings.** No SSH in v1; a settings row that controls nothing is a latent bug report.
- **Server discovery (Bonjour/mDNS).** iOS has `ServerDiscovery.swift`; v1 uses manual URL entry.
- **Device self-reporting.** The iOS app registers itself as a device and pushes metrics (`MetricsReporter`, `CapabilityReporter`). The Android app is a controller only in v1.
- **Localization.** Korean/English strings are hardcoded matching the iOS app's current mix.
- **Play Store release, signing config, ProGuard rules.** Debug builds only.

## Architecture overview

### Module graph

```
:app  ──────────────────────────────┐
  │  Application(Hilt), MainActivity │
  │  NavHost + bottom NavigationBar  │
  ▼                                  ▼
:feature:dashboard  :feature:chat  :feature:settings
  │                   │              │
  └───────────────────┴──────────────┘
                      ▼
              :core:data ──────► :core:network ──► :core:model
              (repositories,     (Retrofit, OkHttp,  (data classes,
               DataStore,         interceptors,       kotlinx.serialization)
               Keystore)          error mapping)

:core:designsystem  ◄── all :feature:* (Theme, Color, Typography, HydraCard)
```

Each feature module exports a single `NavGraphBuilder` extension (e.g. `fun NavGraphBuilder.dashboardScreen()`); `:app` assembles them. Feature modules never depend on each other.

Build configuration lives in `android/build-logic` as three convention plugins — `hydra.android.application`, `hydra.android.library`, `hydra.android.compose` — with versions in `android/gradle/libs.versions.toml`.

- compileSdk 36, targetSdk 36, minSdk 26
- Kotlin 2.x with the Compose Compiler Gradle plugin
- Retrofit + OkHttp + kotlinx.serialization converter
- Hilt for DI
- DataStore (Preferences) for settings

### Package root

`com.hydra.android` (mirrors the iOS bundle id `com.hydra.ios`).

## Data layer

### `:core:model`

Pure Kotlin `@Serializable` data classes, one per iOS model actually used in v1:

| Kotlin | iOS source | Notes |
|---|---|---|
| `Device` | `Models/Device.swift` | plus computed `isOnline`, `displayName`, `shortName` |
| `Orch` | `Models/Orch.swift` | `isRunning`, `workerCount` |
| `NagaTask` | `Models/ServerTask.swift` | `isRunning`/`isCompleted`/`isFailed`/`isPending` |
| `GpuNodeStatus`, `GpuInfo` | `Models/GPUMonitor.swift` | |
| `DeviceMetrics` | `Models/DeviceMetrics.swift` | |
| `ChatTurn`, `ChatRequest`, `ChatResponse` | `Models/ChatTurn.swift` | |
| `AgentPlan`, `AgentAction`, `ActionResult` | `Models/AgentPlan.swift` | |

Field names match the Go JSON tags exactly, so no `@SerialName` is needed.

**Timestamps.** `Instant` uses a custom serializer that accepts RFC3339 both with and without fractional seconds. iOS needs the same fallback (`APIClient.swift:20-26`) because Go's `time.Time` omits the fraction when it is zero.

**Client-side list ids are never serialized.** Three models carry a `UUID` that exists only so SwiftUI can diff a list, and all three exclude it via `CodingKeys`: `ChatTurn` (`case role, content, plan, results`), `AgentAction` (`case type, args`), and `ActionResult` (`case type, status, output, error`). Kotlin marks each corresponding `id` `@Transient`.

This matters in both directions, not just for the chat history: `POST /api/agent/execute` echoes the whole `AgentPlan` — including its `AgentAction` list — back to the server, so a leaked `id` field would ride along into the execute request too.

**`AgentAction.args` is free-form.** iOS types it `AnyCodable`; Kotlin uses `kotlinx.serialization.json.JsonObject` and renders a sorted `key=value` summary in the plan card.

### `:core:network`

One Retrofit service interface covering the eight v1 endpoints:

| Method | Path | Used by |
|---|---|---|
| GET | `/health` | server status banner |
| GET | `/api/devices?refresh=&include_mobile=` | dashboard |
| GET | `/api/orchs` | dashboard |
| GET | `/api/tasks` | dashboard |
| GET | `/api/monitor/gpu` | dashboard |
| GET | `/api/monitor/snapshot` | dashboard |
| POST | `/api/agent/chat` | chat |
| POST | `/api/agent/execute` | chat (plan run) |

Two interceptors:

1. **`BaseUrlInterceptor`** — Retrofit pins its base URL at construction, but the server address is user-editable at runtime (iOS handles this with `APIClient.reloadBaseURL()`). Retrofit is built with a placeholder base; this interceptor rewrites every request's scheme/host/port from the current `SettingsRepository` value. Changing the server in Settings takes effect on the next request with no object graph rebuild.
2. **`AuthInterceptor`** — adds `Authorization: Bearer <key>` only when a key is stored. Absent key means no header, not an empty one.

**Cleartext HTTP.** The default server is `http://localhost:8080` and real use is `http://<tailscale-ip>:8080`. Android blocks cleartext from API 28.

The server address is arbitrary user input, so the addresses cannot be enumerated ahead of time — `network_security_config.xml` matches on hostnames and has no CIDR form, so "allow the Tailscale range" is not expressible. v1 therefore ships a `network_security_config.xml` whose `<base-config>` sets `cleartextTrafficPermitted="true"`, referenced from the manifest via `android:networkSecurityConfig`.

This is a deliberate trade-off, recorded here rather than left implicit: the app talks only to a host the user typed, normally over a private tailnet. Using a config file instead of `android:usesCleartextTraffic="true"` keeps the decision in one reviewable place and leaves room to tighten it later (e.g. pinning to the configured host once HTTPS is an option server-side).

The Android device must be on the same tailnet. That is a documented prerequisite, not something the app arranges.

**Error mapping.** A single mapper produces `ApiException`:

- `IOException` → "서버에 연결할 수 없습니다"
- HTTP 401 → "API 키가 유효하지 않습니다"
- other non-2xx → the server's `{"error": "..."}` body string, matching iOS (`APIClient.swift:336`); falls back to the status code when the body does not parse.

### `:core:data`

- `SettingsRepository` — DataStore Preferences: `serverUrl`, `aiInstruction`, `hideMobileDevices`. Exposed as `Flow`.
- `SecureStore` — the API key only, encrypted with an Android Keystore AES/GCM key. `androidx.security-crypto` is deprecated in Jetpack, and v1 has exactly one secret, so a small Keystore wrapper beats adding a deprecated dependency. Corresponds to the single `serverAPIKey` case of the iOS `CredentialStore`.
- `DashboardRepository`, `ChatRepository` — return `Result<T>` (see Error handling).

## Feature layer

### Navigation

`:app` hosts a `NavHost` with a bottom `NavigationBar` of three destinations: 대시보드 / Chat / 설정. The iOS `TabView` has six; the other three routes are simply absent in v1.

### Dashboard

Section order follows `HydraiOS/Screens/DashboardScreen.swift:9-115` exactly, minus Quick Command:

1. Server status banner (`/health` → status + version)
2. Offline-devices alert — rendered only when non-empty
3. Summary grid, 2×2: Devices `online/total` · GPU Nodes + total GPUs · Orchs + running count · Tasks running/total
4. Device cards
5. GPU section (gauge + per-node stats)
6. Running orchs — rendered only when non-empty
7. Recent tasks — 10 most recent by `completedAt ?? createdAt`
8. Last-updated timestamp

**Polling diverges from iOS deliberately.** iOS pairs `startPolling(interval: 5)` in `.task` with `stopPolling()` in `.onDisappear` (`DashboardViewModel.swift:161-173`). Android instead exposes the poll as a flow collected only while the UI is subscribed:

```kotlin
flow { while (true) { emit(load(force = false)); delay(5.seconds) } }
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), DashboardUiState.Loading)
```

Leaving the tab or backgrounding the app stops the polling automatically and resuming restarts it. The class of bug where a missed `onDisappear` leaks a poll loop becomes structurally impossible.

**Refresh semantics.** Pull-to-refresh calls with `force = true`, which makes the server bypass its Tailscale cache, re-probe `:22`, and re-collect SSH metrics. Polling ticks use `force = false` (the cached path). This mirrors the intent documented at `DashboardViewModel.swift:129-134`.

**Loading overlay** appears only when `isLoading && devices.isEmpty && orchs.isEmpty`, so poll ticks do not flash the screen.

### Chat

Layout: message list → pending plan card (when present) → input bar; empty state reads "Ask Hydra".

- A turn renders a role label (`YOU` / `ASK` / `PLAN` / `RESULT`) above its content, matching `ChatTurnRow`.
- The plan card shows `plan.intent`, the optional assistant message, one row per action (monospaced type chip + args summary), and Run / Cancel.
- Run posts to `/api/agent/execute` and appends a `system_result` turn summarizing the `ActionResult` list (`✓ all N action(s) completed`, or `ran N action(s) — X ok, Y failed`).
- Outbound history is capped at the last 20 turns (`serverHistoryCap`); the UI keeps all of them.
- The `aiInstruction` setting is attached to each request as `instruction` so it applies without a separate save-and-push step.
- The list auto-scrolls to the pending plan when one exists, otherwise to the last turn.

### Settings

Four controls: server URL, API key (Keystore-backed, masked), AI instruction (multi-line), and a "모바일 디바이스 숨기기" switch feeding `include_mobile` on the devices query. iOS keeps this last toggle on its device-list screen, which v1 does not have.

## Error handling

Repositories return `Result<T>` rather than throwing, because the dashboard merges five independent sources and a thrown exception would let the first failure swallow the rest.

The **core/auxiliary asymmetry** from iOS is preserved:

- `devices` and `orchs` are fetched concurrently and their failure sets `UiState.error` (iOS: `async let` + a `catch` that assigns `error`).
- `gpu`, `metrics`, and `tasks` failures are swallowed and leave their sections empty (iOS: `loadGPU`'s empty `catch`, commented "GPU monitoring is optional"). Without this, a server with no GPU nodes would show the whole dashboard as failed.
- `/health` failure is never an error banner — it sets the status banner to `disconnected`.

## Testing strategy

Tests are written before the implementation they cover.

| Module | Coverage |
|---|---|
| `:core:model` | RFC3339 round-trip with and without fractional seconds; `ChatTurn`, `AgentAction`, and `ActionResult` all omit `id` when serialized; `AgentAction.args` survives a decode/encode round-trip as an opaque `JsonObject` |
| `:core:network` | MockWebServer: `BaseUrlInterceptor` reflects a settings change on the next request; `AuthInterceptor` omits the header entirely when no key is stored and sets `Bearer` when one is; error-body `{"error":...}` mapping and its status-code fallback |
| `:core:data` | Dashboard load succeeds partially when GPU/metrics/tasks fail; fails visibly when devices or orchs fail; `SecureStore` round-trips a key |
| `:feature:chat` | Turbine + fake repository: send → thinking → `assistant_plan` → pending plan; Run → `system_result`; Cancel clears the plan; history truncates to 20 |
| `:feature:dashboard` | Poll emits on interval and stops when unsubscribed; force-refresh passes `refresh=true`; loading overlay only on first load |
| Compose UI | One smoke test per screen. Not a priority surface. |

## Build integration

- `cd android && ./gradlew :app:assembleDebug`
- Root `Makefile` gains `android-build` and `android-test` targets that delegate to Gradle.
- `.gitignore` gains `android/.gradle/`, `android/**/build/`, `android/local.properties`.

The Android build is not wired into `make build` or `make test`; those stay Go-only so backend CI does not acquire a JDK/Android SDK dependency.

## Open questions

None blocking. Deferred decisions are listed under Non-Goals with their rationale.
