package domain

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// GPUInfo represents a single GPU's metrics from nvidia-smi
type GPUInfo struct {
	Index              int     `json:"index"`
	Name               string  `json:"name"`
	UtilizationPercent float64 `json:"utilizationPercent"`
	MemoryUsedMB       int     `json:"memoryUsedMB"`
	MemoryTotalMB      int     `json:"memoryTotalMB"`
	TemperatureC       int     `json:"temperatureC"`
	PowerDrawW         float64 `json:"powerDrawW"`
	PowerLimitW        float64 `json:"powerLimitW"`
	// UUID maps compute-app processes back to their GPU. Internal only —
	// not exposed in the API payload.
	UUID string `json:"-"`
	// Processes lists the compute apps occupying this GPU. Populated by
	// AttachComputeApps; omitted when none are running.
	Processes []GPUProcess `json:"processes,omitempty"`
	// Extended nvidia-smi fields — populated only by the 15-field query.
	// All omitempty so 8/9-field legacy callers keep producing clean JSON.
	ClockSMMHz      int    `json:"clockSMMHz,omitempty"`      // current SM/graphics clock
	ClockMemoryMHz  int    `json:"clockMemoryMHz,omitempty"`  // current memory clock
	FanSpeedPercent int    `json:"fanSpeedPercent,omitempty"` // 0 when fanless (Tesla etc.)
	PState          string `json:"pstate,omitempty"`          // "P0".."P15", P0 = max perf
	PCIeLinkGen     int    `json:"pcieLinkGen,omitempty"`     // current PCIe generation
	PCIeLinkWidth   int    `json:"pcieLinkWidth,omitempty"`   // current PCIe lane width
}

// GPUProcess is a single compute process occupying a GPU, from
// `nvidia-smi --query-compute-apps`.
type GPUProcess struct {
	PID          int    `json:"pid"`
	Name         string `json:"name"`
	UsedMemoryMB int    `json:"usedMemoryMB"`
}

// MemoryUsagePercent returns memory usage as a percentage
func (g *GPUInfo) MemoryUsagePercent() float64 {
	if g.MemoryTotalMB == 0 {
		return 0
	}
	return float64(g.MemoryUsedMB) / float64(g.MemoryTotalMB) * 100
}

// GPUNodeMetrics holds GPU metrics for a single node
type GPUNodeMetrics struct {
	NodeName    string    `json:"nodeName"`
	DeviceID    string    `json:"deviceId"`
	GPUs        []GPUInfo `json:"gpus"`
	CollectedAt time.Time `json:"collectedAt"`
	Error       string    `json:"error,omitempty"`
}

// HasGPU returns true if the node has at least one GPU
func (m *GPUNodeMetrics) HasGPU() bool {
	return len(m.GPUs) > 0
}

// AvgUtilization returns the average GPU utilization across all GPUs
func (m *GPUNodeMetrics) AvgUtilization() float64 {
	if len(m.GPUs) == 0 {
		return 0
	}
	var total float64
	for _, g := range m.GPUs {
		total += g.UtilizationPercent
	}
	return total / float64(len(m.GPUs))
}

// TotalMemoryUsedMB returns total memory used across all GPUs in MB
func (m *GPUNodeMetrics) TotalMemoryUsedMB() int {
	var total int
	for _, g := range m.GPUs {
		total += g.MemoryUsedMB
	}
	return total
}

// TotalMemoryMB returns total memory across all GPUs in MB
func (m *GPUNodeMetrics) TotalMemoryMB() int {
	var total int
	for _, g := range m.GPUs {
		total += g.MemoryTotalMB
	}
	return total
}

