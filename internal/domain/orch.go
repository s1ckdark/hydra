package domain

import (
	"errors"
	"time"
)

// OrchMode represents the execution mode of a orch
type OrchMode string

const (
	OrchModeBasic OrchMode = "basic" // SSH-based direct execution
	OrchModeRay   OrchMode = "ray"   // Ray orch orchestration
)

// OrchStatus represents the current status of a orch
type OrchStatus string

const (
	OrchStatusPending  OrchStatus = "pending"
	OrchStatusStarting OrchStatus = "starting"
	OrchStatusRunning  OrchStatus = "running"
	OrchStatusStopping OrchStatus = "stopping"
	OrchStatusStopped  OrchStatus = "stopped"
	OrchStatusError    OrchStatus = "error"
)

// CoordinatorTransfer records a head node change event
type CoordinatorTransfer struct {
	FromDeviceID string    `json:"fromDeviceId"`
	ToDeviceID   string    `json:"toDeviceId"`
	Reason       string    `json:"reason"` // "manual", "failover", "election"
	Timestamp    time.Time `json:"timestamp"`
}

// Orch errors
var (
	ErrOrchNotFound     = errors.New("orch not found")
	ErrOrchAlreadyExist = errors.New("orch already exists")
	ErrOrchInUse        = errors.New("orch is currently in use")
	ErrCoordinatorRequired    = errors.New("head node is required")
	ErrNodeAlreadyInOrch = errors.New("node is already in a orch")
	ErrNodeNotInOrch    = errors.New("node is not in this orch")
	ErrCannotRemoveHead    = errors.New("cannot remove head node, change head first")
)

// Orch represents a orch configuration
type Orch struct {
	ID          string        `json:"id"`
	Name        string        `json:"name"`
	Description string        `json:"description"`
	Mode        OrchMode   `json:"mode"`
	Status      OrchStatus `json:"status"`
	CoordinatorID  string        `json:"coordinatorId"`
	WorkerIDs   []string      `json:"workerIds"`
	DashboardURL string       `json:"dashboardUrl"`

	// Ray configuration (only used when Mode == "ray")
	RayPort         int    `json:"rayPort,omitempty"`
	DashboardPort   int    `json:"dashboardPort,omitempty"`
	ObjectStoreMemory int64 `json:"objectStoreMemory,omitempty"` // bytes

	// Metadata
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
	StartedAt *time.Time `json:"startedAt,omitempty"`
	StoppedAt *time.Time `json:"stoppedAt,omitempty"`

	// Error tracking
	LastError     string    `json:"lastError,omitempty"`
	LastErrorAt   *time.Time `json:"lastErrorAt,omitempty"`

	// Head transfer history
	HeadHistory []CoordinatorTransfer `json:"headHistory,omitempty"`
}

// NewOrch creates a new orch with default settings
func NewOrch(name, coordinatorID string, workerIDs []string) *Orch {
	return NewOrchWithMode(name, coordinatorID, workerIDs, OrchModeBasic)
}

// NewOrchWithMode creates a new orch with the specified mode
func NewOrchWithMode(name, coordinatorID string, workerIDs []string, mode OrchMode) *Orch {
	now := time.Now()
	c := &Orch{
		Name:       name,
		Mode:       mode,
		Status:     OrchStatusPending,
		CoordinatorID: coordinatorID,
		WorkerIDs:  workerIDs,
		CreatedAt:  now,
		UpdatedAt:  now,
	}
	if mode == OrchModeRay {
		c.RayPort = 6379
		c.DashboardPort = 8265
	}
	return c
}

// IsRayMode returns true if the orch uses Ray orchestration
func (c *Orch) IsRayMode() bool {
	return c.Mode == OrchModeRay
}

// TotalNodes returns the total number of nodes (head + workers)
func (c *Orch) TotalNodes() int {
	return 1 + len(c.WorkerIDs)
}

// AllNodeIDs returns all node IDs including head and workers
func (c *Orch) AllNodeIDs() []string {
	ids := make([]string, 0, c.TotalNodes())
	ids = append(ids, c.CoordinatorID)
	ids = append(ids, c.WorkerIDs...)
	return ids
}

