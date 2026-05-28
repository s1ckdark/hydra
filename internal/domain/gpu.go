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
		// 8 fields = base query; 9 = base + uuid (used to map processes to
		// this GPU). Accept both so callers that omit uuid keep working.
		if len(parts) != 8 && len(parts) != 9 {
			return nil, fmt.Errorf("expected 8 or 9 fields, got %d: %q", len(parts), line)
		}

		index, err := strconv.Atoi(strings.TrimSpace(parts[0]))
		if err != nil {
			return nil, fmt.Errorf("invalid index %q: %w", parts[0], err)
		}

		name := strings.TrimSpace(parts[1])

		utilization, err := strconv.ParseFloat(strings.TrimSpace(parts[2]), 64)
		if err != nil {
			return nil, fmt.Errorf("invalid utilization %q: %w", parts[2], err)
		}

		memUsed, err := strconv.Atoi(strings.TrimSpace(parts[3]))
		if err != nil {
			return nil, fmt.Errorf("invalid memory.used %q: %w", parts[3], err)
		}

		memTotal, err := strconv.Atoi(strings.TrimSpace(parts[4]))
		if err != nil {
			return nil, fmt.Errorf("invalid memory.total %q: %w", parts[4], err)
		}

		temp, err := strconv.Atoi(strings.TrimSpace(parts[5]))
		if err != nil {
			return nil, fmt.Errorf("invalid temperature %q: %w", parts[5], err)
		}

		powerDraw, err := strconv.ParseFloat(strings.TrimSpace(parts[6]), 64)
		if err != nil {
			return nil, fmt.Errorf("invalid power.draw %q: %w", parts[6], err)
		}

		powerLimit, err := strconv.ParseFloat(strings.TrimSpace(parts[7]), 64)
		if err != nil {
			return nil, fmt.Errorf("invalid power.limit %q: %w", parts[7], err)
		}

		var uuid string
		if len(parts) == 9 {
			uuid = strings.TrimSpace(parts[8])
		}

		gpus = append(gpus, GPUInfo{
			Index:              index,
			Name:               name,
			UtilizationPercent: utilization,
			MemoryUsedMB:       memUsed,
			MemoryTotalMB:      memTotal,
			TemperatureC:       temp,
			PowerDrawW:         powerDraw,
			PowerLimitW:        powerLimit,
			UUID:               uuid,
		})
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
