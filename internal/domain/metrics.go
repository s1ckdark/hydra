package domain

import "time"

// CPUMetrics represents CPU usage information
type CPUMetrics struct {
	UsagePercent float64   `json:"usagePercent"`
	Cores        int       `json:"cores"`
	ModelName    string    `json:"modelName"`
	LoadAvg1    float64   `json:"loadAvg1"`
	LoadAvg5    float64   `json:"loadAvg5"`
	LoadAvg15   float64   `json:"loadAvg15"`
}

// MemoryMetrics represents memory usage information
type MemoryMetrics struct {
	Total        uint64  `json:"total"`        // bytes
	Used         uint64  `json:"used"`         // bytes
	Free         uint64  `json:"free"`         // bytes
	Available    uint64  `json:"available"`    // bytes
	UsagePercent float64 `json:"usagePercent"`
	SwapTotal    uint64  `json:"swapTotal"`
	SwapUsed     uint64  `json:"swapUsed"`
	SwapFree     uint64  `json:"swapFree"`
}

// DiskMetrics represents disk usage information
type DiskMetrics struct {
	Partitions []PartitionMetrics `json:"partitions"`
}

// PartitionMetrics represents a single disk partition
type PartitionMetrics struct {
	MountPoint   string  `json:"mountPoint"`
	Device       string  `json:"device"`
	FSType       string  `json:"fsType"`
	Total        uint64  `json:"total"`        // bytes
	Used         uint64  `json:"used"`         // bytes
	Free         uint64  `json:"free"`         // bytes
	UsagePercent float64 `json:"usagePercent"`
}

// GPUMetrics represents GPU usage information (for future use)
type GPUMetrics struct {
	GPUs []SingleGPUMetrics `json:"gpus"`
}

// SingleGPUMetrics represents a single GPU's metrics
type SingleGPUMetrics struct {
	Index            int     `json:"index"`
	Name             string  `json:"name"`
	MemoryTotal      uint64  `json:"memoryTotal"`      // bytes
	MemoryUsed       uint64  `json:"memoryUsed"`       // bytes
	MemoryFree       uint64  `json:"memoryFree"`       // bytes
	UsagePercent     float64 `json:"usagePercent"`
	Temperature      float64 `json:"temperature"`      // Celsius
	PowerDraw        float64 `json:"powerDraw"`        // Watts
	PowerLimit       float64 `json:"powerLimit"`       // Watts
}

// NetworkMetrics represents network usage information (for future use)
type NetworkMetrics struct {
	Interfaces []InterfaceMetrics `json:"interfaces"`
}

// InterfaceMetrics represents a single network interface
type InterfaceMetrics struct {
	Name        string `json:"name"`
	BytesSent   uint64 `json:"bytesSent"`
	BytesRecv   uint64 `json:"bytesRecv"`
	PacketsSent uint64 `json:"packetsSent"`
	PacketsRecv uint64 `json:"packetsRecv"`
	ErrorsIn    uint64 `json:"errorsIn"`
	ErrorsOut   uint64 `json:"errorsOut"`
}

// MetricsSource identifies how a DeviceMetrics snapshot was obtained.
// Self-reported metrics from the GUI host take precedence over SSH-
// collected metrics in MonitorUseCase.GetDeviceMetrics so the local Mac
// (which has no SSH path back to itself) shows real numbers.
type MetricsSource string

const (
	MetricsSourceSSH        MetricsSource = "ssh"
	MetricsSourceSelfReport MetricsSource = "self"
	// MetricsSourceReachability is a lightweight TCP :22 probe — it
	// proves the SSH port is open, not that the device is actually
	// responding usefully. Callers that need a real signal of liveness
	// (status promotion, "is this device really online?") should treat
	// reachability entries as weaker than SSH/self-report and require
	// one of those before claiming online.
	MetricsSourceReachability MetricsSource = "reachability"
)

// DeviceMetrics represents all metrics for a device
type DeviceMetrics struct {
	DeviceID    string          `json:"deviceId"`
	CPU         CPUMetrics      `json:"cpu"`
	Memory      MemoryMetrics   `json:"memory"`
	Disk        DiskMetrics     `json:"disk"`
	GPU         *GPUMetrics     `json:"gpu,omitempty"`
	Network     *NetworkMetrics `json:"network,omitempty"`
	Source      MetricsSource   `json:"source,omitempty"`   // NEW
	// UptimeSeconds is the host's uptime in seconds since boot. Optional
	// (omitempty) — older collectors and agent payloads that don't set it
	// keep round-tripping cleanly.
	UptimeSeconds int64     `json:"uptimeSeconds,omitempty"`
	CollectedAt   time.Time `json:"collectedAt"`
	Error         string    `json:"error,omitempty"`
	// Suppressed is true when Error came from the connection circuit breaker
	// declining to dial (too many recent failures) rather than a live dial that
	// failed. The UI shows this as a "cooling down / retry pending" state,
	// distinct from an outright connection error, and can offer a manual retry.
	Suppressed bool `json:"suppressed,omitempty"`
}

// HasError returns true if there was an error collecting metrics
func (m *DeviceMetrics) HasError() bool {
	return m.Error != ""
}

// MetricsHistory represents historical metrics for a device
type MetricsHistory struct {
	DeviceID string          `json:"deviceId"`
	Points   []DeviceMetrics `json:"points"`
}

// MetricsSnapshot represents metrics for multiple devices at a point in time
type MetricsSnapshot struct {
	Devices     map[string]*DeviceMetrics `json:"devices"`
	CollectedAt time.Time                 `json:"collectedAt"`
}
