# Android Orchs 탭 + Tasks 탭 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the last two iOS tabs to the Android client — Orchs (a server resource: list, create, delete, detail with health/execute/process polling) and Tasks (device-local command templates that run through the device-execute endpoint).

**Architecture:** Two new feature modules following the established pattern. `OrchRepository` and `SavedTaskStore` both live in `:core:data` — the dashboard already reads orchs, and running a saved task needs `DevicesRepository`. Orchs is pure REST; Tasks persists a template list as one JSON document in an app-private file, the same shape as `KnownHostsStore`.

**Tech Stack:** Kotlin 2.1, Jetpack Compose (Material3), Hilt, Retrofit, kotlinx.serialization, kotlinx-datetime.

**Spec:** `docs/superpowers/specs/2026-09-04-android-orchs-tasks-design.md`

## Global Constraints

- All work lives under `android/`. Do not touch Go (`cmd/`, `internal/`) or Swift (`Hydra/`) sources.
- Package root `com.hydra.android`. compileSdk 36, targetSdk 36, minSdk 26.
- `JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS` on every Gradle invocation; `java` is not on PATH.
- Both Java and Kotlin emit **17** bytecode on a JDK 21 toolchain. Do not change either.
- Korean UI strings, matching the existing app. No localization.
- Every task ends with a commit. Work on branch `feat/android-orchs-tasks`.
- Text fields are **screen-owned** — never bind a `TextField`'s `value` straight to ViewModel state. v1 lost real keystrokes doing that.
- Polling is subscription-driven: `stateIn(..., SharingStarted.WhileSubscribed(5_000), ...)` with the `delay` **after** a completed load, never an independent ticker.

### Server contract — exact wire names, verified against the Go handler

Do not copy iOS here; it is wrong in one place. These values are authoritative.

| Payload | Wire fields |
|---|---|
| `POST api/orchs` request | `name`, **`coordinator_id`**, `worker_ids` (iOS sends `head_id` — wrong; `handler.go:532`) |
| execute request | `command`, `timeout_seconds` (server clamps 1–300, defaults 30) |
| orch execute response | `orch_id`, `command`, `worker_count`, `results` — snake wrapper |
| processes response | `orch_id`, `timestamp`, `worker_count`, `workers` — snake wrapper |
| `WorkerStatus` | `deviceId`, `deviceName`, `gpu`, `processes`, `error` — camel |
| `WorkerProcess` | `pid` (**String**, not Int), `processName`, `cpuPercent`, `memPercent`, `vramMB`, `command`, `isGpu` — camel |
| `TaskResult` | `deviceId`, `deviceName`, `gpu`, `output`, `error`, `durationMs` — camel |
| orch health | `orchId`, `name`, `status`, `nodes[]` of `nodeId`/`role`/`healthy`/`error` — camel |

---

## File Structure

```
android/
├── core/model/…/
│   ├── OrchDetail.kt          NEW  health, execute, processes, worker types
│   └── SavedTask.kt           NEW  local template + priority
├── core/network/…/HydraApi.kt MODIFY  six endpoints
├── core/data/…/
│   ├── OrchRepository.kt      NEW  Result<T> over the five orch calls
│   └── SavedTaskStore.kt      NEW  JSON file persistence
├── feature/orchs/             NEW  list + create + detail
└── feature/tasks/             NEW  list + editor
```

---

### Task 1: `:core:model` — orch detail and saved-task types

**Files:**
- Create: `android/core/model/src/main/kotlin/com/hydra/android/core/model/OrchDetail.kt`, `SavedTask.kt`
- Test: `android/core/model/src/test/kotlin/com/hydra/android/core/model/OrchSerializationTest.kt`, `SavedTaskSerializationTest.kt`

**Interfaces:**
- Consumes: `InstantSerializer` (existing).
- Produces: `CreateOrchRequest`, `ExecuteRequest`, `TaskResult`, `OrchExecuteResponse`, `OrchHealth`, `OrchNodeStatus`, `OrchProcessesResponse`, `WorkerStatus`, `WorkerProcess`, `SavedTask`, `TaskPriority`.

- [ ] **Step 1: Write the failing serialization tests**

`OrchSerializationTest.kt`:

```kotlin
package com.hydra.android.core.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OrchSerializationTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun `create request uses the server's coordinator_id, not iOS's head_id`() {
        // handler.go:532 binds HeadID to `coordinator_id`. iOS sends `head_id`,
        // which this server reads as an empty coordinator and rejects.
        val encoded = json.encodeToString(
            CreateOrchRequest(name = "o1", coordinatorId = "d1", workerIds = listOf("d2", "d3"))
        )
        assertTrue(encoded, encoded.contains("\"coordinator_id\":\"d1\""))
        assertTrue(encoded, encoded.contains("\"worker_ids\":[\"d2\",\"d3\"]"))
        assertTrue("must not send head_id", !encoded.contains("head_id"))
    }

    @Test
    fun `execute request uses timeout_seconds`() {
        val encoded = json.encodeToString(ExecuteRequest(command = "uptime", timeoutSeconds = 30))
        assertTrue(encoded, encoded.contains("\"timeout_seconds\":30"))
    }

    @Test
    fun `orch execute response decodes its snake_case wrapper`() {
        val r = json.decodeFromString<OrchExecuteResponse>(
            """{"orch_id":"o1","command":"uptime","worker_count":2,
               "results":[{"deviceId":"d1","deviceName":"high15","gpu":"",
                           "output":"ok","durationMs":12.5}]}"""
        )
        assertEquals("o1", r.orchId)
        assertEquals(2, r.workerCount)
        assertEquals("high15", r.results.single().deviceName)
        assertEquals(12.5, r.results.single().durationMs, 0.001)
    }

    @Test
    fun `processes response mixes a snake wrapper with camel bodies`() {
        val r = json.decodeFromString<OrchProcessesResponse>(
            """{"orch_id":"o1","timestamp":"2026-09-04T10:00:00Z","worker_count":1,
               "workers":[{"deviceId":"d1","deviceName":"high15","gpu":"RTX 4090",
                 "processes":[{"pid":"4242","processName":"python","cpuPercent":12.0,
                               "memPercent":3.5,"vramMB":2048,"command":"train.py",
                               "isGpu":true}]}]}"""
        )
        val worker = r.workers.single()
        assertEquals("d1", worker.deviceId)
        // pid is a string on the wire (handler.go:2170), not an int.
        assertEquals("4242", worker.processes.single().pid)
        assertTrue(worker.processes.single().isGpu)
    }

    @Test
    fun `a worker with an error and no processes still decodes`() {
        val r = json.decodeFromString<OrchProcessesResponse>(
            """{"orch_id":"o1","timestamp":"2026-09-04T10:00:00Z","worker_count":1,
               "workers":[{"deviceId":"d1","deviceName":"x","error":"unreachable"}]}"""
        )
        val w = r.workers.single()
        assertTrue(w.hasError)
        assertTrue(w.processes.isEmpty())
    }

    @Test
    fun `orch health decodes camelCase throughout`() {
        val h = json.decodeFromString<OrchHealth>(
            """{"orchId":"o1","name":"ray","status":"running",
               "nodes":[{"nodeId":"d1","role":"head","healthy":true},
                        {"nodeId":"d2","role":"worker","healthy":false,"error":"down"}]}"""
        )
        assertEquals("o1", h.orchId)
        assertEquals(2, h.nodes.size)
        assertEquals("down", h.nodes[1].error)
    }

    @Test
    fun `a task result without an error is not an error`() {
        val t = json.decodeFromString<TaskResult>(
            """{"deviceId":"d1","deviceName":"x","gpu":"","output":"hi","durationMs":1.0}"""
        )
        assertTrue(!t.hasError)
    }
}
```

