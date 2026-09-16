package usecase

import (
	"context"
	"errors"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

type freshInventoryClient struct {
	mockTailscale
	fresh      []*domain.Device
	freshErr   error
	freshCalls int
}

func (c *freshInventoryClient) ListDevicesFresh(context.Context) ([]*domain.Device, error) {
	c.freshCalls++
	return c.fresh, c.freshErr
}

func TestRefreshTailscaleDevicesBypassesBothCaches(t *testing.T) {
	c := &freshInventoryClient{mockTailscale: mockTailscale{devices: []*domain.Device{{ID: "old", Name: "old"}}}, fresh: []*domain.Device{{ID: "intlmac", Name: "intlmac"}}}
	uc := NewDeviceUseCase(nil, c, nil)
	if _, err := uc.ListDevices(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	devices, err := uc.RefreshTailscaleDevices(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if c.freshCalls != 1 || len(devices) != 1 || devices[0].ID != "intlmac" {
		t.Fatalf("refresh did not bypass both caches: calls=%d devices=%v", c.freshCalls, devices)
	}
	cached, err := uc.ListDevices(context.Background(), false)
	if err != nil || len(cached) != 1 || cached[0].ID != "intlmac" {
		t.Fatalf("fresh inventory did not persist: %v %v", cached, err)
	}
}

func TestRefreshTailscaleDevicesReportsFailureAndKeepsFallback(t *testing.T) {
	c := &freshInventoryClient{mockTailscale: mockTailscale{devices: []*domain.Device{{ID: "old", Name: "old"}}}, freshErr: errors.New("upstream failed")}
	uc := NewDeviceUseCase(nil, c, nil)
	_, _ = uc.ListDevices(context.Background(), false)
	devices, err := uc.RefreshTailscaleDevices(context.Background())
	if err == nil || devices != nil {
		t.Fatalf("manual refresh returned stale success: %v %v", devices, err)
	}
	cached, err := uc.ListDevices(context.Background(), false)
	if err != nil || len(cached) != 1 || cached[0].ID != "old" {
		t.Fatalf("last good snapshot lost: %v %v", cached, err)
	}
}

func TestRefreshTailscaleDevicesRejectsPartialInventory(t *testing.T) {
	old := []*domain.Device{{ID: "1", Name: "a"}, {ID: "2", Name: "b"}, {ID: "3", Name: "c"}, {ID: "4", Name: "d"}}
	c := &freshInventoryClient{mockTailscale: mockTailscale{devices: old}, fresh: old[:1]}
	uc := NewDeviceUseCase(nil, c, nil)
	_, _ = uc.ListDevices(context.Background(), false)
	if devices, err := uc.RefreshTailscaleDevices(context.Background()); err == nil || devices != nil {
		t.Fatalf("partial inventory claimed fresh: %v %v", devices, err)
	}
	if len(uc.cachedDevices) != 4 {
		t.Fatal("partial response replaced cache")
	}
}

func TestRefreshTailscaleDevicesRejectsEmptyResponseForKnownSmallTailnet(t *testing.T) {
	c := &freshInventoryClient{mockTailscale: mockTailscale{devices: []*domain.Device{{ID: "old", Name: "old"}}}}
	uc := NewDeviceUseCase(nil, c, nil)
	_, _ = uc.ListDevices(context.Background(), false)
	if devices, err := uc.RefreshTailscaleDevices(context.Background()); err == nil || devices != nil {
		t.Fatalf("empty response erased known small tailnet: %v %v", devices, err)
	}
	if len(uc.cachedDevices) != 1 {
		t.Fatal("empty response replaced known device")
	}
}

type forbiddenGPUChecker struct{}

func (forbiddenGPUChecker) CollectGPUMetrics(context.Context, *domain.Device) *domain.GPUNodeMetrics {
	panic("inventory refresh must not probe SSH")
}

func TestRefreshTailscaleDevicesDoesNotProbeGPU(t *testing.T) {
	c := &freshInventoryClient{fresh: []*domain.Device{{ID: "linux", Name: "linux", OS: "Linux", Status: domain.DeviceStatusOnline, SSHEnabled: true}}}
	uc := NewDeviceUseCase(nil, c, nil)
	uc.SetGPUChecker(forbiddenGPUChecker{})
	if _, err := uc.RefreshTailscaleDevices(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestRefreshTailscaleDevicesOldGPUCompletionCannotRestoreOldInventory(t *testing.T) {
	old := []*domain.Device{{ID: "old", Name: "old"}}
	c := &freshInventoryClient{mockTailscale: mockTailscale{devices: old}, fresh: []*domain.Device{{ID: "intlmac", Name: "intlmac"}}}
	uc := NewDeviceUseCase(setupTestRepos(t), c, nil)
	_, _ = uc.ListDevices(context.Background(), false)
	oldGeneration := uc.cacheGeneration
	if _, err := uc.RefreshTailscaleDevices(context.Background()); err != nil {
		t.Fatal(err)
	}
	if uc.saveGPUResults(context.Background(), old, oldGeneration) {
		t.Fatal("old GPU result accepted after newer inventory")
	}
	devices, err := uc.ListDevices(context.Background(), false)
	if err != nil || len(devices) != 1 || devices[0].ID != "intlmac" {
		t.Fatalf("old GPU callback restored stale inventory: %v %v", devices, err)
	}
	if !uc.saveGPUResults(context.Background(), devices, uc.cacheGeneration) {
		t.Fatal("current generation GPU results rejected")
	}
}
