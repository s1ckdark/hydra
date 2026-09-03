package com.hydra.android.core.data

import com.hydra.android.core.model.Device
import com.hydra.android.core.network.HydraApi
import com.hydra.android.core.network.apiCall
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Lives in :core:data rather than :feature:devices because the terminal needs
 * it too — it resolves a device id to a host before dialing.
 */
interface DevicesRepository {
    suspend fun list(): Result<List<Device>>
}

@Singleton
class ApiDevicesRepository @Inject constructor(
    private val api: HydraApi,
) : DevicesRepository {
    override suspend fun list(): Result<List<Device>> = apiCall { api.listDevices() }
}
