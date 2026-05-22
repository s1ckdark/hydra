package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

// resolveTailscaleBinary tries PATH first, then the two canonical macOS
// locations for the Tailscale CLI. Matches the same logic as
// internal/web/handler/device_taildrop.go so the two callers always agree
// on which binary to use.
func resolveTailscaleBinary() (string, error) {
	if p, err := exec.LookPath("tailscale"); err == nil {
		return p, nil
	}
	candidates := []string{
		"/usr/local/bin/tailscale",
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return "", errors.New("tailscale CLI not found (searched $PATH, /usr/local/bin/tailscale, /Applications/Tailscale.app/Contents/MacOS/Tailscale)")
}

// cliStatusResponse is the top-level shape of `tailscale status --json`.
type cliStatusResponse struct {
	Self cliPeer                    `json:"Self"`
	Peer map[string]cliPeer         `json:"Peer"`
	User map[string]cliUser         `json:"User"`
}

// cliPeer represents a single node (Self or a Peer entry).
type cliPeer struct {
	ID           string   `json:"ID"`
	HostName     string   `json:"HostName"`
	DNSName      string   `json:"DNSName"`
	OS           string   `json:"OS"`
	UserID       int64    `json:"UserID"`
	TailscaleIPs []string `json:"TailscaleIPs"`
	Online       bool     `json:"Online"`
	Active       bool     `json:"Active"`
	LastSeen     string   `json:"LastSeen"`
	Tags         []string `json:"Tags"`
}

// cliUser is the User map value returned by tailscale status --json.
type cliUser struct {
	ID          int64  `json:"ID"`
	LoginName   string `json:"LoginName"`
	DisplayName string `json:"DisplayName"`
}

// zeroTime is the sentinel zero-value time that Tailscale emits for active peers.
var zeroTime = time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC)

// CLIClient satisfies the usecase.TailscaleClient interface by shelling out to
// `tailscale status --json`. It maintains a short TTL cache (5 s) to amortise
// the ~50–200 ms latency of each exec call when multiple handlers call
// ListDevices per request.
type CLIClient struct {
	binary string

	mu         sync.Mutex
	cached     []*domain.Device
	cachedAt   time.Time
	cacheTTL   time.Duration
}

// NewCLIClient resolves the Tailscale binary and returns a ready CLIClient, or
// an error if the binary cannot be found so the caller can emit a useful hint.
func NewCLIClient() (*CLIClient, error) {
	bin, err := resolveTailscaleBinary()
	if err != nil {
		return nil, err
	}
	return &CLIClient{
		binary:   bin,
		cacheTTL: 5 * time.Second,
	}, nil
}

// ListDevices shells out to `tailscale status --json`, parses the response, and
// returns a domain.Device per node (Self + each Peer). Results are cached for
// cacheTTL to reduce exec overhead when multiple handlers call ListDevices
// within the same request cycle.
func (c *CLIClient) ListDevices(ctx context.Context) ([]*domain.Device, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if time.Since(c.cachedAt) < c.cacheTTL && len(c.cached) > 0 {
		return c.cached, nil
	}

	devices, err := c.fetch(ctx)
	if err != nil {
		return nil, err
	}

	c.cached = devices
	c.cachedAt = time.Now()
	return devices, nil
}

// GetDevice re-fetches (via ListDevices, which may hit the cache) and finds the
// first device matching nameOrID by: NodeID, DNSName (with or without trailing
// dot), or HostName (case-insensitive).
func (c *CLIClient) GetDevice(ctx context.Context, nameOrID string) (*domain.Device, error) {
	devices, err := c.ListDevices(ctx)
	if err != nil {
		return nil, err
	}

	needle := strings.ToLower(nameOrID)
	for _, d := range devices {
		if d.ID == nameOrID {
			return d, nil
		}
		nameLower := strings.ToLower(d.Name)
		if nameLower == needle || nameLower == strings.TrimSuffix(needle, ".") {
			return d, nil
		}
		if strings.ToLower(d.Hostname) == needle {
			return d, nil
		}
	}

	return nil, fmt.Errorf("device not found: %s", nameOrID)
}

