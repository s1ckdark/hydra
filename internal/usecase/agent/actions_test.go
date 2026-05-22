package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

type stubDeviceLister struct {
	devices []*domain.Device
}

func (s *stubDeviceLister) ListDevices(ctx context.Context, force bool) ([]*domain.Device, error) {
	return s.devices, nil
}

func TestActionListDevices(t *testing.T) {
	reg := NewActionRegistry(&stubDeviceLister{
		devices: []*domain.Device{
			{ID: "a", Name: "alpha", Status: domain.DeviceStatusOnline},
			{ID: "b", Name: "beta", Status: domain.DeviceStatusOffline},
		},
	}, nil, nil, nil, nil, nil)
	res := reg.Run(context.Background(), Action{Type: "list_devices", Args: json.RawMessage(`{}`)})
	if res.Status != "ok" {
		t.Fatalf("status = %q, err=%q", res.Status, res.Error)
	}
	if len(res.Output) == 0 {
		t.Fatalf("output empty")
	}
}

func TestActionUnknownTypeFails(t *testing.T) {
	reg := NewActionRegistry(&stubDeviceLister{}, nil, nil, nil, nil, nil)
	res := reg.Run(context.Background(), Action{Type: "bogus", Args: json.RawMessage(`{}`)})
	if res.Status != "error" || res.Error == "" {
		t.Fatalf("got %+v", res)
	}
}

func TestValidateUnknownDevice(t *testing.T) {
	v := NewValidator(&stubDeviceLister{devices: []*domain.Device{{ID: "a", Name: "alpha"}}}, nil)
	plan := Plan{Actions: []Action{{
		Type: "execute_command",
		Args: json.RawMessage(`{"device_id":"ghost","command":"ls"}`),
	}}}
	errs := v.Validate(context.Background(), plan)
	if len(errs) != 1 {
		t.Fatalf("want 1 error, got %d", len(errs))
	}
}

func TestValidateDenyListBlocksRMRf(t *testing.T) {
	v := NewValidator(&stubDeviceLister{devices: []*domain.Device{{ID: "a", Name: "alpha", Status: domain.DeviceStatusOnline}}}, nil)
	plan := Plan{Actions: []Action{{
		Type: "execute_command",
		Args: json.RawMessage(`{"device_id":"a","command":"rm -rf /"}`),
	}}}
	if errs := v.Validate(context.Background(), plan); len(errs) == 0 {
		t.Fatalf("rm -rf should be blocked")
	}
}

func TestValidateDenyListBlocksRMRfVar(t *testing.T) {
	v := NewValidator(&stubDeviceLister{devices: []*domain.Device{{ID: "a"}}}, nil)
	for _, cmd := range []string{"rm -rf /var/log", "rm -rf ~/secrets", "rm -fr /etc"} {
		plan := Plan{Actions: []Action{{
			Type: "execute_command",
			Args: json.RawMessage(`{"device_id":"a","command":"` + cmd + `"}`),
		}}}
		if errs := v.Validate(context.Background(), plan); len(errs) == 0 {
			t.Errorf("expected %q to be blocked", cmd)
		}
	}
}

func TestValidateDenyListIgnoresFalsePositives(t *testing.T) {
	v := NewValidator(&stubDeviceLister{devices: []*domain.Device{{ID: "a"}}}, nil)
	for _, cmd := range []string{"echo gracefulShutdown", "cat rebootedAt.txt", "ls /var/log"} {
		plan := Plan{Actions: []Action{{
			Type: "execute_command",
			Args: json.RawMessage(`{"device_id":"a","command":"` + cmd + `"}`),
		}}}
		if errs := v.Validate(context.Background(), plan); len(errs) > 0 {
			t.Errorf("expected %q to pass, got %v", cmd, errs[0])
		}
	}
}

type erroringDeviceLister struct{}

func (e *erroringDeviceLister) ListDevices(ctx context.Context, force bool) ([]*domain.Device, error) {
	return nil, errors.New("tailscale down")
}

func TestValidateSurfaceListDevicesError(t *testing.T) {
	v := NewValidator(&erroringDeviceLister{}, nil)
	plan := Plan{Actions: []Action{{
		Type: "get_metrics",
		Args: json.RawMessage(`{"device_id":"a"}`),
	}}}
	errs := v.Validate(context.Background(), plan)
	if len(errs) != 1 {
		t.Fatalf("want 1 error, got %d: %v", len(errs), errs)
	}
	if !strings.Contains(errs[0].Error(), "device cache unavailable") {
		t.Fatalf("error = %q", errs[0])
	}
}

func TestRecentTasksReturnsEmptyArray(t *testing.T) {
	reg := NewActionRegistry(&stubDeviceLister{}, nil, nil, nil, nil, nil)
	res := reg.Run(context.Background(), Action{Type: "recent_tasks", Args: json.RawMessage(`{}`)})
	if res.Status != "ok" || string(res.Output) != "[]" {
		t.Fatalf("got status=%q output=%s err=%q", res.Status, res.Output, res.Error)
	}
}
