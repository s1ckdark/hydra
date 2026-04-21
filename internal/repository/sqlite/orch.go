package sqlite

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"github.com/google/uuid"

	"github.com/s1ckdark/hydra/internal/domain"
)

// OrchRepository implements repository.OrchRepository for SQLite
type OrchRepository struct {
	db dbExecutor
}

// NewOrchRepository creates a new OrchRepository
func NewOrchRepository(db dbExecutor) *OrchRepository {
	return &OrchRepository{db: db}
}

// Create creates a new orch
func (r *OrchRepository) Create(ctx context.Context, orch *domain.Orch) error {
	if orch.ID == "" {
		orch.ID = uuid.New().String()
	}

	workerIDs, _ := json.Marshal(orch.WorkerIDs)

	_, err := r.db.ExecContext(ctx, `
		INSERT INTO orchs (
			id, name, description, mode, status, head_node_id, worker_ids,
			dashboard_url, ray_port, dashboard_port, object_store_memory,
			created_at, updated_at, started_at, stopped_at, last_error, last_error_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`,
		orch.ID, orch.Name, orch.Description, orch.Mode, orch.Status,
		orch.CoordinatorID, string(workerIDs), orch.DashboardURL,
		orch.RayPort, orch.DashboardPort, orch.ObjectStoreMemory,
		orch.CreatedAt, orch.UpdatedAt, orch.StartedAt, orch.StoppedAt,
		orch.LastError, orch.LastErrorAt,
	)

	return err
}

// Update updates an existing orch
func (r *OrchRepository) Update(ctx context.Context, orch *domain.Orch) error {
	workerIDs, _ := json.Marshal(orch.WorkerIDs)
	orch.UpdatedAt = time.Now()

	result, err := r.db.ExecContext(ctx, `
		UPDATE orchs SET
			name = ?, description = ?, mode = ?, status = ?, head_node_id = ?,
			worker_ids = ?, dashboard_url = ?, ray_port = ?, dashboard_port = ?,
			object_store_memory = ?, updated_at = ?, started_at = ?, stopped_at = ?,
			last_error = ?, last_error_at = ?
		WHERE id = ?
	`,
		orch.Name, orch.Description, orch.Mode, orch.Status, orch.CoordinatorID,
		string(workerIDs), orch.DashboardURL, orch.RayPort, orch.DashboardPort,
		orch.ObjectStoreMemory, orch.UpdatedAt, orch.StartedAt, orch.StoppedAt,
		orch.LastError, orch.LastErrorAt, orch.ID,
	)
	if err != nil {
		return err
	}

	rows, _ := result.RowsAffected()
	if rows == 0 {
		return domain.ErrOrchNotFound
	}

	return nil
}

// GetByID retrieves a orch by its ID
func (r *OrchRepository) GetByID(ctx context.Context, id string) (*domain.Orch, error) {
	row := r.db.QueryRowContext(ctx, `
		SELECT id, name, description, mode, status, head_node_id, worker_ids,
			   dashboard_url, ray_port, dashboard_port, object_store_memory,
			   created_at, updated_at, started_at, stopped_at, last_error, last_error_at
		FROM orchs WHERE id = ?
	`, id)

	return r.scanOrch(row)
}

// GetByName retrieves a orch by its name
func (r *OrchRepository) GetByName(ctx context.Context, name string) (*domain.Orch, error) {
	row := r.db.QueryRowContext(ctx, `
		SELECT id, name, description, mode, status, head_node_id, worker_ids,
			   dashboard_url, ray_port, dashboard_port, object_store_memory,
			   created_at, updated_at, started_at, stopped_at, last_error, last_error_at
		FROM orchs WHERE name = ?
	`, name)

	return r.scanOrch(row)
}

// GetAll retrieves all orchs
func (r *OrchRepository) GetAll(ctx context.Context) ([]*domain.Orch, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, name, description, mode, status, head_node_id, worker_ids,
			   dashboard_url, ray_port, dashboard_port, object_store_memory,
			   created_at, updated_at, started_at, stopped_at, last_error, last_error_at
		FROM orchs ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return r.scanOrchs(rows)
}