// GetDeviceByID re-fetches and finds the device with an exact NodeID match.
func (c *CLIClient) GetDeviceByID(ctx context.Context, id string) (*domain.Device, error) {
	devices, err := c.ListDevices(ctx)
	if err != nil {
		return nil, err
	}

	for _, d := range devices {
		if d.ID == id {
			return d, nil
		}
	}

	return nil, fmt.Errorf("device not found: %s", id)
}

// fetch runs `tailscale status --json` and converts the output into
// domain.Device values. It is the inner, non-cached call.
func (c *CLIClient) fetch(ctx context.Context) ([]*domain.Device, error) {
	execCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	out, err := exec.CommandContext(execCtx, c.binary, "status", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("tailscale status --json: %w", err)
	}

	var data cliStatusResponse
	if err := json.Unmarshal(out, &data); err != nil {
		return nil, fmt.Errorf("parse tailscale status: %w", err)
	}

	// Build a userID → LoginName lookup table.
	userNames := make(map[string]string, len(data.User))
	for k, u := range data.User {
		userNames[k] = u.LoginName
	}

	var devices []*domain.Device

	// Include Self.
	if data.Self.ID != "" {
		devices = append(devices, peerToDevice(&data.Self, userNames))
	}

	// Include all peers.
	for _, p := range data.Peer {
		p := p // capture loop variable
		devices = append(devices, peerToDevice(&p, userNames))
	}

	return devices, nil
}

// peerToDevice converts a cliPeer (Self or Peer entry) into a domain.Device.
func peerToDevice(p *cliPeer, userNames map[string]string) *domain.Device {
	// Name: DNSName with trailing dot stripped.
	name := strings.TrimSuffix(p.DNSName, ".")

	// TailscaleIP: first IPv4 address, fallback to first address.
	var tsIP string
	for _, ip := range p.TailscaleIPs {
		parsed := net.ParseIP(ip)
		if parsed != nil && parsed.To4() != nil {
			tsIP = ip
			break
		}
	}
	if tsIP == "" && len(p.TailscaleIPs) > 0 {
		tsIP = p.TailscaleIPs[0]
	}

	// Status.
	status := domain.DeviceStatusOffline
	if p.Online {
		status = domain.DeviceStatusOnline
	}

	// User login name via the User map.
	uidStr := strconv.FormatInt(p.UserID, 10)
	user := userNames[uidStr]

	// LastSeen: parse RFC3339; if zero-time and peer is online set to now
	// (active peers report "0001-01-01T00:00:00Z" in LastSeen).
	var lastSeen time.Time
	if p.LastSeen != "" {
		if t, err := time.Parse(time.RFC3339, p.LastSeen); err == nil {
			lastSeen = t
		}
	}
	if (lastSeen.IsZero() || lastSeen.Equal(zeroTime)) && p.Online {
		lastSeen = time.Now()
	}

	osNorm := normalizeOS(p.OS)

	// SSHEnabled heuristic: Tailscale status does not expose whether SSH is
	// configured. We assume Linux and macOS nodes have SSH available; iOS
	// devices (and anything else) are treated as non-SSH. This is a best-effort
	// approximation — the SSH reachability probe in MonitorUseCase provides
	// ground truth on the next cycle.
	sshEnabled := osNorm == "Linux" || osNorm == "macOS"

	return &domain.Device{
		ID:          p.ID,
		Name:        name,
		Hostname:    p.HostName,
		IPAddresses: p.TailscaleIPs,
		TailscaleIP: tsIP,
		OS:          osNorm,
		Status:      status,
		IsExternal:  false, // CLI shows our tailnet only
		Tags:        p.Tags,
		User:        user,
		LastSeen:    lastSeen,
		SSHEnabled:  sshEnabled,
	}
}
