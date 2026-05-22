package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

// APIAgentChat accepts the conversation history + latest user message
// and returns either a clarifying question or a runnable plan.
func (h *Handler) APIAgentChat(c echo.Context) error {
	if h.agentUC == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	var req agent.ChatRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	resp, err := h.agentUC.Chat(c.Request().Context(), req)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, resp)
}

// APIAgentExecute runs a plan returned by /api/agent/chat. The plan is
// re-validated before any action runs.
func (h *Handler) APIAgentExecute(c echo.Context) error {
	if h.agentUC == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	var req agent.ExecuteRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	resp, err := h.agentUC.Execute(c.Request().Context(), req.Plan)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, resp)
}
