package com.hydra.android.core.designsystem

import com.hydra.android.core.model.AgentRunEdge
import com.hydra.android.core.model.AgentRunNode
import com.hydra.android.core.model.AgentRunSnapshot
import org.junit.Assert.*
import org.junit.Test

class AgentTreeLayoutTest {
    @Test fun `phone layout preserves readable cards actual order and arrow endpoints`() {
        val snapshot = graph()
        val layout = AgentTreeLayout.calculate(snapshot, 360f)
        assertEquals(snapshot.orderedNodes.map { it.id }, layout.nodes.map { it.id })
        assertNull(layout.nodes.first().step)
        assertEquals(1, layout.nodes.first { it.id == "head" }.step)
        assertEquals(4, layout.nodes.first { it.id == "action-0" }.step)
        assertTrue(layout.nodes.all { it.frame.width >= 232f })
        val frames = layout.nodes.associate { it.id to it.frame }
        assertTrue(frames.getValue("head").bottom < frames.getValue("agent").top)
        layout.connectors.forEach {
            assertEquals(frames.getValue(it.edge.from).bottom, it.points.first().y)
            assertEquals(frames.getValue(it.edge.to).top, it.points.last().y)
        }
        val reversed = AgentTreeLayout.calculate(snapshot.copy(nodes = snapshot.nodes.reversed(), edges = snapshot.edges.reversed()), 360f)
        assertEquals(layout, reversed)
    }

    @Test fun `long delegation edges route outside unrelated card interiors`() {
        val layout = AgentTreeLayout.calculate(graph(100), 320f)
        layout.connectors.forEach { connector ->
            layout.nodes.filter { it.id != connector.edge.from && it.id != connector.edge.to }.forEach { card ->
                connector.points.zipWithNext().forEach { (start, end) ->
                    assertFalse("${connector.edge} crosses ${card.id}", AgentTreeLayout.segmentIntersects(start, end, card.frame))
                }
            }
        }
        assertTrue(layout.width <= 360f)
        assertEquals(1, layout.branches.size)
        assertTrue(layout.connectors.first { it.edge.from == "agent" && it.edge.to == "summary" }.points.size > 4)
    }

    @Test fun `branches occupy separate lanes and missing edge endpoints are ignored`() {
        val snapshot = graph().let { original ->
            original.copy(nodes = original.nodes + AgentRunNode("agent-2", "root", "agent", "Second", "queued", 20),
                edges = original.edges + listOf(AgentRunEdge("head", "agent-2", "sequence"), AgentRunEdge("missing", "agent-2", "delegation")))
        }
        val layout = AgentTreeLayout.calculate(snapshot, 320f)
        val first = layout.nodes.first { it.id == "agent" }.frame
        val second = layout.nodes.first { it.id == "agent-2" }.frame
        assertEquals(first.top, second.top)
        assertTrue(first.right < second.left)
        assertTrue(layout.width > 320f)
        assertFalse(layout.connectors.any { it.edge.from == "missing" })
    }

    @Test fun `empty duplicate and cyclic input remain bounded`() {
        assertTrue(AgentTreeLayout.calculate(AgentRunSnapshot("empty", "planning"), 280f).nodes.isEmpty())
        val source = graph()
        val cyclic = source.copy(nodes = source.nodes + source.nodes.first(), edges = source.edges + AgentRunEdge("summary", "head", "sequence"))
        val layout = AgentTreeLayout.calculate(cyclic, 280f)
        assertEquals(source.nodes.size, layout.nodes.size)
        assertTrue(layout.width.isFinite())
        assertTrue(layout.height.isFinite())
    }

    private fun graph(actions: Int = 2): AgentRunSnapshot {
        val nodes = mutableListOf(
            AgentRunNode("root", kind = "root", title = "Task", status = "running", order = 0),
            AgentRunNode("head", "root", "head", "Head", "completed", 10),
            AgentRunNode("agent", "root", "agent", "Reviewer", "running", 20),
            AgentRunNode("approval", "agent", "approval", "Approval", "completed", 30),
        )
        repeat(actions) { nodes += AgentRunNode("action-$it", "agent", "action", "Action", "queued", 40 + it) }
        nodes += AgentRunNode("summary", "agent", "summary", "Summary", "queued", 40 + actions)
        val edges = mutableListOf(AgentRunEdge("root", "head", "delegation"), AgentRunEdge("root", "agent", "delegation"),
            AgentRunEdge("head", "agent", "sequence"), AgentRunEdge("agent", "approval", "delegation"))
        (nodes.drop(4)).forEachIndexed { index, node ->
            edges += AgentRunEdge("agent", node.id, "delegation")
            edges += AgentRunEdge(if (index == 0) "approval" else "action-${index - 1}", node.id, "sequence")
        }
        return AgentRunSnapshot("run", "executing", nodes = nodes, edges = edges)
    }
}
