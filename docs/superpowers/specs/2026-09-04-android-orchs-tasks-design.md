# Hydra Android — Orchs 탭 + Tasks 탭 (v3) — Design

## Context

The Android client ships four tabs: 설정 · 대시보드 · Chat (v1) and 디바이스 with its SSH terminal (v2). The two iOS tabs still missing are Orchs and Tasks, deferred in both prior specs as v2/v3 work.

Reading the iOS implementation before designing turned up a fact that reshapes the whole cycle: **the two tabs are not the same kind of thing.**

- **Orchs** is a pure server resource. `OrchViewModel` does nothing but call REST — list, create, delete, health, processes, execute. No local state.
- **Tasks is not a server resource.** `TasksScreen` never touches `/api/tasks`. It reads `SavedTaskStore`, which keeps *saved command templates* in a JSON file on the device and runs them through `/api/devices/{id}/execute`. It also carries an in-app scheduler.

So the dashboard's "Tasks 0" card (the server queue at `/api/tasks`) and the Tasks tab (local templates) share a name and nothing else. Designing the tab as "the server task list" would have built the wrong feature.

## Goals

- Orchs tab at iOS parity: list, create, delete, and a detail screen with health, command execution, and worker-process polling.
- Tasks tab at iOS parity minus the scheduler: save, edit, delete, and manually run command templates stored on the device.
- Follow the wiring already proven in v1/v2 — subscription-driven polling, `Result<T>` for partial failure, screen-owned text buffers.

## Non-Goals

