# macOS GUI Self-Reported Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Hydra GUI's own host (the Mac running the app) self-report CPU/memory/disk/GPU-static metrics every 5 seconds via a new `POST /api/devices/{id}/metrics` endpoint, so its dashboard panels stop showing empty bars and "handshake error". The same Tailscale device ID is shared between capability reporting and metric reporting via a new shared `DeviceIdentity` actor backed by a new `POST /api/devices/match` endpoint.

**Architecture:** Server side adds (a) a `MetricsSource` enum + `Source` field on `DeviceMetrics`, (b) `MonitorUseCase.PushSelfMetrics` plus a self-report-first short circuit in `GetDeviceMetrics`, and (c) two new HTTP handlers (`/api/devices/match` for hostname→ID resolution, `/api/devices/{id}/metrics` for the push). Swift side adds `MetricsSampler` (static syscalls), `DeviceIdentity` actor (caches the resolved ID), `APIClient` extensions, `MetricsReporter` (5 s timer), migrates `CapabilityReporter` to use `DeviceIdentity` instead of its Keychain UUID for the POST target, and starts the reporter from `HydraApp.swift`. ID discovery uses **hostname only** (Tailscale-derived `TailscaleIP.current()` helper does not exist in this codebase — the spec's IP fallback is dropped to keep scope tight; hostname matching is the strong key in personal tailnets anyway).

**Tech Stack:** Go (server, existing patterns in `internal/repository`, `internal/usecase`, `internal/web/handler`). Swift 5.9+ for macOS 14 (existing `Hydra` SPM package). Foundation/Darwin/Metal for sampling. SwiftUI scenes already in place.

**Spec:** [`docs/superpowers/specs/2026-04-29-macos-self-metrics-design.md`](../specs/2026-04-29-macos-self-metrics-design.md) — read this first if anything below is unclear.

**Verification:** `go test ./...` clean from the worktree root after every Go task. `cd Hydra && swift build` clean after every Swift task. Final task includes a manual smoke test (open the GUI, watch the dashboard fill in).

---

## Task 1: Add `MetricsSource` enum + `Source` field on `DeviceMetrics`

**What:** A small type addition that lets the server distinguish self-reported metrics from SSH-collected ones.

**Files:**
- Modify: `internal/domain/metrics.go` (add type + field)

This task has no tests of its own — its correctness is verified through Task 2's tests. Skip TDD here; this is a pure data-shape addition.

---

- [ ] **Step 1.1: Read the existing struct**

```bash
grep -nA 12 "type DeviceMetrics" /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/internal/domain/metrics.go
```

Note the existing field order; you'll add `Source` between `Network` and `CollectedAt`.

---

- [ ] **Step 1.2: Add the `MetricsSource` type and `Source` field**

In `internal/domain/metrics.go`, immediately above the `DeviceMetrics` type declaration, add:

```go
// MetricsSource identifies how a DeviceMetrics snapshot was obtained.
// Self-reported metrics from the GUI host take precedence over SSH-
// collected metrics in MonitorUseCase.GetDeviceMetrics so the local Mac
// (which has no SSH path back to itself) shows real numbers.
type MetricsSource string

const (
	MetricsSourceSSH        MetricsSource = "ssh"
	MetricsSourceSelfReport MetricsSource = "self"
)
```

Then in the `DeviceMetrics` struct, add the `Source` field between `Network` and `CollectedAt`:

```go
type DeviceMetrics struct {
	DeviceID    string          `json:"deviceId"`
	CPU         CPUMetrics      `json:"cpu"`
	Memory      MemoryMetrics   `json:"memory"`
	Disk        DiskMetrics     `json:"disk"`
	GPU         *GPUMetrics     `json:"gpu,omitempty"`
	Network     *NetworkMetrics `json:"network,omitempty"`
	Source      MetricsSource   `json:"source,omitempty"`   // NEW
	CollectedAt time.Time       `json:"collectedAt"`
	Error       string          `json:"error,omitempty"`
}
```

The `omitempty` keeps existing JSON payloads compact and back-compatible — a missing `source` field deserializes to `MetricsSource("")`, which compares unequal to `MetricsSourceSelfReport` and falls through to the SSH path in `GetDeviceMetrics`.

---

- [ ] **Step 1.3: Verify compile**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
go build ./...
```

Expected: clean build, no errors.

---

- [ ] **Step 1.4: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add internal/domain/metrics.go
git commit -m "feat(metrics): add MetricsSource enum and Source field

Distinguishes self-reported metrics (pushed from the macOS GUI host)
from SSH-collected ones, so MonitorUseCase.GetDeviceMetrics can give
self-reports precedence when the local device has no SSH path back
to itself.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `PushSelfMetrics` + self-report precedence in `GetDeviceMetrics`

**What:** A new `MonitorUseCase` method that handler code uses to store a self-reported metric, plus a fast-path branch in `GetDeviceMetrics` that returns the cached self-report when one is fresh (≤30 s), bypassing the SSH collector entirely.

**Files:**
- Modify: `internal/usecase/monitor_usecase.go` (`PushSelfMetrics`, `GetDeviceMetrics` branch, `freshSelfReport` const)
- Modify: `internal/usecase/monitor_usecase_test.go` (new test cases)

---

- [ ] **Step 2.1: Locate the existing `GetDeviceMetrics` body**

```bash
grep -nA 15 "func (uc \*MonitorUseCase) GetDeviceMetrics" /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/internal/usecase/monitor_usecase.go
```

Note the current shape — you'll wrap a self-report check around the existing SSH-fallback logic without removing any of it.

---

- [ ] **Step 2.2: Write four failing tests in `monitor_usecase_test.go`**

If `monitor_usecase_test.go` does not exist yet, create it with this content. If it does, append after the last test. The tests use a stubbed `MetricsCollector`, `DeviceUseCase`, and a real `MonitorUseCase`.

```go
package usecase

import (
	"context"
	"testing"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
)

// stubCollector returns canned SSH metrics or an error.
type stubCollector struct {
	called  bool
	metrics *domain.DeviceMetrics
	err     error
}

func (s *stubCollector) CollectMetrics(ctx context.Context, d *domain.Device) (*domain.DeviceMetrics, error) {
	s.called = true
	if s.err != nil {
		return nil, s.err
	}
	if s.metrics != nil {
		return s.metrics, nil
	}
	return &domain.DeviceMetrics{DeviceID: d.ID, CollectedAt: time.Now(), Source: domain.MetricsSourceSSH}, nil
}

func (s *stubCollector) CollectMetricsParallel(ctx context.Context, devices []*domain.Device) ([]*domain.DeviceMetrics, error) {
	return nil, nil
}

// minDeviceUC builds a DeviceUseCase that returns a single fixed device.
func minDeviceUC(t *testing.T, dev *domain.Device) *DeviceUseCase {
	t.Helper()
	uc := &DeviceUseCase{}
	// Insert dev into the override path: GetDevice walks Tailscale, but
	// here we sidestep by populating cachedDevices to a 1-device list.
	uc.cachedDevices = []*domain.Device{dev}
	uc.cacheTime = time.Now()
	uc.cacheTTL = time.Hour
	return uc
}

func TestMonitorUC_PushSelfMetrics_StoresInLatest(t *testing.T) {
	uc := NewMonitorUseCase(nil, &stubCollector{}, nil)
	m := &domain.DeviceMetrics{DeviceID: "dev-1", Source: domain.MetricsSourceSelfReport, CollectedAt: time.Now()}

	uc.PushSelfMetrics(m)

	got := uc.GetLatestCached("dev-1")
	if got == nil {
		t.Fatal("PushSelfMetrics did not populate latest cache")
	}
	if got.Source != domain.MetricsSourceSelfReport {
		t.Errorf("Source = %q; want self", got.Source)
	}
}

func TestMonitorUC_GetDeviceMetrics_PrefersFreshSelfReport(t *testing.T) {
	collector := &stubCollector{}
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-1", IPAddresses: []string{"100.1.1.1"}, OnlineStatus: domain.DeviceStatusOnline, SSHEnabled: true}
	uc := NewMonitorUseCase(nil, collector, minDeviceUC(t, dev))

	uc.PushSelfMetrics(&domain.DeviceMetrics{
		DeviceID:    "dev-1",
		Source:      domain.MetricsSourceSelfReport,
		CollectedAt: time.Now(),
		CPU:         domain.CPUMetrics{UsagePercent: 42},
	})

	got, err := uc.GetDeviceMetrics(context.Background(), "dev-1")
	if err != nil {
		t.Fatalf("GetDeviceMetrics: %v", err)
	}
	if got.Source != domain.MetricsSourceSelfReport {
		t.Errorf("Source = %q; want self", got.Source)
	}
	if got.CPU.UsagePercent != 42 {
		t.Errorf("CPU not preserved from self-report: %+v", got.CPU)
	}
	if collector.called {
		t.Error("SSH collector should not be invoked when fresh self-report is available")
	}
}

func TestMonitorUC_GetDeviceMetrics_FallsThroughOnStaleSelfReport(t *testing.T) {
	collector := &stubCollector{}
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-1", IPAddresses: []string{"100.1.1.1"}, OnlineStatus: domain.DeviceStatusOnline, SSHEnabled: true}
	uc := NewMonitorUseCase(nil, collector, minDeviceUC(t, dev))

	stale := &domain.DeviceMetrics{
		DeviceID:    "dev-1",
		Source:      domain.MetricsSourceSelfReport,
		CollectedAt: time.Now().Add(-2 * time.Minute), // > freshSelfReport
	}
	uc.PushSelfMetrics(stale)

	if _, err := uc.GetDeviceMetrics(context.Background(), "dev-1"); err != nil {
		t.Fatalf("GetDeviceMetrics: %v", err)
	}
	if !collector.called {
		t.Error("SSH collector should be invoked when self-report is stale")
	}
}

func TestMonitorUC_GetDeviceMetrics_FallsThroughWithoutSelfReport(t *testing.T) {
	collector := &stubCollector{}
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-1", IPAddresses: []string{"100.1.1.1"}, OnlineStatus: domain.DeviceStatusOnline, SSHEnabled: true}
	uc := NewMonitorUseCase(nil, collector, minDeviceUC(t, dev))

	if _, err := uc.GetDeviceMetrics(context.Background(), "dev-1"); err != nil {
		t.Fatalf("GetDeviceMetrics: %v", err)
	}
	if !collector.called {
		t.Error("SSH collector should be invoked when no self-report exists")
	}
}
```

If `MetricsCollector` is an interface elsewhere (likely in `monitor_usecase.go` itself) and `stubCollector` clashes with an existing fake, rename to `monitorStubCollector`. If `DeviceUseCase`'s field names differ from `cachedDevices`/`cacheTime`/`cacheTTL`, look at `internal/usecase/device_usecase.go` and adjust the helper. Stop and ask if the device-fixture path is more involved than expected.

---

- [ ] **Step 2.3: Run new tests, expect compile failure**

```bash
go test ./internal/usecase/ -run TestMonitorUC -v
```

Expected: `undefined: PushSelfMetrics` (and undefined Source field if Task 1 wasn't merged — but it should be, since this builds on Task 1).

---

- [ ] **Step 2.4: Add `PushSelfMetrics` and the precedence branch**

In `internal/usecase/monitor_usecase.go`, near the top of the file (after imports), add:

```go
// freshSelfReport is the maximum age of a self-reported metrics snapshot
// for it to take precedence over SSH-collected metrics. Sized at 6× the
// 5-second push cadence to absorb a missed tick or two without reverting
// to SSH polling, but short enough that a stuck reporter eventually
// surfaces SSH errors instead of silently masking them.
const freshSelfReport = 30 * time.Second
```

Add the new method (placement: after `cacheLatest`):

```go
// PushSelfMetrics stores a metric snapshot reported by the device itself
// (typically the macOS GUI host POSTing to /api/devices/{id}/metrics).
// The cache slot is shared with SSH-collected metrics — Source on the
// stored value distinguishes the two when GetDeviceMetrics looks up the
// latest cached entry.
func (uc *MonitorUseCase) PushSelfMetrics(m *domain.DeviceMetrics) {
	if m == nil || m.DeviceID == "" {
		return
	}
	uc.latestMu.Lock()
	defer uc.latestMu.Unlock()
	uc.latest[m.DeviceID] = m
}
```

Then modify `GetDeviceMetrics` to prefer fresh self-reports. Replace the existing body:

```go
func (uc *MonitorUseCase) GetDeviceMetrics(ctx context.Context, deviceNameOrID string) (*domain.DeviceMetrics, error) {
	device, err := uc.deviceUC.GetDevice(ctx, deviceNameOrID)
	if err != nil {
		return nil, err
	}

	// Self-reported metrics take precedence when fresh — they describe
	// the GUI host directly, which has no SSH path back to itself.
	if cached := uc.GetLatestCached(device.ID); cached != nil &&
		cached.Source == domain.MetricsSourceSelfReport &&
		time.Since(cached.CollectedAt) < freshSelfReport {
		return cached, nil
	}

	if !device.CanSSH() {
		return &domain.DeviceMetrics{
			DeviceID:    device.ID,
			CollectedAt: time.Now(),
			Error:       "device is offline or SSH is disabled",
		}, nil
	}

	return uc.collector.CollectMetrics(ctx, device)
}
```

`GetLatestCached` already exists (the read-only sibling of `cacheLatest`). Reuse it — don't introduce a parallel cache.

---

- [ ] **Step 2.5: Run tests, expect PASS**

```bash
go test ./internal/usecase/ -run TestMonitorUC -v
```

Expected: 4 tests pass.

---

- [ ] **Step 2.6: Run full usecase test suite**

```bash
go test ./internal/usecase/...
```

Expected: clean. (Existing `TestMonitorUseCase_*` tests, if any, must still pass.)

---

- [ ] **Step 2.7: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add internal/usecase/monitor_usecase.go internal/usecase/monitor_usecase_test.go
git commit -m "feat(metrics): self-report precedence in MonitorUseCase

Adds PushSelfMetrics for handler use and a fresh-self-report fast path
in GetDeviceMetrics — when a self-reported snapshot is < 30s old, it
short-circuits the SSH collector. Stale or absent self-reports fall
through to the existing SSH path unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `POST /api/devices/match` handler

**What:** A new HTTP handler that resolves `{hostname}` to a Tailscale device ID by walking the cached device list. Used by Swift `DeviceIdentity` to obtain the canonical ID once at app launch.

**Files:**
- Create: `internal/web/handler/device_match.go`
- Create: `internal/web/handler/device_match_test.go`
- Modify: `internal/web/handler/handler.go` (route registration only — single line)

---

- [ ] **Step 3.1: Locate where existing `/api/devices/...` routes are registered**

```bash
grep -n "api/devices/:id\|api/devices/:id/capabilities" internal/web/handler/handler.go | head -5
```

Note the line and the surrounding pattern (echo's group + handler binding). You'll insert the new `match` route alongside.

---

- [ ] **Step 3.2: Write failing tests in `internal/web/handler/device_match_test.go`**

Create the file. Use the existing handler-test pattern (search for `httptest.NewRecorder` in `handler_test.go` for shape):

```go
package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
)

