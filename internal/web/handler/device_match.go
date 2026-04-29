package handler

import (
	"context"
	"net/http"

	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
)

// deviceLister is the minimal DeviceUseCase surface APIDeviceMatch needs.
// Defined here (rather than in handler.go) so the match handler can be
// tested in isolation against a stub without depending on the full UseCase.
type deviceLister interface {
	ListDevices(ctx context.Context, refresh bool) ([]*domain.Device, error)
}

type matchRequest struct {
	Hostname string `json:"hostname,omitempty"`
	IP       string `json:"ip,omitempty"`
}

type matchResponse struct {
	DeviceID string `json:"deviceId"`
}

// APIDeviceMatch resolves a hostname or Tailnet IP to the canonical
// Tailscale device ID. The Swift DeviceIdentity actor calls this once
// per app launch so capability and metric reporters can address the
// same device by a single ID.
//
// Hostname is the strong key — Tailscale hostnames are unique within
// a tailnet. IP is a backup for cases where the caller can't resolve
// its own hostname. At least one is required.
func (h *Handler) APIDeviceMatch(c echo.Context) error {
	var req matchRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid body"})
	}
	if req.Hostname == "" && req.IP == "" {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "hostname or ip required"})
	}

	devices, err := h.deviceLister.ListDevices(c.Request().Context(), false)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}

	for _, d := range devices {
		if req.Hostname != "" && d.Hostname == req.Hostname {
			return c.JSON(http.StatusOK, matchResponse{DeviceID: d.ID})
		}
		if req.IP != "" {
			for _, ip := range d.IPAddresses {
				if ip == req.IP {
					return c.JSON(http.StatusOK, matchResponse{DeviceID: d.ID})
				}
			}
		}
	}
	return c.JSON(http.StatusNotFound, map[string]string{"error": "device not found in tailnet"})
}
