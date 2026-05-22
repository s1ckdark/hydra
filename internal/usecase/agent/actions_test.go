package agent

import (
	"context"
	"encoding/json"
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