// ParseNvidiaSmiOutput parses nvidia-smi CSV output into GPUInfo slices.
// Input format: "index, name, utilization.gpu, memory.used, memory.total, temperature.gpu, power.draw, power.limit"
// nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits
func ParseNvidiaSmiOutput(raw string) ([]GPUInfo, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}

	var gpus []GPUInfo
	lines := strings.Split(raw, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		parts := strings.Split(line, ", ")
		// Three accepted shapes, all back-compat:
		//   8  = base query (index..power.limit) — legacy
		//   9  = base + uuid (lets us map compute-app processes to GPUs)
		//   15 = base + uuid + extended (clocks SM/Mem, fan, pstate, PCIe gen/width)
		if len(parts) != 8 && len(parts) != 9 && len(parts) != 15 {
			return nil, fmt.Errorf("expected 8, 9, or 15 fields, got %d: %q", len(parts), line)
		}

		index, err := strconv.Atoi(strings.TrimSpace(parts[0]))
		if err != nil {
			return nil, fmt.Errorf("invalid index %q: %w", parts[0], err)
		}

		name := strings.TrimSpace(parts[1])

		// Base numeric fields are tolerant of nvidia-smi's "[N/A]" /
		// "[Not Supported]" sentinels (collapse to 0), mirroring the extended
		// fields below. A single card omitting power.draw/utilization/temp
		// (common on consumer cards, vGPU, MIG) must not discard the whole
		// node's GPU list. Index stays strict — it's the GPU identifier.
		utilization := unsupportedOrFloat(parts[2])
		memUsed := unsupportedOrInt(parts[3])
		memTotal := unsupportedOrInt(parts[4])
		temp := unsupportedOrInt(parts[5])
		powerDraw := unsupportedOrFloat(parts[6])
		powerLimit := unsupportedOrFloat(parts[7])

		var uuid string
		if len(parts) >= 9 {
			uuid = strings.TrimSpace(parts[8])
		}

		gpu := GPUInfo{
			Index:              index,
			Name:               name,
			UtilizationPercent: utilization,
			MemoryUsedMB:       memUsed,
			MemoryTotalMB:      memTotal,
			TemperatureC:       temp,
			PowerDrawW:         powerDraw,
			PowerLimitW:        powerLimit,
			UUID:               uuid,
		}

		// Extended fields (15-field query). Each is tolerant: nvidia-smi
		// emits "[N/A]" / "[Not Supported]" on cards that don't expose a
		// given counter (e.g., Tesla data-center cards have no fan), which
		// would fail strict int parsing. unsupportedOrInt collapses those
		// to 0 so the rest of the row still parses.
		if len(parts) == 15 {
			gpu.ClockSMMHz = unsupportedOrInt(parts[9])
			gpu.ClockMemoryMHz = unsupportedOrInt(parts[10])
			gpu.FanSpeedPercent = unsupportedOrInt(parts[11])
			gpu.PState = unsupportedOrString(parts[12])
			gpu.PCIeLinkGen = unsupportedOrInt(parts[13])
			gpu.PCIeLinkWidth = unsupportedOrInt(parts[14])
		}

		gpus = append(gpus, gpu)
	}

	return gpus, nil
}

// AttachComputeApps parses `nvidia-smi --query-compute-apps=gpu_uuid,pid,
// process_name,used_memory --format=csv,noheader,nounits` output and attaches
// each process to its owning GPU (matched by UUID). It is tolerant: malformed
// or unsupported rows ([N/A], [Not Supported]) are skipped rather than failing,
// since "no running processes" is a normal, common state.
func AttachComputeApps(gpus []GPUInfo, raw string) {
	raw = strings.TrimSpace(raw)
	if raw == "" || len(gpus) == 0 {
		return
	}

	// Index GPUs by UUID for O(1) lookup.
	byUUID := make(map[string]int, len(gpus))
	for i := range gpus {
		if gpus[i].UUID != "" {
			byUUID[gpus[i].UUID] = i
		}
	}

	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Fields: gpu_uuid, pid, process_name, used_memory. process_name may
		// itself contain ", " (rare), so split off the known head/tail and
		// rejoin the middle as the name.
		parts := strings.Split(line, ", ")
		if len(parts) < 4 {
			continue
		}
		uuid := strings.TrimSpace(parts[0])
		pid, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil {
			continue
		}
		mem, err := strconv.Atoi(strings.TrimSpace(parts[len(parts)-1]))
		if err != nil {
			mem = 0 // [N/A] / [Not Supported] — keep the process, unknown VRAM
		}
		name := strings.Join(parts[2:len(parts)-1], ", ")

		gi, ok := byUUID[uuid]
		if !ok {
			// Single-GPU nodes (or drivers that omit uuid) can't be mapped by
			// UUID; attach to GPU 0 so the data isn't silently dropped.
			if len(gpus) == 1 {
				gi = 0
			} else {
				continue
			}
		}
		gpus[gi].Processes = append(gpus[gi].Processes, GPUProcess{
			PID:          pid,
			Name:         name,
			UsedMemoryMB: mem,
		})
	}
}

// unsupportedOrInt returns 0 for nvidia-smi's "[N/A]" / "[Not Supported]"
// sentinels or any other unparsable field, so a single missing counter on
// one card (e.g., fanless Tesla) doesn't fail the whole row.
func unsupportedOrInt(s string) int {
	s = strings.TrimSpace(s)
	if s == "" || strings.HasPrefix(s, "[") {
		return 0
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return n
}

// unsupportedOrFloat mirrors unsupportedOrInt for float fields like power.draw
// / utilization, collapsing "[N/A]" / "[Not Supported]" (and any unparsable
// value) to 0 so one missing counter doesn't fail the whole row.
func unsupportedOrFloat(s string) float64 {
	s = strings.TrimSpace(s)
	if s == "" || strings.HasPrefix(s, "[") {
		return 0
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return f
}

// unsupportedOrString mirrors unsupportedOrInt for string fields like pstate.
// "[N/A]" / "[Not Supported]" collapse to "" so the UI can omit the field.
func unsupportedOrString(s string) string {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "[") {
		return ""
	}
	return s
}
