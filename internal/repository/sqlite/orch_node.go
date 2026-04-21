package sqlite

import (
	"context"
	"database/sql"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

// OrchNodeRepository implements repository.OrchNodeRepository for SQLite
type OrchNodeRepository struct {
	db dbExecutor
}

// NewOrchNodeRepository creates a new OrchNodeRepository
func NewOrchNodeRepository(db dbExecutor) *OrchNodeRepository {
	return &OrchNodeRepository{db: db}
}

// Save creates or updates a orch node
func (r *OrchNodeRepository) Save(ctx context.Context, node *domain.OrchNode) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO orch_nodes (
			device_id, orch_id, role, status, ray_address,
			num_cpus, num_gpus, memory_bytes, joined_at, left_at,
			last_error, last_error_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(device_id, orch_id) DO UPDATE SET
			role = excluded.role,
			status = excluded.status,
			ray_address = excluded.ray_address,
			num_cpus = excluded.num_cpus,
			num_gpus = excluded.num_gpus,
			memory_bytes = excluded.memory_bytes,
			left_at = excluded.left_at,
			last_error = excluded.last_error,
			last_error_at = excluded.last_error_at
	`,
		node.DeviceID, node.OrchID, node.Role, node.Status,
		node.RayAddress, node.NumCPUs, node.NumGPUs, node.MemoryBytes,
		node.JoinedAt, node.LeftAt, node.LastError, node.LastErrorAt,
	)

	return err
}

// GetByDeviceAndOrch retrieves a node by device and orch IDs
func (r *OrchNodeRepository) GetByDeviceAndOrch(ctx context.Context, deviceID, orchID string) (*domain.OrchNode, error) {
	row := r.db.QueryRowContext(ctx, `
		SELECT device_id, orch_id, role, status, ray_address,
			   num_cpus, num_gpus, memory_bytes, joined_at, left_at,
			   last_error, last_error_at
		FROM orch_nodes WHERE device_id = ? AND orch_id = ?
	`, deviceID, orchID)

	return r.scanNode(row)
}

// GetByOrch retrieves all nodes for a orch
func (r *OrchNodeRepository) GetByOrch(ctx context.Context, orchID string) ([]*domain.OrchNode, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT device_id, orch_id, role, status, ray_address,
			   num_cpus, num_gpus, memory_bytes, joined_at, left_at,
			   last_error, last_error_at
		FROM orch_nodes WHERE orch_id = ?
		ORDER BY role, joined_at
	`, orchID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	return r.scanNodes(rows)
}

// Delete removes a node from a orch
func (r *OrchNodeRepository) Delete(ctx context.Context, deviceID, orchID string) error {
	_, err := r.db.ExecContext(ctx,
		"DELETE FROM orch_nodes WHERE device_id = ? AND orch_id = ?",
		deviceID, orchID)
	return err
}

func (r *OrchNodeRepository) scanNode(row *sql.Row) (*domain.OrchNode, error) {
	var n domain.OrchNode
	var rayAddress, lastError sql.NullString
	var leftAt, lastErrorAt sql.NullTime

	err := row.Scan(
		&n.DeviceID, &n.OrchID, &n.Role, &n.Status, &rayAddress,
		&n.NumCPUs, &n.NumGPUs, &n.MemoryBytes, &n.JoinedAt, &leftAt,
		&lastError, &lastErrorAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	if rayAddress.Valid {
		n.RayAddress = rayAddress.String
	}
	if lastError.Valid {
		n.LastError = lastError.String
	}
	if leftAt.Valid {
		n.LeftAt = &leftAt.Time
	}
	if lastErrorAt.Valid {
		n.LastErrorAt = &lastErrorAt.Time
	}

	return &n, nil
}

func (r *OrchNodeRepository) scanNodes(rows *sql.Rows) ([]*domain.OrchNode, error) {
	var nodes []*domain.OrchNode

	for rows.Next() {
		var n domain.OrchNode
		var rayAddress, lastError sql.NullString
		var leftAt, lastErrorAt sql.NullTime

		err := rows.Scan(
			&n.DeviceID, &n.OrchID, &n.Role, &n.Status, &rayAddress,
			&n.NumCPUs, &n.NumGPUs, &n.MemoryBytes, &n.JoinedAt, &leftAt,
			&lastError, &lastErrorAt,
		)
		if err != nil {
			return nil, err
		}

		if rayAddress.Valid {
			n.RayAddress = rayAddress.String
		}
		if lastError.Valid {
			n.LastError = lastError.String
		}
		if leftAt.Valid {
			n.LeftAt = &leftAt.Time
		}
		if lastErrorAt.Valid {
			n.LastErrorAt = &lastErrorAt.Time
		}

		nodes = append(nodes, &n)
	}

	return nodes, rows.Err()
}

// Ensure time package is used
var _ = time.Now
