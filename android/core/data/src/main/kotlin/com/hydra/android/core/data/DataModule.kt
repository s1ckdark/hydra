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
    fun provideServerConfigProvider(
        secureStore: SecureStore,
        settings: SettingsRepository,
    ): ServerConfigProvider {
        val provider = SettingsServerConfigProvider(secureStore)
        // Keeps the atomic cell current for the non-suspending interceptors.
        CoroutineScope(SupervisorJob()).launch {
            settings.serverUrl.collectLatest { provider.updateServerUrl(it) }
        }
        return provider
    }
}