// WorkerRefs returns WorkerIDs parsed as WorkerRef values
func (c *Orch) WorkerRefs() []WorkerRef {
	refs := make([]WorkerRef, len(c.WorkerIDs))
	for i, id := range c.WorkerIDs {
		refs[i] = ParseWorkerRef(id)
	}
	return refs
}

// DeviceWorkerIDs returns only the device IDs from workers (excludes sub-orchs)
func (c *Orch) DeviceWorkerIDs() []string {
	var ids []string
	for _, id := range c.WorkerIDs {
		ref := ParseWorkerRef(id)
		if ref.IsDevice() {
			ids = append(ids, ref.ID())
		}
	}
	return ids
}

// OrchWorkerIDs returns only the sub-orch IDs from workers
func (c *Orch) OrchWorkerIDs() []string {
	var ids []string
	for _, id := range c.WorkerIDs {
		ref := ParseWorkerRef(id)
		if ref.IsOrch() {
			ids = append(ids, ref.ID())
		}
	}
	return ids
}

// HasWorker checks if a device is a worker in this orch
func (c *Orch) HasWorker(deviceID string) bool {
	for _, id := range c.WorkerIDs {
		ref := ParseWorkerRef(id)
		if ref.ID() == deviceID {
			return true
		}
	}
	return false
}

// IsRunning returns true if the orch is in running state
func (c *Orch) IsRunning() bool {
	return c.Status == OrchStatusRunning
}

// CanModify returns true if the orch can be modified
func (c *Orch) CanModify() bool {
	return c.Status == OrchStatusPending ||
		   c.Status == OrchStatusStopped ||
		   c.Status == OrchStatusRunning
}

// AddWorker adds a worker node to the orch
func (c *Orch) AddWorker(deviceID string) error {
	if deviceID == c.CoordinatorID {
		return errors.New("cannot add head node as worker")
	}
	if c.HasWorker(deviceID) {
		return ErrNodeAlreadyInOrch
	}
	c.WorkerIDs = append(c.WorkerIDs, deviceID)
	c.UpdatedAt = time.Now()
	return nil
}

// RemoveWorker removes a worker node from the orch
func (c *Orch) RemoveWorker(deviceID string) error {
	if deviceID == c.CoordinatorID {
		return ErrCannotRemoveHead
	}

	for i, id := range c.WorkerIDs {
		if id == deviceID {
			c.WorkerIDs = append(c.WorkerIDs[:i], c.WorkerIDs[i+1:]...)
			c.UpdatedAt = time.Now()
			return nil
		}
	}
	return ErrNodeNotInOrch
}

// ChangeHead changes the head node of the orch.
// The old head becomes a worker, and the new head is removed from workers if present.
// reason should be one of "manual", "failover", or "election".
func (c *Orch) ChangeHead(newHeadID string, reason string) error {
	if newHeadID == c.CoordinatorID {
		return nil // No change needed
	}

	oldHeadID := c.CoordinatorID

	// Remove new head from workers if present
	for i, id := range c.WorkerIDs {
		if id == newHeadID {
			c.WorkerIDs = append(c.WorkerIDs[:i], c.WorkerIDs[i+1:]...)
			break
		}
	}

	// Add old head to workers
	c.WorkerIDs = append(c.WorkerIDs, oldHeadID)

	// Set new head
	c.CoordinatorID = newHeadID
	now := time.Now()
	c.UpdatedAt = now

	// Record transfer history
	c.HeadHistory = append(c.HeadHistory, CoordinatorTransfer{
		FromDeviceID: oldHeadID,
		ToDeviceID:   newHeadID,
		Reason:       reason,
		Timestamp:    now,
	})

	return nil
}

// SetError sets an error state on the orch
func (c *Orch) SetError(err string) {
	now := time.Now()
	c.Status = OrchStatusError
	c.LastError = err
	c.LastErrorAt = &now
	c.UpdatedAt = now
}
