package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/usecase"
)

type refreshTailscaleStub struct {
	devices    []*domain.Device
	fresh      []*domain.Device
	err        error
	freshCalls int
}

func (s *refreshTailscaleStub) ListDevices(context.Context) ([]*domain.Device, error) {
	return s.devices, s.err
}
func (s *refreshTailscaleStub) ListDevicesFresh(context.Context) ([]*domain.Device, error) {
	s.freshCalls++
	return s.fresh, s.err
}
func (s *refreshTailscaleStub) GetDevice(context.Context, string) (*domain.Device, error) {
	return nil, errors.New("unused")
}
func (s *refreshTailscaleStub) GetDeviceByID(context.Context, string) (*domain.Device, error) {
	return nil, errors.New("unused")
}

func deviceRefreshRequest(t *testing.T, h *Handler, query string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	c := echo.New().NewContext(httptest.NewRequest(http.MethodGet, "/api/devices"+query, nil), recorder)
	if err := h.APIDeviceList(c); err != nil {
		t.Fatal(err)
	}
	return recorder
}

func TestAPIDeviceListTailscaleRefreshFindsNewHostWithoutMetrics(t *testing.T) {
	s := &refreshTailscaleStub{devices: []*domain.Device{{ID: "old", Name: "old"}}, fresh: []*domain.Device{{ID: "intlmac", Name: "intlmac"}}}
	uc := usecase.NewDeviceUseCase(nil, s, nil)
	_, _ = uc.ListDevices(context.Background(), false)
	// RefreshAll requires dependencies that this inventory-only route must not use.
	h := &Handler{deviceUC: uc, monitorUC: usecase.NewMonitorUseCase(nil, nil, nil)}
	rec := deviceRefreshRequest(t, h, "?refresh=tailscale")
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body)
	}
	if rec.Header().Get("X-Hydra-Tailscale-Refresh") != "fresh" || rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("missing fresh/no-store acknowledgment: %v", rec.Header())
	}
	var devices []*domain.Device
	if err := json.Unmarshal(rec.Body.Bytes(), &devices); err != nil {
		t.Fatal(err)
	}
	if s.freshCalls != 1 || len(devices) != 1 || devices[0].ID != "intlmac" {
		t.Fatalf("stale response: freshCalls=%d body=%s", s.freshCalls, rec.Body)
	}
	rec = deviceRefreshRequest(t, h, "")
	if rec.Header().Get("X-Hydra-Tailscale-Refresh") != "" {
		t.Fatal("ordinary cache read marked fresh")
	}
}

func TestAPIDeviceListTailscaleRefreshFailureIsNotStaleSuccess(t *testing.T) {
	s := &refreshTailscaleStub{devices: []*domain.Device{{ID: "old", Name: "old"}}}
	uc := usecase.NewDeviceUseCase(nil, s, nil)
	_, _ = uc.ListDevices(context.Background(), false)
	s.err = errors.New("upstream credential=private-value")
	h := &Handler{deviceUC: uc}
	rec := deviceRefreshRequest(t, h, "?refresh=tailscale")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want503 body=%s", rec.Code, rec.Body)
	}
	if rec.Header().Get("X-Hydra-Tailscale-Refresh") != "" {
		t.Fatal("failure marked fresh")
	}
	if strings.Contains(rec.Body.String(), "private-value") {
		t.Fatal("raw upstream error leaked")
	}
	var failure map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &failure); err != nil {
		t.Fatal(err)
	}
	if failure["code"] != "tailscale_refresh_failed" {
		t.Fatalf("missing actionable error code: %v", failure)
	}
	if rec := deviceRefreshRequest(t, h, ""); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "old") {
		t.Fatalf("ordinary fallback unavailable: %d %s", rec.Code, rec.Body)
	}
}

func TestAPIDeviceListTailscaleRefreshRejectsSuspiciousShrink(t *testing.T) {
	old := []*domain.Device{{ID: "1", Name: "a"}, {ID: "2", Name: "b"}, {ID: "3", Name: "c"}, {ID: "4", Name: "d"}}
	s := &refreshTailscaleStub{devices: old, fresh: old[:1]}
	uc := usecase.NewDeviceUseCase(nil, s, nil)
	_, _ = uc.ListDevices(context.Background(), false)
	rec := deviceRefreshRequest(t, &Handler{deviceUC: uc}, "?refresh=tailscale")
	if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("X-Hydra-Tailscale-Refresh") != "" {
		t.Fatalf("partial inventory claimed success: %d %v", rec.Code, rec.Header())
	}
}

func TestAPIDeviceListLegacyRefreshActuallyReloadsInventory(t *testing.T) {
	s := &refreshTailscaleStub{devices: []*domain.Device{{ID: "old", Name: "old"}}, fresh: []*domain.Device{{ID: "intlmac", Name: "intlmac"}}}
	uc := usecase.NewDeviceUseCase(nil, s, nil)
	_, _ = uc.ListDevices(context.Background(), false)
	rec := deviceRefreshRequest(t, &Handler{deviceUC: uc}, "?refresh=true")
	if rec.Code != http.StatusOK || s.freshCalls != 1 || !strings.Contains(rec.Body.String(), "intlmac") {
		t.Fatalf("legacy refresh ignored inventory: %d calls=%d %s", rec.Code, s.freshCalls, rec.Body)
	}
	if rec.Header().Get("X-Hydra-Tailscale-Refresh") != "" {
		t.Fatal("legacy stale-fallback route must not claim verified fresh")
	}
}
