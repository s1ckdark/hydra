package ssh

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	gossh "golang.org/x/crypto/ssh"

	"github.com/s1ckdark/hydra/internal/domain"
)

// newTestExecutor returns an executor with an initialized breaker map but no
// real SSH config — enough to exercise the breaker bookkeeping directly.
func newTestExecutor() *Executor {
	return NewExecutor(Config{User: "tester", Port: 22})
}

// Error strings chosen so categorizeSSHError maps them to the intended class.
var (
	errAuth     = errors.New("ssh: handshake failed: ssh: unable to authenticate, attempted methods [none publickey]")
	errHostKey  = errors.New("ssh: handshake failed: knownhosts: key mismatch")
	errNetwork  = errors.New("dial tcp 100.64.0.1:22: connect: connection refused")
	errKeyFile  = errors.New("failed to read private key: open /home/x/.ssh/id_ed25519: no such file or directory")
	errMysteryX = errors.New("something we have never seen before")
)

func mustOpen(t *testing.T, e *Executor, deviceID string, now time.Time) {
	t.Helper()
	if err := e.acquireAttempt(deviceID, now); err == nil {
		t.Fatalf("expected breaker for %q to be OPEN, but attempt was permitted", deviceID)
	} else if _, ok := err.(*CircuitOpenError); !ok {
		t.Fatalf("expected *CircuitOpenError, got %T: %v", err, err)
	}
}

func mustClosed(t *testing.T, e *Executor, deviceID string, now time.Time) {
	t.Helper()
	if err := e.acquireAttempt(deviceID, now); err != nil {
		t.Fatalf("expected breaker for %q to be CLOSED, but attempt was suppressed: %v", deviceID, err)
	}
}

func TestBreaker_AuthFailsTripImmediately(t *testing.T) {
	e := newTestExecutor()
	now := time.Unix(1_000, 0)

	mustClosed(t, e, "dev", now) // nothing recorded yet
	e.recordFailure("dev", errAuth, now)
	mustOpen(t, e, "dev", now) // a single auth failure must trip
}

func TestBreaker_HostKeyAndKeyFileTripImmediately(t *testing.T) {
	now := time.Unix(2_000, 0)
	for name, err := range map[string]error{"hostkey": errHostKey, "keyfile": errKeyFile} {
		e := newTestExecutor()
		e.recordFailure(name, err, now)
		mustOpen(t, e, name, now)
	}
}

func TestBreaker_NetworkToleratesThenTrips(t *testing.T) {
	e := newTestExecutor()
	now := time.Unix(3_000, 0)

	// First two network failures are tolerated (threshold is 3).
	e.recordFailure("dev", errNetwork, now)
	mustClosed(t, e, "dev", now)
	e.recordFailure("dev", errNetwork, now)
	mustClosed(t, e, "dev", now)

	// Third trips it.
	e.recordFailure("dev", errNetwork, now)
	mustOpen(t, e, "dev", now)
}

func TestBreaker_UnknownErrorUsesNetworkThreshold(t *testing.T) {
	e := newTestExecutor()
	now := time.Unix(3_500, 0)
	e.recordFailure("dev", errMysteryX, now)
	e.recordFailure("dev", errMysteryX, now)
	mustClosed(t, e, "dev", now) // 2 < 3, still closed
	e.recordFailure("dev", errMysteryX, now)
	mustOpen(t, e, "dev", now)
}

func TestBreaker_CooldownHalfOpensThenTrialFailureReopens(t *testing.T) {
	e := newTestExecutor()
	now := time.Unix(4_000, 0)

	e.recordFailure("dev", errAuth, now) // trips, openUntil = now+cooldown
	mustOpen(t, e, "dev", now)

	// Still open one tick before cooldown elapses.
	mustOpen(t, e, "dev", now.Add(breakerCooldown-time.Second))

	// After the cooldown a half-open trial is permitted.
	afterCooldown := now.Add(breakerCooldown + time.Second)
	mustClosed(t, e, "dev", afterCooldown)

	// A failed trial re-opens the breaker for another full cooldown.
	e.recordFailure("dev", errAuth, afterCooldown)
	mustOpen(t, e, "dev", afterCooldown)
	mustClosed(t, e, "dev", afterCooldown.Add(breakerCooldown+time.Second))
}

