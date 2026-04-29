package usecase

import (
	"context"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

// stubCollector returns canned SSH metrics or an error.
type stubCollector struct {
	called  bool
	metrics *domain.DeviceMetrics
	err     error
}

func (s *stubCollector) CollectMetrics(ctx context.Context, d *domain.Device) (*domain.DeviceMetrics, error) {
	s.called = true
	if s.err != nil {
		return nil, s.err
	}
	if s.metrics != nil {
		return s.metrics, nil
	}
	return &domain.DeviceMetrics{DeviceID: d.ID, CollectedAt: time.Now(), Source: domain.MetricsSourceSSH}, nil
}

func (s *stubCollector) CollectMetricsParallel(ctx context.Context, devices []*domain.Device) ([]*domain.DeviceMetrics, error) {
	return nil, nil
}

// stubTailscale satisfies TailscaleClient for a single fixed device.
type stubTailscale struct {
	dev *domain.Device
}

func (s *stubTailscale) ListDevices(ctx context.Context) ([]*domain.Device, error) {
	return []*domain.Device{s.dev}, nil
}

func (s *stubTailscale) GetDevice(ctx context.Context, nameOrID string) (*domain.Device, error) {
	return s.dev, nil
}

func (s *stubTailscale) GetDeviceByID(ctx context.Context, id string) (*domain.Device, error) {
	return s.dev, nil
}

// minDeviceUC builds a DeviceUseCase that returns a single fixed device.
func minDeviceUC(t *testing.T, dev *domain.Device) *DeviceUseCase {
	t.Helper()
	return &DeviceUseCase{
		tailscale: &stubTailscale{dev: dev},
	}
}

func TestMonitorUC_PushSelfMetrics_StoresInLatest(t *testing.T) {
	uc := NewMonitorUseCase(nil, &stubCollector{}, nil)
	m := &domain.DeviceMetrics{DeviceID: "dev-1", Source: domain.MetricsSourceSelfReport, CollectedAt: time.Now()}

	uc.PushSelfMetrics(m)

	got := uc.GetLatestCached("dev-1")
	if got == nil {
		t.Fatal("PushSelfMetrics did not populate latest cache")
	}
	if got.Source != domain.MetricsSourceSelfReport {
		t.Errorf("Source = %q; want self", got.Source)
	}
}

func TestMonitorUC_GetDeviceMetrics_PrefersFreshSelfReport(t *testing.T) {
	collector := &stubCollector{}
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-1", IPAddresses: []string{"100.1.1.1"}, Status: domain.DeviceStatusOnline, SSHEnabled: true}
	uc := NewMonitorUseCase(nil, collector, minDeviceUC(t, dev))

	uc.PushSelfMetrics(&domain.DeviceMetrics{
		DeviceID:    "dev-1",
		Source:      domain.MetricsSourceSelfReport,
		CollectedAt: time.Now(),
		CPU:         domain.CPUMetrics{UsagePercent: 42},
	})

	got, err := uc.GetDeviceMetrics(context.Background(), "dev-1")
	if err != nil {
		t.Fatalf("GetDeviceMetrics: %v", err)
	}
	if got.Source != domain.MetricsSourceSelfReport {
		t.Errorf("Source = %q; want self", got.Source)
	}
	if got.CPU.UsagePercent != 42 {
		t.Errorf("CPU not preserved from self-report: %+v", got.CPU)
	}
	if collector.called {
		t.Error("SSH collector should not be invoked when fresh self-report is available")
	}
}

func TestMonitorUC_GetDeviceMetrics_FallsThroughOnStaleSelfReport(t *testing.T) {
	collector := &stubCollector{}
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-1", IPAddresses: []string{"100.1.1.1"}, Status: domain.DeviceStatusOnline, SSHEnabled: true}
	uc := NewMonitorUseCase(nil, collector, minDeviceUC(t, dev))

	stale := &domain.DeviceMetrics{
		DeviceID:    "dev-1",
		Source:      domain.MetricsSourceSelfReport,
		CollectedAt: time.Now().Add(-2 * time.Minute), // > freshSelfReport
	}
	uc.PushSelfMetrics(stale)

	if _, err := uc.GetDeviceMetrics(context.Background(), "dev-1"); err != nil {
		t.Fatalf("GetDeviceMetrics: %v", err)
	}
	if !collector.called {
		t.Error("SSH collector should be invoked when self-report is stale")
	}
}

func TestMonitorUC_GetDeviceMetrics_FallsThroughWithoutSelfReport(t *testing.T) {
	collector := &stubCollector{}
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-1", IPAddresses: []string{"100.1.1.1"}, Status: domain.DeviceStatusOnline, SSHEnabled: true}
	uc := NewMonitorUseCase(nil, collector, minDeviceUC(t, dev))

	if _, err := uc.GetDeviceMetrics(context.Background(), "dev-1"); err != nil {
		t.Fatalf("GetDeviceMetrics: %v", err)
	}
	if !collector.called {
		t.Error("SSH collector should be invoked when no self-report exists")
	}
}
