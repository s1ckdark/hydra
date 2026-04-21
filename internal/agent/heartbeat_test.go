package agent

import (
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

func TestHeartbeatMonitor_DetectFailure(t *testing.T) {
	mon := NewHeartbeatMonitor(3*time.Second, 500*time.Millisecond)

	mon.RecordHeartbeat(domain.Heartbeat{
		NodeID:    "head-1",
		OrchID: "orch-1",
		Role:      domain.NodeRoleHead,
		Timestamp: time.Now(),
	})

	if !mon.IsNodeHealthy("head-1") {
		t.Error("expected head-1 to be healthy")
	}

	// Simulate timeout
	mon.nodeHealth["head-1"].LastHeartbeat = time.Now().Add(-4 * time.Second)

	if mon.IsNodeHealthy("head-1") {
		t.Error("expected head-1 to be unhealthy after timeout")
	}

	failed := mon.GetFailedNodes("orch-1")
	if len(failed) != 1 || failed[0].NodeID != "head-1" {
		t.Errorf("expected 1 failed node (head-1), got %v", failed)
	}
}

func TestHeartbeatMonitor_GetHealthyWorkers(t *testing.T) {
	mon := NewHeartbeatMonitor(15*time.Second, time.Second)
	now := time.Now()
	mon.RecordHeartbeat(domain.Heartbeat{NodeID: "head-1", OrchID: "c1", Role: domain.NodeRoleHead, Timestamp: now})
	mon.RecordHeartbeat(domain.Heartbeat{NodeID: "worker-1", OrchID: "c1", Role: domain.NodeRoleWorker, Timestamp: now})
	mon.RecordHeartbeat(domain.Heartbeat{NodeID: "worker-2", OrchID: "c1", Role: domain.NodeRoleWorker, Timestamp: now})

	workers := mon.GetHealthyWorkers("c1")
	if len(workers) != 2 {
		t.Errorf("expected 2 healthy workers, got %d", len(workers))
	}
}
