package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

// APIAgentChat accepts the conversation history + latest user message
// and returns either a clarifying question or a runnable plan.
func (h *Handler) APIAgentChat(c echo.Context) error {
	if c.QueryParam("stream") == "1" {
		return h.streamAgentChat(c)
	}
	uc := h.agentUseCase()
	if uc == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	var req agent.ChatRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid chat request"})
	}
	if !req.HasTeamScope() && !uc.HasLLM() {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	resp, err := uc.Chat(c.Request().Context(), req)
	if err != nil {
		if req.HasTeamScope() {
			return agentTeamError(c, err)
		}
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, resp)
}

// APIAgentCommand turns a natural-language request into a single shell
// command for the target host. It does NOT execute — the client fills the
// command field for the user to review and run via the normal path.
func (h *Handler) APIAgentCommand(c echo.Context) error {
	uc := h.agentUseCase()
	if !uc.HasLLM() {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "command assistant not configured"})
	}
	var req agent.CommandRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	resp, err := uc.GenerateCommand(c.Request().Context(), req)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, resp)
}

// APIAgentAssess classifies a shell command as safe or risky for the "Auto"
// execution policy. It does not run anything.
func (h *Handler) APIAgentAssess(c echo.Context) error {
	uc := h.agentUseCase()
	if !uc.HasLLM() {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "command assistant not configured"})
	}
	var req agent.AssessRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	resp, err := uc.AssessCommand(c.Request().Context(), req)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	return c.JSON(http.StatusOK, resp)
}

// APIAgentExecute runs a plan returned by /api/agent/chat. The plan is
// re-validated before any action runs.
func (h *Handler) APIAgentExecute(c echo.Context) error {
	if c.QueryParam("stream") == "1" {
		return h.streamAgentExecute(c)
	}
	uc := h.agentUseCase()
	if uc == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	var req agent.ExecuteRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid execute request"})
	}
	if !req.HasTeamSelection() && !uc.HasLLM() {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	resp, err := uc.ExecuteRequest(c.Request().Context(), req)
	if err != nil {
		return agentTeamError(c, err)
	}
	return c.JSON(http.StatusOK, resp)
}
