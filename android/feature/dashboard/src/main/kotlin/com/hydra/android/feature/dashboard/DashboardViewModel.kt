package com.hydra.android.feature.dashboard

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hydra.android.core.data.DashboardRepository
import com.hydra.android.core.data.DashboardSnapshot
import com.hydra.android.core.data.SettingsSource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import javax.inject.Inject
import kotlin.time.Duration.Companion.seconds

data class DashboardUiState(
    val snapshot: DashboardSnapshot = DashboardSnapshot(),
    val isLoading: Boolean = true,
    val lastRefresh: Instant? = null,
) {
    /**
     * Full-screen spinner only before anything has arrived; poll ticks must
     * not flash the screen. Mirrors DashboardScreen.swift:76.
     */
    val showBlockingLoader: Boolean
        get() = isLoading && snapshot.devices.isEmpty() && snapshot.orchs.isEmpty()
}

@HiltViewModel
class DashboardViewModel @Inject constructor(
    private val repository: DashboardRepository,
    private val settings: SettingsSource,
) : ViewModel() {

    /** Manual refresh requests, merged into the same load pipeline as the poll. */
    private val forcedRefreshes = MutableSharedFlow<Unit>(
        replay = 0,
        extraBufferCapacity = 1,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    /**
     * Polling is driven by subscription rather than by explicit start/stop
     * calls. iOS pairs startPolling/stopPolling with .task/.onDisappear
     * (DashboardViewModel.swift:161-173); here, leaving the tab drops the
     * collector and the loop ends on its own, so a missed teardown cannot
     * leak a poll loop.
     *
     * The delay sits *after* a completed load, not on an independent ticker:
     * a server slower than the interval would otherwise have every load
     * cancelled by the next tick and never finish one. iOS gets this ordering
     * from `await load()` followed by `Task.sleep`.
     *
     * A manual refresh restarts the loop with force = true, which makes the
     * server bypass its Tailscale cache, re-probe :22, and re-collect SSH
     * metrics. Poll ticks take the cached path.
     */
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    val state: StateFlow<DashboardUiState> =
        forcedRefreshes
            .map { true }
            .onStart { emit(false) }
            .flatMapLatest { forceFirst ->
                flow {
                    var force = forceFirst
                    while (true) {
                        val hideMobile = settings.hideMobileDevices.first()
                        val snapshot = repository.load(force = force, hideMobile = hideMobile)
                        emit(
                            DashboardUiState(
                                snapshot = snapshot,
                                isLoading = false,
                                lastRefresh = Clock.System.now(),
                            )
                        )
                        force = false
                        delay(POLL_INTERVAL)
                    }
                }
            }
            .stateIn(
                scope = viewModelScope,
                started = SharingStarted.WhileSubscribed(5_000),
                initialValue = DashboardUiState(),
            )

    fun refresh() {
        forcedRefreshes.tryEmit(Unit)
    }

    private companion object {
        val POLL_INTERVAL = 5.seconds
    }
}
