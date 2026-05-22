package main

import (
	"context"
	"log"

	"github.com/s1ckdark/hydra/config"
	"github.com/s1ckdark/hydra/internal/infra/ai"
	"github.com/s1ckdark/hydra/internal/infra/ai/claude"
	"github.com/s1ckdark/hydra/internal/infra/ai/lmstudio"
	"github.com/s1ckdark/hydra/internal/infra/ai/ollama"
	"github.com/s1ckdark/hydra/internal/infra/ai/openai"
	"github.com/s1ckdark/hydra/internal/infra/ai/zai"
	"github.com/s1ckdark/hydra/internal/usecase/agent"
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
	if cp := buildChatProvider(aicfg.Resolve("chat")); cp != nil {
		reg.SetChatProvider(cp)
	} else if cp = buildChatProvider(aicfg.Resolve("schedule")); cp != nil {
		// Fall back to the schedule-role provider when no chat-specific
		// override is configured. T7 will add proper "chat" role resolution.
		reg.SetChatProvider(cp)
	}
	// CapacityEstimator: no concrete provider implements it yet; left nil by design.
	return reg
}

// buildTaskScheduler returns an ai.TaskScheduler for the given provider config,
// or nil when credentials/endpoint are missing or the provider is unknown.
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
	case "zai":
		if p.APIKey == "" {
			log.Println("[ai] zai task-scheduler: empty api_key; disabled")
			return nil
		}
		endpoint := p.Endpoint
		if endpoint == "" {
			endpoint = "https://api.z.ai/v1"
		}
		return zai.NewProvider(p.APIKey, endpoint, p.Model)
	case "openai_compatible":
		if p.Endpoint == "" {
			log.Println("[ai] openai_compatible task-scheduler: empty endpoint; disabled")
			return nil
		}
		return openai.NewLocalProvider(p.Endpoint, p.Model)
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

// buildChatProvider returns an ai.ChatProvider for the given provider config,
// or nil when credentials/endpoint are missing or the provider is unknown.
func buildChatProvider(p config.ProviderConfig) ai.ChatProvider {
	switch p.Provider {
	case "":
		return nil
	case "claude":
		if p.APIKey == "" {
			log.Println("[ai] claude chat-provider: empty api_key; disabled")
			return nil
		}
		return claude.NewProvider(p.APIKey, p.Model)
	case "openai":
		if p.APIKey == "" {
			log.Println("[ai] openai chat-provider: empty api_key; disabled")
			return nil
		}
		return openai.NewProvider(p.APIKey, p.Model)
	case "ollama":
		if p.Endpoint == "" {
			log.Println("[ai] ollama chat-provider: empty endpoint; disabled")
			return nil
		}
		return ollama.NewProvider(p.Endpoint, p.Model)
	case "lmstudio":
		if p.Endpoint == "" {
			log.Println("[ai] lmstudio chat-provider: empty endpoint; disabled")
			return nil
		}
		return lmstudio.NewProvider(p.Endpoint, p.Model)
	case "zai":
		if p.APIKey == "" {
			log.Println("[ai] zai chat-provider: empty api_key; disabled")
			return nil
		}
		endpoint := p.Endpoint
		if endpoint == "" {
			endpoint = "https://api.z.ai/v1"
		}
		return zai.NewProvider(p.APIKey, endpoint, p.Model)
	case "openai_compatible":
		if p.Endpoint == "" {
			log.Println("[ai] openai_compatible chat-provider: empty endpoint; disabled")
			return nil
		}
		return openai.NewLocalProvider(p.Endpoint, p.Model)
	default:
		log.Printf("[ai] unknown provider %q for chat; disabled", p.Provider)
		return nil
	}
}

// buildChatLLM returns an agent.LLMClient backed by the registry's chat
// provider, or nil when no chat provider is configured.
func buildChatLLM(registry *ai.Registry) agent.LLMClient {
	provider := registry.ChatProvider()
	if provider == nil {
		return nil
	}
	return &chatLLMAdapter{p: provider}
}

// chatLLMAdapter bridges ai.ChatProvider to agent.LLMClient.
type chatLLMAdapter struct{ p ai.ChatProvider }

func (a *chatLLMAdapter) Complete(ctx context.Context, system, prompt string) (string, error) {
	return a.p.Complete(ctx, system, prompt)
}
