package domain

import (
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

// WorkerRef represents a reference to either a device or a sub-orch.
// Format: "device:<id>" or "orch:<id>"
type WorkerRef string

const (
	WorkerRefPrefixDevice  = "device:"
	WorkerRefPrefixOrch = "orch:"
)

// NewDeviceRef creates a WorkerRef for a device
func NewDeviceRef(deviceID string) WorkerRef {
	return WorkerRef(WorkerRefPrefixDevice + deviceID)
}

// NewOrchRef creates a WorkerRef for a sub-orch
func NewOrchRef(orchID string) WorkerRef {
	return WorkerRef(WorkerRefPrefixOrch + orchID)
}

// IsDevice returns true if this ref points to a device
func (r WorkerRef) IsDevice() bool {
	return strings.HasPrefix(string(r), WorkerRefPrefixDevice)
}

// IsOrch returns true if this ref points to a sub-orch
func (r WorkerRef) IsOrch() bool {
	return strings.HasPrefix(string(r), WorkerRefPrefixOrch)
}

// ID returns the underlying device or orch ID
func (r WorkerRef) ID() string {
	s := string(r)
	if i := strings.Index(s, ":"); i >= 0 {
		return s[i+1:]
	}
	return s // legacy: plain ID treated as device
}

// Type returns "device" or "orch"
func (r WorkerRef) Type() string {
	if r.IsOrch() {
		return "orch"
	}
	return "device"
}

// String returns the full ref string
func (r WorkerRef) String() string {
	return string(r)
}

// ParseWorkerRef parses a string into a WorkerRef.
// Plain IDs without prefix are treated as device refs for backward compatibility.
func ParseWorkerRef(s string) WorkerRef {
	if strings.HasPrefix(s, WorkerRefPrefixDevice) || strings.HasPrefix(s, WorkerRefPrefixOrch) {
		return WorkerRef(s)
	}
	// Legacy: plain ID → device
	return NewDeviceRef(s)
}

// OrchGroup represents a federation of orchs
type OrchGroup struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	OrchIDs  []string `json:"orchIds"`

	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// NewOrchGroup creates a new orch group
func NewOrchGroup(name string, orchIDs []string) *OrchGroup {
	now := time.Now()
	return &OrchGroup{
		ID:         uuid.New().String(),
		Name:       name,
		OrchIDs: orchIDs,
		CreatedAt:  now,
		UpdatedAt:  now,
	}
}

// Validate checks the orch group configuration
func (g *OrchGroup) Validate() error {
	if g.Name == "" {
		return fmt.Errorf("orch group name is required")
	}
	if len(g.OrchIDs) == 0 {
		return fmt.Errorf("orch group must contain at least one orch")
	}
	return nil
}