// stubMatchDeviceUC is the minimal DeviceUseCase shape APIDeviceMatch needs.
type stubMatchDeviceUC struct {
	devices []*domain.Device
	err     error
}

func (s *stubMatchDeviceUC) ListDevices(ctx context.Context, refresh bool) ([]*domain.Device, error) {
	if s.err != nil {
		return nil, s.err
	}
	return s.devices, nil
}

// matchHandlerForTest constructs a Handler with only the deviceUC dependency
// wired, since APIDeviceMatch only consults that.
func matchHandlerForTest(uc deviceLister) *Handler {
	return &Handler{deviceLister: uc}
}

func TestAPIDeviceMatch_ByHostname(t *testing.T) {
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-pro.tail-net.ts.net"}
	h := matchHandlerForTest(&stubMatchDeviceUC{devices: []*domain.Device{dev}})

	body, _ := json.Marshal(map[string]string{"hostname": "mac-pro.tail-net.ts.net"})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/match", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	if err := h.APIDeviceMatch(c); err != nil {
		t.Fatalf("APIDeviceMatch: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var resp struct {
		DeviceID string `json:"deviceId"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.DeviceID != "dev-1" {
		t.Errorf("deviceId = %q; want dev-1", resp.DeviceID)
	}
}

func TestAPIDeviceMatch_ByIP(t *testing.T) {
	dev := &domain.Device{ID: "dev-1", IPAddresses: []string{"100.64.1.5", "192.168.1.10"}}
	h := matchHandlerForTest(&stubMatchDeviceUC{devices: []*domain.Device{dev}})

	body, _ := json.Marshal(map[string]string{"ip": "100.64.1.5"})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/match", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	if err := h.APIDeviceMatch(c); err != nil {
		t.Fatalf("APIDeviceMatch: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
}

func TestAPIDeviceMatch_BothEmptyReturns400(t *testing.T) {
	h := matchHandlerForTest(&stubMatchDeviceUC{devices: nil})

	body, _ := json.Marshal(map[string]string{})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/match", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	_ = h.APIDeviceMatch(c)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rec.Code)
	}
}

func TestAPIDeviceMatch_NotFoundReturns404(t *testing.T) {
	h := matchHandlerForTest(&stubMatchDeviceUC{devices: []*domain.Device{
		{ID: "dev-1", Hostname: "other-host"},
	}})

	body, _ := json.Marshal(map[string]string{"hostname": "missing-host"})
	req := httptest.NewRequest(http.MethodPost, "/api/devices/match", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)

	_ = h.APIDeviceMatch(c)
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}
```

If `Handler` exposes `deviceUC` rather than `deviceLister`, the test will need a different injection shape. The cleanest fix is to introduce a small `deviceLister` interface on `Handler` for testability — defined in the new file alongside the handler. See Step 3.4.

---

- [ ] **Step 3.3: Run new tests, expect compile failure**

```bash
go test ./internal/web/handler/ -run TestAPIDeviceMatch -v
```

Expected: `undefined: APIDeviceMatch` and (likely) `undefined: deviceLister`.

---

- [ ] **Step 3.4: Implement the handler in `internal/web/handler/device_match.go`**

```go
package handler

import (
	"context"
	"net/http"

	"github.com/labstack/echo/v4"
	"github.com/s1ckdark/hydra/internal/domain"
)

// deviceLister is the minimal DeviceUseCase surface APIDeviceMatch needs.
// Defined here (rather than in handler.go) so the match handler can be
// tested in isolation against a stub without depending on the full UseCase.
type deviceLister interface {
	ListDevices(ctx context.Context, refresh bool) ([]*domain.Device, error)
}

type matchRequest struct {
	Hostname string `json:"hostname,omitempty"`
	IP       string `json:"ip,omitempty"`
}

type matchResponse struct {
	DeviceID string `json:"deviceId"`
}

// APIDeviceMatch resolves a hostname or Tailnet IP to the canonical
// Tailscale device ID. The Swift DeviceIdentity actor calls this once
// per app launch so capability and metric reporters can address the
// same device by a single ID.
//
// Hostname is the strong key — Tailscale hostnames are unique within
// a tailnet. IP is a backup for cases where the caller can't resolve
// its own hostname. At least one is required.
func (h *Handler) APIDeviceMatch(c echo.Context) error {
	var req matchRequest
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid body"})
	}
	if req.Hostname == "" && req.IP == "" {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "hostname or ip required"})
	}

	devices, err := h.deviceLister.ListDevices(c.Request().Context(), false)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}

	for _, d := range devices {
		if req.Hostname != "" && d.Hostname == req.Hostname {
			return c.JSON(http.StatusOK, matchResponse{DeviceID: d.ID})
		}
		if req.IP != "" {
			for _, ip := range d.IPAddresses {
				if ip == req.IP {
					return c.JSON(http.StatusOK, matchResponse{DeviceID: d.ID})
				}
			}
		}
	}
	return c.JSON(http.StatusNotFound, map[string]string{"error": "device not found in tailnet"})
}
```

Then in `internal/web/handler/handler.go`, add a `deviceLister` field to the `Handler` struct (keep the existing `deviceUC` — `deviceLister` is just a typed alias view of it):

```go
// Find the Handler struct definition and add this field at the bottom of
// its declaration list:
deviceLister deviceLister
```

In the constructor (or wherever the Handler is built — search `func NewHandler` or similar), assign:

```go
h.deviceLister = h.deviceUC
```

This works because `*DeviceUseCase` already has a `ListDevices(ctx, bool)` method (verified at `internal/usecase/device_usecase.go:139`).

If `Handler` is constructed without a single constructor (e.g., zero-value + setter pattern via `SetTaskQueue` etc.), find the comparable pattern for `deviceUC` and mirror it for `deviceLister`. Stop and ask if the wiring is non-obvious.

---

- [ ] **Step 3.5: Register the route**

In `internal/web/handler/handler.go`, find where other `/api/devices/...` routes are bound (look for the line that registers `APIRegisterCapabilities`). Add directly after:

```go
e.POST("/api/devices/match", h.APIDeviceMatch)
```

(Echo's `e` may be named `api` or something else depending on local style — match the surrounding lines.)

---

- [ ] **Step 3.6: Run new tests, expect PASS**

```bash
go test ./internal/web/handler/ -run TestAPIDeviceMatch -v
```

Expected: 4 tests pass.

---

- [ ] **Step 3.7: Run full handler test suite**

```bash
go test ./internal/web/handler/...
```

Expected: clean.

---

- [ ] **Step 3.8: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add internal/web/handler/device_match.go internal/web/handler/device_match_test.go internal/web/handler/handler.go
git commit -m "feat(metrics): POST /api/devices/match — resolve hostname/IP → ID

Lets the Swift DeviceIdentity actor call this once at launch to obtain
the canonical Tailscale device ID for both capability and metric
reporting, eliminating the Keychain UUID divergence between the two
reporters. Hostname is the strong key; IP is a backup.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `POST /api/devices/{id}/metrics` handler

**What:** A new HTTP handler that accepts a `DeviceMetrics` payload from the Swift `MetricsReporter` and stores it via `MonitorUseCase.PushSelfMetrics`.

**Files:**
- Modify: `internal/web/handler/handler.go` (new handler method + route)
- Modify: `internal/web/handler/handler_test.go` (test)

---

- [ ] **Step 4.1: Write the failing test**

In `internal/web/handler/handler_test.go`, append:

```go
func TestAPIDeviceMetricsPush_StoresWithSelfSource(t *testing.T) {
	// Arrange: handler with stub deviceLister returning one device,
	// and a real MonitorUseCase whose latest cache we can inspect after
	// the push.
	dev := &domain.Device{ID: "dev-1", Hostname: "mac-1"}
	monitorUC := usecase.NewMonitorUseCase(nil, &stubMetricsCollector{}, nil)
	h := &Handler{
		deviceLister: &stubMatchDeviceUC{devices: []*domain.Device{dev}},
		monitorUC:    monitorUC,
	}

	body := []byte(`{
		"cpu": {"usagePercent": 42},
		"memory": {"totalBytes": 16000000000, "usedBytes": 8000000000, "usagePercent": 50},
		"disk":   {"totalBytes": 500000000000, "availableBytes": 250000000000, "usagePercent": 50}
	}`)
	req := httptest.NewRequest(http.MethodPost, "/api/devices/dev-1/metrics", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("dev-1")

	if err := h.APIDeviceMetricsPush(c); err != nil {
		t.Fatalf("APIDeviceMetricsPush: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}

	cached := monitorUC.GetLatestCached("dev-1")
	if cached == nil {
		t.Fatal("MonitorUseCase did not store the pushed metric")
	}
	if cached.Source != domain.MetricsSourceSelfReport {
		t.Errorf("Source = %q; want self", cached.Source)
	}
	if cached.CPU.UsagePercent != 42 {
		t.Errorf("CPU.UsagePercent = %v; want 42", cached.CPU.UsagePercent)
	}
	if cached.CollectedAt.IsZero() {
		t.Error("CollectedAt should be set server-side")
	}
}

func TestAPIDeviceMetricsPush_404ForUnknownDevice(t *testing.T) {
	monitorUC := usecase.NewMonitorUseCase(nil, &stubMetricsCollector{}, nil)
	h := &Handler{
		deviceLister: &stubMatchDeviceUC{devices: nil},
		monitorUC:    monitorUC,
	}

	body := []byte(`{}`)
	req := httptest.NewRequest(http.MethodPost, "/api/devices/missing/metrics", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := echo.New().NewContext(req, rec)
	c.SetParamNames("id")
	c.SetParamValues("missing")

	_ = h.APIDeviceMetricsPush(c)
	if rec.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rec.Code)
	}
}

// stubMetricsCollector is the minimal MetricsCollector for these tests —
// it never gets called when self-reports take precedence, but the
// MonitorUseCase constructor requires a non-nil one.
type stubMetricsCollector struct{}

func (s *stubMetricsCollector) CollectMetrics(ctx context.Context, d *domain.Device) (*domain.DeviceMetrics, error) {
	return nil, nil
}
func (s *stubMetricsCollector) CollectMetricsParallel(ctx context.Context, devices []*domain.Device) ([]*domain.DeviceMetrics, error) {
	return nil, nil
}
```

If `stubMatchDeviceUC` is in `device_match_test.go` (Task 3) and not visible from `handler_test.go`, both tests are in the same package (`handler`) so the type is shared. If a name collision arises with an existing `stubMetricsCollector`, rename to `pushTestCollector`.

---

- [ ] **Step 4.2: Run, expect compile failure**

```bash
go test ./internal/web/handler/ -run TestAPIDeviceMetricsPush -v
```

Expected: `undefined: APIDeviceMetricsPush`.

---

- [ ] **Step 4.3: Implement the handler in `internal/web/handler/handler.go`**

Add the method (placement: near `APIDeviceMetrics` — search for that name and add directly below):

```go
// APIDeviceMetricsPush accepts a self-reported metric snapshot from the
// device itself. Used by the macOS GUI's MetricsReporter to fill in
// dashboard values for the host running the app, which has no SSH path
// back to itself.
//
// The device ID is validated against the tailnet device list — bogus or
// stale IDs return 404 rather than silently populating the cache.
// Source is set server-side so a malicious or buggy client can't claim
// to be SSH-collected.
func (h *Handler) APIDeviceMetricsPush(c echo.Context) error {
	id := c.Param("id")

	devices, err := h.deviceLister.ListDevices(c.Request().Context(), false)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": err.Error()})
	}
	var dev *domain.Device
	for _, d := range devices {
		if d.ID == id {
			dev = d
			break
		}
	}
	if dev == nil {
		return c.JSON(http.StatusNotFound, map[string]string{"error": "device not found"})
	}

	var payload domain.DeviceMetrics
	if err := c.Bind(&payload); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "invalid metrics payload"})
	}
	payload.DeviceID = dev.ID
	payload.CollectedAt = time.Now()
	payload.Source = domain.MetricsSourceSelfReport

	h.monitorUC.PushSelfMetrics(&payload)
	return c.JSON(http.StatusOK, map[string]bool{"ok": true})
}
```

If `time` isn't imported in handler.go, add it.

---

- [ ] **Step 4.4: Register the route**

Same place as Task 3.5. Add:

```go
e.POST("/api/devices/:id/metrics", h.APIDeviceMetricsPush)
```

---

- [ ] **Step 4.5: Run, expect PASS**

```bash
go test ./internal/web/handler/ -run TestAPIDeviceMetricsPush -v
```

Expected: 2 tests pass.

---

- [ ] **Step 4.6: Run full module tests**

```bash
go test ./...
```

Expected: clean. (Adding a method requires no other changes; this verifies nothing else regressed.)

---

- [ ] **Step 4.7: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add internal/web/handler/handler.go internal/web/handler/handler_test.go
git commit -m "feat(metrics): POST /api/devices/:id/metrics — accept self-reports

Validates the device ID against the tailnet device list, sets
Source=self and CollectedAt server-side, and stores via
MonitorUseCase.PushSelfMetrics. The Swift MetricsReporter calls this
every 5 seconds.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `MetricsSampler` (Swift static syscalls)

**What:** Foundation/Darwin/Metal sampling functions that build the four metric snapshots. Pure data; no networking.

**Files:**
- Create: `Hydra/Hydra/Services/MetricsSampler.swift`
- Create: `Hydra/Tests/MetricsSamplerTests.swift`

---

- [ ] **Step 5.1: Write the failing test**

Create `Hydra/Tests/MetricsSamplerTests.swift`:

```swift
import XCTest
import Foundation
@testable import Hydra

final class MetricsSamplerTests: XCTestCase {
    func testSampleMemory_ReturnsPlausibleValues() {
        let snapshot = MetricsSampler.sampleMemory()
        XCTAssertGreaterThan(snapshot.totalBytes, 0, "totalBytes should be > 0 on any real machine")
        XCTAssertGreaterThan(snapshot.usedBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.usedBytes, snapshot.totalBytes)
        XCTAssertGreaterThanOrEqual(snapshot.usagePercent, 0)
        XCTAssertLessThanOrEqual(snapshot.usagePercent, 100)
    }

    func testSampleDisk_ReturnsPlausibleValues() {
        let snapshot = MetricsSampler.sampleDisk()
        XCTAssertGreaterThan(snapshot.totalBytes, 0, "root volume must report a non-zero capacity")
        XCTAssertLessThanOrEqual(snapshot.availableBytes, snapshot.totalBytes)
    }

    func testSampleCPU_FirstCallReturnsZero() {
        var prev: host_cpu_load_info? = nil
        let snapshot = MetricsSampler.sampleCPU(prev: &prev)
        XCTAssertEqual(snapshot.usagePercent, 0,
                       "first call has no delta; should report 0 rather than NaN/garbage")
        XCTAssertGreaterThan(snapshot.cores, 0, "processorCount > 0 on any real machine")
    }

    func testSampleCPU_SecondCallProducesValidPercent() {
        var prev: host_cpu_load_info? = nil
        _ = MetricsSampler.sampleCPU(prev: &prev)
        // Spin briefly so the next sample sees real ticks
        let deadline = Date().addingTimeInterval(0.1)
        var n = 0
        while Date() < deadline { n += 1 }
        XCTAssertGreaterThan(n, 0)

        let snapshot = MetricsSampler.sampleCPU(prev: &prev)
        XCTAssertGreaterThanOrEqual(snapshot.usagePercent, 0)
        XCTAssertLessThanOrEqual(snapshot.usagePercent, 100)
    }

    #if os(macOS)
    func testSampleGPU_ReturnsNonNilOnAppleSilicon() {
        // Apple Silicon Macs always have Metal. Intel Macs without
        // discrete GPU may return nil — accept that case.
        let snapshot = MetricsSampler.sampleGPU()
        if let s = snapshot {
            XCTAssertFalse(s.name.isEmpty, "GPU name should be populated")
            XCTAssertGreaterThan(s.recommendedWorkingSetBytes, 0)
        }
    }
    #endif
}
```

---

- [ ] **Step 5.2: Run, expect compile failure**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra
swift test --filter MetricsSamplerTests
```

Expected: `cannot find 'MetricsSampler' in scope`.

---

- [ ] **Step 5.3: Create `Hydra/Hydra/Services/MetricsSampler.swift`**

```swift
import Foundation
import Darwin
#if os(macOS)
import Metal
#endif

struct CPUSnapshot {
    let usagePercent: Double
    let cores: Int
    let loadAvg1: Double
    let loadAvg5: Double
    let loadAvg15: Double
}

struct MemorySnapshot {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
    let usagePercent: Double
}

struct DiskSnapshot {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let usagePercent: Double
}

struct GPUSnapshot {
    let name: String
    let recommendedWorkingSetBytes: UInt64
    let isLowPower: Bool
}

/// Pure-function metric samplers. No state — `sampleCPU` requires the
/// caller to hold the previous tick snapshot for delta computation.
enum MetricsSampler {

    static func sampleCPU(prev: inout host_cpu_load_info?) -> CPUSnapshot {
        var info = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kern == KERN_SUCCESS else {
            return CPUSnapshot(usagePercent: 0,
                               cores: ProcessInfo.processInfo.processorCount,
                               loadAvg1: 0, loadAvg5: 0, loadAvg15: 0)
        }

        // Compute delta against prev. First call has no prev → 0%.
        var usage = 0.0
        if let p = prev {
            let userDelta = Double(info.cpu_ticks.0 &- p.cpu_ticks.0)
            let sysDelta  = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
            let idleDelta = Double(info.cpu_ticks.2 &- p.cpu_ticks.2)
            let niceDelta = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
            let total = userDelta + sysDelta + idleDelta + niceDelta
            if total > 0 {
                usage = (userDelta + sysDelta + niceDelta) / total * 100.0
            }
        }
        prev = info

        var loadInfo = [Double](repeating: 0, count: 3)
        getloadavg(&loadInfo, 3)

        return CPUSnapshot(
            usagePercent: usage,
            cores: ProcessInfo.processInfo.processorCount,
            loadAvg1: loadInfo[0],
            loadAvg5: loadInfo[1],
            loadAvg15: loadInfo[2]
        )
    }

    static func sampleMemory() -> MemorySnapshot {
        let total = ProcessInfo.processInfo.physicalMemory  // bytes

        var info = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard kern == KERN_SUCCESS else {
            return MemorySnapshot(totalBytes: total, usedBytes: 0, freeBytes: total, usagePercent: 0)
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(info.free_count) * pageSize
        let active = UInt64(info.active_count) * pageSize
        let inactive = UInt64(info.inactive_count) * pageSize
        let wired = UInt64(info.wire_count) * pageSize
        let compressed = UInt64(info.compressor_page_count) * pageSize
        let used = active + inactive + wired + compressed
        let percent = total > 0 ? Double(used) / Double(total) * 100.0 : 0
        return MemorySnapshot(totalBytes: total, usedBytes: used, freeBytes: free, usagePercent: percent)
    }

    static func sampleDisk() -> DiskSnapshot {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let avail = values.volumeAvailableCapacityForImportantUsage else {
            return DiskSnapshot(totalBytes: 0, availableBytes: 0, usagePercent: 0)
        }
        let used = UInt64(total) - UInt64(avail)
        let percent = total > 0 ? Double(used) / Double(total) * 100.0 : 0
        return DiskSnapshot(totalBytes: UInt64(total), availableBytes: UInt64(avail), usagePercent: percent)
    }

    #if os(macOS)
    static func sampleGPU() -> GPUSnapshot? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return GPUSnapshot(
            name: device.name,
            recommendedWorkingSetBytes: UInt64(device.recommendedMaxWorkingSetSize),
            isLowPower: device.isLowPower
        )
    }
    #else
    static func sampleGPU() -> GPUSnapshot? { nil }
    #endif
}
```

---

- [ ] **Step 5.4: Run, expect PASS**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra
swift test --filter MetricsSamplerTests
```

Expected: 4-5 tests pass (5 on Apple Silicon, 4 on Intel without GPU).

---

- [ ] **Step 5.5: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add Hydra/Hydra/Services/MetricsSampler.swift Hydra/Tests/MetricsSamplerTests.swift
git commit -m "feat(metrics): MetricsSampler — Foundation/Darwin/Metal samplers

Pure-function samplers for CPU usage (host_statistics + delta against
prev tick), memory (vm_statistics64 + ProcessInfo.physicalMemory),
disk (URLResourceKey on root volume), and GPU static info (Metal
MTLDevice properties — name + recommendedMaxWorkingSetSize). No live
GPU utilisation since Apple offers no public API for that.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `DeviceIdentity` actor

**What:** A Swift actor that resolves the local Mac's Tailscale device ID once via `POST /api/devices/match` (hostname only) and caches it for the rest of the session. Both `CapabilityReporter` and `MetricsReporter` consume it.

**Files:**
- Create: `Hydra/Hydra/Services/DeviceIdentity.swift`
- Create: `Hydra/Tests/DeviceIdentityTests.swift`

---

- [ ] **Step 6.1: Write the failing test**

Create `Hydra/Tests/DeviceIdentityTests.swift`:

```swift
import XCTest
@testable import Hydra

final class DeviceIdentityTests: XCTestCase {
    func testCurrent_CachesAfterFirstResolve() async {
        let stub = StubMatchClient()
        stub.canned = "dev-A"
        let identity = DeviceIdentity()

        let id1 = await identity.current(via: stub)
        let id2 = await identity.current(via: stub)
        XCTAssertEqual(id1, "dev-A")
        XCTAssertEqual(id2, "dev-A")
        XCTAssertEqual(stub.calls, 1, "second call should be served from cache")
    }

    func testCurrent_ReturnsNilWhenMatchFails_DoesNotCache() async {
        let stub = StubMatchClient()
        stub.shouldFail = true
        let identity = DeviceIdentity()

        let id1 = await identity.current(via: stub)
        XCTAssertNil(id1, "failed match should not return an ID")

        // Recover and try again — should hit the network again, not stay nil.
        stub.shouldFail = false
        stub.canned = "dev-A"
        let id2 = await identity.current(via: stub)
        XCTAssertEqual(id2, "dev-A")
        XCTAssertEqual(stub.calls, 2, "failure should not be cached; second call must hit network")
    }
}

/// StubMatchClient implements only the surface DeviceIdentity needs.
final class StubMatchClient: DeviceMatchClient {
    var canned: String = ""
    var shouldFail = false
    var calls = 0
    func matchDevice(hostname: String, ip: String?) async throws -> String {
        calls += 1
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return canned
    }
}
```

---

- [ ] **Step 6.2: Run, expect compile failure**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra
swift test --filter DeviceIdentityTests
```

Expected: `cannot find 'DeviceIdentity' / 'DeviceMatchClient' in scope`.

---

- [ ] **Step 6.3: Create `Hydra/Hydra/Services/DeviceIdentity.swift`**

```swift
import Foundation

/// The minimal client surface DeviceIdentity needs. APIClient conforms
/// to this; tests inject a fake.
protocol DeviceMatchClient {
    func matchDevice(hostname: String, ip: String?) async throws -> String
}

/// Resolves the local device's canonical Tailscale ID once per session.
///
/// Hostname is the strong key — Tailscale hostnames are unique within a
/// tailnet. We deliberately don't pass an IP here: discovering the
/// machine's Tailnet IP from Swift would require walking utun
/// interfaces, which adds complexity for diminishing returns. If
/// hostname lookup fails (404), the reporter logs and stops; that's a
/// preferable failure mode to silently mis-identifying a device by IP.
actor DeviceIdentity {
    static let shared = DeviceIdentity()
    private var cached: String?

    /// Returns the resolved device ID, or nil on failure. Failures are
    /// not cached, so the next call retries — a temporary network
    /// hiccup at launch shouldn't keep the reporter dormant for the
    /// whole session.
    func current(via client: DeviceMatchClient) async -> String? {
        if let id = cached { return id }
        let hostname = ProcessInfo.processInfo.hostName
        do {
            let id = try await client.matchDevice(hostname: hostname, ip: nil)
            cached = id
            return id
        } catch {
            NSLog("[DeviceIdentity] hostname=%@ resolve failed: %@", hostname, "\(error)")
            return nil
        }
    }
}
```

---

- [ ] **Step 6.4: Run, expect PASS**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra
swift test --filter DeviceIdentityTests
```

Expected: 2 tests pass.

---

- [ ] **Step 6.5: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add Hydra/Hydra/Services/DeviceIdentity.swift Hydra/Tests/DeviceIdentityTests.swift
git commit -m "feat(metrics): DeviceIdentity actor caches resolved Tailscale ID

CapabilityReporter and MetricsReporter both await this actor's
current(via:) once per session to obtain the canonical Tailscale
device ID via POST /api/devices/match. Hostname is the strong key;
IP lookup is skipped since walking utun interfaces from Swift adds
complexity for diminishing returns. Failures are not cached so a
network hiccup at launch doesn't keep the reporter dormant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `APIClient.matchDevice` + `APIClient.postMetrics`

**What:** Two thin HTTP wrappers on the existing `APIClient`. No new abstractions — match the existing method-per-endpoint style.

**Files:**
- Modify: `Hydra/Hydra/Services/APIClient.swift`

This task has no dedicated unit test — the wrappers are thin and their wire format is verified end-to-end by the manual smoke test in Task 10. The compile guarantee plus `DeviceIdentity` conformance to `DeviceMatchClient` (Task 6) is sufficient TDD coverage.

---

- [ ] **Step 7.1: Locate the existing `registerCapabilities` method to mirror its shape**

```bash
grep -nA 10 "func registerCapabilities" /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra/Hydra/Services/APIClient.swift
```

Note the JSON encode + URL build + post pattern. The new methods follow the same shape.

---

- [ ] **Step 7.2: Add an extension that conforms `APIClient` to `DeviceMatchClient` and adds `postMetrics`**

In `Hydra/Hydra/Services/APIClient.swift`, append at the bottom of the file:

```swift
// MARK: - Device match + self-reported metrics

extension APIClient: DeviceMatchClient {
    private struct MatchRequest: Encodable {
        let hostname: String
        let ip: String?
    }
    private struct MatchResponse: Decodable {
        let deviceId: String
    }

    func matchDevice(hostname: String, ip: String?) async throws -> String {
        let body = try JSONEncoder().encode(MatchRequest(hostname: hostname, ip: ip))
        let url = baseURL.appendingPathComponent("/api/devices/match")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoded = try JSONDecoder().decode(MatchResponse.self, from: data)
        return decoded.deviceId
    }

    func postMetrics(deviceID: String, payload: DeviceMetricsPayload) async throws {
        let url = baseURL.appendingPathComponent("/api/devices/\(deviceID)/metrics")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}

// DeviceMetricsPayload is the JSON shape MetricsReporter sends. Field
// names match the server's domain.DeviceMetrics so a CodingKeys map
// isn't needed — just conform to Encodable.
struct DeviceMetricsPayload: Encodable {
    struct CPUPayload: Encodable {
        let usagePercent: Double
        let cores: Int
        let loadAvg1: Double
        let loadAvg5: Double
        let loadAvg15: Double
    }
    struct MemoryPayload: Encodable {
        let total: UInt64
        let used: UInt64
        let free: UInt64
        let usagePercent: Double
    }
    struct DiskPayload: Encodable {
        let total: UInt64
        let available: UInt64
        let usagePercent: Double
    }
    struct GPUPayload: Encodable {
        let name: String
        let memoryBudgetBytes: UInt64
        let isLowPower: Bool
    }
    let cpu: CPUPayload
    let memory: MemoryPayload
    let disk: DiskPayload
    let gpu: GPUPayload?
}
```

If `APIError`, `baseURL`, or the existing pattern uses different names, mirror what `registerCapabilities` does — consistency with the existing surface beats stylistic preference. If the existing pattern uses `URLSession.shared.data(from:)` instead of `data(for:)`, match that.

---

- [ ] **Step 7.3: Verify compile**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra
swift build
```

Expected: clean build.

---

- [ ] **Step 7.4: Verify test compile (no new tests, but ensure existing ones still build)**

```bash
swift test --filter DeviceIdentityTests
```

Expected: 2 tests still pass — `APIClient` extension makes `DeviceIdentity` injectable with the real client at runtime, while tests continue to use `StubMatchClient`.

---

- [ ] **Step 7.5: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add Hydra/Hydra/Services/APIClient.swift
git commit -m "feat(metrics): APIClient.matchDevice + postMetrics

Thin wrappers on the existing APIClient — match the registerCapabilities
shape. APIClient now conforms to DeviceMatchClient so DeviceIdentity
can take it directly. DeviceMetricsPayload mirrors the server-side
domain.DeviceMetrics field names so no CodingKeys translation is
needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `MetricsReporter`

**What:** A 5-second timer that samples local metrics and POSTs them. Coordinates with `DeviceIdentity` for the device ID.

**Files:**
- Create: `Hydra/Hydra/Services/MetricsReporter.swift`

No dedicated test — the timer behavior is hard to unit test reliably (timing-sensitive), and the underlying components (`MetricsSampler`, `DeviceIdentity`, `APIClient.postMetrics`) are individually covered. End-to-end verification happens in Task 10's smoke test.

---

- [ ] **Step 8.1: Create `Hydra/Hydra/Services/MetricsReporter.swift`**

```swift
import Foundation
import Darwin

/// Periodically samples local CPU/memory/disk/GPU and POSTs the snapshot
/// to /api/devices/{id}/metrics so the dashboard panels for the GUI
/// host fill in. Bypasses the SSH metrics path that would otherwise
/// require the server to ssh-into-self.
@MainActor
final class MetricsReporter {
    static let shared = MetricsReporter()
    private var task: Task<Void, Never>?
    private var prevCPU: host_cpu_load_info?

    /// Starts the 5-second reporting loop. Idempotent — calling start()
    /// twice cancels the previous loop first.
    func start(via client: APIClient) {
        task?.cancel()
        prevCPU = nil
        task = Task.detached { [weak self] in
            guard let self else { return }
            // Seed prevCPU so the first reported sample isn't a 0%
            // misread. The seed itself is discarded.
            await self.seedCPU()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                await self.tick(via: client)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func seedCPU() async {
        var seed: host_cpu_load_info? = nil
        _ = MetricsSampler.sampleCPU(prev: &seed)
        await MainActor.run { self.prevCPU = seed }
    }

    private func tick(via client: APIClient) async {
        guard let id = await DeviceIdentity.shared.current(via: client) else {
            // Identity not yet resolved — try again next tick. No log
            // spam: DeviceIdentity already logs once on each failure.
            return
        }

        let cpu = await MainActor.run { () -> CPUSnapshot in
            return MetricsSampler.sampleCPU(prev: &self.prevCPU)
        }
        let memory = MetricsSampler.sampleMemory()
        let disk = MetricsSampler.sampleDisk()
        let gpu = MetricsSampler.sampleGPU()

        let payload = DeviceMetricsPayload(
            cpu: .init(
                usagePercent: cpu.usagePercent,
                cores: cpu.cores,
                loadAvg1: cpu.loadAvg1,
                loadAvg5: cpu.loadAvg5,
                loadAvg15: cpu.loadAvg15
            ),
            memory: .init(
                total: memory.totalBytes,
                used: memory.usedBytes,
                free: memory.freeBytes,
                usagePercent: memory.usagePercent
            ),
            disk: .init(
                total: disk.totalBytes,
                available: disk.availableBytes,
                usagePercent: disk.usagePercent
            ),
            gpu: gpu.map {
                .init(name: $0.name,
                      memoryBudgetBytes: $0.recommendedWorkingSetBytes,
                      isLowPower: $0.isLowPower)
            }
        )

        do {
            try await client.postMetrics(deviceID: id, payload: payload)
        } catch {
            // Best-effort. Server unreachable / transient errors fall
            // through to the next tick.
            NSLog("[MetricsReporter] postMetrics failed: %@", "\(error)")
        }
    }
}
```

---

- [ ] **Step 8.2: Verify compile**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra
swift build
```

Expected: clean.

---

- [ ] **Step 8.3: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add Hydra/Hydra/Services/MetricsReporter.swift
git commit -m "feat(metrics): MetricsReporter — 5s sampling loop

Detached Task drives a 5-second loop that samples CPU/memory/disk/GPU,
resolves the device ID via DeviceIdentity, and POSTs the snapshot.
Seeded prevCPU avoids the first-tick 0% misread. start() is idempotent
so HydraApp can call it from .task without worrying about reentry.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `CapabilityReporter` migration to `DeviceIdentity`

**What:** Switch `CapabilityReporter.report(via:)` to use `DeviceIdentity.shared.current(via:)` for the device ID, instead of the Keychain UUID. The Keychain UUID code stays in place (deprecated, follow-up retires it) so existing per-device state on disk isn't disturbed.

**Files:**
- Modify: `Hydra/Hydra/Services/CapabilityReporter.swift`

---

- [ ] **Step 9.1: Read the existing `report(via:)` method**

```bash
grep -nA 30 "func report" /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra/Hydra/Services/CapabilityReporter.swift
```

Note where `self.deviceID` is referenced inside the method — that's what changes.

---

- [ ] **Step 9.2: Replace the body of `report(via:)`**

Find the line in `report(via apiClient: APIClient)` that calls `apiClient.registerCapabilities(deviceID: self.deviceID, capabilities: ...)`.

Replace `self.deviceID` with the resolved Tailscale ID:

```swift
// Was: apiClient.registerCapabilities(deviceID: self.deviceID, ...)
// Now:
guard let resolvedID = await DeviceIdentity.shared.current(via: apiClient) else {
    NSLog("[CapabilityReporter] device identity not resolved; skipping capability report")
    return
}
// ... existing retry loop, but pass resolvedID instead of self.deviceID:
try await apiClient.registerCapabilities(deviceID: resolvedID, capabilities: caps)
```

Add a `// TODO(uuid-retirement)` line above the `init()` body's Keychain UUID resolution so the next pass over this file finds it.

---

- [ ] **Step 9.3: Verify compile**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra
swift build
swift test
```

Expected: clean build, all existing tests pass.

---

- [ ] **Step 9.4: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add Hydra/Hydra/Services/CapabilityReporter.swift
git commit -m "refactor(capabilities): use DeviceIdentity for POST target

CapabilityReporter.report() now resolves the device ID via
DeviceIdentity.shared instead of its Keychain UUID, so capabilities
and metrics share one canonical Tailscale ID. The Keychain UUID code
in init() stays (marked TODO(uuid-retirement)) — a follow-up PR will
migrate any leftover per-device override state and remove it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Wire `MetricsReporter.start` in `HydraApp.swift` + smoke test

**What:** Start the metrics reporter alongside the capabilities report at app launch. Manual verification via the smoke test from the spec.

**Files:**
- Modify: `Hydra/Hydra/HydraApp.swift`

---

- [ ] **Step 10.1: Locate the existing `reportCapabilities` `.task` site**

```bash
grep -nB 1 -A 5 "reportCapabilities\|setupCapabilities" /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics/Hydra/Hydra/HydraApp.swift
```

Note the `.task` modifier that calls `await reportCapabilities()`.

---

- [ ] **Step 10.2: Wire MetricsReporter.start**

In `HydraApp.swift`, find the `.task` block that runs at WindowGroup root:

```swift
.task {
    await autoDiscoverServer()
    await reportCapabilities()
}
```

Modify to also start the metrics reporter on macOS:

```swift
.task {
    await autoDiscoverServer()
    await reportCapabilities()
    #if os(macOS)
    MetricsReporter.shared.start(via: APIClient.shared)
    #endif
}
```

`MetricsReporter` is `@MainActor`-isolated, so the call is implicitly main-actor-safe.

---

- [ ] **Step 10.3: Build the .app bundle**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
make hydra-app
```

Expected: Build complete; `.app` bundle at `Hydra/.build/arm64-apple-macosx/release/Hydra.app`.

---

- [ ] **Step 10.4: Manual smoke test**

1. Kill any running Hydra: `killall Hydra 2>/dev/null`
2. Start the server (from another terminal at the worktree root):
   ```bash
   make build
   ./bin/server
   ```
   Confirm Tailscale is active: `tailscale status` should list this Mac.
3. Launch the app:
   ```bash
   open Hydra/.build/arm64-apple-macosx/release/Hydra.app
   ```
4. In the dashboard, find the entry for this Mac (its Tailscale hostname).
5. Click into detail. Within ~10 seconds, the CPU bar, RAM bar, and disk bar should all show non-zero values; the GPU row should show "Apple M1 Max" (or the local GPU name) plus a memory budget. **The handshake-error banner that previously appeared for this device should be gone.**
6. Open another tab or run `stress -c 4` — the CPU bar should rise on the next 5-second tick.
7. Server log should show 5-second-interval lines like `POST /api/devices/.../metrics 200`.
8. Direct verification:
   ```bash
   DEV_ID=$(curl -s -X POST http://localhost:8080/api/devices/match \
     -H 'content-type: application/json' \
     -d "{\"hostname\":\"$(hostname)\"}" | jq -r .deviceId)
   curl -s "http://localhost:8080/api/devices/$DEV_ID/metrics" | jq '.source, .cpu.usagePercent, .memory.usagePercent'
   ```
   Expected: `"self"`, two non-zero numbers.

---

- [ ] **Step 10.5: Commit**

```bash
cd /Users/dave/iWorks/hydra/.claude/worktrees/macos-self-metrics
git add Hydra/Hydra/HydraApp.swift
git commit -m "feat(metrics): start MetricsReporter at app launch on macOS

After capability report and server discovery, kick off the 5-second
self-reporting loop. iOS path unchanged — MetricsReporter is macOS
only for now (iOS battery/thermal surfaced through DeviceMetrics is
a follow-up).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## File map (summary)

| File | Action | Approx LoC |
|---|---|---|
| `internal/domain/metrics.go` | modify (add type + field) | +12 |
| `internal/usecase/monitor_usecase.go` | modify (PushSelfMetrics + GetDeviceMetrics branch) | +30 |
| `internal/usecase/monitor_usecase_test.go` | new tests | +110 |
| `internal/web/handler/device_match.go` | create | +60 |
| `internal/web/handler/device_match_test.go` | create | +110 |
| `internal/web/handler/handler.go` | modify (handler + 2 routes) | +50 |
| `internal/web/handler/handler_test.go` | new tests | +90 |
| `Hydra/Hydra/Services/MetricsSampler.swift` | create | +130 |
| `Hydra/Hydra/Services/DeviceIdentity.swift` | create | +35 |
| `Hydra/Hydra/Services/MetricsReporter.swift` | create | +85 |
| `Hydra/Hydra/Services/APIClient.swift` | modify (extension + payload type) | +75 |
| `Hydra/Hydra/Services/CapabilityReporter.swift` | modify (one method body) | +5 −3 |
| `Hydra/Hydra/HydraApp.swift` | modify (one line in .task) | +3 |
| `Hydra/Tests/MetricsSamplerTests.swift` | create | +60 |
| `Hydra/Tests/DeviceIdentityTests.swift` | create | +50 |

Net: ~+625 LoC production + tests across 10 commits.
