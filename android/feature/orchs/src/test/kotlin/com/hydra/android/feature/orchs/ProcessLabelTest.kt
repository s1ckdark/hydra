package com.hydra.android.feature.orchs

import com.hydra.android.core.model.WorkerProcess
import org.junit.Assert.assertEquals
import org.junit.Test

class ProcessLabelTest {

    // Found on device: every row read blank. handler.go sends processName ""
    // and puts the real thing in command, which is what iOS renders too.
    @Test
    fun `the command is used when the server sends no process name`() {
        val process = WorkerProcess(pid = "1", processName = "", command = "mongod --auth")
        assertEquals("mongod --auth", processLabel(process))
    }

    @Test
    fun `a process name wins when the server sends one`() {
        val process = WorkerProcess(pid = "1", processName = "mongod", command = "mongod --auth")
        assertEquals("mongod", processLabel(process))
    }

    @Test
    fun `a process with neither is labelled by its pid`() {
        assertEquals("PID 42", processLabel(WorkerProcess(pid = "42")))
    }
}
