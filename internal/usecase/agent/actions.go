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

// CommandRunner runs a shell command on a device. Mirrors the
// DeviceUseCase / handler surface.
type CommandRunner interface {
	ExecuteOnDevice(ctx context.Context, deviceID, command string, timeoutSec int) (*domain.TaskResult, error)
}

// OrchManager covers create/delete used by write actions.
type OrchManager interface {
	CreateOrch(ctx context.Context, name, headID string, workerIDs []string) (*domain.Orch, error)
	DeleteOrch(ctx context.Context, id string, force bool) error
}

// ActionRegistry dispatches Actions to their handlers.
type ActionRegistry struct {
	devices DeviceLister
	orchs   OrchLister
	metrics MetricsReader
	gpu     GPULister
	cmd     CommandRunner
	orchMgr OrchManager
}

func NewActionRegistry(d DeviceLister, o OrchLister, m MetricsReader, g GPULister, c CommandRunner, om OrchManager) *ActionRegistry {
	return &ActionRegistry{devices: d, orchs: o, metrics: m, gpu: g, cmd: c, orchMgr: om}
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
	case "create_orch":
		return r.runCreateOrch(ctx, a)
	case "delete_orch":
		return r.runDeleteOrch(ctx, a)
	case "execute_command":
		return r.runExecuteCommand(ctx, a)
	case "recent_tasks":
		return r.runRecentTasks(ctx, a)
	default:
		return errResult(a.Type, fmt.Errorf("unknown action %q", a.Type))
	}
}

func (r *ActionRegistry) runListDevices(ctx context.Context, a Action) ActionResult {
	if r.devices == nil {
		return errResult(a.Type, errors.New("device service unavailable"))
	}
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
		return errResult(t, fmt.Errorf("marshal output: %w", err))
	}
	return ActionResult{Type: t, Status: "ok", Output: raw}
}

type createOrchArgs struct {
	Name      string   `json:"name"`
	HeadID    string   `json:"head_id"`
	WorkerIDs []string `json:"worker_ids"`
}

func (r *ActionRegistry) runCreateOrch(ctx context.Context, a Action) ActionResult {
	if r.orchMgr == nil {
		return errResult(a.Type, errors.New("orch manager unavailable"))
	}
	var args createOrchArgs
	if err := json.Unmarshal(a.Args, &args); err != nil {
		return errResult(a.Type, fmt.Errorf("args: %w", err))
	}
	o, err := r.orchMgr.CreateOrch(ctx, args.Name, args.HeadID, args.WorkerIDs)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, o)
}

type deleteOrchArgs struct {
	OrchID string `json:"orch_id"`
	Force  bool   `json:"force"`
}

func (r *ActionRegistry) runDeleteOrch(ctx context.Context, a Action) ActionResult {
	if r.orchMgr == nil {
		return errResult(a.Type, errors.New("orch manager unavailable"))
	}
	var args deleteOrchArgs
	if err := json.Unmarshal(a.Args, &args); err != nil {
		return errResult(a.Type, fmt.Errorf("args: %w", err))
	}
	if err := r.orchMgr.DeleteOrch(ctx, args.OrchID, args.Force); err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, map[string]string{"status": "deleted", "orch_id": args.OrchID})
}

type execCmdArgs struct {
	DeviceID       string `json:"device_id"`
	Command        string `json:"command"`
	TimeoutSeconds int    `json:"timeout_seconds"`
}

func (r *ActionRegistry) runExecuteCommand(ctx context.Context, a Action) ActionResult {
	if r.cmd == nil {
		return errResult(a.Type, errors.New("command runner unavailable"))
	}
	var args execCmdArgs
	if err := json.Unmarshal(a.Args, &args); err != nil {
		return errResult(a.Type, fmt.Errorf("args: %w", err))
	}
	timeout := args.TimeoutSeconds
	if timeout <= 0 {
		timeout = 30
	}
	out, err := r.cmd.ExecuteOnDevice(ctx, args.DeviceID, args.Command, timeout)
	if err != nil {
		return errResult(a.Type, err)
	}
	return okResult(a.Type, out)
}

// runRecentTasks is a stub: it returns an empty list with status=ok.
// TODO: wire to the task repo (TaskUseCase.RecentTasks) once that
// surface exists. We deliberately do NOT return an error here — the
// LLM may include this action speculatively, and surfacing it as an
// empty list keeps multi-action plans running. Pin the empty-array
// contract with a test so the future swap is a visible diff.
func (r *ActionRegistry) runRecentTasks(ctx context.Context, a Action) ActionResult {
	return okResult(a.Type, []any{})
}

func errResult(t string, err error) ActionResult {
	return ActionResult{Type: t, Status: "error", Error: err.Error()}
}
