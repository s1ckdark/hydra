package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/repository"
	"github.com/s1ckdark/hydra/internal/usecase/agent"
)

type handlerTeamOrchs struct{}

func (handlerTeamOrchs) GetOrch(_ context.Context, id string) (*domain.Orch, error) {
	if id == "orch" || id == "friendly-name" {
		return &domain.Orch{ID: "orch", Name: "friendly-name"}, nil
	}
	return nil, domain.ErrOrchNotFound
}

func teamHandler(t *testing.T) (*Handler, *repository.FileAgentTeams, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "agent-teams.json")
	store := repository.NewFileAgentTeams(path)
	h := &Handler{}
	h.SetAgentTeams(agent.NewTeamService(store, handlerTeamOrchs{}, nil))
	return h, store, path
}

func requestTeam(t *testing.T, h *Handler, method, id, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, "/api/orchs/"+id+"/ai-agents", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues(id)
	var err error
	if method == http.MethodGet {
		err = h.APIGetAgentTeam(c)
	} else {
		err = h.APIPutAgentTeam(c)
	}
	if err != nil {
		t.Fatal(err)
	}
	return rec
}

func teamBody(endpoint, provider, keyField string) string {
	return `{"connections":[{"id":"connection","name":" Cloud ","provider":"` + provider + `","endpoint":"` + endpoint + `","models":["exact-model"]` + keyField + `}],"head_model":null,"agents":[{"id":"worker","name":"Worker","role":"review","model_override":{"connection_id":"connection","model":"exact-model"}}]}`
}

func TestAgentTeamAPIEmptyMaskedSaveReloadAndKeyRetention(t *testing.T) {
	h, store, path := teamHandler(t)
	empty := requestTeam(t, h, http.MethodGet, "orch", "")
	if empty.Code != 200 || strings.TrimSpace(empty.Body.String()) != `{"connections":[],"head_model":null,"agents":[]}` {
		t.Fatalf("empty: %d %s", empty.Code, empty.Body)
	}
	for _, keyField := range []string{`,"api_key":"do-not-expose-key"`, ""} {
		put := requestTeam(t, h, http.MethodPut, "friendly-name", teamBody("", "openai", keyField))
		if put.Code != 200 || strings.Contains(put.Body.String(), "do-not-expose-key") || strings.Contains(put.Body.String(), `"api_key"`) || !strings.Contains(put.Body.String(), `"has_api_key":true`) || !strings.Contains(put.Body.String(), `"name":"Cloud"`) {
			t.Fatalf("put: %d %s", put.Code, put.Body)
		}
	}
	saved, err := store.Get(context.Background(), "orch")
	if err != nil || saved.Connections[0].APIKey != "do-not-expose-key" {
		t.Fatal("omitted key was not retained")
	}
	nameEntry, _ := store.Get(context.Background(), "friendly-name")
	if len(nameEntry.Connections) != 0 {
		t.Fatal("team stored under alias instead of canonical orchestration id")
	}
	h.SetAgentTeams(agent.NewTeamService(repository.NewFileAgentTeams(path), handlerTeamOrchs{}, nil))
	get := requestTeam(t, h, http.MethodGet, "orch", "")
	if get.Code != 200 || strings.Contains(get.Body.String(), "do-not-expose-key") || strings.Contains(get.Body.String(), `"api_key"`) || !strings.Contains(get.Body.String(), `"has_api_key":true`) {
		t.Fatalf("get: %d %s", get.Code, get.Body)
	}
}

