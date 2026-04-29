package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
)

// stubMatchDeviceUC is the minimal DeviceUseCase shape APIDeviceMatch needs.
type stubMatchDeviceUC struct {
	devices []*domain.Device
	err     error
}

func (s *stubMatchDeviceUC) ListDevices(ctx context.Context, refresh bool) ([]*domain.Device, error) {
	if s.err != nil {
		return nil, s.err
	}
	return s.devices, nil
}

// matchHandlerForTest constructs a Handler with only the deviceLister dependency
// wired, since APIDeviceMatch only consults that.
func matchHandlerForTest(uc deviceLister) *Handler {
	return &Handler{deviceLister: uc}
}

func TestAPIDeviceMatch_ByHostname(t *testing.T) {
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-pro.tail-net.ts.net"}
	h := matchHandlerForTest(&stubMatchDeviceUC{devices: []*domain.Device{dev}})

	body, _ := json.Marshal(map[string]string{"hostname": "mac-pro.tail-net.ts.net"})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/match", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	if err := h.APIDeviceMatch(c); err != nil {
		t.Fatalf("APIDeviceMatch: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var resp struct {
		DeviceID string `json:"deviceId"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.DeviceID != "dev-1" {
		t.Errorf("deviceId = %q; want dev-1", resp.DeviceID)
	}
}

func TestAPIDeviceMatch_ByIP(t *testing.T) {
	dev := &domain.Device{ID: "dev-1", IPAddresses: []string{"100.64.1.5", "192.168.1.10"}}
	h := matchHandlerForTest(&stubMatchDeviceUC{devices: []*domain.Device{dev}})

	body, _ := json.Marshal(map[string]string{"ip": "100.64.1.5"})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/match", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	if err := h.APIDeviceMatch(c); err != nil {
		t.Fatalf("APIDeviceMatch: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
}

func TestAPIDeviceMatch_BothEmptyReturns400(t *testing.T) {
	h := matchHandlerForTest(&stubMatchDeviceUC{devices: nil})

	body, _ := json.Marshal(map[string]string{})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/match", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	_ = h.APIDeviceMatch(c)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rec.Code)
	}
}

func TestAPIDeviceMatch_NotFoundReturns404(t *testing.T) {
	h := matchHandlerForTest(&stubMatchDeviceUC{devices: []*domain.Device{
		{ID: "dev-1", Hostname: "other-host"},
	}})

	body, _ := json.Marshal(map[string]string{"hostname": "missing-host"})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/match", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	_ = h.APIDeviceMatch(c)
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}
