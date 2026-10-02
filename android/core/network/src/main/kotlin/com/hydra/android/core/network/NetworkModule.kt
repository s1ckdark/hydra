package com.hydra.android.core.network

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.util.concurrent.TimeUnit
import javax.inject.Singleton
import javax.inject.Qualifier

@Qualifier
@Retention(AnnotationRetention.BINARY)
annotation class AgentNetwork

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun provideJson(): Json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    @Provides
    @Singleton
    fun provideOkHttp(config: ServerConfigProvider): OkHttpClient =
        OkHttpClient.Builder()
            .addInterceptor(BaseUrlInterceptor(config))
            .addInterceptor(AuthInterceptor(config))
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()

    /**
     * This base URL is a placeholder that BaseUrlInterceptor overwrites on
     * every request. Retrofit still requires a syntactically valid absolute
     * URL ending in '/', so the constant must stay well-formed.
     */
    @Provides
    @Singleton
    fun provideRetrofit(client: OkHttpClient, json: Json): Retrofit =
        Retrofit.Builder()
            .baseUrl("http://placeholder.invalid/")
            .client(client)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()

    @Provides
    @Singleton
    fun provideHydraApi(retrofit: Retrofit): HydraApi = retrofit.create(HydraApi::class.java)

    @Provides @Singleton @AgentNetwork
    fun provideAgentHttp(config: ServerConfigProvider): OkHttpClient = agentHttpClient(config)

    @Provides @Singleton
    fun provideAgentApi(@AgentNetwork client: OkHttpClient, json: Json): AgentApi = Retrofit.Builder()
        .baseUrl("http://placeholder.invalid/").client(client)
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build().create(AgentApi::class.java)

    @Provides @Singleton
    fun provideAgentStreamTransport(@AgentNetwork client: OkHttpClient, config: ServerConfigProvider, json: Json): AgentStreamTransport =
        OkHttpAgentStreamTransport(client, config, json)
}
