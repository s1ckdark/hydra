package com.hydra.android.feature.dashboard

import com.hydra.android.core.model.CpuMetrics
import com.hydra.android.core.model.Device
import com.hydra.android.core.model.DeviceMetrics
import com.hydra.android.core.model.DiskMetrics
import com.hydra.android.core.model.MemoryMetrics
import com.hydra.android.feature.dashboard.sections.DeviceCardBody
import com.hydra.android.feature.dashboard.sections.DeviceHealthBadge
import com.hydra.android.feature.dashboard.sections.deviceCardBody
import com.hydra.android.feature.dashboard.sections.deviceHealthBadge
import kotlinx.datetime.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

private val T0 = Instant.parse("2026-09-04T10:00:00Z")

private fun device(
    id: String = "d1",
    hasGpu: Boolean = false,
    gpuModel: String? = null,
    tailscaleIp: String = "",
) = Device(
    id = id,
    hostname = id,
    status = "online",
    lastSeen = T0,
    hasGpu = hasGpu,
    gpuModel = gpuModel,
    gpuCount = if (hasGpu) 1 else 0,
    tailscaleIp = tailscaleIp,
)

private fun metrics(error: String? = null, suppressed: Boolean? = null) = DeviceMetrics(
    deviceId = "d1",
    cpu = CpuMetrics(usagePercent = 12.0),
    memory = MemoryMetrics(usagePercent = 40.0),
    disk = DiskMetrics(),
    collectedAt = T0,
    error = error,
    suppressed = suppressed,
)

class DeviceCardBodyTest {

    @Test
    fun `healthy metrics render the usage bars`() {
        val body = deviceCardBody(device(), metrics())
        assertEquals(DeviceCardBody.Usage, body)
    }

    @Test
    fun `no metrics at all renders the usage bars with unknown values`() {
        // A missing sample is not an error — the bars render an em dash.
        assertEquals(DeviceCardBody.Usage, deviceCardBody(device(), null))
    }

    @Test
    fun `a metrics error suppresses the bars and falls back to the gpu line`() {
        // iOS: `if let m = metrics, !m.hasError { richBody } else if hasGpu { gpuLine }`.
        // Rendering 0% bars next to a failure would read as "idle", not "unknown".
        val body = deviceCardBody(device(hasGpu = true, gpuModel = "RTX 4090"), metrics(error = "boom"))
        assertEquals(DeviceCardBody.Gpu, body)
    }

    @Test
    fun `a metrics error on a gpu-less device falls back to the address`() {
        val body = deviceCardBody(device(tailscaleIp = "100.1.2.3"), metrics(error = "boom"))
        assertEquals(DeviceCardBody.Address, body)
    }

    @Test
    fun `a healthy device with no error keeps the bars even when it has a gpu`() {
        assertEquals(DeviceCardBody.Usage, deviceCardBody(device(hasGpu = true), metrics()))
    }

    @Test
    fun `no badge when metrics are healthy`() {
        assertNull(deviceHealthBadge(metrics()))
    }

    @Test
    fun `no badge when metrics are absent`() {
        assertNull(deviceHealthBadge(null))
    }

    @Test
    fun `a live failure badges as unreachable`() {
        assertEquals(DeviceHealthBadge.UNREACHABLE, deviceHealthBadge(metrics(error = "boom")))
    }

    @Test
    fun `a breaker cooldown badges as waiting, not as a failure`() {
        // The breaker declining to dial is an operational state, not a fault;
        // iOS gives it its own icon and colour rather than the error treatment.
        val badge = deviceHealthBadge(metrics(error = "connection suppressed…", suppressed = true))
        assertEquals(DeviceHealthBadge.COOLING_DOWN, badge)
    }

    @Test
    fun `suppressed false is still a plain failure`() {
        val badge = deviceHealthBadge(metrics(error = "boom", suppressed = false))
        assertEquals(DeviceHealthBadge.UNREACHABLE, badge)
    }
}
