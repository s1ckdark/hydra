# AI Auth Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add AI provider auth (API Key / Local API endpoint) to Hydra settings so multi-task orchestration's 3 AI roles (HeadSelection / TaskScheduling / CapacityEstimation) can be configured from the macOS GUI.

**Architecture:** Role-override + default config model in Go. Legacy single-provider fields are auto-migrated at `config.Load`. New `PUT/GET /api/config/ai` handler mirrors the existing Tailscale config pattern. macOS Settings gains an "AI" tab with Basic / Advanced (disclosure) UX; iOS is out of scope.

**Tech Stack:** Go (Echo, Viper), SwiftUI (macOS Settings), Keychain (CredentialStore).

**Spec:** [docs/superpowers/specs/2026-04-24-ai-auth-settings-design.md](../specs/2026-04-24-ai-auth-settings-design.md)

---

## Phase A — Go Backend: Config Schema

### Task 1: Define ProviderConfig, AIConfig types and Resolve method

**Files:**
- Modify: `config/config.go`
- Test: `config/config_test.go`

- [ ] **Step 1: Write failing test for AIConfig.Resolve**

Append to `config/config_test.go`:

```go
func TestAIConfig_Resolve_FallsBackToDefault(t *testing.T) {
	cfg := AIConfig{
		Default: ProviderConfig{Provider: "claude", APIKey: "sk-default"},
	}
	got := cfg.Resolve("head")
	if got.Provider != "claude" || got.APIKey != "sk-default" {
		t.Errorf("Resolve(head) = %+v; want claude/sk-default default fallback", got)
	}
}

func TestAIConfig_Resolve_UsesRoleOverride(t *testing.T) {
	override := ProviderConfig{Provider: "ollama", Endpoint: "http://localhost:11434", Model: "llama3"}
	cfg := AIConfig{
		Default:        ProviderConfig{Provider: "claude", APIKey: "sk-default"},
		TaskScheduling: &override,
	}
	got := cfg.Resolve("schedule")
	if got.Provider != "ollama" || got.Endpoint != "http://localhost:11434" {
		t.Errorf("Resolve(schedule) = %+v; want ollama override", got)
	}
	if got := cfg.Resolve("head"); got.Provider != "claude" {
		t.Errorf("Resolve(head) should fall back to default, got %+v", got)
	}
}

func TestAIConfig_Resolve_EmptyOverrideFallsThrough(t *testing.T) {
	empty := ProviderConfig{}
	cfg := AIConfig{
		Default:       ProviderConfig{Provider: "claude", APIKey: "sk-default"},
		HeadSelection: &empty,
	}
	if got := cfg.Resolve("head"); got.Provider != "claude" {
		t.Errorf("Resolve should ignore empty-Provider override; got %+v", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
go test ./config -run TestAIConfig_Resolve -v
```

Expected: FAIL with `undefined: AIConfig` / `undefined: ProviderConfig`.

- [ ] **Step 3: Add types and Resolve to config.go**

Append to `config/config.go` (before `DefaultConfig`):

```go
// ProviderConfig describes one AI provider instance.
// When Provider is "claude"/"openai"/"zai" the APIKey field is required.
// When Provider is "ollama"/"lmstudio"/"openai_compatible" the Endpoint field is required.
type ProviderConfig struct {
	Provider string `mapstructure:"provider"`
	APIKey   string `mapstructure:"api_key"`
	Endpoint string `mapstructure:"endpoint"`
	Model    string `mapstructure:"model"`
}

// AIConfig routes AI calls to providers per role.
// Default applies to any role without a non-empty override.
type AIConfig struct {
	Default            ProviderConfig  `mapstructure:"default"`
	HeadSelection      *ProviderConfig `mapstructure:"head_selection,omitempty"`
	TaskScheduling     *ProviderConfig `mapstructure:"task_scheduling,omitempty"`
	CapacityEstimation *ProviderConfig `mapstructure:"capacity_estimation,omitempty"`
}

// Resolve returns the ProviderConfig for a given role, falling back to Default
// when no override is set or the override has an empty Provider.
// role must be one of: "head", "schedule", "capacity".
func (a AIConfig) Resolve(role string) ProviderConfig {
	var override *ProviderConfig
	switch role {
	case "head":
		override = a.HeadSelection
	case "schedule":
		override = a.TaskScheduling
	case "capacity":
		override = a.CapacityEstimation
	}
	if override != nil && override.Provider != "" {
		return *override
	}
	return a.Default
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./config -run TestAIConfig_Resolve -v
```

Expected: PASS for all three subtests.

- [ ] **Step 5: Commit**

```bash
git add config/config.go config/config_test.go
git commit -m "feat(config): add AIConfig and ProviderConfig with role-override Resolve"
```

---

### Task 2: Add AI field to AgentConfig + legacy migration

**Files:**
- Modify: `config/config.go`
- Test: `config/config_test.go`

- [ ] **Step 1: Write failing test for legacy migration**

Append to `config/config_test.go`:

