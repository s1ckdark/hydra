package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/config"
)

// TailscaleConfigRequest is the payload for updating Tailscale credentials.
type TailscaleConfigRequest struct {
	APIKey            string `json:"api_key"`
	Tailnet           string `json:"tailnet"`
	OAuthClientID     string `json:"oauth_client_id"`
	OAuthClientSecret string `json:"oauth_client_secret"`
}

// APIGetTailscaleConfig returns the current Tailscale configuration (keys masked).
func (h *Handler) APIGetTailscaleConfig(c echo.Context) error {
	return c.JSON(http.StatusOK, map[string]any{
		"tailnet":         h.cfg.Tailscale.Tailnet,
		"has_api_key":     h.cfg.Tailscale.APIKey != "",
		"has_oauth":       h.cfg.Tailscale.OAuthClientID != "",
		"oauth_client_id": h.cfg.Tailscale.OAuthClientID,
	})
}

// APIPutTailscaleConfig updates the Tailscale credentials and persists to config file.
func (h *Handler) APIPutTailscaleConfig(c echo.Context) error {
	var req TailscaleConfigRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid request body"})
	}

	if req.APIKey == "" && req.OAuthClientID == "" {
		return c.JSON(http.StatusBadRequest, map[string]string{
			"error": "api_key or oauth_client_id/oauth_client_secret required",
		})
	}

	// Update in-memory config
	if req.Tailnet != "" {
		h.cfg.Tailscale.Tailnet = req.Tailnet
	}
	if req.APIKey != "" {
		h.cfg.Tailscale.APIKey = req.APIKey
		// Clear OAuth if switching to API key
		h.cfg.Tailscale.OAuthClientID = ""
		h.cfg.Tailscale.OAuthClientSecret = ""
	}
	if req.OAuthClientID != "" {
		h.cfg.Tailscale.OAuthClientID = req.OAuthClientID
		h.cfg.Tailscale.OAuthClientSecret = req.OAuthClientSecret
		// Clear API key if switching to OAuth
		h.cfg.Tailscale.APIKey = ""
	}

	// Persist to config file
	if err := config.Save(h.cfg); err != nil {
		return internalError(c, "failed to save config", err)
	}

	return c.JSON(http.StatusOK, map[string]string{"status": "updated"})
}
