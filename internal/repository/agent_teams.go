package repository

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/s1ckdark/hydra/internal/domain"
)

var ErrAgentTeamStorage = errors.New("AI agent team storage unavailable; existing data was preserved")

// FileAgentTeams serializes read/modify/write operations in this server. Every
// operation reads the file anew, so a corrupt or unreadable file can never be
// overwritten by a previously cached snapshot.
type FileAgentTeams struct {
	mu   sync.Mutex
	path string
}

func NewFileAgentTeams(path string) *FileAgentTeams { return &FileAgentTeams{path: path} }

type diskConnection struct {
	domain.AIConnection
	APIKey string `json:"api_key"`
}

type diskTeam struct {
	Revision    string                `json:"revision"`
	Connections []diskConnection      `json:"connections"`
	HeadModel   *domain.AgentModelRef `json:"head_model"`
	Agents      []domain.AIAgent      `json:"agents"`
}

type diskTeams struct {
	Version int                 `json:"version"`
	Teams   map[string]diskTeam `json:"teams"`
}

func (r *FileAgentTeams) read() (map[string]domain.AIAgentTeam, error) {
	teams := make(map[string]domain.AIAgentTeam)
	info, err := os.Lstat(r.path)
	if errors.Is(err, os.ErrNotExist) {
		return teams, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return nil, ErrAgentTeamStorage
	}
	data, err := os.ReadFile(r.path)
	if err != nil {
		return nil, ErrAgentTeamStorage
	}
	var disk diskTeams
	if json.Unmarshal(data, &disk) != nil || disk.Version != 1 || disk.Teams == nil {
		return nil, ErrAgentTeamStorage
	}
	for id, d := range disk.Teams {
		team := domain.AIAgentTeam{Revision: d.Revision, Connections: make([]domain.AIConnection, len(d.Connections)), HeadModel: d.HeadModel, Agents: d.Agents}
		for i, c := range d.Connections {
			team.Connections[i] = c.AIConnection
			team.Connections[i].APIKey = c.APIKey
		}
		if id == "" || team.Revision == "" || team.Validate() != nil {
			return nil, ErrAgentTeamStorage
		}
		teams[id] = team
	}
	return teams, nil
}

func (r *FileAgentTeams) Get(ctx context.Context, id string) (domain.AIAgentTeam, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return domain.AIAgentTeam{}, err
	}
	teams, err := r.read()
	if err != nil {
		return domain.AIAgentTeam{}, err
	}
	return teams[id].Clone(), nil
}

// Update includes key retention and validation inside the same critical section
// as persistence. A failed callback or write leaves the previous file intact.
func (r *FileAgentTeams) Update(ctx context.Context, id string, update func(domain.AIAgentTeam) (domain.AIAgentTeam, error)) (domain.AIAgentTeam, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return domain.AIAgentTeam{}, err
	}
	teams, err := r.read()
	if err != nil {
		return domain.AIAgentTeam{}, err
	}
	next, err := update(teams[id].Clone())
	if err != nil {
		return domain.AIAgentTeam{}, err
	}
	if id == "" || next.Revision == "" || next.Validate() != nil {
		return domain.AIAgentTeam{}, ErrAgentTeamStorage
	}
	teams[id] = next.Clone()
	disk := diskTeams{Version: 1, Teams: make(map[string]diskTeam, len(teams))}
	for id, team := range teams {
		d := diskTeam{Revision: team.Revision, Connections: make([]diskConnection, len(team.Connections)), HeadModel: team.HeadModel, Agents: team.Agents}
		for i, c := range team.Connections {
			d.Connections[i] = diskConnection{AIConnection: c, APIKey: c.APIKey}
		}
		disk.Teams[id] = d
	}
	data, err := json.MarshalIndent(disk, "", "  ")
	if err != nil {
		return domain.AIAgentTeam{}, ErrAgentTeamStorage
	}
	if err := os.MkdirAll(filepath.Dir(r.path), 0700); err != nil {
		return domain.AIAgentTeam{}, ErrAgentTeamStorage
	}
	f, err := os.CreateTemp(filepath.Dir(r.path), ".agent-teams-*")
	if err != nil {
		return domain.AIAgentTeam{}, ErrAgentTeamStorage
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if err == nil {
		err = f.Close()
	}
	if err != nil {
		return domain.AIAgentTeam{}, ErrAgentTeamStorage
	}
	if err := ctx.Err(); err != nil {
		return domain.AIAgentTeam{}, err
	}
	if err = os.Rename(f.Name(), r.path); err != nil {
		return domain.AIAgentTeam{}, ErrAgentTeamStorage
	}
	return next.Clone(), nil
}