```go
func TestMigrateLegacyAgentAI_ClaudeKey(t *testing.T) {
	agent := AgentConfig{
		AIProvider:      "claude",
		AnthropicAPIKey: "sk-ant-legacy",
	}
	migrateLegacyAgentAI(&agent)
	if agent.AI.Default.Provider != "claude" {
		t.Errorf("AI.Default.Provider = %q; want claude", agent.AI.Default.Provider)
	}
	if agent.AI.Default.APIKey != "sk-ant-legacy" {
		t.Errorf("AI.Default.APIKey = %q; want sk-ant-legacy", agent.AI.Default.APIKey)
	}
}

func TestMigrateLegacyAgentAI_OpenAIReusesKey(t *testing.T) {
	agent := AgentConfig{
		AIProvider:      "openai",
		AnthropicAPIKey: "sk-openai-legacy",
	}
	migrateLegacyAgentAI(&agent)
	if agent.AI.Default.Provider != "openai" || agent.AI.Default.APIKey != "sk-openai-legacy" {
		t.Errorf("openai legacy migration failed: %+v", agent.AI.Default)
	}
}

func TestMigrateLegacyAgentAI_OllamaEndpoint(t *testing.T) {
	agent := AgentConfig{
		AIProvider:     "ollama",
		OllamaEndpoint: "http://localhost:11434",
		OllamaModel:    "llama3",
	}
	migrateLegacyAgentAI(&agent)
	if agent.AI.Default.Provider != "ollama" ||
		agent.AI.Default.Endpoint != "http://localhost:11434" ||
		agent.AI.Default.Model != "llama3" {
		t.Errorf("ollama legacy migration failed: %+v", agent.AI.Default)
	}
}

func TestMigrateLegacyAgentAI_SkipsWhenAIDefaultPresent(t *testing.T) {
	agent := AgentConfig{
		AIProvider:      "claude",
		AnthropicAPIKey: "sk-legacy",
		AI: AIConfig{
			Default: ProviderConfig{Provider: "openai", APIKey: "sk-new"},
		},
	}
	migrateLegacyAgentAI(&agent)
	if agent.AI.Default.Provider != "openai" {
		t.Errorf("migration overwrote existing AI.Default: %+v", agent.AI.Default)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./config -run TestMigrateLegacyAgentAI -v
```

Expected: FAIL — `AgentConfig` has no field `AI`, function `migrateLegacyAgentAI` undefined.

- [ ] **Step 3: Add AI field and migration function**

Edit `config/config.go`: add `AI AIConfig` to `AgentConfig` struct (append at end):

```go
type AgentConfig struct {
	HeartbeatInterval   int    `mapstructure:"heartbeat_interval"`
	HealthCheckInterval int    `mapstructure:"healthcheck_interval"`
	FailureTimeout      int    `mapstructure:"failure_timeout"`
	CheckpointDir       string `mapstructure:"checkpoint_dir"`
	AnthropicAPIKey     string `mapstructure:"anthropic_api_key"` // deprecated: use AI.Default
	AgentPort           int    `mapstructure:"agent_port"`
	AIProvider          string `mapstructure:"ai_provider"`       // deprecated: use AI.Default.Provider
	OllamaEndpoint      string `mapstructure:"ollama_endpoint"`   // deprecated: use AI.Default.Endpoint
	OllamaModel         string `mapstructure:"ollama_model"`      // deprecated: use AI.Default.Model
	LMStudioEndpoint    string `mapstructure:"lmstudio_endpoint"` // deprecated: use AI.Default.Endpoint
	LMStudioModel       string `mapstructure:"lmstudio_model"`    // deprecated: use AI.Default.Model
	AI                  AIConfig `mapstructure:"ai"`
}
```

Add `migrateLegacyAgentAI` before `DefaultConfig`:

```go
// migrateLegacyAgentAI copies deprecated single-provider fields into the new
// AIConfig.Default structure. No-op when AI.Default.Provider is already set.
func migrateLegacyAgentAI(agent *AgentConfig) {
	if agent.AI.Default.Provider != "" {
		return
	}
	switch agent.AIProvider {
	case "claude":
		agent.AI.Default = ProviderConfig{Provider: "claude", APIKey: agent.AnthropicAPIKey}
	case "openai":
		// Legacy code reused AnthropicAPIKey as OpenAI key; preserve that quirk.
		agent.AI.Default = ProviderConfig{Provider: "openai", APIKey: agent.AnthropicAPIKey}
	case "ollama":
		agent.AI.Default = ProviderConfig{
			Provider: "ollama",
			Endpoint: agent.OllamaEndpoint,
			Model:    agent.OllamaModel,
		}
	case "lmstudio":
		agent.AI.Default = ProviderConfig{
			Provider: "lmstudio",
			Endpoint: agent.LMStudioEndpoint,
			Model:    agent.LMStudioModel,
		}
	}
}
```

Call `migrateLegacyAgentAI(&cfg.Agent)` in `Load()` immediately after the `viper.Unmarshal(cfg)` line:

