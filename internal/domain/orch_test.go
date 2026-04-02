package domain

import (
	"testing"
)

func TestNewOrch(t *testing.T) {
	workers := []string{"w1", "w2"}
	c := NewOrch("test-orch", "head1", workers)

	if c.Name != "test-orch" {
		t.Errorf("Name = %q, want %q", c.Name, "test-orch")
	}
	if c.CoordinatorID != "head1" {
		t.Errorf("CoordinatorID = %q, want %q", c.CoordinatorID, "head1")
	}
	if c.Status != OrchStatusPending {
		t.Errorf("Status = %q, want %q", c.Status, OrchStatusPending)
	}
	if c.Mode != OrchModeBasic {
		t.Errorf("Mode = %q, want %q", c.Mode, OrchModeBasic)
	}
	// Basic mode should not set Ray ports
	if c.RayPort != 0 {
		t.Errorf("RayPort = %d, want 0 for basic mode", c.RayPort)
	}
	// Ray mode should set ports
	rc := NewOrchWithMode("ray-test", "head1", []string{"w1"}, OrchModeRay)
	if rc.RayPort != 6379 {
		t.Errorf("Ray mode RayPort = %d, want 6379", rc.RayPort)
	}
	if rc.DashboardPort != 8265 {
		t.Errorf("Ray mode DashboardPort = %d, want 8265", rc.DashboardPort)
	}
	if len(c.WorkerIDs) != 2 {
		t.Fatalf("WorkerIDs length = %d, want 2", len(c.WorkerIDs))
	}
	if c.CreatedAt.IsZero() {
		t.Error("CreatedAt should not be zero")
	}
}

