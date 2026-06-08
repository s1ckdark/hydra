package ssh

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
	"golang.org/x/sync/singleflight"

	"github.com/s1ckdark/hydra/internal/domain"
)

// Executor executes commands on remote machines via SSH
type Executor struct {
	user            string
	privateKeyPath  string
	port            int
	timeout         time.Duration
	useTailscaleSSH bool

	// Connection pool
	connPool   map[string]*ssh.Client
	connPoolMu sync.RWMutex

	// dialGroup coalesces concurrent connect attempts to the same device so a
	// burst of parallel sub-collectors (CPU/mem/disk/uptime all dial at once)
	// makes a single auth attempt and records a single breaker result instead
	// of one per goroutine.
	dialGroup singleflight.Group

	// Per-device circuit breaker. Stops re-dialing a host that keeps failing
	// so we neither spam it nor get our IP blocked by sshd. See breaker.go.
	breakers   map[string]*circuitBreaker
	breakersMu sync.Mutex

	// Tailscale auth state (checked once at startup)
	tailscaleAuthed   bool
	tailscaleCheckMu  sync.Once
}

// Config holds SSH executor configuration
type Config struct {
	User            string
	PrivateKeyPath  string
	Port            int
	Timeout         time.Duration
	UseTailscaleSSH bool
}

// NewExecutor creates a new SSH executor
func NewExecutor(cfg Config) *Executor {
	if cfg.Port == 0 {
		cfg.Port = 22
	}
	if cfg.Timeout == 0 {
		cfg.Timeout = 30 * time.Second
	}

	return &Executor{
		user:            cfg.User,
		privateKeyPath:  cfg.PrivateKeyPath,
		port:            cfg.Port,
		timeout:         cfg.Timeout,
		useTailscaleSSH: cfg.UseTailscaleSSH,
		connPool:        make(map[string]*ssh.Client),
		breakers:        make(map[string]*circuitBreaker),
	}
}

// Execute runs a command on a remote device
func (e *Executor) Execute(ctx context.Context, device *domain.Device, command string) (string, error) {
	if e.useTailscaleSSH {
		return e.executeTailscaleSSH(ctx, device, command)
	}
	return e.executeRegularSSH(ctx, device, command)
}

// checkTailscaleAuth checks if Tailscale is authenticated (runs once).
func (e *Executor) checkTailscaleAuth() bool {
	e.tailscaleCheckMu.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, findTailscaleBinary(), "status", "--json")
		out, err := cmd.Output()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[hydra] tailscale status check failed: %v\n", err)
			return
		}
		// If BackendState is "Running", we're authenticated
		if bytes.Contains(out, []byte(`"BackendState":"Running"`)) {
			e.tailscaleAuthed = true
		} else {
			fmt.Fprintln(os.Stderr, "[hydra] tailscale is not authenticated — skipping tailscale ssh. Run 'tailscale login' to authenticate.")
		}
	})
	return e.tailscaleAuthed
}

// findTailscaleBinary returns the path to the tailscale binary
func findTailscaleBinary() string {
	if path, err := exec.LookPath("tailscale"); err == nil {
		return path
	}
	// macOS app bundle location
	macOSPath := "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
	if _, err := os.Stat(macOSPath); err == nil {
		return macOSPath
	}
	return "tailscale"
}

// executeTailscaleSSH uses the tailscale ssh command
func (e *Executor) executeTailscaleSSH(ctx context.Context, device *domain.Device, command string) (string, error) {
	if !e.checkTailscaleAuth() {
		return "", fmt.Errorf("tailscale not authenticated — run 'tailscale login' first")
	}

	// Build target: user@device or just device
	target := device.TailscaleIP
	if device.Name != "" {
		target = device.Name
	}
	if e.user != "" {
		target = e.user + "@" + target
	}

	// Use tailscale ssh command
	cmd := exec.CommandContext(ctx, findTailscaleBinary(), "ssh", target, command)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		if stderr.Len() > 0 {
			return "", fmt.Errorf("ssh error: %s", stderr.String())
		}
		return "", fmt.Errorf("ssh failed: %w", err)
	}

	return stdout.String(), nil
}

