package com.hydra.android.core.data

import com.hydra.android.core.model.OrchAIAgents
import com.hydra.android.core.model.AgentStreamException
import com.hydra.android.core.network.ApiException
import com.hydra.android.core.network.AgentApi
import com.hydra.android.core.network.AgentServerIdentity
import com.hydra.android.core.network.ServerConfigProvider
import com.hydra.android.core.network.apiCall
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
open class OrchAgentsRepository @Inject constructor(
    private val api: AgentApi,
    private val config: ServerConfigProvider? = null,
) {
    // Masked validation baseline only; draft keys are never retained here.
    private val originals = ConcurrentHashMap<String, OrchAIAgents>()

    open suspend fun get(id: String): Result<OrchAIAgents> = getPinned(id, null)
    open suspend fun save(id: String, configuration: OrchAIAgents): Result<OrchAIAgents> = savePinned(id, configuration, null)
    open suspend fun get(id: String, expectedServerUrl: String): Result<OrchAIAgents> =
        if (config == null) get(id) else getPinned(id, expectedServerUrl)
    open suspend fun save(id: String, configuration: OrchAIAgents, expectedServerUrl: String): Result<OrchAIAgents> =
        if (config == null) save(id, configuration) else savePinned(id, configuration, expectedServerUrl)

    private suspend fun identity(expected: String?): AgentServerIdentity? {
        val provider = config ?: return null
        withTimeout(10_000) { provider.awaitReady() }
        return AgentServerIdentity.capture(provider, expected)
    }

    private suspend fun getPinned(id: String, expected: String?): Result<OrchAIAgents> = safely {
        val origin = identity(expected)
        val result = apiCall { api.getAgents(id, origin).withoutDraftKeys() }
        result.onSuccess { originals[cacheKey(id, origin)] = it }
    }

    private suspend fun savePinned(id: String, configuration: OrchAIAgents, expected: String?): Result<OrchAIAgents> = safely {
        val origin = identity(expected)
        val key = cacheKey(id, origin)
        val errors = configuration.validationErrors(originals[key] ?: OrchAIAgents())
        if (errors.isNotEmpty()) Result.failure(IllegalArgumentException(errors.first()))
        else apiCall { api.saveAgents(id, configuration.toUpdate(), origin).withoutDraftKeys() }
            .onSuccess { originals[key] = it }
    }

    private fun cacheKey(id: String, identity: AgentServerIdentity?): String = "${identity?.baseUrl.orEmpty()}|$id"

    private suspend fun <T> safely(block: suspend () -> Result<T>): Result<T> = try {
        block()
    } catch (_: TimeoutCancellationException) {
        currentCoroutineContext().ensureActive()
        Result.failure(ApiException(null, "Server settings could not be loaded in time."))
    }
    catch (cancelled: CancellationException) { throw cancelled }
    catch (failure: AgentStreamException) { Result.failure(failure) }
    catch (_: Exception) { Result.failure(ApiException(null, "Could not load or save AI agent configuration.")) }
}
