package com.hydra.android.core.network

import com.hydra.android.core.model.AgentExecuteRequest
import com.hydra.android.core.model.AgentExecuteResponse
import com.hydra.android.core.model.ChatRequest
import com.hydra.android.core.model.ChatResponse
import com.hydra.android.core.model.CreateOrchRequest
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.GpuMonitorResponse
import com.hydra.android.core.model.HealthResponse
import com.hydra.android.core.model.MetricsSnapshotResponse
import com.hydra.android.core.model.NagaTask
import com.hydra.android.core.model.ExecuteRequest
import com.hydra.android.core.model.Orch
import com.hydra.android.core.model.OrchExecuteResponse
import com.hydra.android.core.model.OrchHealth
import com.hydra.android.core.model.OrchProcessesResponse
import com.hydra.android.core.model.TaskResult
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.POST
import retrofit2.http.Query

/** The eight endpoints v1 uses. See the design spec's endpoint table. */
interface HydraApi {

    @GET("health")
    suspend fun health(): HealthResponse

    /**
     * Null query params are dropped by Retrofit, matching iOS's conditional
     * query building (APIClient.swift:43-49): the unforced, mobile-visible
     * call hits a bare /api/devices.
     */
    @GET("api/devices")
    suspend fun listDevices(
        @Query("refresh") refresh: Boolean? = null,
        @Query("include_mobile") includeMobile: Boolean? = null,
    ): List<Device>

    @GET("api/orchs")
    suspend fun listOrchs(): List<Orch>

    @GET("api/tasks")
    suspend fun listTasks(): List<NagaTask>

    @GET("api/monitor/gpu")
    suspend fun gpuMonitor(): GpuMonitorResponse

    @GET("api/monitor/snapshot")
    suspend fun metricsSnapshot(): MetricsSnapshotResponse

    @POST("api/agent/chat")
    suspend fun chat(@Body body: ChatRequest): ChatResponse

    @POST("api/agent/execute")
    suspend fun execute(@Body body: AgentExecuteRequest): AgentExecuteResponse

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

    /** Dropped in v1 along with Quick Command; the Tasks tab brings it back. */
    @POST("api/devices/{id}/execute")
    suspend fun executeOnDevice(
        @Path("id") id: String,
        @Body body: ExecuteRequest,
    ): TaskResult
}
