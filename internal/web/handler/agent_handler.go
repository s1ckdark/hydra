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

// APIAgentCommand turns a natural-language request into a single shell
// command for the target host. It does NOT execute — the client fills the
// command field for the user to review and run via the normal path.
func (h *Handler) APIAgentCommand(c echo.Context) error {
	if h.agentUC == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "command assistant not configured"})
	}
	var req agent.CommandRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	resp, err := h.agentUC.GenerateCommand(c.Request().Context(), req)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, resp)
}

// APIAgentAssess classifies a shell command as safe or risky for the "Auto"
// execution policy. It does not run anything.
func (h *Handler) APIAgentAssess(c echo.Context) error {
	if h.agentUC == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "command assistant not configured"})
	}
	var req agent.AssessRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	resp, err := h.agentUC.AssessCommand(c.Request().Context(), req)
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
