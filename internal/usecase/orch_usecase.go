package usecase

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/repository"
)

// OrchUseCase handles orch-related business logic
type OrchUseCase struct {
	repos      *repository.Repositories
	rayManager RayManager
}

// RayManager interface for Ray orch operations
type RayManager interface {
	// StartHead starts Ray as head node
	StartHead(ctx context.Context, device *domain.Device, port, dashboardPort int) error

	// StartWorker starts Ray as worker node
	StartWorker(ctx context.Context, device *domain.Device, headAddress string) error

	// StopRay stops Ray on a device
	StopRay(ctx context.Context, device *domain.Device) error

	// GetOrchInfo gets Ray orch information from head node
	GetOrchInfo(ctx context.Context, headDevice *domain.Device) (*domain.RayOrchInfo, error)

	// CheckRayInstalled checks if Ray is installed on a device
	CheckRayInstalled(ctx context.Context, device *domain.Device) (bool, string, error)

	// InstallRay installs Ray on a device
	InstallRay(ctx context.Context, device *domain.Device, version string) error

	// HasRunningJobs checks if there are running jobs on the orch
	HasRunningJobs(ctx context.Context, headDevice *domain.Device) (bool, error)
}

// NewOrchUseCase creates a new OrchUseCase
func NewOrchUseCase(repos *repository.Repositories, rayManager RayManager) *OrchUseCase {
	return &OrchUseCase{
		repos:      repos,
		rayManager: rayManager,
	}
}

// CreateOrch creates a new orch configuration
func (uc *OrchUseCase) CreateOrch(ctx context.Context, name string, headID string, workerIDs []string, mode ...domain.OrchMode) (*domain.Orch, error) {
	// Check if orch name already exists
	existing, err := uc.repos.Orchs.GetByName(ctx, name)
	if err != nil && !errors.Is(err, domain.ErrOrchNotFound) {
		return nil, fmt.Errorf("failed to check existing orch name: %w", err)
	}
	if existing != nil {
		return nil, domain.ErrOrchAlreadyExist
	}

	// Check if head node is already in a orch
	existingOrch, err := uc.repos.Orchs.GetOrchByDeviceID(ctx, headID)
	if err != nil && !errors.Is(err, domain.ErrOrchNotFound) {
		return nil, fmt.Errorf("failed to check head node orch membership: %w", err)
	}
	if existingOrch != nil {
		return nil, fmt.Errorf("head node is already in orch: %s", existingOrch.Name)
	}

	// Check if any worker is already in a orch
	for _, wid := range workerIDs {
		existingOrch, err := uc.repos.Orchs.GetOrchByDeviceID(ctx, wid)
		if err != nil && !errors.Is(err, domain.ErrOrchNotFound) {
			return nil, fmt.Errorf("failed to check worker orch membership: %w", err)
		}
		if existingOrch != nil {
			return nil, fmt.Errorf("worker %s is already in orch: %s", wid, existingOrch.Name)
		}
	}

	// Create orch
	orchMode := domain.OrchModeBasic
	if len(mode) > 0 && mode[0] != "" {
		orchMode = mode[0]
	}
	orch := domain.NewOrchWithMode(name, headID, workerIDs, orchMode)

	if err := uc.repos.Orchs.Create(ctx, orch); err != nil {
		return nil, fmt.Errorf("failed to create orch: %w", err)
	}

	return orch, nil
}

// GetOrch retrieves a orch by name
func (uc *OrchUseCase) GetOrch(ctx context.Context, name string) (*domain.Orch, error) {
	return uc.getOrchByIDOrName(ctx, name)
}

// ListOrchs retrieves all orchs
func (uc *OrchUseCase) ListOrchs(ctx context.Context) ([]*domain.Orch, error) {
	return uc.repos.Orchs.GetAll(ctx)
}

