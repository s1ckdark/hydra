package com.hydra.android.core.data

import com.hydra.android.core.network.HydraApi
import com.hydra.android.core.network.apiCall
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Merges the five dashboard sources. The core/auxiliary asymmetry is
 * deliberate and mirrors iOS DashboardViewModel.load():
 *
 *  - devices + orchs: fetched concurrently; a failure sets `error`.
 *  - gpu, metrics, tasks: failures are swallowed and leave the section empty
 *    (iOS comments this "GPU monitoring is optional"). Without this, a server
 *    with no GPU nodes would show the whole dashboard as failed.
 *  - /health never sets `error`; it only drives the status banner.
 *
 * Open so ViewModel tests can substitute a recording subclass.
 */
@Singleton
open class DashboardRepository @Inject constructor(
    private val api: HydraApi,
) {
    open suspend fun load(force: Boolean, hideMobile: Boolean): DashboardSnapshot =
        coroutineScope {
            val health = apiCall { api.health() }

            // Null query params are omitted, matching iOS's conditional build.
            val devicesDeferred = async {
                apiCall {
                    api.listDevices(
                        refresh = if (force) true else null,
                        includeMobile = if (hideMobile) false else null,
                    )
                }
            }
            val orchsDeferred = async { apiCall { api.listOrchs() } }
            val gpuDeferred = async { apiCall { api.gpuMonitor() } }
            val tasksDeferred = async { apiCall { api.listTasks() } }
            val metricsDeferred = async { apiCall { api.metricsSnapshot() } }

            val devices = devicesDeferred.await()
            val orchs = orchsDeferred.await()

            DashboardSnapshot(
                serverStatus = health.fold(
                    onSuccess = {
                        if (it.status == "healthy") ServerStatus.CONNECTED
                        else ServerStatus.DISCONNECTED
                    },
                    onFailure = { ServerStatus.DISCONNECTED },
                ),
                serverVersion = health.getOrNull()?.version.orEmpty(),
                devices = devices.getOrDefault(emptyList()),
                orchs = orchs.getOrDefault(emptyList()),
                gpuNodes = gpuDeferred.await().getOrNull()?.nodes.orEmpty(),
                tasks = tasksDeferred.await().getOrDefault(emptyList()),
                metricsByDevice = metricsDeferred.await().getOrNull()?.devices.orEmpty(),
                error = devices.exceptionOrNull()?.message
                    ?: orchs.exceptionOrNull()?.message,
            )
        }
}
