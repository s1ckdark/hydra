package main

import (
	"context"
	"fmt"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/infra/ssh"
	"github.com/s1ckdark/hydra/internal/usecase"
)

// orchManagerAdapter satisfies agent.OrchManager by wrapping OrchUseCase.
//
// CreateOrch forwards directly; the agent interface omits the variadic mode
// argument so OrchUseCase applies its own default.
//
// DeleteOrch requires a map[string]*domain.Device that OrchUseCase uses to
// tear down running workers. We fetch the current device list from
// DeviceUseCase immediately before the call so the map is always fresh.
type orchManagerAdapter struct {
	orchs   *usecase.OrchUseCase
	devices *usecase.DeviceUseCase
}

func newOrchManagerAdapter(o *usecase.OrchUseCase, d *usecase.DeviceUseCase) *orchManagerAdapter {
	return &orchManagerAdapter{orchs: o, devices: d}
}

func (a *orchManagerAdapter) CreateOrch(ctx context.Context, name, headID string, workerIDs []string) (*domain.Orch, error) {
	return a.orchs.CreateOrch(ctx, name, headID, workerIDs)
}

func (a *orchManagerAdapter) DeleteOrch(ctx context.Context, name string, force bool) error {
	devs, err := a.devices.ListDevices(ctx, false)
	if err != nil {
		return fmt.Errorf("delete orch: fetch device list: %w", err)
	}
	deviceMap := make(map[string]*domain.Device, len(devs))
	for _, d := range devs {
		deviceMap[d.ID] = d
	}
	return a.orchs.DeleteOrch(ctx, name, deviceMap, force)
}

// commandRunnerAdapter satisfies agent.CommandRunner.
//
// The SSH executor signature is Execute(ctx, device, command string) (string, error)
// — it has no timeoutSec parameter. We honour the agent's timeout by wrapping
// ctx with context.WithTimeout before calling Execute.
//
// The agent interface returns *domain.TaskResult. We build one from the
// string output returned by the executor; the Output field carries a
// "stdout" key to keep it compatible with how other TaskResult producers
// populate that flexible map.
type commandRunnerAdapter struct {
	devices *usecase.DeviceUseCase
	ssh     *ssh.Executor
}

func newCommandRunnerAdapter(d *usecase.DeviceUseCase, s *ssh.Executor) *commandRunnerAdapter {
	return &commandRunnerAdapter{devices: d, ssh: s}
}

func (a *commandRunnerAdapter) ExecuteOnDevice(ctx context.Context, deviceID, command string, timeoutSec int) (*domain.TaskResult, error) {
	dev, err := a.devices.GetDevice(ctx, deviceID)
	if err != nil {
		return nil, fmt.Errorf("execute on device: lookup %q: %w", deviceID, err)
	}

	timeout := time.Duration(timeoutSec) * time.Second
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	execCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	start := time.Now()
	output, execErr := a.ssh.Execute(execCtx, dev, command)
	elapsed := time.Since(start)

	if execErr != nil {
		return nil, execErr
	}

	return &domain.TaskResult{
		DeviceID:   dev.ID,
		DeviceName: dev.GetDisplayName(),
		Output:     map[string]interface{}{"stdout": output},
		Duration:   elapsed,
	}, nil
}