// StartOrch starts a Ray orch
func (uc *OrchUseCase) StartOrch(ctx context.Context, name string, devices map[string]*domain.Device) error {
	orch, err := uc.getOrchByIDOrName(ctx, name)
	if err != nil {
		return domain.ErrOrchNotFound
	}

	if orch.Status == domain.OrchStatusRunning {
		return fmt.Errorf("orch is already running")
	}

	// Update status
	orch.Status = domain.OrchStatusStarting
	now := time.Now()
	orch.StartedAt = &now
	if err := uc.repos.Orchs.Update(ctx, orch); err != nil {
		return err
	}

	// Get head device
	headDevice := devices[orch.CoordinatorID]
	if headDevice == nil {
		orch.SetError("head device not found")
		uc.repos.Orchs.Update(ctx, orch)
		return fmt.Errorf("head device not found")
	}

	// Start head node
	if err := uc.rayManager.StartHead(ctx, headDevice, orch.RayPort, orch.DashboardPort); err != nil {
		orch.SetError(fmt.Sprintf("failed to start head: %v", err))
		uc.repos.Orchs.Update(ctx, orch)
		return fmt.Errorf("failed to start head node: %w", err)
	}

	// Start workers
	headAddress := fmt.Sprintf("%s:%d", headDevice.TailscaleIP, orch.RayPort)
	for _, workerID := range orch.WorkerIDs {
		workerDevice := devices[workerID]
		if workerDevice == nil {
			continue
		}

		if err := uc.rayManager.StartWorker(ctx, workerDevice, headAddress); err != nil {
			// Log error but continue with other workers
			fmt.Printf("Warning: failed to start worker %s: %v\n", workerDevice.Name, err)
		}
	}

	// Update status
	orch.Status = domain.OrchStatusRunning
	orch.DashboardURL = fmt.Sprintf("http://%s:%d", headDevice.TailscaleIP, orch.DashboardPort)
	orch.UpdatedAt = time.Now()

	return uc.repos.Orchs.Update(ctx, orch)
}

// StopOrch stops a Ray orch
func (uc *OrchUseCase) StopOrch(ctx context.Context, name string, devices map[string]*domain.Device, force bool) error {
	orch, err := uc.getOrchByIDOrName(ctx, name)
	if err != nil {
		return domain.ErrOrchNotFound
	}

	if !force {
		// Check for running jobs
		headDevice := devices[orch.CoordinatorID]
		if headDevice != nil {
			hasJobs, err := uc.rayManager.HasRunningJobs(ctx, headDevice)
			if err == nil && hasJobs {
				return domain.ErrOrchInUse
			}
		}
	}

	// Update status
	orch.Status = domain.OrchStatusStopping
	if err := uc.repos.Orchs.Update(ctx, orch); err != nil {
		return err
	}

	// Stop all workers first
	var stopErrors []string
	for _, workerID := range orch.WorkerIDs {
		workerDevice := devices[workerID]
		if workerDevice != nil {
			if err := uc.rayManager.StopRay(ctx, workerDevice); err != nil {
				stopErrors = append(stopErrors, fmt.Sprintf("worker %s: %v", workerID, err))
			}
		}
	}

	// Stop head
	headDevice := devices[orch.CoordinatorID]
	if headDevice != nil {
		if err := uc.rayManager.StopRay(ctx, headDevice); err != nil {
			stopErrors = append(stopErrors, fmt.Sprintf("head %s: %v", orch.CoordinatorID, err))
		}
	}

	if len(stopErrors) > 0 {
		orch.SetError("failed to stop Ray on one or more nodes")
		uc.repos.Orchs.Update(ctx, orch)
		return fmt.Errorf("failed to stop Ray on %d node(s): %s", len(stopErrors), strings.Join(stopErrors, "; "))
	}

	// Update status
	orch.Status = domain.OrchStatusStopped
	now := time.Now()
	orch.StoppedAt = &now
	orch.UpdatedAt = now

	return uc.repos.Orchs.Update(ctx, orch)
}

// DeleteOrch deletes a orch
func (uc *OrchUseCase) DeleteOrch(ctx context.Context, name string, devices map[string]*domain.Device, force bool) error {
	orch, err := uc.getOrchByIDOrName(ctx, name)
	if err != nil {
		return domain.ErrOrchNotFound
	}

	// Stop orch if running
	if orch.IsRunning() {
		if err := uc.StopOrch(ctx, name, devices, force); err != nil && !force {
			return err
		}
	}

	return uc.repos.Orchs.Delete(ctx, orch.ID)
}

