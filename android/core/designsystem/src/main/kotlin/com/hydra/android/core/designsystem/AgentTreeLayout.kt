package com.hydra.android.core.designsystem

import com.hydra.android.core.model.AgentRunEdge
import com.hydra.android.core.model.AgentRunSnapshot
import kotlin.math.max
import kotlin.math.min

data class TreePoint(val x: Float, val y: Float)
data class TreeRect(val left: Float, val top: Float, val width: Float, val height: Float) {
    val right get() = left + width
    val bottom get() = top + height
    val centerX get() = left + width / 2
    val centerY get() = top + height / 2
}
data class TreeNodePlacement(val id: String, val frame: TreeRect, val step: Int?)
data class TreeConnector(val edge: AgentRunEdge, val points: List<TreePoint>)
data class TreeBranch(val id: String, val title: String, val frame: TreeRect)

/** Pure dp geometry: real dependencies run top-to-bottom; agent ancestry defines lanes. */
data class AgentTreeLayout(
    val nodes: List<TreeNodePlacement>,
    val connectors: List<TreeConnector>,
    val branches: List<TreeBranch>,
    val width: Float,
    val height: Float,
) {
    companion object {
        fun calculate(snapshot: AgentRunSnapshot, viewportWidth: Float): AgentTreeLayout {
            val ordered = snapshot.nodes.sortedWith(compareBy({ it.order }, { it.id })).distinctBy { it.id }
            val byId = ordered.associateBy { it.id }
            val edges = snapshot.edges.distinct().filter { it.from in byId && it.to in byId && it.from != it.to }
                .sortedWith(compareBy({ it.from }, { it.to }, { it.kind }))
            val agents = ordered.filter { it.kind == "agent" }.mapIndexed { index, node -> node.id to index }.toMap()
            fun lane(id: String): Int {
                var item = byId[id]
                val visited = mutableSetOf<String>()
                while (item != null && visited.add(item.id)) {
                    agents[item.id]?.let { return it }
                    item = item.parentId?.let(byId::get)
                }
                return 0
            }
            val ranks = mutableMapOf<String, Int>()
            val remaining = ordered.toMutableList()
            while (remaining.isNotEmpty()) {
                val ready = remaining.filter { node -> edges.filter { it.to == node.id }.all { it.from in ranks } }
                if (ready.isEmpty()) {
                    val base = (ranks.values.maxOrNull() ?: -1) + 1
                    remaining.forEachIndexed { index, node -> ranks[node.id] = base + index }
                    break
                }
                ready.forEach { node ->
                    ranks[node.id] = edges.filter { it.to == node.id }.maxOfOrNull { ranks.getValue(it.from) + 1 } ?: 0
                }
                remaining.removeAll(ready.toSet())
            }
            val cardWidth = (viewportWidth - 64f).coerceIn(232f, 360f)
            val cardHeight = 176f
            val steps = ordered.filter { it.kind != "root" }.mapIndexed { i, node -> node.id to i + 1 }.toMap()
            val occupied = mutableMapOf<Int, MutableSet<Int>>()
            val placements = ordered.map { node ->
                val row = ranks[node.id] ?: 0
                var column = lane(node.id)
                val rowLanes = occupied.getOrPut(row) { mutableSetOf() }
                while (column in rowLanes) column++
                rowLanes.add(column)
                TreeNodePlacement(node.id, TreeRect(40f + column * (cardWidth + 64f), 24f + row * (cardHeight + 56f), cardWidth, cardHeight), steps[node.id])
            }
            val frames = placements.associate { it.id to it.frame }
            val connectors = edges.mapIndexed { index, edge ->
                val from = frames.getValue(edge.from)
                val to = frames.getValue(edge.to)
                val start = TreePoint(from.centerX, from.bottom)
                val end = TreePoint(to.centerX, to.top)
                val middle = (start.y + end.y) / 2
                val direct = listOf(start, TreePoint(start.x, middle), TreePoint(end.x, middle), end)
                val crosses = placements.any { node ->
                    node.id != edge.from && node.id != edge.to && direct.zipWithNext().any { (a, b) -> segmentIntersects(a, b, node.frame) }
                }
                val points = if (crosses) {
                    // A bounded left gutter keeps long delegation edges off cards.
                    val gutter = 8f + (index % 3) * 7f
                    listOf(start, TreePoint(start.x, start.y + 14f), TreePoint(gutter, start.y + 14f),
                        TreePoint(gutter, end.y - 14f), TreePoint(end.x, end.y - 14f), end)
                } else direct
                TreeConnector(edge, points)
            }
            val branches = ordered.filter { it.kind == "agent" }.mapNotNull { agent ->
                val members = ordered.filter { it.id == agent.id || it.parentId == agent.id }.mapNotNull { frames[it.id] }
                if (members.size <= 1) null else {
                    val left = members.minOf { it.left } - 8
                    val top = members.minOf { it.top } - 8
                    TreeBranch(agent.id, agent.title, TreeRect(left, top, members.maxOf { it.right } - left + 8, members.maxOf { it.bottom } - top + 8))
                }
            }
            return AgentTreeLayout(placements, connectors, branches,
                max(viewportWidth, (placements.maxOfOrNull { it.frame.right } ?: 0f) + 24f),
                max(120f, (placements.maxOfOrNull { it.frame.bottom } ?: 0f) + 24f))
        }

        fun segmentIntersects(a: TreePoint, b: TreePoint, rect: TreeRect): Boolean = when {
            a.y == b.y -> a.y > rect.top && a.y < rect.bottom && max(a.x, b.x) > rect.left && min(a.x, b.x) < rect.right
            a.x == b.x -> a.x > rect.left && a.x < rect.right && max(a.y, b.y) > rect.top && min(a.y, b.y) < rect.bottom
            else -> false
        }
    }
}
