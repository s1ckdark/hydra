package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
)

// Every mutating route must sit behind tailscaleAuthMiddleware. A route that
// slips outside the gate is unauthenticated remote command execution on
// whatever interface the server is bound to, so this is asserted rather than
// left to review.
func TestTailscaleAuthMiddleware_RejectsNonTailnetSource(t *testing.T) {
	cases := []struct {
		name       string
		remoteAddr string
		wantStatus int
	}{
		{"public internet", "203.0.113.9:51000", http.StatusForbidden},
		{"docker bridge", "172.17.0.1:51000", http.StatusForbidden},
		{"private LAN", "192.168.0.7:51000", http.StatusForbidden},
		{"private 10/8", "10.0.2.2:51000", http.StatusForbidden},
		{"tailnet CGNAT", "100.89.158.106:51000", http.StatusOK},
		{"tailnet lower bound", "100.64.0.1:51000", http.StatusOK},
		{"tailnet upper bound", "100.127.255.254:51000", http.StatusOK},
		{"loopback v4", "127.0.0.1:51000", http.StatusOK},
		{"loopback v6", "[::1]:51000", http.StatusOK},
		// Android emulator traffic to 10.0.2.2 arrives on the host loopback, so
		// it passes as 127.0.0.1 — the 10/8 case above is about a real 10/8 peer.
		{"just outside CGNAT", "100.128.0.1:51000", http.StatusForbidden},
		{"below CGNAT", "100.63.255.255:51000", http.StatusForbidden},
	}

	handler := tailscaleAuthMiddleware(func(c echo.Context) error {
		return c.NoContent(http.StatusOK)
	})

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := echo.New()
			req := httptest.NewRequest(http.MethodPost, "/orchs/x/execute", nil)
			req.RemoteAddr = tc.remoteAddr
			rec := httptest.NewRecorder()
			c := e.NewContext(req, rec)

			if err := handler(c); err != nil {
				t.Fatalf("handler returned error: %v", err)
			}
			if rec.Code != tc.wantStatus {
				t.Errorf("remoteAddr %s: got %d, want %d", tc.remoteAddr, rec.Code, tc.wantStatus)
			}
		})
	}
}

// X-Forwarded-For must not be able to talk its way past the gate; the source
// address is the only thing trusted here.
func TestTailscaleAuthMiddleware_IgnoresForwardedFor(t *testing.T) {
	handler := tailscaleAuthMiddleware(func(c echo.Context) error {
		return c.NoContent(http.StatusOK)
	})

	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/orchs/x/execute", nil)
	req.RemoteAddr = "203.0.113.9:51000"
	req.Header.Set("X-Forwarded-For", "100.89.158.106")
	rec := httptest.NewRecorder()

	if err := handler(e.NewContext(req, rec)); err != nil {
		t.Fatalf("handler returned error: %v", err)
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("spoofed X-Forwarded-For passed the gate: got %d, want %d", rec.Code, http.StatusForbidden)
	}
}
