package repository

import (
	"context"

	"github.com/s1ckdark/hydra/internal/domain"
)

// DeviceRepository defines operations for device persistence
type DeviceRepository interface {
	// Save creates or updates a device
	Save(ctx context.Context, device *domain.Device) error

	// GetByID retrieves a device by its ID
	GetByID(ctx context.Context, id string) (*domain.Device, error)

	// GetAll retrieves all devices
	GetAll(ctx context.Context) ([]*domain.Device, error)

	// GetByFilter retrieves devices matching the filter
	GetByFilter(ctx context.Context, filter domain.DeviceFilter) ([]*domain.Device, error)

	// Delete removes a device by ID
	Delete(ctx context.Context, id string) error

	// SaveMany saves multiple devices
	SaveMany(ctx context.Context, devices []*domain.Device) error
}

// OrchRepository defines operations for orch persistence
type OrchRepository interface {
	// Create creates a new orch
	Create(ctx context.Context, orch *domain.Orch) error

	// Update updates an existing orch
	Update(ctx context.Context, orch *domain.Orch) error

	// GetByID retrieves a orch by its ID
	GetByID(ctx context.Context, id string) (*domain.Orch, error)

	// GetByName retrieves a orch by its name
	GetByName(ctx context.Context, name string) (*domain.Orch, error)

	// GetAll retrieves all orchs
	GetAll(ctx context.Context) ([]*domain.Orch, error)

	// GetByStatus retrieves orchs by status
	GetByStatus(ctx context.Context, status domain.OrchStatus) ([]*domain.Orch, error)

	// Delete removes a orch by ID
	Delete(ctx context.Context, id string) error

	// GetOrchByDeviceID finds the orch that contains a device
	GetOrchByDeviceID(ctx context.Context, deviceID string) (*domain.Orch, error)
}

// OrchNodeRepository defines operations for orch node persistence
type OrchNodeRepository interface {
	// Save creates or updates a orch node
	Save(ctx context.Context, node *domain.OrchNode) error

	// GetByDeviceAndOrch retrieves a node by device and orch IDs
	GetByDeviceAndOrch(ctx context.Context, deviceID, orchID string) (*domain.OrchNode, error)

	// GetByOrch retrieves all nodes for a orch
	GetByOrch(ctx context.Context, orchID string) ([]*domain.OrchNode, error)

	// Delete removes a node from a orch
	Delete(ctx context.Context, deviceID, orchID string) error
}

// MetricsRepository defines operations for metrics persistence
type MetricsRepository interface {
	// Save stores metrics for a device
	Save(ctx context.Context, metrics *domain.DeviceMetrics) error

	// GetLatest retrieves the latest metrics for a device
	GetLatest(ctx context.Context, deviceID string) (*domain.DeviceMetrics, error)

	// GetHistory retrieves historical metrics for a device
	GetHistory(ctx context.Context, deviceID string, limit int) (*domain.MetricsHistory, error)

	// GetSnapshot retrieves the latest metrics for all devices
	GetSnapshot(ctx context.Context) (*domain.MetricsSnapshot, error)

	// Cleanup removes old metrics data
	Cleanup(ctx context.Context, olderThanDays int) error
}

// TaskGroupRepository defines operations for task group persistence.
// (Tasks use domain.TaskRepository so domain.TaskQueue can depend on it
// without importing this package — avoids an import cycle.)
type TaskGroupRepository interface {
	Save(ctx context.Context, group *domain.TaskGroup) error
	GetByID(ctx context.Context, id string) (*domain.TaskGroup, error)
}

// UnitOfWork provides transactional support
type UnitOfWork interface {
	// Begin starts a new transaction
	Begin(ctx context.Context) (Transaction, error)
}

// Transaction represents a database transaction
type Transaction interface {
	// Commit commits the transaction
	Commit() error

	// Rollback rolls back the transaction
	Rollback() error

	// Devices returns the device repository for this transaction
	Devices() DeviceRepository

	// Orchs returns the orch repository for this transaction
	Orchs() OrchRepository

	// OrchNodes returns the orch node repository for this transaction
	OrchNodes() OrchNodeRepository

	// Metrics returns the metrics repository for this transaction
	Metrics() MetricsRepository

	// Tasks returns the task repository for this transaction
	Tasks() domain.TaskRepository

	// TaskGroups returns the task group repository for this transaction
	TaskGroups() TaskGroupRepository
}

// Repositories provides access to all repositories
type Repositories struct {
	Devices    DeviceRepository
	Orchs      OrchRepository
	OrchNodes  OrchNodeRepository
	Metrics    MetricsRepository
	Tasks      domain.TaskRepository
	TaskGroups TaskGroupRepository
	UnitOfWork UnitOfWork
}