func TestOrch_TotalNodes(t *testing.T) {
	tests := []struct {
		name    string
		workers []string
		want    int
	}{
		{"head only", nil, 1},
		{"head + 1 worker", []string{"w1"}, 2},
		{"head + 3 workers", []string{"w1", "w2", "w3"}, 4},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := NewOrch("c", "h", tt.workers)
			if got := c.TotalNodes(); got != tt.want {
				t.Errorf("TotalNodes() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestOrch_AllNodeIDs(t *testing.T) {
	c := NewOrch("c", "head1", []string{"w1", "w2"})
	ids := c.AllNodeIDs()

	if len(ids) != 3 {
		t.Fatalf("AllNodeIDs() length = %d, want 3", len(ids))
	}
	if ids[0] != "head1" {
		t.Errorf("first ID = %q, want %q", ids[0], "head1")
	}
	if ids[1] != "w1" || ids[2] != "w2" {
		t.Errorf("worker IDs = %v, want [w1 w2]", ids[1:])
	}
}

func TestOrch_HasWorker(t *testing.T) {
	c := NewOrch("c", "head1", []string{"w1", "w2"})

	if !c.HasWorker("w1") {
		t.Error("HasWorker(w1) = false, want true")
	}
	if c.HasWorker("w3") {
		t.Error("HasWorker(w3) = true, want false")
	}
	if c.HasWorker("head1") {
		t.Error("HasWorker(head1) = true, want false (head is not a worker)")
	}
}

func TestOrch_IsRunning(t *testing.T) {
	c := NewOrch("c", "h", nil)

	if c.IsRunning() {
		t.Error("pending orch should not be running")
	}

	c.Status = OrchStatusRunning
	if !c.IsRunning() {
		t.Error("running orch should be running")
	}
}

func TestOrch_CanModify(t *testing.T) {
	tests := []struct {
		status OrchStatus
		want   bool
	}{
		{OrchStatusPending, true},
		{OrchStatusStopped, true},
		{OrchStatusRunning, true},
		{OrchStatusStarting, false},
		{OrchStatusStopping, false},
		{OrchStatusError, false},
	}

	for _, tt := range tests {
		t.Run(string(tt.status), func(t *testing.T) {
			c := NewOrch("c", "h", nil)
			c.Status = tt.status
			if got := c.CanModify(); got != tt.want {
				t.Errorf("CanModify() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestOrch_AddWorker(t *testing.T) {
	c := NewOrch("c", "head1", []string{"w1"})

	// Add new worker
	if err := c.AddWorker("w2"); err != nil {
		t.Fatalf("AddWorker(w2) error: %v", err)
	}
	if len(c.WorkerIDs) != 2 {
		t.Fatalf("WorkerIDs length = %d, want 2", len(c.WorkerIDs))
	}

	// Duplicate worker
	if err := c.AddWorker("w1"); err != ErrNodeAlreadyInOrch {
		t.Errorf("AddWorker(w1) = %v, want ErrNodeAlreadyInOrch", err)
	}

	// Add head as worker
	if err := c.AddWorker("head1"); err == nil {
		t.Error("AddWorker(head1) should fail")
	}
}

func TestOrch_RemoveWorker(t *testing.T) {
	c := NewOrch("c", "head1", []string{"w1", "w2", "w3"})

	// Remove existing worker
	if err := c.RemoveWorker("w2"); err != nil {
		t.Fatalf("RemoveWorker(w2) error: %v", err)
	}
	if len(c.WorkerIDs) != 2 {
		t.Fatalf("WorkerIDs length = %d, want 2", len(c.WorkerIDs))
	}
	if c.HasWorker("w2") {
		t.Error("w2 should be removed")
	}

	// Remove non-existent worker
	if err := c.RemoveWorker("w99"); err != ErrNodeNotInOrch {
		t.Errorf("RemoveWorker(w99) = %v, want ErrNodeNotInOrch", err)
	}

	// Cannot remove head
	if err := c.RemoveWorker("head1"); err != ErrCannotRemoveHead {
		t.Errorf("RemoveWorker(head1) = %v, want ErrCannotRemoveHead", err)
	}
}

func TestOrch_ChangeHead(t *testing.T) {
	c := NewOrch("c", "head1", []string{"w1", "w2"})

	// Change to existing worker
	if err := c.ChangeHead("w1", "manual"); err != nil {
		t.Fatalf("ChangeHead(w1) error: %v", err)
	}
	if c.CoordinatorID != "w1" {
		t.Errorf("CoordinatorID = %q, want %q", c.CoordinatorID, "w1")
	}
	// Old head should become worker
	if !c.HasWorker("head1") {
		t.Error("old head should become worker")
	}
	// New head should not be in workers
	if c.HasWorker("w1") {
		t.Error("new head should not be in workers")
	}
	// Total node count should remain the same
	if c.TotalNodes() != 3 {
		t.Errorf("TotalNodes() = %d, want 3", c.TotalNodes())
	}

	// Change to same head (no-op)
	if err := c.ChangeHead("w1", "manual"); err != nil {
		t.Fatalf("ChangeHead(same) error: %v", err)
	}

	// Change to external node (not in workers)
	if err := c.ChangeHead("external1", "manual"); err != nil {
		t.Fatalf("ChangeHead(external1) error: %v", err)
	}
	if c.CoordinatorID != "external1" {
		t.Errorf("CoordinatorID = %q, want %q", c.CoordinatorID, "external1")
	}
	// Total nodes should increase by 1 (old head added as worker, external was not removed from workers)
	if c.TotalNodes() != 4 {
		t.Errorf("TotalNodes() = %d, want 4", c.TotalNodes())
	}
}

func TestOrch_SetError(t *testing.T) {
	c := NewOrch("c", "h", nil)
	c.Status = OrchStatusRunning

	c.SetError("connection failed")

	if c.Status != OrchStatusError {
		t.Errorf("Status = %q, want %q", c.Status, OrchStatusError)
	}
	if c.LastError != "connection failed" {
		t.Errorf("LastError = %q, want %q", c.LastError, "connection failed")
	}
	if c.LastErrorAt == nil {
		t.Error("LastErrorAt should not be nil")
	}
}
