package usecase

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/repository"
)

// MonitorUseCase handles monitoring-related business logic
type MonitorUseCase struct {
	repos     *repository.Repositories
	collector MetricsCollector
	deviceUC  *DeviceUseCase

	latestMu sync.RWMutex
	latest   map[string]*domain.DeviceMetrics
}

// NewMonitorUseCase creates a new MonitorUseCase
func NewMonitorUseCase(repos *repository.Repositories, collector MetricsCollector, deviceUC *DeviceUseCase) *MonitorUseCase {
	return &MonitorUseCase{
		repos:     repos,
		collector: collector,
		deviceUC:  deviceUC,
		latest:    make(map[string]*domain.DeviceMetrics),
	}
}

// GetLatestCached returns the most recently collected metrics for a device
// from the background collection loop, or nil if none are cached yet.
// Reads are lock-free fast path for schedulers that tick more often than
// the collection interval.
func (uc *MonitorUseCase) GetLatestCached(deviceID string) *domain.DeviceMetrics {
	uc.latestMu.RLock()
	defer uc.latestMu.RUnlock()
	return uc.latest[deviceID]
}

func (uc *MonitorUseCase) cacheLatest(snapshot *domain.MetricsSnapshot) {
	uc.latestMu.Lock()
	defer uc.latestMu.Unlock()
	for id, m := range snapshot.Devices {
		uc.latest[id] = m
	}
}

// freshSelfReport is the maximum age of a self-reported metrics snapshot
// for it to take precedence over SSH-collected metrics. Sized at 6× the
// 5-second push cadence to absorb a missed tick or two without reverting
// to SSH polling, but short enough that a stuck reporter eventually
// surfaces SSH errors instead of silently masking them.
const freshSelfReport = 30 * time.Second

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

// MarkReachable records a fresh "this device responded just now" signal
// without a full metrics payload. Used by lightweight probes (the GPU
// monitor's nvidia-smi call, future ping checks, etc.) so device-list
// freshness consumers can promote the device to online before the slower
// background SSH cycle finishes a full sweep.
//
// A reachability mark must never downgrade a stronger signal: if a recent
// SSH or self-report metric already lives in the cache, leave it alone.
// Otherwise the 15s reachability probe would clobber the 30s SSH success
// between cycles, causing the status indicator to flicker every interval
// (the freshness-promotion rule in APIDeviceList ignores Reachability-
// source entries — see MetricsSourceReachability).
func (uc *MonitorUseCase) MarkReachable(deviceID string, source domain.MetricsSource) {
	if deviceID == "" {
		return
	}
	uc.latestMu.Lock()
	defer uc.latestMu.Unlock()
	if source == domain.MetricsSourceReachability {
		if existing, ok := uc.latest[deviceID]; ok &&
			existing != nil &&
			existing.Source != domain.MetricsSourceReachability &&
			existing.Error == "" &&
			time.Since(existing.CollectedAt) < 2*time.Minute {
			return
		}
	}
	uc.latest[deviceID] = &domain.DeviceMetrics{
		DeviceID:    deviceID,
		CollectedAt: time.Now(),
		Source:      source,
	}
}

// GetDeviceMetrics gets the current metrics for a device
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
		// Tailscale's view of `status` can lag reality — a host that
		// stops heartbeating but remains SSH-reachable still gets
		// reported as offline. ANY fresh error-free signal in the
		// cache (probe, SSH, or self-report) is enough to attempt
		// a live collection: probe alone proves the network path
		// works, and if the SSH path itself is broken the collector
		// will return a concrete error that surfaces here.
		const liveAttemptWindow = 2 * time.Minute
		cached := uc.GetLatestCached(device.ID)
		hasFreshSignal := cached != nil && cached.Error == "" &&
			time.Since(cached.CollectedAt) < liveAttemptWindow &&
			device.SSHEnabled
		if !hasFreshSignal {
			return &domain.DeviceMetrics{
				DeviceID:    device.ID,
				CollectedAt: time.Now(),
				Error:       "device is offline or SSH is disabled",
			}, nil
		}
		// Coerce status to online for the collector — copy first so we
		// don't mutate the Tailscale-returned struct that GetDevice may
		// have handed us by reference from the cache.
		promoted := *device
		promoted.Status = domain.DeviceStatusOnline
		device = &promoted
	}

	m, err := uc.collector.CollectMetrics(ctx, device)
	if err == nil && m != nil && m.Error == "" {
		// Tag the source so APIDeviceList's freshness-promotion rule
		// can distinguish a real metric from a probe entry, and cache
		// it so the next /api/devices call promotes status without
		// waiting for the next background collector tick.
		m.Source = domain.MetricsSourceSSH
		uc.latestMu.Lock()
		uc.latest[device.ID] = m
		uc.latestMu.Unlock()
	}
	return m, err
}