func TestAgentTeamAPIKeyNeverFollowsChangedIdentity(t *testing.T) {
	for _, change := range []string{"endpoint", "provider", "id", "clear"} {
		t.Run(change, func(t *testing.T) {
			h, store, path := teamHandler(t)
			if rec := requestTeam(t, h, http.MethodPut, "orch", teamBody("https://old.example/v1", "openai", `,"api_key":"private-key"`)); rec.Code != 200 {
				t.Fatal(rec.Body)
			}
			before, _ := os.ReadFile(path)
			body := teamBody("https://old.example/v1", "openai", "")
			switch change {
			case "endpoint":
				body = teamBody("https://new.example/v1", "openai", "")
			case "provider":
				body = teamBody("https://old.example/v1", "claude", "")
			case "id":
				body = strings.ReplaceAll(body, `"id":"connection"`, `"id":"new-connection"`)
				body = strings.ReplaceAll(body, `"connection_id":"connection"`, `"connection_id":"new-connection"`)
			case "clear":
				body = teamBody("https://old.example/v1", "openai", `,"api_key":""`)
			}
			rec := requestTeam(t, h, http.MethodPut, "orch", body)
			if rec.Code != 400 || strings.Contains(rec.Body.String(), "private-key") {
				t.Fatalf("accepted identity change without key: %d %s", rec.Code, rec.Body)
			}
			after, _ := os.ReadFile(path)
			if string(before) != string(after) {
				t.Fatal("failed update changed disk")
			}
			// Local endpoints can be saved without a key, but must not inherit
			// credentials belonging to the former provider/endpoint.
			rec = requestTeam(t, h, http.MethodPut, "orch", teamBody("http://localhost:1234/v1", "openai_compatible", ""))
			if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"has_api_key":false`) {
				t.Fatalf("local change: %d %s", rec.Code, rec.Body)
			}
			saved, _ := store.Get(context.Background(), "orch")
			if saved.Connections[0].APIKey != "" {
				t.Fatal("old key forwarded")
			}
		})
	}
}

func TestAgentTeamAPIInvalidReferencesAndInputDoNotSave(t *testing.T) {
	valid := teamBody("", "openai", `,"api_key":"secret-value"`)
	var parsed map[string]any
	if err := json.Unmarshal([]byte(valid), &parsed); err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"unknown model":      strings.ReplaceAll(valid, `"model":"exact-model"`, `"model":"unknown"`),
		"unknown connection": strings.ReplaceAll(valid, `"connection_id":"connection"`, `"connection_id":"unknown"`),
		"empty models":       strings.ReplaceAll(valid, `["exact-model"]`, `[]`),
		"empty model":        strings.ReplaceAll(valid, `["exact-model"]`, `[""]`),
		"duplicate models":   strings.ReplaceAll(valid, `["exact-model"]`, `["exact-model","exact-model"]`),
		"empty name":         strings.ReplaceAll(valid, `"name":" Cloud "`, `"name":" "`),
		"bad head":           strings.ReplaceAll(valid, `"head_model":null`, `"head_model":{"connection_id":"missing","model":"exact-model"}`),
		"credentials in URL": strings.ReplaceAll(valid, `"endpoint":""`, `"endpoint":"https://user:secret-value@example.com/v1"`),
		"query in URL":       strings.ReplaceAll(valid, `"endpoint":""`, `"endpoint":"https://example.com/v1?api_key=secret-value"`),
		"bad protocol":       strings.ReplaceAll(valid, `"endpoint":""`, `"endpoint":"file:///tmp/secret-value"`),
		"unknown provider":   strings.ReplaceAll(valid, `"provider":"openai"`, `"provider":"secret-value"`),
		"malformed":          `{"api_key":"secret-value",`,
		"null":               `null`,
		"two bodies":         valid + valid,
	}
	for _, field := range []string{"connections", "agents"} {
		copyMap := map[string]any{}
		_ = json.Unmarshal([]byte(valid), &copyMap)
		entries := copyMap[field].([]any)
		copyMap[field] = append(entries, entries[0])
		body, _ := json.Marshal(copyMap)
		cases["duplicate "+field] = string(body)
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			h, _, path := teamHandler(t)
			rec := requestTeam(t, h, http.MethodPut, "orch", body)
			if rec.Code != 400 || strings.Contains(rec.Body.String(), "secret-value") {
				t.Fatalf("invalid accepted/leaked: %d %s", rec.Code, rec.Body)
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("invalid request wrote storage")
			}
		})
	}
}

func TestAgentTeamAPIUnknownOrchestrationAndCorruptStorage(t *testing.T) {
	h, _, path := teamHandler(t)
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		if rec := requestTeam(t, h, method, "missing", `{}`); rec.Code != 404 {
			t.Fatalf("unknown orchestration: %d", rec.Code)
		}
	}
	if err := os.WriteFile(path, []byte(`{"secret":"private-key",`), 0600); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		rec := requestTeam(t, h, method, "orch", `{}`)
		if rec.Code != 500 || strings.Contains(rec.Body.String(), "private-key") {
			t.Fatalf("corrupt storage leak: %d %s", rec.Code, rec.Body)
		}
	}
	data, _ := os.ReadFile(path)
	if string(data) != `{"secret":"private-key",` {
		t.Fatal("corrupt storage overwritten")
	}
}
