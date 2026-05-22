package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/s1ckdark/hydra/internal/domain"
)

// DeviceLister mirrors the read surface of DeviceUseCase the agent needs.
// We avoid importing the full usecase package to keep this layer thin.
type DeviceLister interface {
	ListDevices(ctx context.Context, forceRefresh bool) ([]*domain.Device, error)
}

// OrchLister returns the current orchs for read actions.
type OrchLister interface {
	ListOrchs(ctx context.Context) ([]*domain.Orch, error)
}

// MetricsReader fetches the latest per-device metrics for read actions.
type MetricsReader interface {
	GetDeviceMetrics(ctx context.Context, deviceID string) (*domain.DeviceMetrics, error)
}

// GPULister returns the latest GPU snapshot.
type GPULister interface {
	GetGPUSnapshot(ctx context.Context) ([]*domain.GPUNodeMetrics, error)
}

// ActionRegistry dispatches Actions to their handlers. Read actions only
// in this commit; write actions arrive in T3.
type ActionRegistry struct {
	devices DeviceLister
	orchs   OrchLister
	metrics MetricsReader
	gpu     GPULister
}

func NewActionRegistry(d DeviceLister, o OrchLister, m MetricsReader, g GPULister) *ActionRegistry {
	return &ActionRegistry{devices: d, orchs: o, metrics: m, gpu: g}
}

// Run dispatches a single Action and returns its ActionResult.
func (r *ActionRegistry) Run(ctx context.Context, a Action) ActionResult {
	switch a.Type {
	case "list_devices":
		return r.runListDevices(ctx, a)
	case "list_orchs":
		return r.runListOrchs(ctx, a)
	case "get_metrics":
		return r.runGetMetrics(ctx, a)
	case "get_gpu":
		return r.runGetGPU(ctx, a)
	default:
		return errResult(a.Type, fmt.Errorf("unknown action %q", a.Type))
	}
}

func (r *ActionRegistry) runListDevices(ctx context.Context, a Action) ActionResult {
	devs, err := r.devices.ListDevices(ctx, false)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, devs)
}

func (r *ActionRegistry) runListOrchs(ctx context.Context, a Action) ActionResult {
	if r.orchs == nil {
		return errResult(a.Type, errors.New("orch service unavailable"))
	}
	out, err := r.orchs.ListOrchs(ctx)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, out)
}

type getMetricsArgs struct {
	DeviceID string `json:"device_id"`
}

func (r *ActionRegistry) runGetMetrics(ctx context.Context, a Action) ActionResult {
	if r.metrics == nil {
		return errResult(a.Type, errors.New("metrics service unavailable"))
	}
	var args getMetricsArgs
	if err := json.Unmarshal(a.Args, &args); err != nil {
		return errResult(a.Type, fmt.Errorf("args: %w", err))
	}
	if args.DeviceID == "" {
		return errResult(a.Type, errors.New("device_id required"))
	}
	m, err := r.metrics.GetDeviceMetrics(ctx, args.DeviceID)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, m)
}

func (r *ActionRegistry) runGetGPU(ctx context.Context, a Action) ActionResult {
	if r.gpu == nil {
		return errResult(a.Type, errors.New("gpu service unavailable"))
	}
	out, err := r.gpu.GetGPUSnapshot(ctx)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, out)
}

func okResult(t string, v any) ActionResult {
	raw, err := json.Marshal(v)
	if err != nil {
		return errResult(t, err)
	}
	return ActionResult{Type: t, Status: "ok", Output: raw}
}

func errResult(t string, err error) ActionResult {
	return ActionResult{Type: t, Status: "error", Error: err.Error()}
}
