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
func (uc *MonitorUseCase) MarkReachable(deviceID string, source domain.MetricsSource) {
	if deviceID == "" {
		return
	}
	uc.latestMu.Lock()
	defer uc.latestMu.Unlock()
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
		// Tailscale's view of a device's `status` can lag reality — a host
		// that stops heartbeating but remains SSH-reachable still gets
		// reported as offline. We only override that opinion when a *real*
		// metrics collection (SSH or self-report) recently succeeded —
		// reachability-only entries are too weak a signal to claim the
		// device is online. This is the metrics-endpoint counterpart of
		// the source-gated promotion in APIDeviceList.
		const realMetricWindow = 2 * time.Minute
		cached := uc.GetLatestCached(device.ID)
		hasRealHit := cached != nil && cached.Error == "" &&
			cached.Source != domain.MetricsSourceReachability &&
			time.Since(cached.CollectedAt) < realMetricWindow &&
			device.SSHEnabled
		if !hasRealHit {
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

	return uc.collector.CollectMetrics(ctx, device)
}

// GetAllMetrics gets metrics for all online devices
func (uc *MonitorUseCase) GetAllMetrics(ctx context.Context) (*domain.MetricsSnapshot, error) {
	devices, err := uc.deviceUC.ListDevices(ctx, false)
	if err != nil {
		return nil, err
	}

	// Filter to online devices with SSH
	var sshDevices []*domain.Device
	for _, d := range devices {
		if d.CanSSH() {
			sshDevices = append(sshDevices, d)
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
