package tailscale

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

// loadFixture parses the stored tailscale status JSON fixture and returns the
// same domain.Device slice that CLIClient.fetch() would return.
func loadFixture(t *testing.T) []*domain.Device {
	t.Helper()
	raw, err := os.ReadFile("testdata/status.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var data cliStatusResponse
	if err := json.Unmarshal(raw, &data); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	userNames := make(map[string]string, len(data.User))
	for k, u := range data.User {
		userNames[k] = u.LoginName
	}
	var devices []*domain.Device
	if data.Self.ID != "" {
		devices = append(devices, peerToDevice(&data.Self, userNames))
	}
	for _, p := range data.Peer {
		p := p
		devices = append(devices, peerToDevice(&p, userNames))
	}
	return devices
}

func TestCLIClientFreshBypassesRecentCache(t *testing.T) {
	script := filepath.Join(t.TempDir(), "tailscale")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n' '{\"BackendState\":\"Running\",\"Self\":{\"ID\":\"intlmac\",\"HostName\":\"intlmac\"}}'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	c := &CLIClient{binary: script, cacheTTL: time.Hour, cachedAt: time.Now(), cached: []*domain.Device{{ID: "old"}}}
	devices, err := c.ListDevices(context.Background())
	if err != nil || len(devices) != 1 || devices[0].ID != "old" {
		t.Fatalf("normal cache read = %v %v", devices, err)
	}
	devices, err = c.ListDevicesFresh(context.Background())
	if err != nil || len(devices) != 1 || devices[0].ID != "intlmac" {
		t.Fatalf("fresh read = %v %v", devices, err)
	}
	devices, err = c.ListDevices(context.Background())
	if err != nil || len(devices) != 1 || devices[0].ID != "intlmac" {
		t.Fatalf("new cache read = %v %v", devices, err)
	}
}

func TestCLIClientFreshFailureDoesNotClaimCachedSuccess(t *testing.T) {
	c := &CLIClient{binary: filepath.Join(t.TempDir(), "missing-tailscale"), cacheTTL: time.Hour, cachedAt: time.Now(), cached: []*domain.Device{{ID: "old"}}}
	if devices, err := c.ListDevicesFresh(context.Background()); err == nil || devices != nil {
		t.Fatalf("failed refresh returned stale success: %v %v", devices, err)
	}
	if len(c.cached) != 1 || c.cached[0].ID != "old" {
		t.Fatal("failed refresh discarded good cache")
	}
}

func TestCLIClientFreshRejectsStoppedDaemon(t *testing.T) {
	script := filepath.Join(t.TempDir(), "tailscale")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n' '{\"BackendState\":\"Stopped\",\"Self\":{\"ID\":\"old\"}}'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	c := &CLIClient{binary: script, cacheTTL: time.Hour}
	if devices, err := c.ListDevicesFresh(context.Background()); err == nil || devices != nil {
		t.Fatalf("stopped daemon claimed fresh: %v %v", devices, err)
	}
}

func TestCLIClientFetchForcesBackgroundCLIMode(t *testing.T) {
	for _, inherited := range []string{"", "0", "1"} {
		for _, fresh := range []bool{false, true} {
			name := "cached-fetch/inherited=" + inherited
			if fresh {
				name = "fresh-fetch/inherited=" + inherited
			}
			t.Run(name, func(t *testing.T) {
				t.Setenv("TAILSCALE_BE_CLI", inherited)
				t.Setenv("HYDRA_TEST_PASSTHROUGH", "keep-other-environment")
				script := filepath.Join(t.TempDir(), "tailscale")
				// The bundled macOS app can emit a GUI launch error with exit
				// status zero unless its explicit CLI environment flag is set.
				body := `#!/bin/sh
if [ "$TAILSCALE_BE_CLI" != "1" ]; then
    printf '%s\n' 'The Tailscale GUI failed to start'
    exit 0
fi
if [ "$HYDRA_TEST_PASSTHROUGH" != "keep-other-environment" ]; then
    exit 2
fi
printf '%s\n' '{"BackendState":"Running","Self":{"ID":"intlmac","HostName":"intlmac"}}'
`
				if err := os.WriteFile(script, []byte(body), 0700); err != nil {
					t.Fatal(err)
				}
				c := &CLIClient{binary: script, cacheTTL: time.Hour}
				var devices []*domain.Device
				var err error
				if fresh {
					devices, err = c.ListDevicesFresh(context.Background())
				} else {
					devices, err = c.ListDevices(context.Background())
				}
				if err != nil || len(devices) != 1 || devices[0].ID != "intlmac" {
					t.Fatalf("background CLI mode not enforced: %v %v", devices, err)
				}
				if os.Getenv("TAILSCALE_BE_CLI") != inherited {
					t.Fatal("fetch changed the parent process environment")
				}
			})
		}
	}
}

func findDevice(devices []*domain.Device, id string) *domain.Device {
	for _, d := range devices {
		if d.ID == id {
			return d
		}
	}
	return nil
}

func TestCLIClient_ParseFixture_Count(t *testing.T) {
	devices := loadFixture(t)
	// fixture has Self + 2 peers = 3 devices
	if len(devices) != 3 {
		t.Fatalf("want 3 devices, got %d", len(devices))
	}
}

func TestCLIClient_ParseFixture_Self(t *testing.T) {
	devices := loadFixture(t)
	self := findDevice(devices, "n9HdyxhBHR11CNTRL")
	if self == nil {
		t.Fatal("Self device not found")
	}
	if self.Name != "m4max.tail476516.ts.net" {
		t.Errorf("Name = %q, want m4max.tail476516.ts.net", self.Name)
	}
	if self.OS != "macOS" {
		t.Errorf("OS = %q, want macOS", self.OS)
	}
	if self.TailscaleIP != "100.67.7.48" {
		t.Errorf("TailscaleIP = %q, want 100.67.7.48", self.TailscaleIP)
	}
	if self.Status != domain.DeviceStatusOnline {
		t.Errorf("Status = %q, want online", self.Status)
	}
	// Self is Online=true and LastSeen is zero → LastSeen should be ~now
	if time.Since(self.LastSeen) > 5*time.Second {
		t.Errorf("Self.LastSeen should be ~now for online+zero-time peer, got %v", self.LastSeen)
	}
	if self.User != "s1ckdark@naver.com" {
		t.Errorf("User = %q, want s1ckdark@naver.com", self.User)
	}
	// macOS → SSHEnabled = true
	if !self.SSHEnabled {
		t.Error("SSHEnabled should be true for macOS")
	}
}

func TestCLIClient_ParseFixture_LinuxPeer(t *testing.T) {
	devices := loadFixture(t)
	peer := findDevice(devices, "njYRheyHMQ11CNTRL")
	if peer == nil {
		t.Fatal("high16 peer not found")
	}
	if peer.Hostname != "high16" {
		t.Errorf("Hostname = %q, want high16", peer.Hostname)
	}
	if peer.Name != "high-16.tail476516.ts.net" {
		t.Errorf("Name = %q, want high-16.tail476516.ts.net", peer.Name)
	}
	if peer.OS != "Linux" {
		t.Errorf("OS = %q, want Linux", peer.OS)
	}
	if peer.Status != domain.DeviceStatusOnline {
		t.Errorf("Status = %q, want online (Online=true)", peer.Status)
	}
	// Online active peer with zero LastSeen → LastSeen set to now
	if time.Since(peer.LastSeen) > 5*time.Second {
		t.Errorf("LastSeen should be ~now for active peer, got %v", peer.LastSeen)
	}
	if !peer.SSHEnabled {
		t.Error("SSHEnabled should be true for Linux")
	}
}

func TestCLIClient_ParseFixture_OfflinePeer(t *testing.T) {
	devices := loadFixture(t)
	peer := findDevice(devices, "nzTwDd8ZsV11CNTRL")
	if peer == nil {
		t.Fatal("racknerd peer not found")
	}
	if peer.Status != domain.DeviceStatusOffline {
		t.Errorf("Status = %q, want offline (Online=false)", peer.Status)
	}
	// LastSeen is a real timestamp, not zero
	want, _ := time.Parse(time.RFC3339, "2026-05-20T09:00:00Z")
	if !peer.LastSeen.Equal(want) {
		t.Errorf("LastSeen = %v, want %v", peer.LastSeen, want)
	}
}

func TestCLIClient_ParseFixture_IsExternal(t *testing.T) {
	devices := loadFixture(t)
	for _, d := range devices {
		if d.IsExternal {
			t.Errorf("device %s IsExternal=true, want false (CLI shows own tailnet)", d.ID)
		}
	}
}

func TestCLIClient_GetDevice_ByNodeID(t *testing.T) {
	// Use a CLIClient with the binary pointed at a script that echoes the fixture.
	// Since we can't shell out in a unit test portably, test GetDevice via the
	// cache path: pre-populate the cache with fixture devices.
	devices := loadFixture(t)
	c := &CLIClient{cacheTTL: 5 * time.Second}
	c.cached = devices
	c.cachedAt = time.Now()

	ctx := context.Background()
	d, err := c.GetDevice(ctx, "njYRheyHMQ11CNTRL")
	if err != nil {
		t.Fatalf("GetDevice by ID: %v", err)
	}
	if d.Hostname != "high16" {
		t.Errorf("Hostname = %q, want high16", d.Hostname)
	}
}

func TestCLIClient_GetDevice_ByDNSName(t *testing.T) {
	devices := loadFixture(t)
	c := &CLIClient{cacheTTL: 5 * time.Second}
	c.cached = devices
	c.cachedAt = time.Now()

	ctx := context.Background()
	// Without trailing dot
	d, err := c.GetDevice(ctx, "m4max.tail476516.ts.net")
	if err != nil {
		t.Fatalf("GetDevice by DNS name: %v", err)
	}
	if d.ID != "n9HdyxhBHR11CNTRL" {
		t.Errorf("ID = %q, want n9HdyxhBHR11CNTRL", d.ID)
	}
}

func TestCLIClient_GetDevice_ByHostname(t *testing.T) {
	devices := loadFixture(t)
	c := &CLIClient{cacheTTL: 5 * time.Second}
	c.cached = devices
	c.cachedAt = time.Now()

	ctx := context.Background()
	d, err := c.GetDevice(ctx, "racknerd-7f8887f")
	if err != nil {
		t.Fatalf("GetDevice by hostname: %v", err)
	}
	if d.ID != "nzTwDd8ZsV11CNTRL" {
		t.Errorf("ID = %q, want nzTwDd8ZsV11CNTRL", d.ID)
	}
}

func TestCLIClient_GetDeviceByID_NotFound(t *testing.T) {
	devices := loadFixture(t)
	c := &CLIClient{cacheTTL: 5 * time.Second}
	c.cached = devices
	c.cachedAt = time.Now()

	ctx := context.Background()
	_, err := c.GetDeviceByID(ctx, "nonexistent")
	if err == nil {
		t.Error("expected error for nonexistent device ID")
	}
}

func TestNormalizeOS_CLI(t *testing.T) {
	cases := []struct{ in, want string }{
		{"linux", "Linux"},
		{"macOS", "macOS"},
		{"iOS", "iOS"},
		{"windows", "Windows"},
	}
	for _, tc := range cases {
		if got := normalizeOS(tc.in); got != tc.want {
			t.Errorf("normalizeOS(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
