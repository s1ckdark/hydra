package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

func TestAPIAgentChat_ReturnsServiceUnavailableWhenUnconfigured(t *testing.T) {
	h := &Handler{}
	e := echo.New()
	body, _ := json.Marshal(agent.ChatRequest{Message: "hi"})
	req := httptest.NewRequest(http.MethodPost, "/api/agent/chat", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	if err := h.APIAgentChat(c); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}
