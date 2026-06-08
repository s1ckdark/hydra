package ssh

import (
	"errors"
	"testing"
	"time"
)

func TestAliveWithin_Responsive(t *testing.T) {
	if !aliveWithin(func() error { return nil }, 2*time.Second) {
		t.Fatal("a probe that returns nil immediately must report alive")
	}
}

func TestAliveWithin_Error(t *testing.T) {
	if aliveWithin(func() error { return errors.New("connection reset") }, 2*time.Second) {
		t.Fatal("a probe that returns an error must report not-alive")
	}
}

// The core regression: a keepalive on a silently-dead peer (the pooled conn has
// its deadline cleared after handshake) blocks indefinitely. aliveWithin must
// give up at the timeout and report not-alive so getClient evicts and redials,
// rather than hanging every subsequent call until the process restarts.
func TestAliveWithin_BlockedProbeTimesOut(t *testing.T) {
	release := make(chan struct{})
	defer close(release)

	start := time.Now()
	alive := aliveWithin(func() error {
		<-release // simulate a keepalive wedged on a dead-but-not-torn-down conn
		return nil
	}, 50*time.Millisecond)
	elapsed := time.Since(start)

	if alive {
		t.Fatal("a probe that blocks past the timeout must report not-alive")
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("aliveWithin must return near the timeout, not block; took %v", elapsed)
	}
}
