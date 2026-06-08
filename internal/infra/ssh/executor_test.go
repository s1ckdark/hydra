package ssh

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"net"
	"os"
	"strings"
	"testing"

	gossh "golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

func newTestECDSAKey(t *testing.T) gossh.PublicKey {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("genkey ecdsa: %v", err)
	}
	pk, err := gossh.NewPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatalf("wrap ecdsa pubkey: %v", err)
	}
	return pk
}

// A host previously recorded under only one algorithm (e.g. ecdsa) that now
// presents a different algorithm Go prefers (ed25519) must be accept-new'd, not
// rejected as a key change. This is the exact failure that left GPU hosts
// recorded ecdsa-only stuck "disconnected": Go negotiates ed25519, known_hosts
// has only ecdsa, knownhosts reports a (different-type) Want, and the old
// callback treated any non-empty Want as a mismatch and rejected it.
func TestHostKeyCallback_DifferentAlgoAcceptsNew(t *testing.T) {
	host := "h-gpu-test:22"
	stored := newTestECDSAKey(t)
	seed := knownhosts.Line([]string{knownhosts.Normalize(host)}, stored) + "\n"
	path := setupKnownHosts(t, seed)

	cb, err := (&Executor{}).getHostKeyCallback()
	if err != nil {
		t.Fatalf("getHostKeyCallback: %v", err)
	}

	presented := newTestKey(t) // ed25519 — a different algorithm than stored ecdsa
	remote := &net.TCPAddr{IP: net.ParseIP("10.9.9.9"), Port: 22}

	if err := cb(host, remote, presented); err != nil {
		t.Fatalf("different-algorithm key must be accepted (accept-new), got: %v", err)
	}

	// The new algorithm's key should now be persisted so future dials match.
	data, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("read known_hosts: %v", readErr)
	}
	if !strings.Contains(string(data), "ssh-ed25519") {
		t.Errorf("expected appended ssh-ed25519 line, known_hosts:\n%s", data)
	}
}

// A host that presents a DIFFERENT key of the SAME algorithm it is already known
// under is a genuine key change (rotation or MITM) and must still be rejected.
// This is the security boundary the accept-new relaxation must not cross.
func TestHostKeyCallback_SameAlgoMismatchRejected(t *testing.T) {
	host := "h-mismatch-test:22"
	stored := newTestECDSAKey(t)
	seed := knownhosts.Line([]string{knownhosts.Normalize(host)}, stored) + "\n"
	setupKnownHosts(t, seed)

	cb, err := (&Executor{}).getHostKeyCallback()
	if err != nil {
		t.Fatalf("getHostKeyCallback: %v", err)
	}

	imposter := newTestECDSAKey(t) // same algorithm, different bytes
	remote := &net.TCPAddr{IP: net.ParseIP("10.9.9.9"), Port: 22}

	if err := cb(host, remote, imposter); err == nil {
		t.Fatal("same-algorithm key change must be rejected, got nil")
	}
}

// An entirely unknown host (no known_hosts entry at all) is accept-new'd, the
// existing trust-on-first-use behavior the relaxation must preserve.
func TestHostKeyCallback_UnknownHostAcceptsNew(t *testing.T) {
	path := setupKnownHosts(t, "")

	cb, err := (&Executor{}).getHostKeyCallback()
	if err != nil {
		t.Fatalf("getHostKeyCallback: %v", err)
	}

	presented := newTestKey(t)
	remote := &net.TCPAddr{IP: net.ParseIP("10.9.9.10"), Port: 22}

	if err := cb("brand-new-host:22", remote, presented); err != nil {
		t.Fatalf("unknown host must be accepted, got: %v", err)
	}
	data, _ := os.ReadFile(path)
	if !strings.Contains(string(data), "ssh-ed25519") {
		t.Errorf("expected appended key for unknown host, known_hosts:\n%s", data)
	}
}
