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
