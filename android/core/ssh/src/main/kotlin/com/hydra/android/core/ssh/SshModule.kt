package com.hydra.android.core.ssh

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import java.io.File
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object SshModule {

    @Provides
    @Singleton
    fun provideKnownHostsStore(@ApplicationContext context: Context): KnownHostsStore =
        KnownHostsStore(File(context.filesDir, "known_hosts"))

    @Provides
    @Singleton
    fun provideSshTransportFactory(knownHosts: KnownHostsStore): SshTransportFactory =
        SshjTransportFactory(knownHosts)
}
