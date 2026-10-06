package domain

import (
	"errors"
	"net/url"
	"strings"
)

// AIConnection is a private provider connection. APIKey is never serialized by
// the domain/API types; only the repository's disk representation contains it.
type AIConnection struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Provider  string   `json:"provider"`
	Endpoint  string   `json:"endpoint"`
	Models    []string `json:"models"`
	HasAPIKey bool     `json:"has_api_key"`
	APIKey    string   `json:"-"`
}

type AgentModelRef struct {
	ConnectionID string `json:"connection_id"`
	Model        string `json:"model"`
}

type AIAgent struct {
	ID            string         `json:"id"`
	Name          string         `json:"name"`
	Role          string         `json:"role"`
	ModelOverride *AgentModelRef `json:"model_override"`
}

type AIAgentTeam struct {
	Revision    string         `json:"-"`
	Connections []AIConnection `json:"connections"`
	HeadModel   *AgentModelRef `json:"head_model"`
	Agents      []AIAgent      `json:"agents"`
}

func (t AIAgentTeam) Clone() AIAgentTeam {
	out := AIAgentTeam{Revision: t.Revision, Connections: make([]AIConnection, len(t.Connections)), Agents: make([]AIAgent, len(t.Agents))}
	copy(out.Connections, t.Connections)
	for i := range out.Connections {
		out.Connections[i].Models = append([]string{}, t.Connections[i].Models...)
	}
	if t.HeadModel != nil {
		ref := *t.HeadModel
		out.HeadModel = &ref
	}
	copy(out.Agents, t.Agents)
	for i := range out.Agents {
		if t.Agents[i].ModelOverride != nil {
			ref := *t.Agents[i].ModelOverride
			out.Agents[i].ModelOverride = &ref
		}
	}
	return out
}

func (t AIAgentTeam) Masked() AIAgentTeam {
	out := t.Clone()
	for i := range out.Connections {
		out.Connections[i].HasAPIKey = out.Connections[i].APIKey != ""
		out.Connections[i].APIKey = ""
	}
	return out
}

// Resolve requires an exact registered model, including its case and version.
func (t AIAgentTeam) Resolve(ref AgentModelRef) (AIConnection, bool) {
	for _, c := range t.Connections {
		if c.ID == ref.ConnectionID {
			for _, model := range c.Models {
				if model == ref.Model {
					return c, true
				}
			}
		}
	}
	return AIConnection{}, false
}

// Normalize removes surrounding whitespace, without rewriting model IDs.
func (t *AIAgentTeam) Normalize() {
	for i := range t.Connections {
		c := &t.Connections[i]
		c.ID, c.Name = strings.TrimSpace(c.ID), strings.TrimSpace(c.Name)
		c.Provider, c.Endpoint = strings.TrimSpace(c.Provider), strings.TrimSpace(c.Endpoint)
		c.APIKey = strings.TrimSpace(c.APIKey)
		c.HasAPIKey = c.APIKey != ""
		for j := range c.Models {
			c.Models[j] = strings.TrimSpace(c.Models[j])
		}
	}
	normalizeRef := func(ref *AgentModelRef) {
		if ref != nil {
			ref.ConnectionID, ref.Model = strings.TrimSpace(ref.ConnectionID), strings.TrimSpace(ref.Model)
		}
	}
	normalizeRef(t.HeadModel)
	for i := range t.Agents {
		a := &t.Agents[i]
		a.ID, a.Name, a.Role = strings.TrimSpace(a.ID), strings.TrimSpace(a.Name), strings.TrimSpace(a.Role)
		normalizeRef(a.ModelOverride)
	}
}

// Validate never includes submitted values, endpoints or credentials in errors.
func (t AIAgentTeam) Validate() error {
	ids := make(map[string]bool)
	for _, c := range t.Connections {
		if strings.TrimSpace(c.ID) == "" || strings.TrimSpace(c.Name) == "" {
			return errors.New("connection id and name are required")
		}
		if ids[c.ID] {
			return errors.New("duplicate connection id")
		}
		ids[c.ID] = true
		switch c.Provider {
		case "claude", "openai", "zai":
			if strings.TrimSpace(c.APIKey) == "" {
				return errors.New("cloud connections require an api_key")
			}
		case "ollama", "lmstudio", "openai_compatible":
			if c.Endpoint == "" {
				return errors.New("local and compatible connections require an endpoint")
			}
		default:
			return errors.New("unsupported connection provider")
		}
		if c.Endpoint != "" {
			u, err := url.Parse(c.Endpoint)
			if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || strings.Contains(c.Endpoint, "#") {
				return errors.New("endpoint must be an HTTP(S) URL without credentials, query or fragment")
			}
		}
		if len(c.Models) == 0 {
			return errors.New("connection requires at least one model")
		}
		models := make(map[string]bool)
		for _, model := range c.Models {
			if strings.TrimSpace(model) == "" || models[model] {
				return errors.New("model ids must be nonempty and unique within a connection")
			}
			models[model] = true
		}
	}
	if t.HeadModel != nil {
		if _, ok := t.Resolve(*t.HeadModel); !ok {
			return errors.New("head_model must reference a registered connection and model")
		}
	}
	ids = make(map[string]bool)
	for _, a := range t.Agents {
		if strings.TrimSpace(a.ID) == "" || strings.TrimSpace(a.Name) == "" {
			return errors.New("agent id and name are required")
		}
		if ids[a.ID] {
			return errors.New("duplicate agent id")
		}
		ids[a.ID] = true
		if a.ModelOverride != nil {
			if _, ok := t.Resolve(*a.ModelOverride); !ok {
				return errors.New("model_override must reference a registered connection and model")
			}
		}
	}
	return nil
}
