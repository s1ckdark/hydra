package com.hydra.android.core.data

import android.content.Context
import com.hydra.android.core.network.ServerConfigProvider
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object DataModule {

    @Provides
    @Singleton
    fun provideSecureStore(@ApplicationContext context: Context): SecureStore =
        KeystoreSecureStore(context)

    @Provides
    @Singleton
    fun provideSettingsRepository(@ApplicationContext context: Context) =
        SettingsRepository(context)

    @Provides
    @Singleton
    fun provideSettingsSource(repository: SettingsRepository): SettingsSource = repository

    @Provides
    @Singleton
    fun provideDevicesRepository(api: com.hydra.android.core.network.HydraApi): DevicesRepository =
        ApiDevicesRepository(api)

    @Provides
    @Singleton
    fun provideOrchRepository(api: com.hydra.android.core.network.HydraApi): OrchRepository =
        OrchRepository(api)

    @Provides
    @Singleton
    fun provideSavedTaskStore(@ApplicationContext context: Context): SavedTaskStore =
        SavedTaskStore(java.io.File(context.filesDir, "saved_tasks.json"))

    @Provides
    @Singleton
    fun provideTaskRunner(api: com.hydra.android.core.network.HydraApi): TaskRunner =
        ApiTaskRunner(api)

    @Provides
    @Singleton
    fun provideServerConfigProvider(
        secureStore: SecureStore,
        settings: SettingsRepository,
    ): ServerConfigProvider {
        val provider = SettingsServerConfigProvider(secureStore)
        // Keeps the atomic cell current for the non-suspending interceptors.
        CoroutineScope(SupervisorJob()).launch {
            try { settings.serverUrl.collectLatest { provider.updateServerUrl(it) } }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { provider.failReadiness() }
        }
        return provider
    }
}
