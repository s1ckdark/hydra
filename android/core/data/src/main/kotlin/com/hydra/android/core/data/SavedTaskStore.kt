package com.hydra.android.core.data

import com.hydra.android.core.model.SavedTask
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Saved command templates, persisted as one JSON document in an app-private
 * file — the same shape as KnownHostsStore.
 *
 * Reads never throw: a malformed or truncated file yields an empty list. A
 * corrupt store must not make the tab unopenable, and the next write repairs
 * the file.
 */
class SavedTaskStore(private val file: File) {

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    private val _tasks = MutableStateFlow(read())
    val tasks: StateFlow<List<SavedTask>> = _tasks.asStateFlow()

    fun add(task: SavedTask) = mutate { it + task }

    /** No-op for an unknown id: an edit must never silently become an insert. */
    fun update(task: SavedTask) = mutate { list ->
        if (list.none { it.id == task.id }) list
        else list.map { if (it.id == task.id) task else it }
    }

    fun delete(id: String) = mutate { list -> list.filterNot { it.id == id } }

    fun recordRun(id: String, status: String, at: Instant) = mutate { list ->
        list.map { if (it.id == id) it.copy(lastRunStatus = status, lastRunAt = at) else it }
    }

    private fun mutate(block: (List<SavedTask>) -> List<SavedTask>) {
        val next = block(_tasks.value)
        _tasks.value = next
        write(next)
    }

    private fun read(): List<SavedTask> {
        if (!file.exists()) return emptyList()
        return runCatching { json.decodeFromString<List<SavedTask>>(file.readText()) }
            .getOrDefault(emptyList())
    }

    private fun write(list: List<SavedTask>) {
        file.parentFile?.mkdirs()
        file.writeText(json.encodeToString(list))
    }
}
