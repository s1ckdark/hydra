package repository

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/s1ckdark/hydra/internal/domain"
)

func storedTeam() domain.AIAgentTeam {
	return domain.AIAgentTeam{Revision: "revision-1", Connections: []domain.AIConnection{{ID: "c", Name: "Cloud", Provider: "openai", APIKey: "private-test-key", Models: []string{"exact-model"}}}, HeadModel: &domain.AgentModelRef{ConnectionID: "c", Model: "exact-model"}, Agents: []domain.AIAgent{{ID: "a", Name: "Analyst", ModelOverride: &domain.AgentModelRef{ConnectionID: "c", Model: "exact-model"}}}}
}

func saveTeam(t *testing.T, r *FileAgentTeams, id string, team domain.AIAgentTeam) {
	t.Helper()
	if _, err := r.Update(context.Background(), id, func(domain.AIAgentTeam) (domain.AIAgentTeam, error) { return team, nil }); err != nil {
		t.Fatal(err)
	}
}

func TestFileAgentTeamsPersistReloadPermissionsAndSnapshots(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "agent-teams.json")
	r := NewFileAgentTeams(path)
	empty, err := r.Get(context.Background(), "missing")
	if err != nil || empty.Connections == nil || empty.Agents == nil || empty.HeadModel != nil {
		t.Fatalf("empty team: %#v, %v", empty, err)
	}
	source := storedTeam()
	saveTeam(t, r, "orch", source)
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("file must be 0600: %v, %v", info, err)
	}
	source.Connections[0].Models[0] = "mutated-after-save"
	source.Agents[0].ModelOverride.Model = "mutated-after-save"
	reloaded := NewFileAgentTeams(path)
	got, err := reloaded.Get(context.Background(), "orch")
	if err != nil || got.Connections[0].APIKey != "private-test-key" || got.Connections[0].Models[0] != "exact-model" || got.Revision != "revision-1" {
		t.Fatalf("reload failed: %v", err)
	}
	got.Connections[0].Models[0] = "mutated-read"
	got.HeadModel.Model = "mutated-read"
	got.Agents[0].ModelOverride.Model = "mutated-read"
	again, err := r.Get(context.Background(), "orch")
	if err != nil || again.HeadModel.Model != "exact-model" || again.Agents[0].ModelOverride.Model != "exact-model" || again.Connections[0].Models[0] != "exact-model" {
		t.Fatal("snapshots aliased")
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatal("temporary files left after atomic write")
	}
}

func TestFileAgentTeamsFailuresPreservePreviousBytes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-teams.json")
	r := NewFileAgentTeams(path)
	saveTeam(t, r, "orch", storedTeam())
	before, _ := os.ReadFile(path)
	_, err := r.Update(context.Background(), "orch", func(previous domain.AIAgentTeam) (domain.AIAgentTeam, error) {
		previous.Connections[0].APIKey = "changed"
		return previous, errors.New("reject")
	})
	if err == nil {
		t.Fatal("expected callback rejection")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("failed update changed file")
	}
	for _, corrupt := range []string{`{"api_key":"do-not-echo",`, `null`, `{}`, `{"version":9,"teams":{}}`, `{"version":1,"teams":{"orch":{"revision":"x","connections":[{"provider":"openai","api_key":"do-not-echo"}]}}}`} {
		if err := os.WriteFile(path, []byte(corrupt), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := r.Get(context.Background(), "orch"); !errors.Is(err, ErrAgentTeamStorage) {
			t.Fatalf("corrupt read = %v", err)
		}
		called := false
		_, err := r.Update(context.Background(), "new", func(domain.AIAgentTeam) (domain.AIAgentTeam, error) { called = true; return storedTeam(), nil })
		if !errors.Is(err, ErrAgentTeamStorage) || called || strings.Contains(err.Error(), "do-not-echo") {
			t.Fatalf("unsafe failure: %v", err)
		}
		after, _ := os.ReadFile(path)
		if string(after) != corrupt {
			t.Fatal("corrupt file overwritten")
		}
	}
}

func TestFileAgentTeamsRejectInsecureFileAndSymlink(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-teams.json")
	r := NewFileAgentTeams(path)
	saveTeam(t, r, "orch", storedTeam())
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Get(context.Background(), "orch"); !errors.Is(err, ErrAgentTeamStorage) {
		t.Fatal("accepted public secret file")
	}
	link := filepath.Join(t.TempDir(), "linked.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := NewFileAgentTeams(link).Get(context.Background(), "orch"); !errors.Is(err, ErrAgentTeamStorage) {
		t.Fatal("accepted symlink")
	}
}

func TestFileAgentTeamsConcurrentUpdatesDoNotLoseTeams(t *testing.T) {
	r := NewFileAgentTeams(filepath.Join(t.TempDir(), "agent-teams.json"))
	var wg sync.WaitGroup
	for i := range 24 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			id := fmt.Sprint(i)
			_, err := r.Update(context.Background(), id, func(domain.AIAgentTeam) (domain.AIAgentTeam, error) { return storedTeam(), nil })
			if err != nil {
				t.Error(err)
				return
			}
			if _, err := r.Get(context.Background(), id); err != nil {
				t.Error(err)
			}
		}(i)
	}
	wg.Wait()
	for i := range 24 {
		got, err := r.Get(context.Background(), fmt.Sprint(i))
		if err != nil || len(got.Agents) != 1 {
			t.Fatalf("lost team %d: %v", i, err)
		}
	}
}