// executeRegularSSH uses standard SSH with key authentication
func (e *Executor) executeRegularSSH(ctx context.Context, device *domain.Device, command string) (string, error) {
	client, err := e.getClient(ctx, device)
	if err != nil {
		return "", err
	}

	session, err := client.NewSession()
	if err != nil {
		// Connection might be stale, try to reconnect
		e.closeClient(device.ID)
		client, err = e.getClient(ctx, device)
		if err != nil {
			return "", fmt.Errorf("failed to reconnect: %w", err)
		}
		session, err = client.NewSession()
		if err != nil {
			return "", fmt.Errorf("failed to create session: %w", err)
		}
	}
	defer session.Close()

	var stdout, stderr bytes.Buffer
	session.Stdout = &stdout
	session.Stderr = &stderr

	// Run with context deadline
	done := make(chan error, 1)
	go func() {
		done <- session.Run(command)
	}()

	select {
	case <-ctx.Done():
		session.Signal(ssh.SIGTERM)
		return "", ctx.Err()
	case err := <-done:
		if err != nil {
			if stderr.Len() > 0 {
				return "", fmt.Errorf("command error: %s", strings.TrimSpace(stderr.String()))
			}
			return "", err
		}
	}

	return stdout.String(), nil
}

// getClient gets or creates an SSH client for a device. A cached connection
// is probed with a cheap OpenSSH keepalive request before being returned, so
// a connection that has silently died (server reboot, NAT timeout, network
// blip) is evicted on the next call instead of poisoning every subsequent
// Execute. The probe adds one short round-trip per call, which is negligible
// compared to the cost of a failed handshake or a stale-error display.
func (e *Executor) getClient(ctx context.Context, device *domain.Device) (*ssh.Client, error) {
	e.connPoolMu.RLock()
	client, exists := e.connPool[device.ID]
	e.connPoolMu.RUnlock()

	if exists {
		if isClientAlive(client) {
			// A live pooled connection is proof the host is healthy — clear any
			// lingering breaker state so a recovered device dials freely again.
			e.recordSuccess(device.ID)
			return client, nil
		}
		e.closeClient(device.ID)
	}

	// Coalesce concurrent dials to the same device. When the metric collector
	// fires four parallel sub-collectors against a host with no pooled
	// connection, only one of them actually dials; the rest share its result.
	// For a failing host this collapses four auth attempts (and four breaker
	// failures) into one per cycle; for a healthy host it shares a single
	// connection instead of opening four. The leader's ctx governs the shared
	// dial — acceptable since these callers run on comparable deadlines.
	v, err, _ := e.dialGroup.Do(device.ID, func() (interface{}, error) {
		return e.dialAndPool(ctx, device)
	})
	if err != nil {
		return nil, err
	}
	return v.(*ssh.Client), nil
}

// dialAndPool performs the actual connect for a device under the singleflight
// group, consulting and updating the circuit breaker. It is only ever run by
// the singleflight leader for a given device ID.
func (e *Executor) dialAndPool(ctx context.Context, device *domain.Device) (*ssh.Client, error) {
	// A sibling dial may have populated the pool just before we became leader.
	e.connPoolMu.RLock()
	pooled, ok := e.connPool[device.ID]
	e.connPoolMu.RUnlock()
	if ok {
		if isClientAlive(pooled) {
			e.recordSuccess(device.ID)
			return pooled, nil
		}
		e.closeClient(device.ID)
	}

	now := time.Now()
	if err := e.acquireAttempt(device.ID, now); err != nil {
		// Breaker is open and the cooldown has not elapsed — the device is
		// effectively disconnected. Return without touching the network.
		return nil, err
	}

	config, err := e.getSSHConfig()
	if err != nil {
		// A missing or unparseable key file will never succeed on retry, so
		// feed it through the breaker (key-file class trips on the first hit).
		e.recordFailure(device.ID, err, time.Now())
		return nil, err
	}

	addr := fmt.Sprintf("%s:%d", device.TailscaleIP, e.port)
	client, err := e.dialSSH(ctx, addr, config)
	if err != nil {
		if ctx.Err() != nil {
			// The caller (e.g. a refresh that hit its deadline) canceled the
			// dial. That's our own backpressure, not the host rejecting us, so
			// don't let it trip the breaker against an otherwise-fine device.
			return nil, ctx.Err()
		}
		e.recordFailure(device.ID, err, time.Now())
		return nil, fmt.Errorf("failed to connect to %s: %w", addr, err)
	}

	e.recordSuccess(device.ID)

	e.connPoolMu.Lock()
	e.connPool[device.ID] = client
	e.connPoolMu.Unlock()

	return client, nil
}