// refreshAllDeadline caps how long a user-triggered refresh can take
// before we return whatever we have. SSH collection against a host with
// dead sshd can hang for 30s+ per device; without a ceiling the toolbar
// button would freeze the UI for minutes. Anything slower than this
// will resolve later via background collection.
const refreshAllDeadline = 8 * time.Second

// RefreshAll runs a synchronous probe + collection pass against every
// known device and caches what finishes in time. Used by the user-
// triggered refresh (toolbar button) so an "is the iMac back?" check
// doesn't have to wait for the next background tick. Capped at
// refreshAllDeadline — slow hosts get caught by the next background
// pass instead of stalling the response.
func (uc *MonitorUseCase) RefreshAll(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, refreshAllDeadline)
	defer cancel()

	devices, err := uc.deviceUC.ListDevices(ctx, false)
	if err != nil {
		return
	}
	// Phase 1: parallel TCP :22 probe. Cheap (1.5s timeout per device).
	var probeWg sync.WaitGroup
	for _, d := range devices {
		if d.TailscaleIP == "" {
			continue
		}
		probeWg.Add(1)
		go func(deviceID, ip string) {
			defer probeWg.Done()
			conn, err := net.DialTimeout("tcp", net.JoinHostPort(ip, "22"), 1500*time.Millisecond)
			if err != nil {
				return
			}
			conn.Close()
			uc.MarkReachable(deviceID, domain.MetricsSourceReachability)
		}(d.ID, d.TailscaleIP)
	}
	probeWg.Wait()

	// Phase 2: full metrics collection. GetAllMetrics now picks up
	// probe-reachable devices in addition to Tailscale-online ones, so
	// a host that Tailscale incorrectly thinks is offline will still
	// get attempted — and on success, the resulting non-reachability
	// metric promotes its status in the next /api/devices response.
	// We run the collection in a goroutine so the deadline can force
	// us to return even if a stuck SSH dial is still pending; partial
	// results that did arrive are cached before we bail.
	done := make(chan *domain.MetricsSnapshot, 1)
	go func() {
		snapshot, err := uc.GetAllMetrics(ctx)
		if err != nil || snapshot == nil {
			done <- nil
			return
		}
		done <- snapshot
	}()
	select {
	case snapshot := <-done:
		if snapshot != nil {
			uc.cacheLatest(snapshot)
		}
	case <-ctx.Done():
		// Deadline hit — abandon the collection goroutine (it will
		// finish in the background eventually) and return so the
		// API response can go out promptly.
	}
}

// GetAllMetrics gets metrics for all online devices
func (uc *MonitorUseCase) GetAllMetrics(ctx context.Context) (*domain.MetricsSnapshot, error) {
	devices, err := uc.deviceUC.ListDevices(ctx, false)
	if err != nil {
		return nil, err
	}

	// Collect metrics from SSH-enabled devices that either Tailscale says
	// are online OR the reachability probe has recently confirmed are
	// reachable on :22. Tailscale's `status` can lag reality — a host
	// that stopped heartbeating but still answers SSH is a real candidate
	// for collection, and the resulting non-reachability metric is what
	// then promotes its status back to online via the source-gated rule
	// in APIDeviceList.
	const reachabilityWindow = 2 * time.Minute
	var sshDevices []*domain.Device
	for _, d := range devices {
		if !d.SSHEnabled {
			continue
		}
		if d.CanSSH() {
			sshDevices = append(sshDevices, d)
			continue
		}
		cached := uc.GetLatestCached(d.ID)
		if cached != nil && cached.Error == "" &&
			time.Since(cached.CollectedAt) < reachabilityWindow {
			// Coerce to online for the collector pass — the original
			// device object stays untouched (ListDevices returns the
			// cache backing array, mutating it would leak elsewhere).
			promoted := *d
			promoted.Status = domain.DeviceStatusOnline
			sshDevices = append(sshDevices, &promoted)
		}
	}

	snapshot := &domain.MetricsSnapshot{
		Devices:     make(map[string]*domain.DeviceMetrics),
		CollectedAt: time.Now(),
	}

	if len(sshDevices) == 0 {
		return snapshot, nil
	}

	metrics, err := uc.collector.CollectMetricsParallel(ctx, sshDevices)
	if err != nil {
		return nil, err
	}
	// Tag the source so freshness-promotion in APIDeviceList can
	// distinguish a real SSH metric from a probe-only entry.
	for _, m := range metrics {
		if m != nil && m.Error == "" {
			m.Source = domain.MetricsSourceSSH
		}
	}

	for _, m := range metrics {
		snapshot.Devices[m.DeviceID] = m
	}

	return snapshot, nil
}