// GetByStatus retrieves orchs by status
func (r *OrchRepository) GetByStatus(ctx context.Context, status domain.OrchStatus) ([]*domain.Orch, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, name, description, mode, status, head_node_id, worker_ids,
			   dashboard_url, ray_port, dashboard_port, object_store_memory,
			   created_at, updated_at, started_at, stopped_at, last_error, last_error_at
		FROM orchs WHERE status = ? ORDER BY created_at DESC
	`, status)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return r.scanOrchs(rows)
}

// Delete removes a orch by ID
func (r *OrchRepository) Delete(ctx context.Context, id string) error {
	result, err := r.db.ExecContext(ctx, "DELETE FROM orchs WHERE id = ?", id)
	if err != nil {
		return err
	}

	rows, _ := result.RowsAffected()
	if rows == 0 {
		return domain.ErrOrchNotFound
	}

	return nil
}

// GetOrchByDeviceID finds the orch that contains a device
func (r *OrchRepository) GetOrchByDeviceID(ctx context.Context, deviceID string) (*domain.Orch, error) {
	// Check head node first
	row := r.db.QueryRowContext(ctx, `
		SELECT id, name, description, mode, status, head_node_id, worker_ids,
			   dashboard_url, ray_port, dashboard_port, object_store_memory,
			   created_at, updated_at, started_at, stopped_at, last_error, last_error_at
		FROM orchs WHERE head_node_id = ?
	`, deviceID)

	orch, err := r.scanOrch(row)
	if err == nil {
		return orch, nil
	}

	// Check worker IDs (JSON array search)
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, name, description, mode, status, head_node_id, worker_ids,
			   dashboard_url, ray_port, dashboard_port, object_store_memory,
			   created_at, updated_at, started_at, stopped_at, last_error, last_error_at
		FROM orchs
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		c, err := r.scanOrchFromRows(rows)
		if err != nil {
			continue
		}

		for _, wid := range c.WorkerIDs {
			if wid == deviceID {
				return c, nil
			}
		}
	}

	return nil, domain.ErrOrchNotFound
}

func (r *OrchRepository) scanOrch(row *sql.Row) (*domain.Orch, error) {
	var c domain.Orch
	var workerIDsJSON string
	var description, mode, dashboardURL, lastError sql.NullString
	var startedAt, stoppedAt, lastErrorAt sql.NullTime

	err := row.Scan(
		&c.ID, &c.Name, &description, &mode, &c.Status, &c.CoordinatorID, &workerIDsJSON,
		&dashboardURL, &c.RayPort, &c.DashboardPort, &c.ObjectStoreMemory,
		&c.CreatedAt, &c.UpdatedAt, &startedAt, &stoppedAt, &lastError, &lastErrorAt,
	)
	if err == sql.ErrNoRows {
		return nil, domain.ErrOrchNotFound
	}
	if err != nil {
		return nil, err
	}

	if description.Valid {
		c.Description = description.String
	}
	if mode.Valid && mode.String != "" {
		c.Mode = domain.OrchMode(mode.String)
	} else {
		c.Mode = domain.OrchModeBasic
	}
	if dashboardURL.Valid {
		c.DashboardURL = dashboardURL.String
	}
	if lastError.Valid {
		c.LastError = lastError.String
	}
	if startedAt.Valid {
		c.StartedAt = &startedAt.Time
	}
	if stoppedAt.Valid {
		c.StoppedAt = &stoppedAt.Time
	}
	if lastErrorAt.Valid {
		c.LastErrorAt = &lastErrorAt.Time
	}

	json.Unmarshal([]byte(workerIDsJSON), &c.WorkerIDs)
	if c.WorkerIDs == nil {
		c.WorkerIDs = []string{}
	}

	return &c, nil
}

func (r *OrchRepository) scanOrchFromRows(rows *sql.Rows) (*domain.Orch, error) {
	var c domain.Orch
	var workerIDsJSON string
	var description, mode, dashboardURL, lastError sql.NullString
	var startedAt, stoppedAt, lastErrorAt sql.NullTime

	err := rows.Scan(
		&c.ID, &c.Name, &description, &mode, &c.Status, &c.CoordinatorID, &workerIDsJSON,
		&dashboardURL, &c.RayPort, &c.DashboardPort, &c.ObjectStoreMemory,
		&c.CreatedAt, &c.UpdatedAt, &startedAt, &stoppedAt, &lastError, &lastErrorAt,
	)
	if err != nil {
		return nil, err
	}

	if description.Valid {
		c.Description = description.String
	}
	if mode.Valid && mode.String != "" {
		c.Mode = domain.OrchMode(mode.String)
	} else {
		c.Mode = domain.OrchModeBasic
	}
	if dashboardURL.Valid {
		c.DashboardURL = dashboardURL.String
	}
	if lastError.Valid {
		c.LastError = lastError.String
	}
	if startedAt.Valid {
		c.StartedAt = &startedAt.Time
	}
	if stoppedAt.Valid {
		c.StoppedAt = &stoppedAt.Time
	}
	if lastErrorAt.Valid {
		c.LastErrorAt = &lastErrorAt.Time
	}

	json.Unmarshal([]byte(workerIDsJSON), &c.WorkerIDs)
	if c.WorkerIDs == nil {
		c.WorkerIDs = []string{}
	}

	return &c, nil
}

func (r *OrchRepository) scanOrchs(rows *sql.Rows) ([]*domain.Orch, error) {
	var orchs []*domain.Orch

	for rows.Next() {
		c, err := r.scanOrchFromRows(rows)
		if err != nil {
			return nil, err
		}
		orchs = append(orchs, c)
	}

	return orchs, rows.Err()
}