// TestBreaker_HalfOpenTrialReopensOnCategoryChange guards the single-trial
// guarantee across an error-class change. An auth failure trips the breaker at
// failures=1; after the cooldown the half-open trial fails with a *network*
// error (threshold 3). failures=2 is below the network threshold, so without
// the "already open → re-trip" rule the breaker would stay expired and keep
// permitting dials. It must re-open instead.
func TestBreaker_HalfOpenTrialReopensOnCategoryChange(t *testing.T) {
	e := newTestExecutor()
	now := time.Unix(8_000, 0)

	e.recordFailure("dev", errAuth, now) // trips at failures=1 (auth threshold)
	mustOpen(t, e, "dev", now)

	afterCooldown := now.Add(breakerCooldown + time.Second)
	mustClosed(t, e, "dev", afterCooldown) // half-open trial permitted

	// Trial fails with a network error (threshold 3). failures becomes 2, which
	// is below 3 — the breaker must still re-open because it was already open.
	e.recordFailure("dev", errNetwork, afterCooldown)
	mustOpen(t, e, "dev", afterCooldown)
	mustOpen(t, e, "dev", afterCooldown.Add(time.Minute)) // still suppressed mid-cooldown
	mustClosed(t, e, "dev", afterCooldown.Add(breakerCooldown+time.Second))
}

func TestBreaker_SuccessClosesBreaker(t *testing.T) {
	e := newTestExecutor()
	now := time.Unix(5_000, 0)

	e.recordFailure("dev", errAuth, now)
	mustOpen(t, e, "dev", now)

	e.recordSuccess("dev")
	mustClosed(t, e, "dev", now)

	// And the failure count is reset — a single later network failure should
	// not trip (it would if the old count had survived).
	e.recordFailure("dev", errNetwork, now)
	mustClosed(t, e, "dev", now)
}

func TestBreaker_ManualResetSingleAndAll(t *testing.T) {
	e := newTestExecutor()
	now := time.Unix(6_000, 0)

	e.recordFailure("a", errAuth, now)
	e.recordFailure("b", errAuth, now)
	mustOpen(t, e, "a", now)
	mustOpen(t, e, "b", now)

	e.ResetBreaker("a")
	mustClosed(t, e, "a", now)
	mustOpen(t, e, "b", now) // unaffected

	e.ResetAllBreakers()
	mustClosed(t, e, "b", now)
}

// TestDialAndPool_CanceledContextDoesNotPenalizeBreaker proves the no-penalty
// rule: when the caller's context is already canceled (e.g. a refresh that hit
// its deadline), the aborted dial is our own backpressure, not the host
// rejecting us, so it must NOT count toward the breaker.
func TestDialAndPool_CanceledContextDoesNotPenalizeBreaker(t *testing.T) {
	dir := t.TempDir()

	// A valid private key so getSSHConfig succeeds and we actually reach the dial.
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	block, err := gossh.MarshalPrivateKey(priv, "")
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	keyPath := filepath.Join(dir, "id_ed25519")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(block), 0600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	// Isolate known_hosts so the test never touches the real ~/.ssh.
	t.Setenv("CLUSTERCTL_SSH_KNOWN_HOSTS", filepath.Join(dir, "known_hosts"))

	e := NewExecutor(Config{User: "tester", Port: 22, PrivateKeyPath: keyPath})
	device := &domain.Device{ID: "dev", TailscaleIP: "192.0.2.1"} // TEST-NET-1, unroutable

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // pre-canceled: DialContext returns immediately

	_, err = e.dialAndPool(ctx, device)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
	// The breaker must remain closed — a canceled dial is not a host failure.
	mustClosed(t, e, "dev", time.Unix(9_000, 0))
}

func TestCircuitOpenError_CarriesContext(t *testing.T) {
	e := newTestExecutor()
	now := time.Unix(7_000, 0)
	e.recordFailure("dev", errAuth, now)

	err := e.acquireAttempt("dev", now)
	var coe *CircuitOpenError
	if !errors.As(err, &coe) {
		t.Fatalf("expected *CircuitOpenError, got %T", err)
	}
	if coe.Category != DiagAuthFailed {
		t.Errorf("category = %q, want %q", coe.Category, DiagAuthFailed)
	}
	if coe.RetryAt != now.Add(breakerCooldown) {
		t.Errorf("RetryAt = %v, want %v", coe.RetryAt, now.Add(breakerCooldown))
	}
	if coe.LastErr == "" {
		t.Error("LastErr should carry the last failure message")
	}
}
