package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dave/naga/internal/agent"
	"github.com/dave/naga/internal/domain"
	"github.com/dave/naga/internal/infra/ai/claude"
	"github.com/dave/naga/internal/infra/ai/ollama"
)

func main() {
	nodeID := flag.String("node-id", "", "Node ID (required)")
	clusterID := flag.String("cluster-id", "", "Cluster ID (required)")
	role := flag.String("role", "worker", "Node role: head or worker")
	port := flag.Int("port", 9090, "HTTP listen port")
	heartbeat := flag.Duration("heartbeat", 3*time.Second, "Heartbeat interval")
	timeout := flag.Duration("timeout", 15*time.Second, "Failure timeout")
	anthropicKey := flag.String("anthropic-key", "", "Anthropic API key (default: $ANTHROPIC_API_KEY)")
	aiProvider := flag.String("ai-provider", "", "AI provider: claude, ollama (default: auto-detect)")
	ollamaEndpoint := flag.String("ollama-endpoint", "", "Ollama endpoint (default: http://localhost:11434)")
	ollamaModel := flag.String("ollama-model", "", "Ollama model name (default: gpt-oss:20b)")

	flag.Parse()

	// Resolve API key from env if not set via flag
	if *anthropicKey == "" {
		*anthropicKey = os.Getenv("ANTHROPIC_API_KEY")
	}
	if *aiProvider == "" {
		*aiProvider = os.Getenv("NAGA_AI_PROVIDER")
	}
	if *ollamaEndpoint == "" {
		*ollamaEndpoint = os.Getenv("NAGA_OLLAMA_ENDPOINT")
	}
	if *ollamaModel == "" {
		*ollamaModel = os.Getenv("NAGA_OLLAMA_MODEL")
	}

	if *nodeID == "" {
		fmt.Fprintln(os.Stderr, "error: --node-id is required")
		flag.Usage()
		os.Exit(1)
	}
	if *clusterID == "" {
		fmt.Fprintln(os.Stderr, "error: --cluster-id is required")
		flag.Usage()
		os.Exit(1)
	}

	var nodeRole domain.NodeRole
	switch *role {
	case "head":
		nodeRole = domain.NodeRoleHead
	case "worker":
		nodeRole = domain.NodeRoleWorker
	default:
		fmt.Fprintf(os.Stderr, "error: invalid role %q, must be head or worker\n", *role)
		os.Exit(1)
	}

	cfg := agent.AgentConfig{
		NodeID:            *nodeID,
		ClusterID:         *clusterID,
		Role:              nodeRole,
		ListenAddr:        fmt.Sprintf(":%d", *port),
		HeartbeatInterval: *heartbeat,
		FailureTimeout:    *timeout,
		HeadSelector:      resolveHeadSelector(*aiProvider, *anthropicKey, *ollamaEndpoint, *ollamaModel),
	}

	a := agent.NewAgent(cfg)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		log.Printf("received signal %v, shutting down", sig)
		cancel()
	}()

	if err := a.Run(ctx); err != nil {
		log.Fatalf("agent error: %v", err)
	}
}

func resolveHeadSelector(provider, anthropicKey, ollamaEndpoint, ollamaModel string) agent.HeadSelector {
	switch provider {
	case "ollama":
		log.Printf("using ollama provider (endpoint=%s, model=%s)", ollamaEndpoint, ollamaModel)
		return ollama.NewProvider(ollamaEndpoint, ollamaModel)
	case "claude":
		if anthropicKey == "" {
			return nil
		}
		return claude.NewProvider(anthropicKey, "")
	default:
		// Auto-detect: prefer claude if key exists, otherwise try ollama
		if anthropicKey != "" {
			return claude.NewProvider(anthropicKey, "")
		}
		if ollamaEndpoint != "" || ollamaModel != "" {
			return ollama.NewProvider(ollamaEndpoint, ollamaModel)
		}
		return nil
	}
}