- **The scheduler.** iOS runs saved tasks every N minutes from an in-app `Task` loop. Doing that properly on Android means WorkManager plus battery-optimisation exemptions plus a 15-minute floor plus Samsung's power management — its own cycle. Excluded, and `SavedTask` carries **no** `schedule` field: an unused field would accumulate data no UI shows and become a migration problem. Adding the field when the scheduler arrives is cheaper than defending a dormant one, exactly as `sshUsername` was dropped in v1 and cleanly restored in v2.
- **The server task queue** (`/api/tasks` beyond the dashboard's existing read). A separate screen if it is ever wanted.
- **Full execution output.** A run's result shows status and a truncated output; a full-output viewer is out of scope.
- **Orch start/stop.** The server exposes no such endpoint.
- **Instrumented tests.** v2's six exist because the vendored `TerminalView` has undocumented initialisation contracts. These two tabs are plain Compose; the unit layer covers them.

## Server contract — verified, not inherited

The JSON conventions differ per endpoint, and iOS is wrong in one place. **The Go handler is the authority.**

### `POST /api/orchs`

```
{ "name": string, "coordinator_id": string, "worker_ids": [string] }
```

`handler.go:532` binds `HeadID string \`json:"coordinator_id"\``. iOS's `CreateOrchRequest` sends **`head_id`** (`Models/Orch.swift`), which this server would silently read as an empty coordinator and reject with "coordinator required". Android sends `coordinator_id`.

v1's spec asserted "the server emits camelCase, so no `@SerialName` is needed". That held for the eight endpoints v1 used. It does not generalise, and this cycle must check field-by-field.

### `POST /api/orchs/{id}/execute` and `POST /api/devices/{id}/execute`

Request: `{ "command": string, "timeout_seconds": int }`. The server clamps the timeout to 1–300 and defaults it to 30 (`handler.go:1699-1714`).

Orch execute response (`handler.go:1801`): `orch_id`, `command`, `worker_count`, `results` — **snake_case wrapper**.

### `GET /api/orchs/{id}/processes`

Response (`handler.go:2282`): `orch_id`, `timestamp`, `worker_count`, `workers` — snake_case wrapper — but each worker (`handler.go:2180`) is **camelCase**: `deviceId`, `deviceName`, `gpu`, `processes`, `error`; and each process (`handler.go:2169`): `pid`, `processName`, `cpuPercent`, `memPercent`, `vramMB`, `command`, `isGpu`.

Note `pid` is a **string** on the wire, not an int.

### `GET /api/orchs/{id}/health` and `DELETE /api/orchs/{id}?force=true`

Health is camelCase throughout and does match iOS — checked, not assumed, given the create-request discrepancy above: `orchId`, `name`, `status` (`handler.go:1453`), with `nodes[]` of `nodeId`/`role`/`healthy`/`error` (`handler.go:1417-1420`).

Delete takes `force` as a query parameter; the app always passes `true`, matching iOS.

## Architecture

### New modules

```
:app
 ├── :feature:orchs ──┐
 └── :feature:tasks ──┤
                      ▼
                 :core:data ──► :core:network ──► :core:model
              (OrchRepository,
               SavedTaskStore)
```

Both repositories live in `:core:data`, not in their feature modules: the dashboard already reads orchs, and running a saved task needs `DevicesRepository` to resolve a target.

### `:core:model` additions

`CreateOrchRequest`, `OrchHealth`, `OrchNodeStatus`, `ExecuteRequest`, `OrchExecuteResponse`, `OrchProcessesResponse`, `WorkerStatus`, `WorkerProcess`, and `SavedTask`. `@SerialName` appears only where the wire name differs from the Kotlin name — which, per the contract above, is the snake_case wrappers and `coordinator_id`.

### `:core:network` additions

Six endpoints join `HydraApi`:

| Method | Path |
|---|---|
| POST | `api/orchs` |
| DELETE | `api/orchs/{id}` (`?force=`) |
| GET | `api/orchs/{id}/health` |
| GET | `api/orchs/{id}/processes` |
| POST | `api/orchs/{id}/execute` |
| POST | `api/devices/{id}/execute` |

The device-execute endpoint was dropped in v1 along with Quick Command; the Tasks tab brings it back.

### `:core:data` additions

`OrchRepository` wraps the five orch calls in `Result<T>` — failures are values, as everywhere else in this client.

`SavedTaskStore` persists the template list as one kotlinx.serialization JSON document in an app-private file, the same shape as `KnownHostsStore`. A malformed or truncated file reads as an **empty list**, never an exception: a corrupt store must not make the tab unopenable.

```kotlin
@Serializable
data class SavedTask(
    val id: String,
    val name: String,
    val command: String,
    val targetDeviceId: String? = null,   // null = ask when running
    val targetDeviceName: String? = null, // display only
    val timeout: Int = 30,
    val priority: TaskPriority = TaskPriority.NORMAL,
    val lastRunAt: Instant? = null,
    val lastRunStatus: String? = null,
    val createdAt: Instant,
)

enum class TaskPriority { LOW, NORMAL, HIGH, URGENT }
```

## Screens

### Navigation

The bottom bar reaches six tabs: 대시보드 / 디바이스 / Orchs / Tasks / Chat / 설정 — the iOS set. Material3 recommends at most five destinations, so labels are checked on the narrow outer display and shortened if they truncate. Orch create, orch detail, and the task editor are full-screen routes outside the bar, like the terminal.

### Orchs list

Name, `N workers`, and a status capsule coloured as iOS does: running green, starting yellow, error red, otherwise grey. A `+` action opens create.

Delete is a **long-press with a confirmation dialog**, not a swipe. It is irreversible and goes out with `force=true`; a confirm step is warranted, and long-press-to-act is the Android idiom where iOS uses swipe.

### Orch create

Name, a coordinator picked from online devices, and a multi-select of workers (coordinator excluded, GPU devices badged). Create is enabled only once name and coordinator are set.

### Orch detail

Four blocks, mirroring iOS: header with status, an info grid (head node, worker count), node health, command execution, and worker processes.

Processes poll every five seconds using the v1 dashboard shape: `stateIn(WhileSubscribed)` drives the loop from subscription, and the `delay` sits **after** a completed load so a slow server cannot have each poll cancel the one in flight. iOS's manual `startProcessPolling`/`stopProcessPolling` pair is not carried over — leaving the screen drops the collector on its own.

### Tasks list

One row per template: name, command in monospace (single line), target device, priority badge, and the last run's status and time when present.

Tapping a row opens the editor; **Run is an explicit button inside the row**, not a swipe action. iOS hides Run behind a leading swipe, which is undiscoverable on Android. A running task shows a spinner in place of the button.

### Task editor

Full-screen. Name, command (multi-line monospace), target device (blank means ask at run time), timeout, priority. Every text field is **screen-owned** — v1 lost real keystrokes binding a field straight to ViewModel state, and that rule holds here.

### Run results

A run updates the row: `lastRunAt`, `lastRunStatus`, and the **first 10 lines** of output behind a collapsible. Results are written back into the store so they survive a restart. Ten lines is enough to see whether a command did what was expected without turning a list row into a log viewer.

## Error handling

Unchanged from v1: repositories return `Result<T>`, `ApiException` carries the Korean message, and screens render it inline.

Two specifics:

- **Orch delete failure does not roll back optimistically.** The list is not mutated until the server confirms; on failure only the error is shown. A row that vanishes and reappears is worse than a row that never moved.
- **Running a task with no target device** and no device chosen prompts for one rather than failing.

## Testing

| Module | Coverage |
|---|---|
| `:core:model` | `CreateOrchRequest` serialises `coordinator_id`/`worker_ids` — the field iOS gets wrong; the snake-wrapper / camel-body mix in processes and execute responses decodes; `pid` decodes as a string |
| `:core:network` | The six new endpoints' methods and paths; `force=true` is sent on delete and omitted otherwise |
| `:core:data` | `SavedTaskStore` add/update/delete round-trips through the file; a malformed file reads as empty; `OrchRepository` surfaces failures as `Result` |
| `:feature:orchs` | List load and error; delete success and failure (no optimistic removal); create refreshes the list; detail polls on interval and stops when unsubscribed; execute result lands |
| `:feature:tasks` | CRUD through the store; run marks the row running then records status; a task with no target reports that rather than dialing |

## Open questions

None blocking. Everything deferred is under Non-Goals with its reason.