// dialSSH establishes an SSH client connection that honors ctx for
// cancellation, with e.timeout as a backstop. Plain ssh.Dial only knows
// ClientConfig.Timeout, so a caller that has already given up (a refresh past
// its deadline, a canceled request) cannot abort an in-flight dial and the
// goroutine lingers up to the full SSH timeout. Dialing through DialContext and
// completing the handshake under a connection deadline fixes that.
func (e *Executor) dialSSH(ctx context.Context, addr string, config *ssh.ClientConfig) (*ssh.Client, error) {
	dialCtx, cancel := context.WithTimeout(ctx, e.timeout)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(dialCtx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	// Bound the handshake by the same timeout, then clear the deadline so it
	// does not apply to the long-lived session traffic on this connection.
	_ = conn.SetDeadline(time.Now().Add(e.timeout))
	sshConn, chans, reqs, err := ssh.NewClientConn(conn, addr, config)
	if err != nil {
		conn.Close()
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	return ssh.NewClient(sshConn, chans, reqs), nil
}

// isClientAlive sends an OpenSSH keepalive global request and reports whether
// the peer responded. The request type is unsupported by the protocol on
// purpose — peers respond with "request failure" which still proves the
// connection is alive, while a transport-level error means it is not.
func isClientAlive(client *ssh.Client) bool {
	_, _, err := client.SendRequest("keepalive@openssh.com", true, nil)
	return err == nil
}

// closeClient closes and removes a client from the pool
func (e *Executor) closeClient(deviceID string) {
	e.connPoolMu.Lock()
	defer e.connPoolMu.Unlock()

	if client, exists := e.connPool[deviceID]; exists {
		client.Close()
		delete(e.connPool, deviceID)
	}
}

// Close closes all SSH connections
func (e *Executor) Close() {
	e.connPoolMu.Lock()
	defer e.connPoolMu.Unlock()

	for _, client := range e.connPool {
		client.Close()
	}
	e.connPool = make(map[string]*ssh.Client)
}

// getSSHConfig creates SSH client configuration
func (e *Executor) getSSHConfig() (*ssh.ClientConfig, error) {
	keyPath := e.privateKeyPath
	if strings.HasPrefix(keyPath, "~") {
		home, _ := os.UserHomeDir()
		keyPath = filepath.Join(home, keyPath[1:])
	}

	key, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read private key: %w", err)
	}

	signer, err := ssh.ParsePrivateKey(key)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}

	hostKeyCallback, err := e.getHostKeyCallback()
	if err != nil {
		return nil, err
	}

	return &ssh.ClientConfig{
		User: e.user,
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(signer),
		},
		HostKeyCallback: hostKeyCallback,
		Timeout:         e.timeout,
	}, nil
}

// sameAlgorithmKnown reports whether keyErr records a key of the same algorithm
// as the presented key. When true the host is known under this algorithm but the
// bytes differ — a genuine key change to reject. When false the host is either
// unknown (Want empty) or known only under other algorithms, both of which are
// safe to accept-new.
func sameAlgorithmKnown(keyErr *knownhosts.KeyError, presented ssh.PublicKey) bool {
	for _, k := range keyErr.Want {
		if k.Key.Type() == presented.Type() {
			return true
		}
	}
	return false
}

