package handler

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/usecase"
)

func TestAPIDeviceMetricsPush_StoresWithSelfSource(t *testing.T) {
	// Arrange: handler with stub deviceLister returning one device,
	// and a real MonitorUseCase whose latest cache we can inspect after
	// the push.
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-1"}
	monitorUC := usecase.NewMonitorUseCase(nil, &stubMetricsCollector{}, nil)
	h := &Handler{
		deviceLister: &stubMatchDeviceUC{devices: []*domain.Device{dev}},
		monitorUC:    monitorUC,
	}

	body := []byte(`{
		"cpu": {"usagePercent": 42},
		"memory": {"totalBytes": 16000000000, "usedBytes": 8000000000, "usagePercent": 50},
		"disk":   {"totalBytes": 500000000000, "availableBytes": 250000000000, "usagePercent": 50}
	}`)
	req := httptest.NewRequest(http.MethodPost, "/api/devices/dev-1/metrics", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("dev-1")

	if err := h.APIDeviceMetricsPush(c); err != nil {
		t.Fatalf("APIDeviceMetricsPush: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}

	cached := monitorUC.GetLatestCached("dev-1")
	if cached == nil {
		t.Fatal("MonitorUseCase did not store the pushed metric")
	}
	if cached.Source != domain.MetricsSourceSelfReport {
		t.Errorf("Source = %q; want self", cached.Source)
	}
	if cached.CPU.UsagePercent != 42 {
		t.Errorf("CPU.UsagePercent = %v; want 42", cached.CPU.UsagePercent)
	}
	if cached.CollectedAt.IsZero() {
		t.Error("CollectedAt should be set server-side")
	}
}

func TestAPIDeviceMetricsPush_404ForUnknownDevice(t *testing.T) {
	monitorUC := usecase.NewMonitorUseCase(nil, &stubMetricsCollector{}, nil)
	h := &Handler{
		deviceLister: &stubMatchDeviceUC{devices: nil},
		monitorUC:    monitorUC,
	}

	body := []byte(`{}`)
	req := httptest.NewRequest(http.MethodPost, "/api/devices/missing/metrics", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("missing")

	_ = h.APIDeviceMetricsPush(c)
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}

// stubMetricsCollector is the minimal MetricsCollector for these tests —
// it never gets called when self-reports take precedence, but the
// MonitorUseCase constructor requires a non-nil one.
type stubMetricsCollector struct{}

func (s *stubMetricsCollector) CollectMetrics(ctx context.Context, d *domain.Device) (*domain.DeviceMetrics, error) {
	return nil, nil
}
func (s *stubMetricsCollector) CollectMetricsParallel(ctx context.Context, devices []*domain.Device) ([]*domain.DeviceMetrics, error) {
	return nil, nil
}
