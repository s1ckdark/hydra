package handler

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

func agentTeamError(c echo.Context, err error) error {
	status, message := http.StatusInternalServerError, "AI agent request failed"
	var input agent.TeamInputError
	switch {
	case errors.As(err, &input):
		status, message = http.StatusBadRequest, input.Error()
	case errors.Is(err, domain.ErrOrchNotFound):
		status, message = http.StatusNotFound, "orchestration not found"
	case errors.Is(err, agent.ErrTeamUnavailable):
		status, message = http.StatusServiceUnavailable, err.Error()
	default:
		// TeamService and repository errors are static and sanitized. Never
		// log provider bodies or use internalError with credential errors.
		message = err.Error()
	}
	return c.JSON(status, map[string]string{"error": message})
}

func (h *Handler) APIGetAgentTeam(c echo.Context) error {
	if h.agentTeams == nil {
		return agentTeamError(c, agent.ErrTeamUnavailable)
	}
	team, err := h.agentTeams.Get(c.Request().Context(), c.Param("id"))
	if err != nil {
		return agentTeamError(c, err)
	}
	return c.JSON(http.StatusOK, team)
}

func (h *Handler) APIPutAgentTeam(c echo.Context) error {
	if h.agentTeams == nil {
		return agentTeamError(c, agent.ErrTeamUnavailable)
	}
	// Use body-only JSON binding: path/query parameters cannot rewrite secrets
	// or orchestration identity. A bounded body also bounds the stored catalog.
	var req *agent.TeamUpdate
	decoder := json.NewDecoder(http.MaxBytesReader(c.Response(), c.Request().Body, 1<<20))
	if err := decoder.Decode(&req); err != nil || req == nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid AI agent team request"})
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid AI agent team request"})
	}
	team, err := h.agentTeams.Put(c.Request().Context(), c.Param("id"), *req)
	if err != nil {
		return agentTeamError(c, err)
	}
	return c.JSON(http.StatusOK, team)
}