```go
	if err := viper.Unmarshal(cfg); err != nil {
		return nil, fmt.Errorf("failed to unmarshal config: %w", err)
	}

	migrateLegacyAgentAI(&cfg.Agent)

	return cfg, nil
```

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./config -run TestMigrateLegacyAgentAI -v
go test ./config -v
```

Expected: all pass, including previous Resolve tests.

- [ ] **Step 5: Commit**

```bash
git add config/config.go config/config_test.go
git commit -m "feat(config): add AI field to AgentConfig with legacy field migration"
```

---

### Task 3: Persist AIConfig via config.Save

**Files:**
- Modify: `config/config.go`
- Test: `config/config_test.go`

- [ ] **Step 1: Write failing round-trip test**

Append to `config/config_test.go`:

```go
func TestConfig_SaveAndLoad_AIConfig(t *testing.T) {
	tmpDir := t.TempDir()
	t.Setenv("NAGA_CONFIG_DIR", tmpDir)
	// Tailscale.APIKey required by Validate(); not used here but keep the file loadable.
	cfg := DefaultConfig()
	cfg.Tailscale.APIKey = "tskey-roundtrip"
	override := ProviderConfig{Provider: "ollama", Endpoint: "http://localhost:11434", Model: "llama3"}
	cfg.Agent.AI = AIConfig{
		Default:        ProviderConfig{Provider: "claude", APIKey: "sk-default", Model: "claude-sonnet-4-6"},
		TaskScheduling: &override,
	}

	if err := Save(cfg); err != nil {
		t.Fatalf("Save: %v", err)
	}

	loaded, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if loaded.Agent.AI.Default.Provider != "claude" || loaded.Agent.AI.Default.APIKey != "sk-default" {
		t.Errorf("Default not persisted: %+v", loaded.Agent.AI.Default)
	}
	if loaded.Agent.AI.TaskScheduling == nil || loaded.Agent.AI.TaskScheduling.Provider != "ollama" {
		t.Errorf("TaskScheduling override not persisted: %+v", loaded.Agent.AI.TaskScheduling)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./config -run TestConfig_SaveAndLoad_AIConfig -v
```

Expected: FAIL — Save does not yet write AI fields, so loaded.Agent.AI is empty.

- [ ] **Step 3: Extend Save to write AIConfig**

In `config/config.go`, extend `Save` (after the existing `viper.Set` calls, before `configPath := ...`):

```go
	// AI config — new role-based structure
	viper.Set("agent.ai.default.provider", cfg.Agent.AI.Default.Provider)
	viper.Set("agent.ai.default.api_key", cfg.Agent.AI.Default.APIKey)
	viper.Set("agent.ai.default.endpoint", cfg.Agent.AI.Default.Endpoint)
	viper.Set("agent.ai.default.model", cfg.Agent.AI.Default.Model)
	setRoleOverride("agent.ai.head_selection", cfg.Agent.AI.HeadSelection)
	setRoleOverride("agent.ai.task_scheduling", cfg.Agent.AI.TaskScheduling)
	setRoleOverride("agent.ai.capacity_estimation", cfg.Agent.AI.CapacityEstimation)
```

Add helper at bottom of file:

```go
// setRoleOverride sets a role-override block in viper, or clears it if nil.
func setRoleOverride(key string, p *ProviderConfig) {
	if p == nil {
		viper.Set(key, nil)
		return
	}
	viper.Set(key+".provider", p.Provider)
	viper.Set(key+".api_key", p.APIKey)
	viper.Set(key+".endpoint", p.Endpoint)
	viper.Set(key+".model", p.Model)
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./config -v
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add config/config.go config/config_test.go
git commit -m "feat(config): persist AIConfig through Save/Load round-trip"
```

---

## Phase B — Go Backend: Server Wiring

### Task 4: Refactor cmd/server/ai.go into role builders

**Files:**
- Modify: `cmd/server/ai.go`

- [ ] **Step 1: Replace file contents**

Overwrite `cmd/server/ai.go`:

```go
package main

import (
	"log"

	"github.com/s1ckdark/hydra/config"
	"github.com/s1ckdark/hydra/internal/infra/ai"
	"github.com/s1ckdark/hydra/internal/infra/ai/claude"
	"github.com/s1ckdark/hydra/internal/infra/ai/lmstudio"
	"github.com/s1ckdark/hydra/internal/infra/ai/ollama"
	"github.com/s1ckdark/hydra/internal/infra/ai/openai"
)

// buildAIRegistry wires role-specific providers from the resolved AIConfig.
// Unsupported (provider,role) combinations fall through to the Registry's
// rule-based fallback.
func buildAIRegistry(aicfg config.AIConfig) *ai.Registry {
	reg := ai.NewRegistry(ai.Config{})
	if hs := buildHeadSelector(aicfg.Resolve("head")); hs != nil {
		reg.SetHeadSelector(hs)
	}
	if ts := buildTaskScheduler(aicfg.Resolve("schedule")); ts != nil {
		reg.SetTaskScheduler(ts)
	}
	// CapacityEstimator: no concrete provider implements it yet; left nil by design.
	return reg
}

// buildTaskScheduler returns an ai.TaskScheduler for the given provider config,
// or nil when credentials/endpoint are missing or the provider is unknown.
// Exported-through-package for main.go's legacy call site.
func buildTaskScheduler(p config.ProviderConfig) ai.TaskScheduler {
	switch p.Provider {
	case "":
		return nil
	case "claude":
		if p.APIKey == "" {
			log.Println("[ai] claude task-scheduler: empty api_key; disabled")
			return nil
		}
		return claude.NewProvider(p.APIKey, p.Model)
	case "openai":
		if p.APIKey == "" {
			log.Println("[ai] openai task-scheduler: empty api_key; disabled")
			return nil
		}
		return openai.NewProvider(p.APIKey, p.Model)
	case "ollama":
		if p.Endpoint == "" {
			log.Println("[ai] ollama task-scheduler: empty endpoint; disabled")
			return nil
		}
		return ollama.NewProvider(p.Endpoint, p.Model)
	case "lmstudio":
		if p.Endpoint == "" {
			log.Println("[ai] lmstudio task-scheduler: empty endpoint; disabled")
			return nil
		}
		return lmstudio.NewProvider(p.Endpoint, p.Model)
	default:
		log.Printf("[ai] unknown provider %q for task scheduler; disabled", p.Provider)
		return nil
	}
}

// buildHeadSelector returns an ai.HeadSelector for the given provider config,
// or nil when the provider does not support head selection.
func buildHeadSelector(p config.ProviderConfig) ai.HeadSelector {
	if p.Provider != "claude" {
		return nil
	}
	if p.APIKey == "" {
		return nil
	}
	return claude.NewProvider(p.APIKey, p.Model)
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
go build ./cmd/server/...
```

Expected: build error — `buildAITaskScheduler` still referenced by `main.go` (next task fixes that).

- [ ] **Step 3: Commit**

```bash
git add cmd/server/ai.go
git commit -m "refactor(server): split AI wiring into role-aware builders"
```

---

### Task 5: Update main.go to use buildAIRegistry

**Files:**
- Modify: `cmd/server/main.go`

- [ ] **Step 1: Replace call site**

In `cmd/server/main.go`, lines 156–159 currently read:

```go
	if arbiter := buildAITaskScheduler(cfg.Agent); arbiter != nil {
		taskSupervisor.SetAIArbiter(arbiter, 0.10, 5, 3*time.Second)
		log.Printf("[supervisor] AI tiebreaker enabled (provider=%s, epsilon=0.10, budget=5/tick, timeout=3s)", cfg.Agent.AIProvider)
	}
```

Replace with:

```go
	aiRegistry := buildAIRegistry(cfg.Agent.AI)
	if arbiter := aiRegistry.TaskSchedulerProvider(); arbiter != nil {
		taskSupervisor.SetAIArbiter(arbiter, 0.10, 5, 3*time.Second)
		log.Printf("[supervisor] AI tiebreaker enabled (provider=%s, epsilon=0.10, budget=5/tick, timeout=3s)", cfg.Agent.AI.Resolve("schedule").Provider)
	}
```

- [ ] **Step 2: Add TaskSchedulerProvider accessor to Registry**

In `internal/infra/ai/registry.go`, append:

```go
// TaskSchedulerProvider returns the configured task scheduler or nil.
// Callers that want fallback-aware routing should use ScheduleTask directly.
func (r *Registry) TaskSchedulerProvider() TaskScheduler {
	return r.taskScheduler
}
```

- [ ] **Step 3: Build server**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
go build ./cmd/server/...
```

Expected: clean build.

- [ ] **Step 4: Run all Go tests**

```bash
go test ./...
```

Expected: PASS (no regressions).

- [ ] **Step 5: Commit**

```bash
git add cmd/server/main.go internal/infra/ai/registry.go
git commit -m "feat(server): wire AIRegistry from AIConfig in task supervisor"
```

---

### Task 6: Create AI config HTTP handler

**Files:**
- Create: `internal/web/handler/ai_config_handler.go`
- Create: `internal/web/handler/ai_config_handler_test.go`

- [ ] **Step 1: Write failing handler tests**

Create `internal/web/handler/ai_config_handler_test.go`:

```go
package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/config"
)

func newAIHandler(t *testing.T) (*Handler, *config.Config) {
	t.Helper()
	cfg := config.DefaultConfig()
	// Avoid Save writing to real home dir during tests
	t.Setenv("NAGA_CONFIG_DIR", t.TempDir())
	cfg.Tailscale.APIKey = "tskey-test"
	h := &Handler{cfg: cfg}
	return h, cfg
}

func TestAPIGetAIConfig_MasksSecrets(t *testing.T) {
	h, cfg := newAIHandler(t)
	cfg.Agent.AI = config.AIConfig{
		Default: config.ProviderConfig{Provider: "claude", APIKey: "sk-secret", Model: "claude-sonnet-4-6"},
	}

	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/api/config/ai", nil)
	rec := httptest.NewRecorder()
	ctx := e.NewContext(req, rec)

	if err := h.APIGetAIConfig(ctx); err != nil {
		t.Fatalf("handler returned error: %v", err)
	}
	body := rec.Body.String()
	if strings.Contains(body, "sk-secret") {
		t.Errorf("response leaked secret api key: %s", body)
	}
	if !strings.Contains(body, `"has_api_key":true`) {
		t.Errorf("response missing has_api_key:true: %s", body)
	}
}

func TestAPIPutAIConfig_RejectsProviderlessDefault(t *testing.T) {
	h, _ := newAIHandler(t)
	e := echo.New()
	body := `{"default": {"provider": ""}}`
	req := httptest.NewRequest(http.MethodPut, "/api/config/ai", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	ctx := e.NewContext(req, rec)

	if err := h.APIPutAIConfig(ctx); err != nil {
		t.Fatalf("handler error: %v", err)
	}
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d; want 400", rec.Code)
	}
}

func TestAPIPutAIConfig_AcceptsValidClaude(t *testing.T) {
	h, cfg := newAIHandler(t)
	e := echo.New()
	payload := map[string]any{
		"default": map[string]any{
			"provider": "claude",
			"api_key":  "sk-new",
			"model":    "claude-sonnet-4-6",
		},
	}
	data, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPut, "/api/config/ai", bytes.NewReader(data))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	ctx := e.NewContext(req, rec)

	if err := h.APIPutAIConfig(ctx); err != nil {
		t.Fatalf("handler error: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d; want 200; body=%s", rec.Code, rec.Body.String())
	}
	if cfg.Agent.AI.Default.APIKey != "sk-new" {
		t.Errorf("cfg not updated: %+v", cfg.Agent.AI.Default)
	}
}

func TestAPIPutAIConfig_RequiresAPIKeyForCloudProvider(t *testing.T) {
	h, _ := newAIHandler(t)
	e := echo.New()
	body := `{"default": {"provider": "openai", "api_key": ""}}`
	req := httptest.NewRequest(http.MethodPut, "/api/config/ai", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	ctx := e.NewContext(req, rec)

	if err := h.APIPutAIConfig(ctx); err != nil {
		t.Fatalf("handler error: %v", err)
	}
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d; want 400 for cloud provider without api_key", rec.Code)
	}
}

func TestAPIPutAIConfig_RequiresEndpointForLocalProvider(t *testing.T) {
	h, _ := newAIHandler(t)
	e := echo.New()
	body := `{"default": {"provider": "ollama", "endpoint": ""}}`
	req := httptest.NewRequest(http.MethodPut, "/api/config/ai", strings.NewReader(body))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationJSON)
	rec := httptest.NewRecorder()
	ctx := e.NewContext(req, rec)

	if err := h.APIPutAIConfig(ctx); err != nil {
		t.Fatalf("handler error: %v", err)
	}
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d; want 400 for local provider without endpoint", rec.Code)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/web/handler -run APIGetAIConfig -v
```

Expected: FAIL — handler undefined.

- [ ] **Step 3: Create handler file**

Create `internal/web/handler/ai_config_handler.go`:

```go
package handler

import (
	"net/http"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/config"
)

// AIConfigRequest is the payload for updating AI provider configuration.
type AIConfigRequest struct {
	Default            config.ProviderConfig  `json:"default"`
	HeadSelection      *config.ProviderConfig `json:"head_selection,omitempty"`
	TaskScheduling     *config.ProviderConfig `json:"task_scheduling,omitempty"`
	CapacityEstimation *config.ProviderConfig `json:"capacity_estimation,omitempty"`
}

// APIGetAIConfig returns the current AI configuration with API keys masked.
func (h *Handler) APIGetAIConfig(c echo.Context) error {
	ai := h.cfg.Agent.AI
	return c.JSON(http.StatusOK, map[string]any{
		"default":             maskedProvider(ai.Default),
		"head_selection":      maskedProviderPtr(ai.HeadSelection),
		"task_scheduling":     maskedProviderPtr(ai.TaskScheduling),
		"capacity_estimation": maskedProviderPtr(ai.CapacityEstimation),
	})
}

// APIPutAIConfig updates AI provider config and persists to disk.
func (h *Handler) APIPutAIConfig(c echo.Context) error {
	var req AIConfigRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid request body"})
	}

	if err := validateProvider(req.Default, "default"); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
	}
	for role, p := range map[string]*config.ProviderConfig{
		"head_selection":      req.HeadSelection,
		"task_scheduling":     req.TaskScheduling,
		"capacity_estimation": req.CapacityEstimation,
	} {
		if p == nil || p.Provider == "" {
			continue
		}
		if err := validateProvider(*p, role); err != nil {
			return c.JSON(http.StatusBadRequest, map[string]string{"error": err.Error()})
		}
	}

	h.cfg.Agent.AI = config.AIConfig{
		Default:            req.Default,
		HeadSelection:      req.HeadSelection,
		TaskScheduling:     req.TaskScheduling,
		CapacityEstimation: req.CapacityEstimation,
	}

	if err := config.Save(h.cfg); err != nil {
		return internalError(c, "failed to save config", err)
	}
	return c.JSON(http.StatusOK, map[string]string{"status": "updated"})
}

// maskedProvider returns a JSON-safe view of a ProviderConfig with the secret
// APIKey replaced by a boolean flag.
func maskedProvider(p config.ProviderConfig) map[string]any {
	return map[string]any{
		"provider":    p.Provider,
		"has_api_key": p.APIKey != "",
		"endpoint":    p.Endpoint,
		"model":       p.Model,
	}
}

func maskedProviderPtr(p *config.ProviderConfig) any {
	if p == nil {
		return nil
	}
	return maskedProvider(*p)
}

// validateProvider checks that a ProviderConfig has the required field for its
// auth mode (api_key for cloud providers, endpoint for local providers).
func validateProvider(p config.ProviderConfig, role string) error {
	switch p.Provider {
	case "":
		if role == "default" {
			return echoError("default provider is required")
		}
		return nil
	case "claude", "openai", "zai":
		if p.APIKey == "" {
			return echoError(role + ": api_key required for provider " + p.Provider)
		}
	case "ollama", "lmstudio", "openai_compatible":
		if p.Endpoint == "" {
			return echoError(role + ": endpoint required for provider " + p.Provider)
		}
	default:
		return echoError(role + ": unknown provider " + p.Provider)
	}
	return nil
}

type handlerError struct{ msg string }

func (e handlerError) Error() string { return e.msg }
func echoError(msg string) error     { return handlerError{msg: msg} }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/web/handler -v
```

Expected: the 5 new tests pass. Existing tests also still pass.

- [ ] **Step 5: Commit**

```bash
git add internal/web/handler/ai_config_handler.go internal/web/handler/ai_config_handler_test.go
git commit -m "feat(handler): add GET/PUT /api/config/ai with masked secrets"
```

---

### Task 7: Register AI config routes in main.go

**Files:**
- Modify: `cmd/server/main.go`

- [ ] **Step 1: Add route registrations**

In `cmd/server/main.go`, find the block at line ~269:

```go
	// Config routes (Tailscale network auth required)
	apiWrite.GET("/config/tailscale", h.APIGetTailscaleConfig)
	apiWrite.PUT("/config/tailscale", h.APIPutTailscaleConfig)
```

Add two lines below:

```go
	// Config routes (Tailscale network auth required)
	apiWrite.GET("/config/tailscale", h.APIGetTailscaleConfig)
	apiWrite.PUT("/config/tailscale", h.APIPutTailscaleConfig)
	apiWrite.GET("/config/ai", h.APIGetAIConfig)
	apiWrite.PUT("/config/ai", h.APIPutAIConfig)
```

- [ ] **Step 2: Build and smoke-test**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
go build -o /tmp/hydra-server-test ./cmd/server
```

Expected: clean build.

- [ ] **Step 3: Manual endpoint smoke-test**

Kill the running server first (confirm with user — it's PID 6508 per earlier check). Then:

```bash
# In one terminal
/tmp/hydra-server-test &
SERVER_PID=$!
sleep 2

# GET (no auth needed — localhost is within tailscale middleware allowlist)
curl -s http://127.0.0.1:8080/api/config/ai | head -c 500
echo

# PUT
curl -s -X PUT http://127.0.0.1:8080/api/config/ai \
  -H 'Content-Type: application/json' \
  -d '{"default":{"provider":"claude","api_key":"sk-smoke-test","model":"claude-sonnet-4-6"}}'
echo

# Confirm masked in GET
curl -s http://127.0.0.1:8080/api/config/ai
echo

kill $SERVER_PID
```

Expected:
- First GET: `{"default":{"has_api_key":false,...}, "head_selection":null, ...}`
- PUT: `{"status":"updated"}`
- Second GET: `{"default":{"has_api_key":true, "provider":"claude", ...}, ...}` — no `sk-smoke-test` leak

- [ ] **Step 4: Commit**

```bash
git add cmd/server/main.go
git commit -m "feat(server): expose /api/config/ai routes"
```

---

## Phase C — Swift macOS Frontend

### Task 8: Add Keychain keys for AI credentials

**Files:**
- Modify: `Hydra/Hydra/Services/CredentialStore.swift`

- [ ] **Step 1: Extend the Key enum**

In `Hydra/Hydra/Services/CredentialStore.swift`, replace the `enum Key` block (lines 13–18) with:

```swift
    enum Key: String, CaseIterable {
        case serverAPIKey = "server_api_key"
        case tailscaleAPIKey = "tailscale_api_key"
        case tailscaleOAuthClientID = "tailscale_oauth_client_id"
        case tailscaleOAuthClientSecret = "tailscale_oauth_client_secret"
        case aiDefaultAPIKey = "ai_default_api_key"
        case aiHeadAPIKey = "ai_head_api_key"
        case aiScheduleAPIKey = "ai_schedule_api_key"
        case aiCapacityAPIKey = "ai_capacity_api_key"
    }
```

- [ ] **Step 2: Verify swift build still passes**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79/Hydra
swift build
```

Expected: build success.

- [ ] **Step 3: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
git add Hydra/Hydra/Services/CredentialStore.swift
git commit -m "feat(credentials): add AI provider keychain slots"
```

---

### Task 9: Create AISettingsTab.swift with Basic provider form

**Files:**
- Create: `Hydra/Hydra/Views/Settings/AISettingsTab.swift`

- [ ] **Step 1: Create the file**

Create `Hydra/Hydra/Views/Settings/AISettingsTab.swift`:

```swift
import SwiftUI

#if os(macOS)
struct AISettingsTab: View {
    // Single provider dropdown — no separate Auth Method toggle.
    // Provider value drives whether API Key field or Endpoint field is shown.
    @AppStorage("serverURL") private var serverURL = "http://localhost:8080"
    @AppStorage("aiDefaultProvider") private var provider: String = "claude"
    @AppStorage("aiDefaultEndpoint") private var endpoint: String = ""
    @AppStorage("aiDefaultModel") private var model: String = ""

    @State private var apiKey: String = ""
    @State private var connectionVerified = false
    @State private var testStatus: TestStatus?
    @State private var saveStatus: SaveStatus?
    @State private var showAdvanced = false

    private let store = CredentialStore.shared

    enum TestStatus {
        case testing
        case success(String)
        case error(String)
    }

    enum SaveStatus {
        case saving
        case savedLocally
        case pushedToServer
        case error(String)
    }

    /// Cloud providers require an API key; local providers require an endpoint URL.
    static let cloudProviders: Set<String> = ["claude", "openai", "zai"]
    static let localProviders: Set<String> = ["ollama", "lmstudio", "openai_compatible"]

    private var isCloudProvider: Bool { Self.cloudProviders.contains(provider) }

    /// Display label combining provider id with its group hint.
    private func label(for id: String) -> String {
        switch id {
        case "claude":             return "Claude (cloud)"
        case "openai":             return "OpenAI (cloud)"
        case "zai":                return "Z.AI (cloud)"
        case "ollama":             return "Ollama (local)"
        case "lmstudio":           return "LM Studio (local)"
        case "openai_compatible":  return "OpenAI-compatible (local)"
        default:                   return id
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    Text(label(for: "claude")).tag("claude")
                    Text(label(for: "openai")).tag("openai")
                    Text(label(for: "zai")).tag("zai")
                    Text(label(for: "ollama")).tag("ollama")
                    Text(label(for: "lmstudio")).tag("lmstudio")
                    Text(label(for: "openai_compatible")).tag("openai_compatible")
                }
                .onChange(of: provider) { credentialsChanged() }

                if isCloudProvider {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { credentialsChanged() }
                } else {
                    TextField("Endpoint", text: $endpoint, prompt: Text("http://localhost:11434"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: endpoint) { credentialsChanged() }
                }

                TextField("Model (optional)", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { credentialsChanged() }
            } header: {
                Text("① AI Provider (Default)")
            }

            // Placeholder for Verify/Save sections added in later tasks
            Section {
                Text("Test and Save will be wired up next.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = store.get(.aiDefaultAPIKey)
        }
    }

    private func credentialsChanged() {
        connectionVerified = false
        testStatus = nil
        saveStatus = nil
    }
}
#endif
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79/Hydra
swift build
```

Expected: clean build. (Tab not yet wired into SettingsView — happens in Task 13.)

- [ ] **Step 3: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
git add Hydra/Hydra/Views/Settings/AISettingsTab.swift
git commit -m "feat(ui): AI settings tab scaffold with single provider picker"
```

---

### Task 10: Add Test Connection for the default provider

**Files:**
- Modify: `Hydra/Hydra/Views/Settings/AISettingsTab.swift`

- [ ] **Step 1: Add Test section and test functions**

In `AISettingsTab.swift`, replace the placeholder `Section { Text("Test and Save will be wired up next.") ... }` with:

```swift
            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Image(systemName: "bolt.horizontal.circle")
                        Text("Test Connection")
                    }
                }
                .disabled(testStatus.isTesting || !hasCredentials)

                if let status = testStatus {
                    switch status {
                    case .testing:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Testing…").font(.caption)
                        }
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            } header: {
                Text("② Verify")
            }
```

Add these helpers inside the struct (below `credentialsChanged`):

```swift
    private var hasCredentials: Bool {
        if isCloudProvider { return !apiKey.isEmpty }
        return !endpoint.isEmpty
    }

    private func testConnection() async {
        withAnimation { testStatus = .testing }

        let urlString: String
        var headers: [String: String] = [:]
        switch provider {
        case "claude":
            urlString = "https://api.anthropic.com/v1/models"
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
        case "openai":
            urlString = "https://api.openai.com/v1/models"
            headers["Authorization"] = "Bearer \(apiKey)"
        case "zai":
            urlString = "https://api.z.ai/v1/models"
            headers["Authorization"] = "Bearer \(apiKey)"
        case "ollama":
            urlString = endpoint.trimmingCharacters(in: .whitespaces) + "/api/tags"
        case "lmstudio", "openai_compatible":
            urlString = endpoint.trimmingCharacters(in: .whitespaces) + "/v1/models"
        default:
            withAnimation { testStatus = .error("Unknown provider: \(provider)") }
            return
        }

        guard let url = URL(string: urlString) else {
            withAnimation { testStatus = .error("Invalid endpoint URL") }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                withAnimation { testStatus = .error("No response") }
                return
            }
            if (200...299).contains(http.statusCode) {
                withAnimation {
                    connectionVerified = true
                    testStatus = .success("Connected to \(provider)")
                }
            } else {
                withAnimation { testStatus = .error("\(provider) returned HTTP \(http.statusCode)") }
            }
        } catch {
            withAnimation { testStatus = .error("Connection failed: \(error.localizedDescription)") }
        }
    }
```

Add the TestStatus `isTesting` extension at the bottom of the file (outside the struct, inside `#if os(macOS)`):

```swift
private extension Optional where Wrapped == AISettingsTab.TestStatus {
    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79/Hydra
swift build
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
git add Hydra/Hydra/Views/Settings/AISettingsTab.swift
git commit -m "feat(ui): add Test Connection for AI providers"
```

---

### Task 11: Add Save (local + push to Hydra server)

**Files:**
- Modify: `Hydra/Hydra/Views/Settings/AISettingsTab.swift`

- [ ] **Step 1: Add Save section after Verify**

In `AISettingsTab.swift`, below the Verify `Section`, add:

```swift
            Section {
                HStack {
                    Button("Save Locally") { saveLocally() }
                        .disabled(!connectionVerified)

                    Spacer()

                    Button("Save & Push to Server") {
                        Task { await pushToServer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connectionVerified || saveStatus.isSaving)
                }

                if !connectionVerified {
                    Text("Test the connection first before saving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let status = saveStatus {
                    switch status {
                    case .saving:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Pushing to server…").font(.caption)
                        }
                    case .savedLocally:
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .pushedToServer:
                        Label("Saved locally & pushed to server", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    case .error(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
            } header: {
                Text("③ Save")
            }
```

Add these methods inside the struct:

```swift
    private func saveLocally() {
        // Only persist a key when the chosen provider needs one.
        store.set(.aiDefaultAPIKey, value: isCloudProvider ? apiKey : "")
        withAnimation { saveStatus = .savedLocally }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { saveStatus = nil }
        }
    }

    private func pushToServer() async {
        withAnimation { saveStatus = .saving }
        saveLocally()

        var defaultPayload: [String: String] = [
            "provider": provider,
            "model":    model,
        ]
        if isCloudProvider {
            defaultPayload["api_key"] = apiKey
        } else {
            defaultPayload["endpoint"] = endpoint
        }

        let body: [String: Any] = ["default": defaultPayload]

        do {
            let url = URL(string: serverURL)!.appendingPathComponent("api/config/ai")
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let serverKey = store.get(.serverAPIKey)
            if !serverKey.isEmpty {
                request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                withAnimation { saveStatus = .error("Server returned \(code)") }
                return
            }

            withAnimation { saveStatus = .pushedToServer }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { saveStatus = nil }
            }
        } catch {
            withAnimation { saveStatus = .error(error.localizedDescription) }
        }
    }
```

Add SaveStatus `isSaving` extension at bottom of file (inside `#if os(macOS)`):

```swift
private extension Optional where Wrapped == AISettingsTab.SaveStatus {
    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79/Hydra
swift build
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
git add Hydra/Hydra/Views/Settings/AISettingsTab.swift
git commit -m "feat(ui): save AI config locally and push to Hydra server"
```

---

### Task 12: Add Advanced disclosure with 3 role overrides

**Files:**
- Modify: `Hydra/Hydra/Views/Settings/AISettingsTab.swift`

- [ ] **Step 1: Add Advanced section above Save**

In `AISettingsTab.swift`, after the Verify section and BEFORE the Save section, insert:

```swift
            Section {
                DisclosureGroup("Advanced: per-role overrides", isExpanded: $showAdvanced) {
                    RoleOverrideView(title: "Head Selection", role: "head")
                    RoleOverrideView(title: "Task Scheduling", role: "schedule")
                    RoleOverrideView(title: "Capacity Estimation", role: "capacity")
                }
            } header: {
                Text("③ Advanced (optional)")
            }
```

Renumber Save section header: change `Text("③ Save")` to `Text("④ Save")`.

Add RoleOverrideView at the bottom of the file (inside `#if os(macOS)`, outside AISettingsTab):

```swift
private struct RoleOverrideView: View {
    let title: String
    let role: String

    @AppStorage private var useDefault: Bool
    @AppStorage private var provider: String
    @AppStorage private var endpoint: String
    @AppStorage private var model: String

    init(title: String, role: String) {
        self.title = title
        self.role = role
        self._useDefault = AppStorage(wrappedValue: true, "aiRole_\(role)_useDefault")
        self._provider   = AppStorage(wrappedValue: "",   "aiRole_\(role)_provider")
        self._endpoint   = AppStorage(wrappedValue: "",   "aiRole_\(role)_endpoint")
        self._model      = AppStorage(wrappedValue: "",   "aiRole_\(role)_model")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: Binding(
                get: { useDefault },
                set: { useDefault = $0 }
            ))
            .toggleStyle(.switch)
            .font(.headline)

            if !useDefault {
                HStack {
                    Text("Provider")
                    Spacer()
                    TextField("claude, openai, ollama…", text: $provider)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                HStack {
                    Text("Endpoint / Key")
                    Spacer()
                    SecureField("api key or endpoint URL", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                HStack {
                    Text("Model")
                    Spacer()
                    TextField("(optional)", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                Text("Overrides are stored locally. Push to server to apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Uses the default provider above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
```

Note: the Advanced overrides use a single `endpoint` text field that semantically holds either an API key or an endpoint URL, depending on provider. Full cloud/local differentiation can be added later — the current scope is "a place to put per-role values."

- [ ] **Step 2: Build**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79/Hydra
swift build
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
git add Hydra/Hydra/Views/Settings/AISettingsTab.swift
git commit -m "feat(ui): add Advanced disclosure with per-role AI overrides"
```

---

### Task 13: Wire AISettingsTab into SettingsView and verify end-to-end

**Files:**
- Modify: `Hydra/Hydra/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Add the AI tab**

In `Hydra/Hydra/Views/Settings/SettingsView.swift`, replace the `body` of `SettingsView` (lines 5–15):

```swift
    var body: some View {
        TabView {
            ServerSettingsTab()
                .tabItem { Label("Server", systemImage: "server.rack") }

            TailscaleSettingsTab()
                .tabItem { Label("Tailscale", systemImage: "network") }

            AISettingsTab()
                .tabItem { Label("AI", systemImage: "brain") }
        }
        .frame(width: 560, height: 520)
    }
```

(Frame enlarged from 500×400 to fit the AI form.)

- [ ] **Step 2: Build and launch**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79/Hydra
swift build
# Kill any running Hydra instances first, then launch
pkill -f ".build/.*Hydra$" || true
sleep 1
nohup .build/arm64-apple-macosx/debug/Hydra > /tmp/hydra-gui.log 2>&1 & disown
```

Expected: Hydra GUI window appears. Open Preferences (⌘,) — AI tab is visible.

- [ ] **Step 3: Manual verification checklist**

Confirm each of the following in the running app. If any fail, stop and report before committing.

1. AI tab shows a single Provider dropdown with all 6 entries labeled with group hints (e.g. "Claude (cloud)", "Ollama (local)")
2. Selecting a cloud provider (Claude/OpenAI/Z.AI) reveals a SecureField labeled "API Key"
3. Selecting a local provider (Ollama/LM Studio/OpenAI-compatible) reveals a TextField labeled "Endpoint"
4. Test Connection button disabled until a key/endpoint is entered
5. Test Connection with a real key (ask user) reports success; invalid key reports error
6. Save Locally and Save & Push to Server buttons disabled until test succeeds
7. Save & Push to Server: after successful save, hitting `curl http://127.0.0.1:8080/api/config/ai` shows the new provider with `has_api_key:true` (no key leaked)
8. Advanced disclosure expands to show 3 role sections with Use Default toggles
9. Toggling Use Default OFF reveals per-role provider/endpoint/model fields

- [ ] **Step 4: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
git add Hydra/Hydra/Views/Settings/SettingsView.swift
git commit -m "feat(ui): add AI tab to macOS Settings"
```

---

## Final Verification

- [ ] **Run full Go test suite**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79
go test ./...
```

Expected: all pass.

- [ ] **Confirm Swift app builds release-mode**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/gifted-feynman-8f2d79/Hydra
swift build -c release
```

Expected: clean build.

- [ ] **Verify legacy config still loads**

Create a test YAML with only legacy fields and confirm `config.Load` populates `AI.Default`:

```bash
mkdir -p /tmp/hydra-legacy-test
cat > /tmp/hydra-legacy-test/config.yaml <<EOF
tailscale:
  api_key: tskey-legacy
agent:
  ai_provider: claude
  anthropic_api_key: sk-legacy-migrated
EOF

NAGA_CONFIG_DIR=/tmp/hydra-legacy-test go run ./cmd/server --help 2>&1 | head -5 || true
# Then inspect by printing from a tiny Go program or just trust the unit test TestMigrateLegacyAgentAI_ClaudeKey
```

If migration works, the server logs at startup should show `provider=claude` in the AI tiebreaker line — confirmed by reading the live log after boot.

---

## Rollback Plan

Each phase (A / B / C) is independently revertable: each commit targets a single layer.

- To revert UI: `git revert` commits from Task 8 through Task 13.
- To revert handler exposure but keep config migration: `git revert` commits from Task 6 through Task 7.
- To revert the full change: `git reset --hard <commit before Task 1>` (destructive — confirm with user).
