package handler

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

func bindAgentStream(c echo.Context, value any) error {
	decoder := json.NewDecoder(http.MaxBytesReader(c.Response(), c.Request().Body, 1<<20))
	if err := decoder.Decode(value); err != nil {
		return errors.New("invalid agent request")
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		return errors.New("invalid agent request")
	}
	return nil
}

func agentRunID(value string) (string, error) {
	if value == "" {
		return uuid.NewString(), nil
	}
	parsed, err := uuid.Parse(value)
	if err != nil || len(value) != 36 || parsed.String() != strings.ToLower(value) {
		return "", errors.New("run_id must be a UUID")
	}
	return parsed.String(), nil
}

// agentEventStream writes synchronously. A failed write/flush cancels the
// request's execution context before any following mutation can be dispatched.
type agentEventStream struct {
	mu         sync.Mutex
	ctx        context.Context
	cancel     context.CancelFunc
	response   *echo.Response
	controller *http.ResponseController
	failed     error
}

func newAgentEventStream(c echo.Context) (context.Context, *agentEventStream) {
	ctx, cancel := context.WithCancel(c.Request().Context())
	s := &agentEventStream{ctx: ctx, cancel: cancel, response: c.Response(), controller: http.NewResponseController(c.Response().Writer)}
	c.Response().Header().Set(echo.HeaderContentType, "text/event-stream")
	c.Response().Header().Set(echo.HeaderCacheControl, "no-cache")
	c.Response().Header().Set("X-Accel-Buffering", "no")
	return ctx, s
}

func (s *agentEventStream) send(event string, value any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failed != nil {
		return s.failed
	}
	if err := s.ctx.Err(); err != nil {
		return err
	}
	data, err := json.Marshal(value)
	if err == nil {
		// Real network clients get bounded writes. ResponseRecorder and some
		// middleware may not expose deadlines, which is safe to ignore.
		// Clear it after this frame: leaving a write deadline armed during
		// model computation can make a later response irrecoverably expire.
		defer func() { _ = s.controller.SetWriteDeadline(time.Time{}) }()
		if deadlineErr := s.controller.SetWriteDeadline(time.Now().Add(5 * time.Second)); deadlineErr != nil && !errors.Is(deadlineErr, http.ErrNotSupported) {
			err = deadlineErr
		}
	}
	if err == nil {
		_, err = fmt.Fprintf(s.response, "event: %s\ndata: %s\n\n", event, data)
	}
	if err == nil {
		err = s.controller.Flush()
	}
	if err != nil {
		s.failed = err
		s.cancel()
	}
	return err
}

func (s *agentEventStream) close() {
	s.cancel()
	_ = s.controller.SetWriteDeadline(time.Time{})
}

func agentStreamError(err error) string {
	var input agent.TeamInputError
	switch {
	case errors.Is(err, context.Canceled):
		return "Agent request cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		return "Agent request timed out"
	case errors.As(err, &input):
		return input.Error()
	case errors.Is(err, domain.ErrOrchNotFound):
		return "Orchestration not found"
	case errors.Is(err, agent.ErrTeamUnavailable):
		return "AI agent teams are not configured"
	default:
		return "Agent request failed"
	}
}

func finishAgentStreamError(ctx context.Context, stream *agentEventStream, tracker *agent.RunTracker, err error) {
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	tracker.Fail(errors.Is(err, context.Canceled))
	_ = stream.send("error", map[string]string{"error": agentStreamError(err)})
}

func (h *Handler) streamAgentChat(c echo.Context) error {
	uc := h.agentUseCase()
	if uc == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	var req agent.ChatRequest
	if err := bindAgentStream(c, &req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid chat request"})
	}
	if !req.HasTeamScope() && !uc.HasLLM() {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	runID := uuid.NewString()
	ctx, stream := newAgentEventStream(c)
	defer stream.close()
	tracker := agent.NewRunTracker(runID, func(snapshot agent.AgentRunSnapshot) error { return stream.send("progress", snapshot) })
	ctx = agent.WithRunTracker(ctx, tracker)
	tracker.StartPlanning() // Flushes before any blocking model/provider work.
	if ctx.Err() != nil {
		return nil
	}
	resp, err := uc.Chat(ctx, req)
	if err == nil && ctx.Err() != nil {
		err = ctx.Err()
	}
	if err == nil && resp.Plan != nil && len(resp.Plan.Actions) > agent.MaxProgressActions {
		err = agent.TeamInputError("plan exceeds the 100-action streaming limit")
	}
	if err != nil {
		finishAgentStreamError(ctx, stream, tracker, err)
		return nil
	}
	resp.RunID = runID
	tracker.CompleteChat(resp)
	_ = stream.send("chat_result", resp)
	return nil
}

func (h *Handler) streamAgentExecute(c echo.Context) error {
	uc := h.agentUseCase()
	if uc == nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	var req agent.ExecuteRequest
	if err := bindAgentStream(c, &req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid execute request"})
	}
	runID, err := agentRunID(req.RunID)
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "run_id must be a UUID"})
	}
	if len(req.Plan.Actions) > agent.MaxProgressActions {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "plan exceeds the 100-action streaming limit"})
	}
	if !req.HasTeamSelection() && !uc.HasLLM() {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{"error": "chat agent not configured"})
	}
	ctx, stream := newAgentEventStream(c)
	defer stream.close()
	tracker := agent.NewRunTracker(runID, func(snapshot agent.AgentRunSnapshot) error { return stream.send("progress", snapshot) })
	ctx = agent.WithRunTracker(ctx, tracker)
	tracker.StartExecution(req.Plan)
	if ctx.Err() != nil {
		return nil
	}
	resp, err := uc.ExecuteRequest(ctx, req)
	if err == nil && ctx.Err() != nil {
		err = ctx.Err()
	}
	if err != nil {
		finishAgentStreamError(ctx, stream, tracker, err)
		return nil
	}
	resp.RunID = runID
	tracker.CompleteExecution(resp)
	_ = stream.send("execute_result", resp)
	return nil
}