// AddWorker adds a worker to the orch
func (uc *OrchUseCase) AddWorker(ctx context.Context, orchName string, deviceID string, device *domain.Device, headDevice *domain.Device) error {
	orch, err := uc.getOrchByIDOrName(ctx, orchName)
	if err != nil {
		return domain.ErrOrchNotFound
	}

	// Check if device is already in another orch
	existingOrch, err := uc.repos.Orchs.GetOrchByDeviceID(ctx, deviceID)
	if err != nil && !errors.Is(err, domain.ErrOrchNotFound) {
		return fmt.Errorf("failed to check existing orch membership: %w", err)
	}
	if existingOrch != nil && existingOrch.ID != orch.ID {
		return fmt.Errorf("device is already in orch: %s", existingOrch.Name)
	}

	// Add worker to orch configuration
	if err := orch.AddWorker(deviceID); err != nil {
		return err
	}

	// If orch is running, connect the new worker
	if orch.IsRunning() && device != nil && headDevice != nil {
		headAddress := fmt.Sprintf("%s:%d", headDevice.TailscaleIP, orch.RayPort)
		if err := uc.rayManager.StartWorker(ctx, device, headAddress); err != nil {
			return fmt.Errorf("failed to connect worker: %w", err)
		}
	}

	return uc.repos.Orchs.Update(ctx, orch)
}

// RemoveWorker removes a worker from the orch
func (uc *OrchUseCase) RemoveWorker(ctx context.Context, orchName string, deviceID string, device *domain.Device) error {
	orch, err := uc.getOrchByIDOrName(ctx, orchName)
	if err != nil {
		return domain.ErrOrchNotFound
	}

	// Remove worker from orch configuration
	if err := orch.RemoveWorker(deviceID); err != nil {
		return err
	}

	// If orch is running, stop Ray on the worker
	if orch.IsRunning() && device != nil {
		if err := uc.rayManager.StopRay(ctx, device); err != nil {
			// Log but don't fail
			fmt.Printf("Warning: failed to stop Ray on worker: %v\n", err)
		}
	}

	return uc.repos.Orchs.Update(ctx, orch)
}

// ChangeHead changes the head node of the orch
func (uc *OrchUseCase) ChangeHead(ctx context.Context, orchName string, newHeadID string, devices map[string]*domain.Device) error {
	orch, err := uc.getOrchByIDOrName(ctx, orchName)
	if err != nil {
		return domain.ErrOrchNotFound
	}

	wasRunning := orch.IsRunning()

	// Stop orch if running
	if wasRunning {
		if err := uc.StopOrch(ctx, orchName, devices, true); err != nil {
			return fmt.Errorf("failed to stop orch: %w", err)
		}
	}

	// Change head in configuration
	if err := orch.ChangeHead(newHeadID, "manual"); err != nil {
		return err
	}

	if err := uc.repos.Orchs.Update(ctx, orch); err != nil {
		return err
	}

	// Restart orch if it was running
	if wasRunning {
		if err := uc.StartOrch(ctx, orchName, devices); err != nil {
			return fmt.Errorf("failed to restart orch with new head: %w", err)
		}
	}

	return nil
}

// GetOrchStatus gets the current status of a orch
func (uc *OrchUseCase) GetOrchStatus(ctx context.Context, name string, headDevice *domain.Device) (*domain.RayOrchInfo, error) {
	orch, err := uc.getOrchByIDOrName(ctx, name)
	if err != nil {
		return nil, domain.ErrOrchNotFound
	}

	if !orch.IsRunning() {
		return nil, fmt.Errorf("orch is not running")
	}

	if headDevice == nil {
		return nil, fmt.Errorf("head device not available")
	}

	return uc.rayManager.GetOrchInfo(ctx, headDevice)
}

func (uc *OrchUseCase) getOrchByIDOrName(ctx context.Context, identifier string) (*domain.Orch, error) {
	orch, err := uc.repos.Orchs.GetByID(ctx, identifier)
	if err == nil && orch != nil {
		return orch, nil
	}
	if err != nil && !errors.Is(err, domain.ErrOrchNotFound) {
		return nil, err
	}
	return uc.repos.Orchs.GetByName(ctx, identifier)
}
