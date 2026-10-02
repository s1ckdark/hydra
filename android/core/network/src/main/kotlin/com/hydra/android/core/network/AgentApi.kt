package com.hydra.android.core.network

import com.hydra.android.core.model.OrchAIAgents
import com.hydra.android.core.model.OrchAIAgentsUpdate
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.PUT
import retrofit2.http.Path
import retrofit2.http.Tag

/** Separate from HydraApi so existing clients/fakes keep their original API. */
interface AgentApi {
    @GET("api/orchs/{id}/ai-agents")
    suspend fun getAgents(@Path("id") id: String, @Tag identity: AgentServerIdentity? = null): OrchAIAgents

    @PUT("api/orchs/{id}/ai-agents")
    suspend fun saveAgents(@Path("id") id: String, @Body body: OrchAIAgentsUpdate, @Tag identity: AgentServerIdentity? = null): OrchAIAgents
}
