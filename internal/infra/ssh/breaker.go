package ssh

import (
	"fmt"
	"time"
)

// Circuit-breaker tuning. The background metric collector (30s) and the
// reachability loop keep asking the executor to connect to every device. When
// a host rejects us (bad key, host-key mismatch) or is unreachable, re-dialing
// it forever does two bad things: it spams a host that will never succeed, and
// repeated failed authentications trip sshd's MaxAuthTries / fail2ban and get
// our source IP blocked. The breaker stops dialing a device after a few
// consecutive failures and reports it as "disconnected" until a cooldown
// elapses or a user action (refresh / host-key acceptance) resets it.
const (
	// breakerAuthThreshold trips after a single failure for error classes that
	// will never fix themselves by retrying — a wrong key, a changed host key,
	// or a missing/unparseable key file. Retrying these only risks a block, so
	// we stop immediately.
	breakerAuthThreshold = 1

	// breakerNetworkThreshold is the more lenient limit for transient failures
	// (connection refused, timeout, no route) that often clear on their own.
	// We give the host a few cycles before giving up.
	breakerNetworkThreshold = 3

	// breakerCooldown is how long the breaker stays open before allowing a
	// single half-open trial dial.
	breakerCooldown = 5 * time.Minute
)

// circuitBreaker tracks consecutive connection failures for one device.
// openUntil is the zero time while the breaker is closed; once tripped it
// holds the instant after which a single half-open trial is permitted.
type circuitBreaker struct {
	failures  int
	category  DiagnosisCategory
	lastErr   string
	openUntil time.Time
}

// CircuitOpenError is returned by the executor's connect path when a device's
// breaker is open and the cooldown has not yet elapsed. It carries enough
// context for the UI to explain why the device looks disconnected without
// re-probing it.
type CircuitOpenError struct {
	DeviceID string
	Category DiagnosisCategory
	LastErr  string
	RetryAt  time.Time
}

func (e *CircuitOpenError) Error() string {
	return fmt.Sprintf("connection suppressed after repeated %s failures; retry after %s (last error: %s)",
		e.Category, e.RetryAt.Format("15:04:05"), e.LastErr)
}

// breakerThreshold returns how many consecutive failures of the given class
// are tolerated before the breaker trips.
func breakerThreshold(cat DiagnosisCategory) int {
	switch cat {
	case DiagAuthFailed, DiagHostKeyMismatch, DiagKeyFileMissing:
		return breakerAuthThreshold
	default:
		return breakerNetworkThreshold
	}
}

// acquireAttempt decides whether a connection attempt for deviceID may proceed
// at time now. It returns a *CircuitOpenError while the breaker is open and the
// cooldown has not elapsed; nil otherwise. When the cooldown has elapsed the
// breaker stays in its open-but-expired state and this returns nil to permit a
// single trial — singleflight in getClient guarantees only one such trial dial
// actually runs at a time, so no extra half-open bookkeeping is needed here.
func (e *Executor) acquireAttempt(deviceID string, now time.Time) error {
	e.breakersMu.Lock()
	defer e.breakersMu.Unlock()

	b := e.breakers[deviceID]
	if b == nil || b.openUntil.IsZero() {
		return nil
	}
	if now.Before(b.openUntil) {
		return &CircuitOpenError{
			DeviceID: deviceID,
			Category: b.category,
			LastErr:  b.lastErr,
			RetryAt:  b.openUntil,
		}
	}
	return nil
}

// recordSuccess clears all failure state for a device. A successful dial — or a
// live pooled connection answering a keepalive — fully closes the breaker.
func (e *Executor) recordSuccess(deviceID string) {
	e.breakersMu.Lock()
	defer e.breakersMu.Unlock()
	delete(e.breakers, deviceID)
}

// recordFailure increments the consecutive-failure count for a device and trips
// the breaker once the count reaches the threshold for the failure's class.
//
// A failure observed during a half-open trial (the breaker was already tripped,
// so openUntil is non-zero) re-trips it for another full cooldown regardless of
// the trial error's class. This is required for the single-trial guarantee:
// without it, an auth failure that tripped at failures=1 could be followed by a
// half-open trial that fails with a *network* error (threshold 3) — failures=2
// would stay below 3, openUntil would remain in the past, and subsequent calls
// would keep dialing immediately. recordFailure is only ever reached after
// acquireAttempt permitted the attempt, so a non-zero openUntil here always
// means "this was the half-open trial".
func (e *Executor) recordFailure(deviceID string, err error, now time.Time) {
	cat, msg := categorizeSSHError(err)

	e.breakersMu.Lock()
	defer e.breakersMu.Unlock()

	b := e.breakers[deviceID]
	if b == nil {
		b = &circuitBreaker{}
		e.breakers[deviceID] = b
	}
	wasOpen := !b.openUntil.IsZero()
	b.failures++
	b.category = cat
	b.lastErr = msg
	if wasOpen || b.failures >= breakerThreshold(cat) {
		b.openUntil = now.Add(breakerCooldown)
	}
}

// ResetBreaker clears the breaker for a single device so the next connect
// attempt dials fresh. Called when the user explicitly intervenes for that
// device (e.g. accepting a changed host key).
func (e *Executor) ResetBreaker(deviceID string) {
	e.breakersMu.Lock()
	defer e.breakersMu.Unlock()
	delete(e.breakers, deviceID)
}

// ResetAllBreakers clears every device breaker. Called by a user-triggered
// full refresh so an "is it back yet?" check always gets a real attempt rather
// than a suppressed one.
func (e *Executor) ResetAllBreakers() {
	e.breakersMu.Lock()
	defer e.breakersMu.Unlock()
	e.breakers = make(map[string]*circuitBreaker)
}