func (e *Executor) getHostKeyCallback() (ssh.HostKeyCallback, error) {
	home, _ := os.UserHomeDir()
	knownHostsPath := filepath.Join(home, ".ssh", "known_hosts")

	if file := os.Getenv("CLUSTERCTL_SSH_KNOWN_HOSTS"); file != "" {
		knownHostsPath = file
	}

	// Ensure known_hosts file exists
	if _, err := os.Stat(knownHostsPath); os.IsNotExist(err) {
		dir := filepath.Dir(knownHostsPath)
		os.MkdirAll(dir, 0700)
		os.WriteFile(knownHostsPath, nil, 0600)
	}

	callback, err := knownhosts.New(knownHostsPath)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize SSH host key verification: %w", err)
	}

	// Wrap callback to auto-accept and save unknown host keys (like StrictHostKeyChecking=accept-new)
	return func(hostname string, remote net.Addr, key ssh.PublicKey) error {
		err := callback(hostname, remote, key)
		if err == nil {
			return nil
		}

		// Auto-accept and save when this is not a genuine key change. Two cases
		// qualify, and both are distinguished by knownhosts.KeyError.Want:
		//   - Want empty: the host is entirely unknown (trust-on-first-use).
		//   - Want holds only keys of *other* algorithms: the host was recorded
		//     under, say, ecdsa, but now presents the ed25519 key Go prefers.
		//     That is not a changed key — we simply never stored this algorithm
		//     — so we append it rather than rejecting the host forever.
		// A genuine change (rotation / MITM) is a Want entry of the SAME
		// algorithm as the presented key but different bytes; that still falls
		// through to the reject below. We route the append through
		// AppendKnownHostLine so it shares knownHostsMu with recovery's
		// ReplaceKnownHost/RemoveKnownHost and can not interleave with their
		// read-modify-write rewrites.
		var keyErr *knownhosts.KeyError
		if errors.As(err, &keyErr) && !sameAlgorithmKnown(keyErr, key) {
			if appendErr := AppendKnownHostLine(hostname, key); appendErr != nil {
				return fmt.Errorf("unknown host key and failed to save: %w", appendErr)
			}
			return nil
		}

		// Same-algorithm key change (possible MITM) — reject
		return err
	}, nil
}

// CopyFile copies a file to a remote device
func (e *Executor) CopyFile(ctx context.Context, device *domain.Device, localPath, remotePath string) error {
	if e.useTailscaleSSH {
		return e.copyFileTailscaleSSH(ctx, device, localPath, remotePath)
	}
	return e.copyFileRegularSSH(ctx, device, localPath, remotePath)
}

func (e *Executor) copyFileTailscaleSSH(ctx context.Context, device *domain.Device, localPath, remotePath string) error {
	if !e.checkTailscaleAuth() {
		return fmt.Errorf("tailscale not authenticated — run 'tailscale login' first")
	}

	target := device.TailscaleIP
	if device.Name != "" {
		target = device.Name
	}
	if e.user != "" {
		target = e.user + "@" + target
	}

	// Use scp through tailscale
	cmd := exec.CommandContext(ctx, findTailscaleBinary(), "scp", localPath, target+":"+remotePath)
	return cmd.Run()
}

func (e *Executor) copyFileRegularSSH(ctx context.Context, device *domain.Device, localPath, remotePath string) error {
	client, err := e.getClient(ctx, device)
	if err != nil {
		return err
	}

	session, err := client.NewSession()
	if err != nil {
		return err
	}
	defer session.Close()

	file, err := os.Open(localPath)
	if err != nil {
		return err
	}
	defer file.Close()

	stat, err := file.Stat()
	if err != nil {
		return err
	}

	// Use SCP protocol
	go func() {
		w, _ := session.StdinPipe()
		defer w.Close()

		fmt.Fprintf(w, "C0644 %d %s\n", stat.Size(), filepath.Base(remotePath))
		io.Copy(w, file)
		fmt.Fprint(w, "\x00")
	}()

	return session.Run(fmt.Sprintf("scp -t %s", remotePath))
}

// CheckConnectivity tests if SSH connection is possible
func (e *Executor) CheckConnectivity(ctx context.Context, device *domain.Device) error {
	_, err := e.Execute(ctx, device, "echo ok")
	return err
}

// ExecuteParallel executes a command on multiple devices in parallel
func (e *Executor) ExecuteParallel(ctx context.Context, devices []*domain.Device, command string, maxConcurrent int) map[string]ExecuteResult {
	if maxConcurrent <= 0 {
		maxConcurrent = 10
	}

	results := make(map[string]ExecuteResult)
	var resultsMu sync.Mutex

	sem := make(chan struct{}, maxConcurrent)
	var wg sync.WaitGroup

	for _, device := range devices {
		wg.Add(1)
		go func(d *domain.Device) {
			defer wg.Done()

			sem <- struct{}{}
			defer func() { <-sem }()

			output, err := e.Execute(ctx, d, command)

			resultsMu.Lock()
			results[d.ID] = ExecuteResult{
				Output: output,
				Error:  err,
			}
			resultsMu.Unlock()
		}(device)
	}

	wg.Wait()
	return results
}

// ExecuteResult holds the result of a command execution
type ExecuteResult struct {
	Output string
	Error  error
}
