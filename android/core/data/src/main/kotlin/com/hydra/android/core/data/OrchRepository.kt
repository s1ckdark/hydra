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
 *
 * The execute timeout defaults here rather than on the wire model: see
 * ExecuteRequest for why that model carries no default of its own.
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
        timeout: Int = DEFAULT_TIMEOUT_SECONDS,
    ): Result<OrchExecuteResponse> = apiCall {
        api.executeOnOrch(id, ExecuteRequest(command, timeout))
    }

    companion object {
        const val DEFAULT_TIMEOUT_SECONDS = 30
    }
}
