package main

import (
	"log"

	"github.com/dave/naga/config"
	"github.com/dave/naga/internal/infra/ai"
	"github.com/dave/naga/internal/infra/ai/claude"
	"github.com/dave/naga/internal/infra/ai/lmstudio"
	"github.com/dave/naga/internal/infra/ai/ollama"
	"github.com/dave/naga/internal/infra/ai/openai"
)

// buildAITaskScheduler returns a configured ai.TaskScheduler based on the
// Agent config. Returns nil when no provider is requested or when the
// selected provider is missing required credentials — callers treat nil as
// "no AI tiebreaker configured".
func buildAITaskScheduler(cfg config.AgentConfig) ai.TaskScheduler {
	switch cfg.AIProvider {
	case "":
		return nil
	case "claude":
		if cfg.AnthropicAPIKey == "" {
			log.Println("[ai] claude selected but anthropic_api_key is empty; AI tiebreaker disabled")
			return nil
		}
		return claude.NewProvider(cfg.AnthropicAPIKey, "")
	case "openai":
		if cfg.AnthropicAPIKey == "" {
			log.Println("[ai] openai selected but anthropic_api_key is empty (reused as OpenAI key); AI tiebreaker disabled")
			return nil
		}
		return openai.NewProvider(cfg.AnthropicAPIKey, "")
	case "ollama":
		return ollama.NewProvider(cfg.OllamaEndpoint, cfg.OllamaModel)
	case "lmstudio":
		return lmstudio.NewProvider(cfg.LMStudioEndpoint, cfg.LMStudioModel)
	default:
		log.Printf("[ai] unknown ai_provider %q; AI tiebreaker disabled", cfg.AIProvider)
		return nil
	}
}