`SavedTaskSerializationTest.kt`:

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SavedTaskSerializationTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val t0 = Instant.parse("2026-09-04T10:00:00Z")

    @Test
    fun `round-trips with defaults`() {
        val task = SavedTask(id = "t1", name = "uptime", command = "uptime", createdAt = t0)
        val decoded = json.decodeFromString<SavedTask>(json.encodeToString(task))
        assertEquals(task, decoded)
        assertEquals(30, decoded.timeout)
        assertEquals(TaskPriority.NORMAL, decoded.priority)
        assertNull(decoded.targetDeviceId)
    }

    @Test
    fun `carries no schedule field`() {
        // The scheduler is out of scope, so the field does not exist: an unused
        // field would accumulate data no UI shows and become a migration problem.
        val encoded = json.encodeToString(
            SavedTask(id = "t1", name = "n", command = "c", createdAt = t0)
        )
        assertTrue(encoded, !encoded.contains("schedule"))
    }

    @Test
    fun `a stored run result survives a round trip`() {
        val task = SavedTask(
            id = "t1", name = "n", command = "c", createdAt = t0,
            lastRunAt = t0, lastRunStatus = "success",
        )
        val decoded = json.decodeFromString<SavedTask>(json.encodeToString(task))
        assertEquals("success", decoded.lastRunStatus)
        assertEquals(t0, decoded.lastRunAt)
    }

    @Test
    fun `an unknown priority in a stored file does not crash the decode`() {
        // Written by a future version; ignoreUnknownKeys does not cover enums,
        // so the store must not hand us a value the enum cannot represent.
        val result = runCatching {
            json.decodeFromString<SavedTask>(
                """{"id":"t1","name":"n","command":"c","priority":"COSMIC",
                   "createdAt":"2026-09-04T10:00:00Z"}"""
            )
        }
        assertTrue("expected a failure the store can catch", result.isFailure)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:model:testDebugUnitTest
```

Expected: FAIL — unresolved `CreateOrchRequest`, `OrchExecuteResponse`, `SavedTask`, and friends.

- [ ] **Step 3: Write `OrchDetail.kt`**

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The server binds the coordinator to `coordinator_id` (handler.go:532).
 * iOS sends `head_id`, which this server reads as empty and rejects — do not
 * copy iOS here.
 */
@Serializable
data class CreateOrchRequest(
    val name: String,
    @SerialName("coordinator_id") val coordinatorId: String,
    @SerialName("worker_ids") val workerIds: List<String>,
)

@Serializable
data class ExecuteRequest(
    val command: String,
    /** Server clamps to 1–300 and defaults to 30 (handler.go:1699-1714). */
    @SerialName("timeout_seconds") val timeoutSeconds: Int = 30,
)

@Serializable
data class TaskResult(
    val deviceId: String,
    val deviceName: String = "",
    val gpu: String = "",
    val output: String = "",
    val error: String? = null,
    val durationMs: Double = 0.0,
) {
    val hasError: Boolean get() = !error.isNullOrEmpty()
}

/** Wrapper is snake_case; the results inside are camelCase. */
@Serializable
data class OrchExecuteResponse(
    @SerialName("orch_id") val orchId: String,
    val command: String = "",
    @SerialName("worker_count") val workerCount: Int = 0,
    val results: List<TaskResult> = emptyList(),
)

@Serializable
data class OrchHealth(
    val orchId: String,
    val name: String = "",
    val status: String = "",
    val nodes: List<OrchNodeStatus> = emptyList(),
)

@Serializable
data class OrchNodeStatus(
    val nodeId: String,
    val role: String = "",
    val healthy: Boolean = false,
    val error: String? = null,
)

@Serializable
data class OrchProcessesResponse(
    @SerialName("orch_id") val orchId: String,
    @Serializable(with = InstantSerializer::class) val timestamp: Instant,
    @SerialName("worker_count") val workerCount: Int = 0,
    val workers: List<WorkerStatus> = emptyList(),
)

@Serializable
data class WorkerStatus(
    val deviceId: String,
    val deviceName: String = "",
    val gpu: String? = null,
    val processes: List<WorkerProcess> = emptyList(),
    val error: String? = null,
) {
    val hasError: Boolean get() = !error.isNullOrEmpty()
    val shortName: String get() = deviceName.substringBefore('.').ifEmpty { deviceId }
    val gpuProcesses: List<WorkerProcess> get() = processes.filter { it.isGpu }
}

@Serializable
data class WorkerProcess(
    /** A string on the wire (handler.go:2170), not an int. */
    val pid: String,
    val processName: String = "",
    val cpuPercent: Double = 0.0,
    val memPercent: Double = 0.0,
    val vramMB: Int = 0,
    val command: String = "",
    val isGpu: Boolean = false,
)
```

- [ ] **Step 4: Write `SavedTask.kt`**

```kotlin
package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

/**
 * A reusable command template stored on the device. Deliberately NOT the
 * server's `/api/tasks` queue — that is a different thing with the same name.
 *
 * There is no `schedule` field: the scheduler is out of scope for this cycle,
 * and a field no UI shows would only accumulate data and become a migration
 * problem. Add it when the scheduler arrives.
 */
@Serializable
data class SavedTask(
    val id: String,
    val name: String,
    val command: String,
    /** null = ask which device when the task is run. */
    val targetDeviceId: String? = null,
    val targetDeviceName: String? = null,
    val timeout: Int = 30,
    val priority: TaskPriority = TaskPriority.NORMAL,
    @Serializable(with = InstantSerializer::class) val lastRunAt: Instant? = null,
    val lastRunStatus: String? = null,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant,
)

enum class TaskPriority { LOW, NORMAL, HIGH, URGENT }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:model:testDebugUnitTest
```

Expected: PASS — 11 new tests on top of the existing 11.

- [ ] **Step 6: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/model
git commit -m "feat(android): orch 상세/실행 모델 + 로컬 저장 태스크 모델"
```

---

### Task 2: `:core:network` — the six new endpoints

**Files:**
- Modify: `android/core/network/src/main/kotlin/com/hydra/android/core/network/HydraApi.kt`
- Test: `android/core/network/src/test/kotlin/com/hydra/android/core/network/OrchApiTest.kt`

**Interfaces:**
- Consumes: Task 1's models.
- Produces: `HydraApi.createOrch`, `deleteOrch`, `orchHealth`, `orchProcesses`, `executeOnOrch`, `executeOnDevice`.

- [ ] **Step 1: Write the failing API tests**

```kotlin
package com.hydra.android.core.network

import com.hydra.android.core.model.CreateOrchRequest
import com.hydra.android.core.model.ExecuteRequest
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class OrchApiTest {
    private lateinit var server: MockWebServer
    private lateinit var api: HydraApi

    @Before
    fun setUp() {
        server = MockWebServer().also { it.start() }
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
        api = Retrofit.Builder()
            .baseUrl(server.url("/"))
            .client(OkHttpClient())
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(HydraApi::class.java)
    }

    @After
    fun tearDown() = server.shutdown()

    @Test
    fun `createOrch posts coordinator_id`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"id":"o1","name":"ray","status":"starting","coordinatorId":"d1",
                   "workerIds":["d2"],"createdAt":"2026-09-04T10:00:00Z",
                   "updatedAt":"2026-09-04T10:00:00Z"}"""
            )
        )
        api.createOrch(CreateOrchRequest("ray", "d1", listOf("d2")))
        val recorded = server.takeRequest()
        assertEquals("POST", recorded.method)
        assertEquals("/api/orchs", recorded.path)
        val body = recorded.body.readUtf8()
        assertTrue(body, body.contains("\"coordinator_id\":\"d1\""))
    }

    @Test
    fun `deleteOrch sends force when asked`() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        api.deleteOrch("o1", force = true)
        assertEquals("/api/orchs/o1?force=true", server.takeRequest().path)
    }

    @Test
    fun `deleteOrch omits force when not asked`() = runTest {
        server.enqueue(MockResponse().setResponseCode(204))
        api.deleteOrch("o1", force = null)
        assertEquals("/api/orchs/o1", server.takeRequest().path)
    }

    @Test
    fun `orchHealth decodes nodes`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"orchId":"o1","name":"ray","status":"running",
                   "nodes":[{"nodeId":"d1","role":"head","healthy":true}]}"""
            )
        )
        val h = api.orchHealth("o1")
        assertEquals("/api/orchs/o1/health", server.takeRequest().path)
        assertEquals("d1", h.nodes.single().nodeId)
    }

    @Test
    fun `orchProcesses decodes the mixed-case payload`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"orch_id":"o1","timestamp":"2026-09-04T10:00:00Z","worker_count":1,
                   "workers":[{"deviceId":"d1","deviceName":"high15",
                     "processes":[{"pid":"1","processName":"py","isGpu":false}]}]}"""
            )
        )
        val p = api.orchProcesses("o1")
        assertEquals("/api/orchs/o1/processes", server.takeRequest().path)
        assertEquals("1", p.workers.single().processes.single().pid)
    }

    @Test
    fun `executeOnOrch posts the command and timeout`() = runTest {
        server.enqueue(
            MockResponse().setBody("""{"orch_id":"o1","command":"uptime","worker_count":0,"results":[]}""")
        )
        api.executeOnOrch("o1", ExecuteRequest("uptime", 45))
        val recorded = server.takeRequest()
        assertEquals("/api/orchs/o1/execute", recorded.path)
        val body = recorded.body.readUtf8()
        assertTrue(body, body.contains("\"timeout_seconds\":45"))
    }

    @Test
    fun `executeOnDevice returns a single result`() = runTest {
        server.enqueue(
            MockResponse().setBody(
                """{"deviceId":"d1","deviceName":"high15","gpu":"","output":"ok","durationMs":9.0}"""
            )
        )
        val r = api.executeOnDevice("d1", ExecuteRequest("uptime"))
        assertEquals("/api/devices/d1/execute", server.takeRequest().path)
        assertEquals("ok", r.output)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:network:testDebugUnitTest --tests '*OrchApiTest*'
```

Expected: FAIL — `createOrch` and the rest are undefined.

- [ ] **Step 3: Add the endpoints to `HydraApi`**

Append inside the interface, and add the imports for the new model types:

```kotlin
    @POST("api/orchs")
    suspend fun createOrch(@Body body: CreateOrchRequest): Orch

    /** `force` is a query param; a null value is omitted by Retrofit. */
    @DELETE("api/orchs/{id}")
    suspend fun deleteOrch(
        @Path("id") id: String,
        @Query("force") force: Boolean? = null,
    )

    @GET("api/orchs/{id}/health")
    suspend fun orchHealth(@Path("id") id: String): OrchHealth

    @GET("api/orchs/{id}/processes")
    suspend fun orchProcesses(@Path("id") id: String): OrchProcessesResponse

    @POST("api/orchs/{id}/execute")
    suspend fun executeOnOrch(
        @Path("id") id: String,
        @Body body: ExecuteRequest,
    ): OrchExecuteResponse

    /**
     * Dropped in v1 along with Quick Command; the Tasks tab brings it back.
     */
    @POST("api/devices/{id}/execute")
    suspend fun executeOnDevice(
        @Path("id") id: String,
        @Body body: ExecuteRequest,
    ): TaskResult
```

Imports to add: `retrofit2.http.DELETE`, `retrofit2.http.Path`, and the model types `CreateOrchRequest`, `ExecuteRequest`, `OrchExecuteResponse`, `OrchHealth`, `OrchProcessesResponse`, `TaskResult`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:network:testDebugUnitTest
```

Expected: PASS — 7 new tests on top of the existing 21.

- [ ] **Step 5: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/network
git commit -m "feat(android): orch 생성/삭제/헬스/프로세스/실행 + 디바이스 실행 엔드포인트"
```

---

### Task 3: `:core:data` — `OrchRepository`

**Files:**
- Create: `android/core/data/src/main/kotlin/com/hydra/android/core/data/OrchRepository.kt`
- Modify: `android/core/data/src/main/kotlin/com/hydra/android/core/data/DataModule.kt`
- Test: `android/core/data/src/test/kotlin/com/hydra/android/core/data/OrchRepositoryTest.kt`

**Interfaces:**
- Consumes: `HydraApi` (Task 2), `apiCall` (existing in `:core:network`).
- Produces: `open class OrchRepository` with `list()`, `create(name, coordinatorId, workerIds)`, `delete(id)`, `health(id)`, `processes(id)`, `execute(id, command, timeout)` — all returning `Result<T>`.

- [ ] **Step 1: Write the failing repository tests**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.*
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.test.runTest
import kotlinx.datetime.Instant
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response
import java.io.IOException

private val T0 = Instant.parse("2026-09-04T10:00:00Z")

private fun orch(id: String) =
    Orch(id = id, name = id, status = "running", createdAt = T0, updatedAt = T0)

private open class OrchFakeApi : HydraApi {
    var lastCreate: CreateOrchRequest? = null
    var lastDeleteForce: Boolean? = null
    var lastExecute: ExecuteRequest? = null

    override suspend fun health() = throw UnsupportedOperationException()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun listOrchs(): List<Orch> = listOf(orch("o1"))
    override suspend fun listTasks() = throw UnsupportedOperationException()
    override suspend fun gpuMonitor() = throw UnsupportedOperationException()
    override suspend fun metricsSnapshot() = throw UnsupportedOperationException()
    override suspend fun chat(body: ChatRequest) = throw UnsupportedOperationException()
    override suspend fun execute(body: AgentExecuteRequest) = throw UnsupportedOperationException()
    override suspend fun createOrch(body: CreateOrchRequest): Orch {
        lastCreate = body
        return orch("o-new")
    }
    override suspend fun deleteOrch(id: String, force: Boolean?) { lastDeleteForce = force }
    override suspend fun orchHealth(id: String) = OrchHealth(orchId = id)
    override suspend fun orchProcesses(id: String) =
        OrchProcessesResponse(orchId = id, timestamp = T0)
    override suspend fun executeOnOrch(id: String, body: ExecuteRequest): OrchExecuteResponse {
        lastExecute = body
        return OrchExecuteResponse(orchId = id)
    }
    override suspend fun executeOnDevice(id: String, body: ExecuteRequest) =
        TaskResult(deviceId = id)
}

class OrchRepositoryTest {

    @Test
    fun `list returns the orchs`() = runTest {
        val result = OrchRepository(OrchFakeApi()).list()
        assertEquals("o1", result.getOrNull()?.single()?.id)
    }

    @Test
    fun `create sends the coordinator and workers`() = runTest {
        val api = OrchFakeApi()
        OrchRepository(api).create("ray", "d1", listOf("d2", "d3"))
        assertEquals("d1", api.lastCreate?.coordinatorId)
        assertEquals(listOf("d2", "d3"), api.lastCreate?.workerIds)
    }

    @Test
    fun `delete always forces, matching iOS`() = runTest {
        val api = OrchFakeApi()
        OrchRepository(api).delete("o1")
        assertEquals(true, api.lastDeleteForce)
    }

    @Test
    fun `execute passes the timeout through`() = runTest {
        val api = OrchFakeApi()
        OrchRepository(api).execute("o1", "uptime", timeout = 45)
        assertEquals(45, api.lastExecute?.timeoutSeconds)
    }

    @Test
    fun `a network failure comes back as a failed Result, not an exception`() = runTest {
        val api = object : OrchFakeApi() {
            override suspend fun listOrchs(): List<Orch> = throw IOException("down")
        }
        val result = OrchRepository(api).list()
        assertTrue(result.isFailure)
        assertEquals("서버에 연결할 수 없습니다", result.exceptionOrNull()?.message)
    }

    @Test
    fun `a server error body surfaces its message`() = runTest {
        val api = object : OrchFakeApi() {
            override suspend fun deleteOrch(id: String, force: Boolean?) {
                throw HttpException(
                    Response.error<Any>(
                        409,
                        """{"error":"orch is running"}"""
                            .toResponseBody("application/json".toMediaType()),
                    )
                )
            }
        }
        val result = OrchRepository(api).delete("o1")
        assertEquals("orch is running", result.exceptionOrNull()?.message)
        assertNull(result.getOrNull())
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest --tests '*OrchRepositoryTest*'
```

Expected: FAIL — unresolved reference `OrchRepository`.

- [ ] **Step 3: Write `OrchRepository`**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.CreateOrchRequest
import com.hydra.android.core.model.ExecuteRequest
import com.hydra.android.core.model.Orch
import com.hydra.android.core.model.OrchExecuteResponse
import com.hydra.android.core.model.OrchHealth
import com.hydra.android.core.model.OrchProcessesResponse
import com.hydra.android.core.network.HydraApi
import com.hydra.android.core.network.apiCall
import javax.inject.Inject
import javax.inject.Singleton

/**
 * The orch REST surface, with failures as values rather than exceptions —
 * the same convention as DashboardRepository. Open so ViewModel tests can
 * substitute a recording subclass.
 */
@Singleton
open class OrchRepository @Inject constructor(
    private val api: HydraApi,
) {
    open suspend fun list(): Result<List<Orch>> = apiCall { api.listOrchs() }

    open suspend fun create(
        name: String,
        coordinatorId: String,
        workerIds: List<String>,
    ): Result<Orch> = apiCall {
        api.createOrch(CreateOrchRequest(name, coordinatorId, workerIds))
    }

    /** Always forced, matching iOS `deleteOrch(id:force:)` at its only call site. */
    open suspend fun delete(id: String): Result<Unit> = apiCall { api.deleteOrch(id, force = true) }

    open suspend fun health(id: String): Result<OrchHealth> = apiCall { api.orchHealth(id) }

    open suspend fun processes(id: String): Result<OrchProcessesResponse> =
        apiCall { api.orchProcesses(id) }

    open suspend fun execute(
        id: String,
        command: String,
        timeout: Int = 30,
    ): Result<OrchExecuteResponse> = apiCall {
        api.executeOnOrch(id, ExecuteRequest(command, timeout))
    }
}
```

Add to `DataModule`:

```kotlin
    @Provides
    @Singleton
    fun provideOrchRepository(api: com.hydra.android.core.network.HydraApi): OrchRepository =
        OrchRepository(api)
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest
```

Expected: PASS — 6 new tests on top of the existing 24.

- [ ] **Step 5: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data
git commit -m "feat(android): OrchRepository — 다섯 개 orch 호출을 Result로"
```

---

### Task 4: `:core:data` — `SavedTaskStore`

**Files:**
- Create: `android/core/data/src/main/kotlin/com/hydra/android/core/data/SavedTaskStore.kt`
- Modify: `android/core/data/src/main/kotlin/com/hydra/android/core/data/DataModule.kt`
- Test: `android/core/data/src/test/kotlin/com/hydra/android/core/data/SavedTaskStoreTest.kt`

**Interfaces:**
- Consumes: `SavedTask`, `TaskPriority` (Task 1).
- Produces: `class SavedTaskStore(file: File)` with `val tasks: StateFlow<List<SavedTask>>`, `add(task)`, `update(task)`, `delete(id)`, `recordRun(id, status, at)`.

- [ ] **Step 1: Write the failing store tests**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.SavedTask
import com.hydra.android.core.model.TaskPriority
import kotlinx.datetime.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

private val T0 = Instant.parse("2026-09-04T10:00:00Z")

private fun task(id: String, name: String = id) =
    SavedTask(id = id, name = name, command = "uptime", createdAt = T0)

class SavedTaskStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun store(seed: String? = null): Pair<SavedTaskStore, File> {
        val f = File(temp.root, "saved_tasks.json")
        if (seed != null) f.writeText(seed)
        return SavedTaskStore(f) to f
    }

    @Test
    fun `a missing file starts empty`() {
        val (s, _) = store()
        assertTrue(s.tasks.value.isEmpty())
    }

    @Test
    fun `add persists and is readable by a fresh store`() {
        val (s, f) = store()
        s.add(task("t1", "uptime check"))
        assertEquals(1, s.tasks.value.size)
        assertEquals("uptime check", SavedTaskStore(f).tasks.value.single().name)
    }

    @Test
    fun `update replaces by id and keeps order`() {
        val (s, _) = store()
        s.add(task("t1"))
        s.add(task("t2"))
        s.update(task("t1", "renamed"))
        assertEquals(listOf("renamed", "t2"), s.tasks.value.map { it.name })
    }

    @Test
    fun `update of an unknown id is a no-op rather than an insert`() {
        val (s, _) = store()
        s.add(task("t1"))
        s.update(task("ghost"))
        assertEquals(listOf("t1"), s.tasks.value.map { it.id })
    }

    @Test
    fun `delete removes and persists`() {
        val (s, f) = store()
        s.add(task("t1"))
        s.add(task("t2"))
        s.delete("t1")
        assertEquals(listOf("t2"), SavedTaskStore(f).tasks.value.map { it.id })
    }

    @Test
    fun `recordRun stamps status and time`() {
        val (s, f) = store()
        s.add(task("t1"))
        s.recordRun("t1", status = "success", at = T0)
        val stored = SavedTaskStore(f).tasks.value.single()
        assertEquals("success", stored.lastRunStatus)
        assertEquals(T0, stored.lastRunAt)
    }

    @Test
    fun `a malformed file reads as empty rather than throwing`() {
        // A corrupt store must not make the tab unopenable.
        val (s, _) = store(seed = "{ this is not json")
        assertTrue(s.tasks.value.isEmpty())
    }

    @Test
    fun `a file with an unrepresentable enum reads as empty`() {
        val (s, _) = store(
            seed = """[{"id":"t1","name":"n","command":"c","priority":"COSMIC",
                        "createdAt":"2026-09-04T10:00:00Z"}]"""
        )
        assertTrue(s.tasks.value.isEmpty())
    }

    @Test
    fun `writing over a malformed file recovers it`() {
        val (s, f) = store(seed = "garbage")
        s.add(task("t1"))
        assertEquals(listOf("t1"), SavedTaskStore(f).tasks.value.map { it.id })
    }

    @Test
    fun `priority round-trips`() {
        val (s, f) = store()
        s.add(task("t1").copy(priority = TaskPriority.URGENT))
        assertEquals(TaskPriority.URGENT, SavedTaskStore(f).tasks.value.single().priority)
    }

    @Test
    fun `a task with no target device keeps a null target`() {
        val (s, f) = store()
        s.add(task("t1"))
        assertNull(SavedTaskStore(f).tasks.value.single().targetDeviceId)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest --tests '*SavedTaskStoreTest*'
```

Expected: FAIL — unresolved reference `SavedTaskStore`.

- [ ] **Step 3: Write `SavedTaskStore`**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.SavedTask
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Saved command templates, persisted as one JSON document in an app-private
 * file — the same shape as KnownHostsStore.
 *
 * Reads never throw: a malformed or truncated file yields an empty list. A
 * corrupt store must not make the tab unopenable, and the next write repairs
 * the file.
 */
class SavedTaskStore(private val file: File) {

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    private val _tasks = MutableStateFlow(read())
    val tasks: StateFlow<List<SavedTask>> = _tasks.asStateFlow()

    fun add(task: SavedTask) = mutate { it + task }

    /** No-op for an unknown id: an edit must never silently become an insert. */
    fun update(task: SavedTask) = mutate { list ->
        if (list.none { it.id == task.id }) list
        else list.map { if (it.id == task.id) task else it }
    }

    fun delete(id: String) = mutate { list -> list.filterNot { it.id == id } }

    fun recordRun(id: String, status: String, at: Instant) = mutate { list ->
        list.map { if (it.id == id) it.copy(lastRunStatus = status, lastRunAt = at) else it }
    }

    private fun mutate(block: (List<SavedTask>) -> List<SavedTask>) {
        val next = block(_tasks.value)
        _tasks.value = next
        write(next)
    }

    private fun read(): List<SavedTask> {
        if (!file.exists()) return emptyList()
        return runCatching { json.decodeFromString<List<SavedTask>>(file.readText()) }
            .getOrDefault(emptyList())
    }

    private fun write(list: List<SavedTask>) {
        file.parentFile?.mkdirs()
        file.writeText(json.encodeToString(list))
    }
}
```

Add to `DataModule`:

```kotlin
    @Provides
    @Singleton
    fun provideSavedTaskStore(@ApplicationContext context: Context): SavedTaskStore =
        SavedTaskStore(java.io.File(context.filesDir, "saved_tasks.json"))
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest
```

Expected: PASS — 11 new tests on top of the 30 from Task 3.

- [ ] **Step 5: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data
git commit -m "feat(android): SavedTaskStore — 로컬 명령 템플릿 JSON 파일 저장"
```

---

### Task 5: `:feature:orchs` — list, create, and delete

**Files:**
- Create: `android/feature/orchs/build.gradle.kts`
- Create: `.../feature/orchs/OrchsViewModel.kt`, `OrchsScreen.kt`, `CreateOrchViewModel.kt`, `CreateOrchScreen.kt`, `OrchsNavigation.kt`
- Modify: `android/settings.gradle.kts`
- Test: `android/feature/orchs/src/test/kotlin/.../OrchsViewModelTest.kt`, `CreateOrchViewModelTest.kt`

**Interfaces:**
- Consumes: `OrchRepository` (Task 3), `DevicesRepository` (existing).
- Produces: `ORCHS_ROUTE`, `CREATE_ORCH_ROUTE`, `fun NavGraphBuilder.orchsScreens(onOpenDetail: (String) -> Unit, onOpenCreate: () -> Unit, onBack: () -> Unit)`.

- [ ] **Step 1: Register the module**

In `android/settings.gradle.kts`, extend the feature include:

```kotlin
include(":feature:dashboard", ":feature:chat", ":feature:settings", ":feature:devices", ":feature:terminal", ":feature:orchs", ":feature:tasks")
```

`android/feature/orchs/build.gradle.kts` — same block as `:feature:devices`, with `android { namespace = "com.hydra.android.feature.orchs" }` and additionally `implementation(libs.kotlinx.datetime)`.

Create `android/feature/tasks/build.gradle.kts` the same way (namespace `com.hydra.android.feature.tasks`) so configuration succeeds; Task 7 fills it in.

- [ ] **Step 2: Write the failing ViewModel tests**

```kotlin
package com.hydra.android.feature.orchs

import app.cash.turbine.test
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.Orch
import com.hydra.android.core.network.ApiException
import com.hydra.android.core.network.HydraApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private val T0 = Instant.parse("2026-09-04T10:00:00Z")

private fun orch(id: String, status: String = "running") =
    Orch(id = id, name = id, status = status, createdAt = T0, updatedAt = T0)

private object UnusedApi : HydraApi {
    override suspend fun health() = throw UnsupportedOperationException()
    override suspend fun listDevices(refresh: Boolean?, includeMobile: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun listOrchs() = throw UnsupportedOperationException()
    override suspend fun listTasks() = throw UnsupportedOperationException()
    override suspend fun gpuMonitor() = throw UnsupportedOperationException()
    override suspend fun metricsSnapshot() = throw UnsupportedOperationException()
    override suspend fun chat(body: com.hydra.android.core.model.ChatRequest) =
        throw UnsupportedOperationException()
    override suspend fun execute(body: com.hydra.android.core.model.AgentExecuteRequest) =
        throw UnsupportedOperationException()
    override suspend fun createOrch(body: com.hydra.android.core.model.CreateOrchRequest) =
        throw UnsupportedOperationException()
    override suspend fun deleteOrch(id: String, force: Boolean?) =
        throw UnsupportedOperationException()
    override suspend fun orchHealth(id: String) = throw UnsupportedOperationException()
    override suspend fun orchProcesses(id: String) = throw UnsupportedOperationException()
    override suspend fun executeOnOrch(id: String, body: com.hydra.android.core.model.ExecuteRequest) =
        throw UnsupportedOperationException()
    override suspend fun executeOnDevice(id: String, body: com.hydra.android.core.model.ExecuteRequest) =
        throw UnsupportedOperationException()
}

private class FakeOrchRepo(
    private var listResult: Result<List<Orch>> = Result.success(listOf(orch("o1"), orch("o2"))),
    private val deleteResult: Result<Unit> = Result.success(Unit),
) : OrchRepository(api = UnusedApi) {
    var listCalls = 0
    var deletedId: String? = null
    override suspend fun list(): Result<List<Orch>> { listCalls++; return listResult }
    override suspend fun delete(id: String): Result<Unit> { deletedId = id; return deleteResult }
    fun setList(result: Result<List<Orch>>) { listResult = result }
}

@OptIn(ExperimentalCoroutinesApi::class)
class OrchsViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `loads orchs on first subscription`() = runTest {
        val vm = OrchsViewModel(FakeOrchRepo())
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals(2, s.orchs.size)
            assertNull(s.error)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a failure surfaces the message and leaves the list empty`() = runTest {
        val repo = FakeOrchRepo(listResult = Result.failure(ApiException(null, "서버에 연결할 수 없습니다")))
        val vm = OrchsViewModel(repo)
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals("서버에 연결할 수 없습니다", s.error)
            assertTrue(s.orchs.isEmpty())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a successful delete reloads the list`() = runTest {
        val repo = FakeOrchRepo()
        val vm = OrchsViewModel(repo)
        vm.state.test {
            awaitItem(); advanceUntilIdle()
            val before = repo.listCalls
            vm.delete("o1"); advanceUntilIdle()
            assertEquals("o1", repo.deletedId)
            assertTrue("delete should trigger a reload", repo.listCalls > before)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a failed delete shows the error and does not remove the row`() = runTest {
        // No optimistic removal: a row that vanishes and reappears is worse
        // than one that never moved.
        val repo = FakeOrchRepo(deleteResult = Result.failure(ApiException(409, "orch is running")))
        val vm = OrchsViewModel(repo)
        vm.state.test {
            awaitItem(); advanceUntilIdle()
            vm.delete("o1"); advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals("orch is running", s.error)
            assertEquals(2, s.orchs.size)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `refresh reloads`() = runTest {
        val repo = FakeOrchRepo()
        val vm = OrchsViewModel(repo)
        vm.state.test {
            awaitItem(); advanceUntilIdle()
            val before = repo.listCalls
            vm.refresh(); advanceUntilIdle()
            assertTrue(repo.listCalls > before)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

`CreateOrchViewModelTest.kt`:

```kotlin
package com.hydra.android.feature.orchs

import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.Orch
import com.hydra.android.core.network.ApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private val D0 = Instant.parse("2026-09-04T10:00:00Z")

private fun device(id: String, online: Boolean = true) =
    Device(id = id, hostname = id, status = if (online) "online" else "offline", lastSeen = D0)

private class CreateFakeRepo(
    private val result: Result<Orch> = Result.success(
        Orch(id = "o-new", name = "ray", status = "starting", createdAt = D0, updatedAt = D0)
    ),
) : OrchRepository(api = UnusedApi) {
    var created: Triple<String, String, List<String>>? = null
    override suspend fun create(
        name: String,
        coordinatorId: String,
        workerIds: List<String>,
    ): Result<Orch> {
        created = Triple(name, coordinatorId, workerIds)
        return result
    }
}

private class CreateFakeDevices(private val devices: List<Device>) : DevicesRepository {
    override suspend fun list(): Result<List<Device>> = Result.success(devices)
}

@OptIn(ExperimentalCoroutinesApi::class)
class CreateOrchViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(
        repo: OrchRepository = CreateFakeRepo(),
        devices: List<Device> = listOf(device("d1"), device("d2"), device("d3", online = false)),
    ) = CreateOrchViewModel(repo, CreateFakeDevices(devices))

    @Test
    fun `only online devices are offered`() = runTest {
        val v = vm()
        advanceUntilIdle()
        assertEquals(listOf("d1", "d2"), v.state.value.devices.map { it.id })
    }

    @Test
    fun `create is disabled until name and coordinator are set`() = runTest {
        val v = vm(); advanceUntilIdle()
        assertFalse(v.state.value.canCreate)
        v.onNameChange("ray")
        assertFalse(v.state.value.canCreate)
        v.onCoordinatorChange("d1")
        assertTrue(v.state.value.canCreate)
    }

    @Test
    fun `selecting the coordinator removes it from the worker set`() = runTest {
        val v = vm(); advanceUntilIdle()
        v.toggleWorker("d1")
        v.onCoordinatorChange("d1")
        assertFalse(v.state.value.selectedWorkers.contains("d1"))
    }

    @Test
    fun `create sends name, coordinator and workers`() = runTest {
        val repo = CreateFakeRepo()
        val v = vm(repo); advanceUntilIdle()
        v.onNameChange("ray")
        v.onCoordinatorChange("d1")
        v.toggleWorker("d2")
        v.create(); advanceUntilIdle()
        assertEquals(Triple("ray", "d1", listOf("d2")), repo.created)
        assertTrue(v.state.value.created)
    }

    @Test
    fun `a failed create surfaces the error and does not report success`() = runTest {
        val repo = CreateFakeRepo(result = Result.failure(ApiException(400, "coordinator required")))
        val v = vm(repo); advanceUntilIdle()
        v.onNameChange("ray"); v.onCoordinatorChange("d1")
        v.create(); advanceUntilIdle()
        assertEquals("coordinator required", v.state.value.error)
        assertFalse(v.state.value.created)
    }
}
```

`UnusedApi` is declared in `OrchsViewModelTest.kt`; both test files are in the same package, so it is shared.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:orchs:testDebugUnitTest
```

Expected: FAIL — `OrchsViewModel` and `CreateOrchViewModel` are undefined.

- [ ] **Step 4: Write `OrchsViewModel`**

```kotlin
package com.hydra.android.feature.orchs

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.Orch
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.transformLatest
import kotlinx.coroutines.launch
import javax.inject.Inject

data class OrchsUiState(
    val orchs: List<Orch> = emptyList(),
    val isLoading: Boolean = true,
    val error: String? = null,
)

@HiltViewModel
class OrchsViewModel @Inject constructor(
    private val repository: OrchRepository,
) : ViewModel() {

    private val reloads = MutableSharedFlow<Unit>(
        replay = 0, extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /** Errors raised by an action (delete), kept separate from load errors. */
    private val actionError = MutableStateFlow<String?>(null)

    @OptIn(ExperimentalCoroutinesApi::class)
    private val loaded: StateFlow<OrchsUiState> = reloads
        .map { }
        .onStart { emit(Unit) }
        .transformLatest {
            val result = repository.list()
            emit(
                OrchsUiState(
                    orchs = result.getOrDefault(emptyList()),
                    isLoading = false,
                    error = result.exceptionOrNull()?.message,
                )
            )
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrchsUiState())

    val state: StateFlow<OrchsUiState> =
        combine(loaded, actionError) { base, action ->
            if (action == null) base else base.copy(error = action)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrchsUiState())

    fun refresh() {
        actionError.value = null
        reloads.tryEmit(Unit)
    }

    /**
     * The list is not touched until the server confirms. Removing the row
     * optimistically and putting it back on failure is a worse experience
     * than a row that simply does not move.
     */
    fun delete(id: String) {
        viewModelScope.launch {
            repository.delete(id).fold(
                onSuccess = {
                    actionError.value = null
                    reloads.tryEmit(Unit)
                },
                onFailure = { actionError.value = it.message },
            )
        }
    }
}
```

- [ ] **Step 5: Write `CreateOrchViewModel`**

```kotlin
package com.hydra.android.feature.orchs

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.Device
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class CreateOrchUiState(
    val name: String = "",
    val devices: List<Device> = emptyList(),
    val coordinatorId: String = "",
    val selectedWorkers: Set<String> = emptySet(),
    val isCreating: Boolean = false,
    val created: Boolean = false,
    val error: String? = null,
) {
    val canCreate: Boolean
        get() = name.isNotBlank() && coordinatorId.isNotEmpty() && !isCreating
}

@HiltViewModel
class CreateOrchViewModel @Inject constructor(
    private val orchs: OrchRepository,
    private val devices: DevicesRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(CreateOrchUiState())
    val state: StateFlow<CreateOrchUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            // Only online devices can join an orch, so only those are offered.
            val online = devices.list().getOrDefault(emptyList()).filter { it.isOnline }
            _state.update { it.copy(devices = online) }
        }
    }

    fun onNameChange(value: String) = _state.update { it.copy(name = value, error = null) }

    /** A device cannot be both coordinator and worker. */
    fun onCoordinatorChange(id: String) = _state.update {
        it.copy(coordinatorId = id, selectedWorkers = it.selectedWorkers - id, error = null)
    }

    fun toggleWorker(id: String) = _state.update {
        val next = if (id in it.selectedWorkers) it.selectedWorkers - id else it.selectedWorkers + id
        it.copy(selectedWorkers = next)
    }

    fun create() {
        val s = _state.value
        if (!s.canCreate) return
        _state.update { it.copy(isCreating = true, error = null) }
        viewModelScope.launch {
            orchs.create(s.name.trim(), s.coordinatorId, s.selectedWorkers.toList()).fold(
                onSuccess = { _state.update { st -> st.copy(isCreating = false, created = true) } },
                onFailure = { e ->
                    _state.update { st -> st.copy(isCreating = false, error = e.message) }
                },
            )
        }
    }
}
```

- [ ] **Step 6: Write the screens and navigation**

`OrchsScreen(onOpenDetail: (String) -> Unit, onOpenCreate: () -> Unit)` — a `Scaffold` titled "Orchs" with a `+` action calling `onOpenCreate`, over a `PullToRefreshBox` and `LazyColumn`:

- The error, when present, as the first item in `colorScheme.error`.
- One `HydraCard` per orch: name in `titleSmall`, `"${orch.workerCount} workers"` in `labelSmall`/`onSurfaceVariant`, and a trailing status capsule — text in `labelSmall` bold on a `tint.copy(alpha = 0.12f)` rounded background, tinted `running`→`HydraGreen`, `starting`→`HydraOrange`, `error`→`colorScheme.error`, else `onSurfaceVariant`.
- `Modifier.combinedClickable(onClick = { onOpenDetail(orch.id) }, onLongClick = { pendingDelete = orch })` — long press is the Android idiom where iOS swipes.
- When `pendingDelete != null`, an `AlertDialog` titled `"Orch을 삭제할까요?"`, text `"${orch.name} — 되돌릴 수 없습니다."`, confirm `"삭제"` in `colorScheme.error` calling `viewModel.delete(orch.id)`, dismiss `"취소"`.
- A centred `CircularProgressIndicator` while `isLoading && orchs.isEmpty()`.

`CreateOrchScreen(onDone: () -> Unit, onBack: () -> Unit)` — a `Scaffold` titled "새 Orchestration" with a back navigation icon and a `TextButton("생성", enabled = state.canCreate)` action, over a scrolling column:

- An `OutlinedTextField` for the name, **screen-owned buffer** as in `SettingsScreen`.
- "코디네이터" section: one `RadioButton` row per online device showing `shortName` and `tailscaleIp`.
- "워커" section: a `Checkbox` row per online device excluding the coordinator, with a purple `"${gpuCount}x ${gpuModel}"` badge when `hasGpu`.
- `state.error` below in `colorScheme.error`.
- `LaunchedEffect(state.created) { if (state.created) onDone() }`.

`OrchsNavigation.kt`:

```kotlin
package com.hydra.android.feature.orchs

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument

const val ORCHS_ROUTE = "orchs"
const val CREATE_ORCH_ROUTE = "orchs/create"
const val ORCH_DETAIL_ROUTE = "orchs/{orchId}"

fun orchDetailRoute(orchId: String) = "orchs/$orchId"

fun NavGraphBuilder.orchsScreens(
    onOpenDetail: (String) -> Unit,
    onOpenCreate: () -> Unit,
    onBack: () -> Unit,
) {
    composable(ORCHS_ROUTE) {
        OrchsScreen(onOpenDetail = onOpenDetail, onOpenCreate = onOpenCreate)
    }
    composable(CREATE_ORCH_ROUTE) {
        CreateOrchScreen(onDone = onBack, onBack = onBack)
    }
    composable(
        ORCH_DETAIL_ROUTE,
        arguments = listOf(navArgument("orchId") { type = NavType.StringType }),
    ) { entry ->
        OrchDetailScreen(
            orchId = entry.arguments?.getString("orchId").orEmpty(),
            onBack = onBack,
        )
    }
}
```

`OrchDetailScreen` arrives in Task 6; until then this file will not compile, so add a minimal placeholder composable in `OrchDetailScreen.kt` that Task 6 replaces:

```kotlin
package com.hydra.android.feature.orchs

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

@Composable
fun OrchDetailScreen(orchId: String, onBack: () -> Unit) {
    Text(orchId)
}
```

- [ ] **Step 7: Run the tests and build**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:orchs:testDebugUnitTest :feature:orchs:assembleDebug
```

Expected: PASS, 10 tests; `BUILD SUCCESSFUL`.

- [ ] **Step 8: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/settings.gradle.kts android/feature/orchs android/feature/tasks
git commit -m "feat(android): Orchs 탭 — 목록/생성/삭제"
```

---

### Task 6: `:feature:orchs` — the detail screen

**Files:**
- Create: `.../feature/orchs/OrchDetailViewModel.kt`
- Modify: `.../feature/orchs/OrchDetailScreen.kt` (replacing the Task 5 placeholder)
- Test: `android/feature/orchs/src/test/kotlin/.../OrchDetailViewModelTest.kt`

**Interfaces:**
- Consumes: `OrchRepository` (Task 3).
- Produces: `OrchDetailViewModel` with `state: StateFlow<OrchDetailUiState>`, `execute(command)`, `refresh()`.

- [ ] **Step 1: Write the failing tests**

```kotlin
package com.hydra.android.feature.orchs

import app.cash.turbine.test
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.*
import com.hydra.android.core.network.ApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

private val TS = Instant.parse("2026-09-04T10:00:00Z")

private class DetailFakeRepo(
    private val healthResult: Result<OrchHealth> =
        Result.success(OrchHealth(orchId = "o1", nodes = listOf(OrchNodeStatus("d1", "head", true)))),
    private val executeResult: Result<OrchExecuteResponse> =
        Result.success(OrchExecuteResponse(orchId = "o1", results = listOf(TaskResult("d1")))),
) : OrchRepository(api = UnusedApi) {
    var processCalls = 0
    var lastCommand: String? = null
    override suspend fun health(id: String) = healthResult
    override suspend fun processes(id: String): Result<OrchProcessesResponse> {
        processCalls++
        return Result.success(
            OrchProcessesResponse(
                orchId = id, timestamp = TS,
                workers = listOf(WorkerStatus(deviceId = "d1", deviceName = "high15.ts.net")),
            )
        )
    }
    override suspend fun execute(id: String, command: String, timeout: Int): Result<OrchExecuteResponse> {
        lastCommand = command
        return executeResult
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class OrchDetailViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `health and processes load on first subscription`() = runTest {
        val vm = OrchDetailViewModel(DetailFakeRepo(), "o1")
        vm.state.test {
            awaitItem()
            advanceUntilIdle()
            val s = expectMostRecentItem()
            assertEquals("d1", s.health?.nodes?.single()?.nodeId)
            assertEquals("high15", s.workers.single().shortName)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `processes poll on the interval while subscribed`() = runTest {
        val repo = DetailFakeRepo()
        val vm = OrchDetailViewModel(repo, "o1")
        vm.state.test {
            awaitItem(); awaitItem()
            advanceTimeBy(5_100)
            awaitItem()
            assertEquals(2, repo.processCalls)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `polling stops once nothing is subscribed`() = runTest {
        val repo = DetailFakeRepo()
        val vm = OrchDetailViewModel(repo, "o1")
        vm.state.test {
            awaitItem(); awaitItem()
            cancelAndIgnoreRemainingEvents()
        }
        val atUnsubscribe = repo.processCalls
        advanceTimeBy(30_000)
        assertTrue(
            "polling kept running: $atUnsubscribe -> ${repo.processCalls}",
            repo.processCalls - atUnsubscribe <= 1,
        )
    }

    @Test
    fun `execute records the result`() = runTest {
        val repo = DetailFakeRepo()
        val vm = OrchDetailViewModel(repo, "o1")
        vm.state.test {
            awaitItem(); advanceUntilIdle()
            vm.execute("uptime"); advanceUntilIdle()
            assertEquals("uptime", repo.lastCommand)
            assertEquals(1, expectMostRecentItem().executeResult?.results?.size)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a blank command does not reach the repository`() = runTest {
        val repo = DetailFakeRepo()
        val vm = OrchDetailViewModel(repo, "o1")
        vm.execute("   ")
        advanceUntilIdle()
        assertEquals(null, repo.lastCommand)
    }

    @Test
    fun `an execute failure surfaces the error`() = runTest {
        val repo = DetailFakeRepo(
            executeResult = Result.failure(ApiException(500, "orch not running"))
        )
        val vm = OrchDetailViewModel(repo, "o1")
        vm.state.test {
            awaitItem(); advanceUntilIdle()
            vm.execute("uptime"); advanceUntilIdle()
            assertEquals("orch not running", expectMostRecentItem().error)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:orchs:testDebugUnitTest --tests '*OrchDetailViewModelTest*'
```

Expected: FAIL — unresolved reference `OrchDetailViewModel`.

- [ ] **Step 3: Write `OrchDetailViewModel`**

```kotlin
package com.hydra.android.feature.orchs

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.OrchRepository
import com.hydra.android.core.model.OrchExecuteResponse
import com.hydra.android.core.model.OrchHealth
import com.hydra.android.core.model.WorkerStatus
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject
import kotlin.time.Duration.Companion.seconds

data class OrchDetailUiState(
    val health: OrchHealth? = null,
    val workers: List<WorkerStatus> = emptyList(),
    val isExecuting: Boolean = false,
    val executeResult: OrchExecuteResponse? = null,
    val error: String? = null,
)

@HiltViewModel
class OrchDetailViewModel @Inject constructor(
    private val repository: OrchRepository,
    private val orchId: String,
) : ViewModel() {

    /** Hilt supplies orchId from the route argument. */
    @Inject
    constructor(
        repository: OrchRepository,
        savedState: SavedStateHandle,
    ) : this(repository, savedState.get<String>("orchId").orEmpty())

    private val actions = MutableStateFlow(
        OrchDetailUiState()
    )

    /**
     * Health once, processes every five seconds. The delay sits after a
     * completed load, so a slow server cannot have each tick cancel the poll
     * in flight — the same shape the dashboard uses.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    private val polled: StateFlow<Pair<OrchHealth?, List<WorkerStatus>>> = flow {
        val health = repository.health(orchId).getOrNull()
        while (true) {
            val workers = repository.processes(orchId).getOrNull()?.workers.orEmpty()
            emit(health to workers)
            delay(POLL_INTERVAL)
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null to emptyList())

    val state: StateFlow<OrchDetailUiState> =
        combine(polled, actions) { (health, workers), action ->
            action.copy(health = health, workers = workers)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrchDetailUiState())

    fun execute(command: String) {
        val trimmed = command.trim()
        if (trimmed.isEmpty()) return
        actions.value = actions.value.copy(isExecuting = true, error = null, executeResult = null)
        viewModelScope.launch {
            repository.execute(orchId, trimmed).fold(
                onSuccess = { r ->
                    actions.value = actions.value.copy(isExecuting = false, executeResult = r)
                },
                onFailure = { e ->
                    actions.value = actions.value.copy(isExecuting = false, error = e.message)
                },
            )
        }
    }

    private companion object {
        val POLL_INTERVAL = 5.seconds
    }
}
```

If Hilt rejects the two-constructor shape, drop the primary `orchId` parameter and read it from `SavedStateHandle` in a single `@Inject constructor`, and have the test construct the ViewModel with `SavedStateHandle(mapOf("orchId" to "o1"))`. The tests are the gate — adjust them to whichever shape compiles, keeping the assertions identical.

- [ ] **Step 4: Write `OrchDetailScreen`**

Replace the Task 5 placeholder. A `Scaffold` titled by the orch id with a back icon, over a scrolling column of four blocks:

1. **Header** — status capsule using the same tint mapping as the list.
2. **Info grid** — two `HydraCard`s side by side: "Head Node" with `health.nodes.firstOrNull { it.role == "head" }?.nodeId ?: "-"`, and "Workers" with `state.workers.size`.
3. **Node health** — a `HydraCard` titled "노드 상태", one row per `health.nodes`: `StatusDot(node.healthy)`, `nodeId` in monospace `labelSmall`, `role` in `onSurfaceVariant`, and `node.error` in `colorScheme.error` when non-empty. Renders nothing when `health == null`.
4. **Execute** — a `HydraCard` titled "명령 실행" with a screen-owned `OutlinedTextField` and a `Button("실행", enabled = draft.isNotBlank() && !state.isExecuting)`. While executing, a `CircularProgressIndicator`. `state.executeResult` renders one row per `TaskResult`: `deviceName`, `"%.0fms".format(durationMs)`, and `output` in monospace `labelSmall` with `maxLines = 6`, or `error` in `colorScheme.error`.
5. **Workers** — a `HydraCard` titled "워커 프로세스", one section per `WorkerStatus`: `shortName`, `gpu` when present, then one row per process showing `processName`, `"PID ${pid}"`, `"%.0f%%".format(cpuPercent)`, and `"${vramMB}MB"` when `vramMB > 0`. A worker with `hasError` shows its `error` instead of rows.

`state.error` renders under the header in `colorScheme.error`.

- [ ] **Step 5: Run the tests and build**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:orchs:testDebugUnitTest :feature:orchs:assembleDebug
```

Expected: PASS, 16 tests total in the module; `BUILD SUCCESSFUL`.

- [ ] **Step 6: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/feature/orchs
git commit -m "feat(android): Orch 상세 — 헬스/명령 실행/워커 프로세스 5초 폴링"
```

---

### Task 7: `:feature:tasks` — list, editor, and run

**Files:**
- Modify: `android/feature/tasks/build.gradle.kts`
- Create: `.../feature/tasks/TasksViewModel.kt`, `TasksScreen.kt`, `TaskEditorScreen.kt`, `TasksNavigation.kt`
- Test: `android/feature/tasks/src/test/kotlin/.../TasksViewModelTest.kt`

**Interfaces:**
- Consumes: `SavedTaskStore` (Task 4), `DevicesRepository` (existing), `HydraApi.executeOnDevice` (Task 2).
- Produces: `TASKS_ROUTE`, `TASK_EDITOR_ROUTE`, `taskEditorRoute(id)`, `fun NavGraphBuilder.tasksScreens(onOpenEditor: (String?) -> Unit, onBack: () -> Unit)`.

- [ ] **Step 1: Write the module build file**

Same block as `:feature:orchs`, with `android { namespace = "com.hydra.android.feature.tasks" }`.

- [ ] **Step 2: Write the failing ViewModel tests**

```kotlin
package com.hydra.android.feature.tasks

import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.SavedTaskStore
import com.hydra.android.core.data.TaskRunner
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.SavedTask
import com.hydra.android.core.model.TaskResult
import com.hydra.android.core.network.ApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

private val T0 = Instant.parse("2026-09-04T10:00:00Z")

private fun task(id: String, target: String? = "d1") =
    SavedTask(id = id, name = id, command = "uptime", targetDeviceId = target, createdAt = T0)

private class FakeRunner(
    private val result: Result<TaskResult> = Result.success(TaskResult(deviceId = "d1", output = "ok")),
) : TaskRunner {
    var ranOn: String? = null
    override suspend fun run(deviceId: String, command: String, timeout: Int): Result<TaskResult> {
        ranOn = deviceId
        return result
    }
}

private class FakeDevices(private val devices: List<Device> = emptyList()) : DevicesRepository {
    override suspend fun list(): Result<List<Device>> = Result.success(devices)
}

@OptIn(ExperimentalCoroutinesApi::class)
class TasksViewModelTest {

    @get:Rule val temp = TemporaryFolder()

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun store() = SavedTaskStore(File(temp.root, "saved_tasks.json"))

    private fun vm(
        s: SavedTaskStore = store(),
        runner: FakeRunner = FakeRunner(),
    ) = TasksViewModel(s, runner, FakeDevices()) to runner

    @Test
    fun `the list reflects the store`() = runTest {
        val s = store()
        s.add(task("t1"))
        val (v, _) = vm(s)
        assertEquals(listOf("t1"), v.state.value.tasks.map { it.id })
    }

    @Test
    fun `save adds a new task and updates an existing one`() = runTest {
        val s = store()
        val (v, _) = vm(s)
        v.save(task("t1", target = "d1"))
        assertEquals(1, v.state.value.tasks.size)
        v.save(task("t1").copy(name = "renamed"))
        assertEquals(listOf("renamed"), v.state.value.tasks.map { it.name })
    }

    @Test
    fun `delete removes the task`() = runTest {
        val s = store(); s.add(task("t1"))
        val (v, _) = vm(s)
        v.delete("t1")
        assertTrue(v.state.value.tasks.isEmpty())
    }

    @Test
    fun `running marks the task running then records success`() = runTest {
        val s = store(); s.add(task("t1"))
        val (v, runner) = vm(s)
        v.run("t1"); advanceUntilIdle()
        assertEquals("d1", runner.ranOn)
        val stored = v.state.value.tasks.single()
        assertEquals("success", stored.lastRunStatus)
        assertTrue(v.state.value.runningIds.isEmpty())
    }

    @Test
    fun `a failed run records failure and surfaces the message`() = runTest {
        val s = store(); s.add(task("t1"))
        val (v, _) = vm(s, FakeRunner(Result.failure(ApiException(500, "device unreachable"))))
        v.run("t1"); advanceUntilIdle()
        assertEquals("failed", v.state.value.tasks.single().lastRunStatus)
        assertEquals("device unreachable", v.state.value.error)
    }

    @Test
    fun `a task with no target device asks instead of dialing`() = runTest {
        val s = store(); s.add(task("t1", target = null))
        val (v, runner) = vm(s)
        v.run("t1"); advanceUntilIdle()
        assertNull("must not pick a device on its own", runner.ranOn)
        assertEquals("t1", v.state.value.needsTargetForTaskId)
    }

    @Test
    fun `choosing a target runs the task on it`() = runTest {
        val s = store(); s.add(task("t1", target = null))
        val (v, runner) = vm(s)
        v.run("t1"); advanceUntilIdle()
        v.runOnDevice("t1", "d9"); advanceUntilIdle()
        assertEquals("d9", runner.ranOn)
        assertNull(v.state.value.needsTargetForTaskId)
    }

    @Test
    fun `the run output is kept for the row`() = runTest {
        val s = store(); s.add(task("t1"))
        val (v, _) = vm(s)
        v.run("t1"); advanceUntilIdle()
        assertEquals("ok", v.state.value.lastOutputs["t1"])
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :feature:tasks:testDebugUnitTest
```

Expected: FAIL — `TaskRunner` and `TasksViewModel` are undefined.

- [ ] **Step 4: Add `TaskRunner` to `:core:data`**

```kotlin
package com.hydra.android.core.data

import com.hydra.android.core.model.ExecuteRequest
import com.hydra.android.core.model.TaskResult
import com.hydra.android.core.network.HydraApi
import com.hydra.android.core.network.apiCall
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Runs a saved template on one device. An interface so the Tasks ViewModel can
 * be tested without a transport, mirroring DevicesRepository.
 */
interface TaskRunner {
    suspend fun run(deviceId: String, command: String, timeout: Int): Result<TaskResult>
}

@Singleton
class ApiTaskRunner @Inject constructor(
    private val api: HydraApi,
) : TaskRunner {
    override suspend fun run(
        deviceId: String,
        command: String,
        timeout: Int,
    ): Result<TaskResult> = apiCall {
        api.executeOnDevice(deviceId, ExecuteRequest(command, timeout))
    }
}
```

Bind it in `DataModule`:

```kotlin
    @Provides
    @Singleton
    fun provideTaskRunner(api: com.hydra.android.core.network.HydraApi): TaskRunner =
        ApiTaskRunner(api)
```

- [ ] **Step 5: Write `TasksViewModel`**

```kotlin
package com.hydra.android.feature.tasks

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DevicesRepository
import com.hydra.android.core.data.SavedTaskStore
import com.hydra.android.core.data.TaskRunner
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.SavedTask
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.datetime.Clock
import javax.inject.Inject

data class TasksUiState(
    val tasks: List<SavedTask> = emptyList(),
    val runningIds: Set<String> = emptySet(),
    val lastOutputs: Map<String, String> = emptyMap(),
    val devices: List<Device> = emptyList(),
    /** Set when a run needs a device the task does not name. */
    val needsTargetForTaskId: String? = null,
    val error: String? = null,
)

@HiltViewModel
class TasksViewModel @Inject constructor(
    private val store: SavedTaskStore,
    private val runner: TaskRunner,
    private val devices: DevicesRepository,
) : ViewModel() {

    private val runtime = MutableStateFlow(TasksUiState())

    val state: StateFlow<TasksUiState> =
        combine(store.tasks, runtime) { tasks, rt -> rt.copy(tasks = tasks) }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), TasksUiState())

    init {
        viewModelScope.launch {
            val online = devices.list().getOrDefault(emptyList()).filter { it.isOnline }
            runtime.value = runtime.value.copy(devices = online)
        }
    }

    fun save(task: SavedTask) {
        if (store.tasks.value.any { it.id == task.id }) store.update(task) else store.add(task)
    }

    fun delete(id: String) = store.delete(id)

    /**
     * A task with no target does not get one picked for it — running a command
     * on the wrong machine is not a recoverable mistake.
     */
    fun run(id: String) {
        val task = store.tasks.value.firstOrNull { it.id == id } ?: return
        val target = task.targetDeviceId
        if (target == null) {
            runtime.value = runtime.value.copy(needsTargetForTaskId = id, error = null)
            return
        }
        launchRun(task, target)
    }

    fun runOnDevice(id: String, deviceId: String) {
        val task = store.tasks.value.firstOrNull { it.id == id } ?: return
        runtime.value = runtime.value.copy(needsTargetForTaskId = null)
        launchRun(task, deviceId)
    }

    fun dismissTargetPrompt() {
        runtime.value = runtime.value.copy(needsTargetForTaskId = null)
    }

    private fun launchRun(task: SavedTask, deviceId: String) {
        runtime.value = runtime.value.copy(
            runningIds = runtime.value.runningIds + task.id,
            error = null,
        )
        viewModelScope.launch {
            val result = runner.run(deviceId, task.command, task.timeout)
            val now = Clock.System.now()
            result.fold(
                onSuccess = { r ->
                    val failed = r.hasError
                    store.recordRun(task.id, if (failed) "failed" else "success", now)
                    runtime.value = runtime.value.copy(
                        runningIds = runtime.value.runningIds - task.id,
                        lastOutputs = runtime.value.lastOutputs + (task.id to r.output),
                        error = r.error,
                    )
                },
                onFailure = { e ->
                    store.recordRun(task.id, "failed", now)
                    runtime.value = runtime.value.copy(
                        runningIds = runtime.value.runningIds - task.id,
                        error = e.message,
                    )
                },
            )
        }
    }
}
```

- [ ] **Step 6: Write the screens and navigation**

`TasksScreen(onOpenEditor: (String?) -> Unit)` — a `Scaffold` titled "Tasks" with a `+` action calling `onOpenEditor(null)`, over a `LazyColumn`:

- An empty state when `tasks.isEmpty()`: "저장된 태스크가 없습니다" with "+ 로 명령 템플릿을 만들어 두세요" in `onSurfaceVariant`.
- One `HydraCard` per task: name in `titleSmall` with a priority badge (`LOW` grey, `NORMAL` blue, `HIGH` orange, `URGENT` red), the command in monospace `labelSmall` with `maxLines = 1` and `TextOverflow.Ellipsis`, the target device name or "실행 시 선택", and — when `lastRunStatus != null` — the status and `lastRunAt`.
- The card is `clickable { onOpenEditor(task.id) }`; **Run is an explicit `IconButton` inside the row** (`Icons.Filled.PlayArrow`, description "실행"), replaced by a 20dp `CircularProgressIndicator` when `task.id in runningIds`. iOS hides Run behind a swipe, which is undiscoverable here.
- `lastOutputs[task.id]` renders under the row behind a collapsible "출력 보기", showing the **first 10 lines** — enough to see whether the command did what was expected without turning a list row into a log viewer.
- A long-press opens a delete confirmation `AlertDialog`, as on the Orchs list.
- When `needsTargetForTaskId != null`, an `AlertDialog` titled "어느 기기에서 실행할까요?" listing `state.devices` as clickable rows calling `viewModel.runOnDevice(id, device.id)`, dismissed by `viewModel::dismissTargetPrompt`.
- `state.error` at the top in `colorScheme.error`.

`TaskEditorScreen(taskId: String?, onDone: () -> Unit, onBack: () -> Unit)` — a `Scaffold` titled "새 태스크" or "태스크 편집" with a back icon and a `TextButton("저장", enabled = name.isNotBlank() && command.isNotBlank())`. Fields, all **screen-owned buffers**:

- Name — `OutlinedTextField`, single line.
- Command — `OutlinedTextField`, `FontFamily.Monospace`, `minLines = 3`.
- Target device — radio rows over `state.devices` plus a "실행 시 선택" option that stores `null`.
- Timeout — `OutlinedTextField` with `KeyboardType.Number`, defaulting to 30; a non-numeric or out-of-range entry falls back to 30 on save (the server clamps to 1–300 anyway).
- Priority — a row of `FilterChip`s over `TaskPriority.entries`.

Saving builds a `SavedTask` — reusing the existing `id` and `createdAt` when editing, or `UUID.randomUUID().toString()` and `Clock.System.now()` when new — calls `viewModel.save(task)`, then `onDone()`.

`TasksNavigation.kt`:

```kotlin
package com.hydra.android.feature.tasks

import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavType
import androidx.navigation.compose.composable
import androidx.navigation.navArgument

const val TASKS_ROUTE = "tasks"
const val TASK_EDITOR_ROUTE = "tasks/edit?taskId={taskId}"

fun taskEditorRoute(taskId: String?) =
    if (taskId == null) "tasks/edit?taskId=" else "tasks/edit?taskId=$taskId"

fun NavGraphBuilder.tasksScreens(
    onOpenEditor: (String?) -> Unit,
    onBack: () -> Unit,
) {
    composable(TASKS_ROUTE) { TasksScreen(onOpenEditor = onOpenEditor) }
    composable(
        TASK_EDITOR_ROUTE,
        arguments = listOf(
            navArgument("taskId") { type = NavType.StringType; defaultValue = "" },
        ),
    ) { entry ->
        TaskEditorScreen(
            taskId = entry.arguments?.getString("taskId")?.ifEmpty { null },
            onDone = onBack,
            onBack = onBack,
        )
    }
}
```

- [ ] **Step 7: Run the tests and build**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :core:data:testDebugUnitTest :feature:tasks:testDebugUnitTest :feature:tasks:assembleDebug
```

Expected: PASS, 8 tasks tests; `BUILD SUCCESSFUL`.

- [ ] **Step 8: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android/core/data android/feature/tasks
git commit -m "feat(android): Tasks 탭 — 로컬 템플릿 CRUD + 기기에서 실행"
```

---

### Task 8: `:app` — six tabs and the new routes

**Files:**
- Modify: `android/app/build.gradle.kts`, `.../android/HydraApp.kt`
- Test: `android/app/src/test/kotlin/com/hydra/android/NavigationRoutesTest.kt`

**Interfaces:**
- Consumes: `ORCHS_ROUTE`/`orchsScreens`/`orchDetailRoute`/`CREATE_ORCH_ROUTE`, `TASKS_ROUTE`/`tasksScreens`/`taskEditorRoute`.
- Produces: the shipped app.

- [ ] **Step 1: Add the feature dependencies**

In `android/app/build.gradle.kts`:

```kotlin
    implementation(project(":feature:orchs"))
    implementation(project(":feature:tasks"))
```

- [ ] **Step 2: Update the failing route test**

Replace the two ordering tests and add one:

```kotlin
    @Test
    fun `bottom tabs are ordered dashboard, devices, orchs, tasks, chat, settings`() {
        assertEquals(
            listOf(DASHBOARD_ROUTE, DEVICES_ROUTE, ORCHS_ROUTE, TASKS_ROUTE, CHAT_ROUTE, SETTINGS_ROUTE),
            HydraDestination.entries.map { it.route },
        )
    }

    @Test
    fun `tab labels match the iOS wording`() {
        assertEquals(
            listOf("대시보드", "디바이스", "Orchs", "Tasks", "Chat", "설정"),
            HydraDestination.entries.map { it.label },
        )
    }

    @Test
    fun `full-screen routes are not tabs`() {
        // Orch create/detail and the task editor are full-screen, like the terminal.
        val tabRoutes = HydraDestination.entries.map { it.route }
        assertTrue(CREATE_ORCH_ROUTE !in tabRoutes)
        assertTrue(orchDetailRoute("o1") !in tabRoutes)
        assertTrue(taskEditorRoute("t1") !in tabRoutes)
    }

    @Test
    fun `route builders substitute their ids`() {
        assertEquals("orchs/o1", orchDetailRoute("o1"))
        assertEquals("tasks/edit?taskId=t1", taskEditorRoute("t1"))
        assertEquals("tasks/edit?taskId=", taskEditorRoute(null))
    }
```

Keep the existing "start destination", "terminal is not a tab", "terminalRoute substitutes", and "routes are unique" tests. Add the imports for `ORCHS_ROUTE`, `CREATE_ORCH_ROUTE`, `orchDetailRoute`, `TASKS_ROUTE`, `taskEditorRoute`.

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew :app:testDebugUnitTest
```

Expected: FAIL — the enum has four entries and the new routes are unresolved.

- [ ] **Step 4: Add the tabs and routes**

In `HydraApp.kt`, extend the enum between DEVICES and CHAT:

```kotlin
    ORCHS(ORCHS_ROUTE, "Orchs", Icons.Filled.Hub),
    TASKS(TASKS_ROUTE, "Tasks", Icons.AutoMirrored.Filled.ListAlt),
```

Widen the bottom-bar hide rule and register the graphs:

```kotlin
    val hideBottomBar = currentRoute?.startsWith("terminal/") == true ||
        currentRoute == SSH_KEY_ROUTE ||
        currentRoute == CREATE_ORCH_ROUTE ||
        currentRoute?.startsWith("orchs/") == true && currentRoute != ORCHS_ROUTE ||
        currentRoute?.startsWith("tasks/edit") == true
```

```kotlin
            orchsScreens(
                onOpenDetail = { id -> navController.navigate(orchDetailRoute(id)) },
                onOpenCreate = { navController.navigate(CREATE_ORCH_ROUTE) },
                onBack = { navController.popBackStack() },
            )
            tasksScreens(
                onOpenEditor = { id -> navController.navigate(taskEditorRoute(id)) },
                onBack = { navController.popBackStack() },
            )
```

- [ ] **Step 5: Run the full suite and build the APK**

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS \
  ./gradlew testDebugUnitTest assembleDebug
```

Expected: `BUILD SUCCESSFUL`, all module tests green, APK present.

- [ ] **Step 6: Check the six-tab bar on the narrow display**

Material3 recommends at most five bottom-bar destinations; six may truncate labels on the narrow outer screen. Install and look:

```bash
cd /Users/dave/iWorks/hydra/android
JAVA_HOME=/Users/dave/.asdf/installs/java/temurin-21.0.3+9.0.LTS ./gradlew :app:installDebug
adb shell am start -n com.hydra.android/.MainActivity
adb exec-out screencap -p -d 4630947123231501204 > /tmp/tabs.png
```

If any label is clipped, shorten the two new ones to "Orch" and "Task" rather than letting the bar ellipsize — a truncated label reads as a rendering bug. Report which you chose.

- [ ] **Step 7: Verify against a real server**

With the backend running and a device or emulator attached, confirm by hand and report what you actually saw:

1. Orchs tab lists the server's orchs with correct status colours.
2. `+` → create: only online devices are offered; picking a coordinator removes it from the worker list; Create is disabled until name and coordinator are set.
3. Creating an orch returns to the list and the new orch appears.
4. Long-press an orch → confirm → it disappears; long-press → cancel → it stays.
5. Tap an orch: health rows render, worker processes appear and refresh about every five seconds.
6. Run a command in the detail's execute box and see per-worker output.
7. Tasks tab: create a task with a target device, run it, see the status and output; create one without a target, run it, and confirm the device picker appears.
8. Kill the app and reopen: saved tasks are still there.

If no device or backend is available, say so explicitly rather than reporting this step as done.

- [ ] **Step 8: Commit**

```bash
cd /Users/dave/iWorks/hydra
git add android
git commit -m "feat(android): 하단 탭 6개 — Orchs/Tasks 배선"
```

---

## Self-Review

**Spec coverage.** Server contract table → Task 1 (models) and Task 2 (endpoints), with the `coordinator_id` discrepancy asserted directly in Task 1's first test. `OrchRepository` → Task 3. `SavedTaskStore`, including the empty-list-on-corruption rule → Task 4. Orchs list, create, long-press delete without optimistic removal → Task 5. Orch detail's four blocks and subscription-driven polling → Task 6. Tasks list with an explicit Run button, the editor, and the 10-line output excerpt → Task 7. Six-tab navigation and full-screen routes → Task 8, whose Step 6 covers the spec's "labels are checked on the narrow display and shortened if they truncate". Every testing-strategy row maps to a task's test step.

**Interface additions discovered while planning.** `TaskRunner` (Task 7, Step 4) is not named in the spec: the Tasks ViewModel needs a seam over `executeOnDevice` for the same reason `DevicesRepository` exists — otherwise its tests would need a transport. It lands in `:core:data` beside the other repositories.

**Known soft spot.** Task 6's `OrchDetailViewModel` takes `orchId` through `SavedStateHandle`, and Hilt's tolerance for the secondary-constructor shape is not verified. That task says explicitly to collapse to a single `SavedStateHandle` constructor if it does not compile, keeping the assertions unchanged — the compile step is the gate.

**Type consistency.** `OrchRepository`'s six methods are declared in Task 3 and overridden with identical signatures in the fakes of Tasks 5 and 6. `SavedTaskStore`'s five members are defined in Task 4 and used unchanged in Task 7. `TaskResult`, `WorkerStatus`, and `WorkerProcess` are produced in Task 1 and consumed by name in Tasks 3, 6 and 7. `UnusedApi` implements all fourteen `HydraApi` members — the six added in Task 2 plus the existing eight — and must be updated if that interface grows again.