// GetOrchMetrics gets metrics for all nodes in a orch
func (uc *MonitorUseCase) GetOrchMetrics(ctx context.Context, orch *domain.Orch) (*domain.MetricsSnapshot, error) {
	deviceMap, err := uc.deviceUC.GetDeviceMap(ctx)
	if err != nil {
		return nil, err
	}

	// Get devices for this orch
	var orchDevices []*domain.Device
	for _, nodeID := range orch.AllNodeIDs() {
		if device, ok := deviceMap[nodeID]; ok && device.CanSSH() {
			orchDevices = append(orchDevices, device)
		}
	}

	snapshot := &domain.MetricsSnapshot{
		Devices:     make(map[string]*domain.DeviceMetrics),
		CollectedAt: time.Now(),
	}

	if len(orchDevices) == 0 {
		return snapshot, nil
	}

	metrics, err := uc.collector.CollectMetricsParallel(ctx, orchDevices)
	if err != nil {
		return nil, err
	}

	for _, m := range metrics {
		snapshot.Devices[m.DeviceID] = m
	}

	return snapshot, nil
}

// SaveMetrics saves metrics to the repository
func (uc *MonitorUseCase) SaveMetrics(ctx context.Context, metrics *domain.DeviceMetrics) error {
	if uc.repos == nil || uc.repos.Metrics == nil {
		return nil
	}
	return uc.repos.Metrics.Save(ctx, metrics)
}

// GetMetricsHistory gets historical metrics for a device
func (uc *MonitorUseCase) GetMetricsHistory(ctx context.Context, deviceID string, limit int) (*domain.MetricsHistory, error) {
	if uc.repos == nil || uc.repos.Metrics == nil {
		return &domain.MetricsHistory{DeviceID: deviceID}, nil
	}
	return uc.repos.Metrics.GetHistory(ctx, deviceID, limit)
}

// StartReachabilityProbe runs a lightweight TCP :22 connect against every
// known device on each tick and marks reachable hosts in the freshness
// cache. Cheap (parallel, 1s timeout per device) so it can run on a
// short interval and keep the menu-bar device count accurate even when
// the full SSH metric collector is slow or the Tailscale API is broken.
// SSH-disabled devices (iOS) will always look offline through this path;
// they need a separate self-report channel to be counted as alive.
func (uc *MonitorUseCase) StartReachabilityProbe(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			devices, err := uc.deviceUC.ListDevices(ctx, false)
			if err != nil {
				continue
			}
			var wg sync.WaitGroup
			for _, d := range devices {
				addr := d.TailscaleIP
				if addr == "" {
					continue
				}
				wg.Add(1)
				go func(deviceID, ip string) {
					defer wg.Done()
					conn, err := net.DialTimeout("tcp", net.JoinHostPort(ip, "22"), time.Second)
					if err != nil {
						return
					}
					conn.Close()
					uc.MarkReachable(deviceID, domain.MetricsSourceReachability)
				}(d.ID, addr)
			}
			wg.Wait()
		}
	}
}

// StartBackgroundCollection starts background metrics collection
func (uc *MonitorUseCase) StartBackgroundCollection(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			snapshot, err := uc.GetAllMetrics(ctx)
			if err != nil {
				continue
			}

			uc.cacheLatest(snapshot)

			// Save all metrics
			for _, m := range snapshot.Devices {
				uc.SaveMetrics(ctx, m)
			}
		}
	}
}
