package handler

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sort"
	"time"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/internal/domain"
)

type pingRequest struct {
	Count int `json:"count,omitempty"`
	Port  int `json:"port,omitempty"`
}

type pingResult struct {
	DeviceID  string    `json:"deviceId"`
	Target    string    `json:"target"`
	Port      int       `json:"port"`
	Samples   int       `json:"samples"`
	Success   int       `json:"success"`
	Loss      int       `json:"loss"`
	MinMs     float64   `json:"minMs"`
	AvgMs     float64   `json:"avgMs"`
	MaxMs     float64   `json:"maxMs"`
	P50Ms     float64   `json:"p50Ms"`
	// SamplesMs is the per-attempt RTT in *attempt order* (not sorted). A
	// failed sample is encoded as 0 so the array length always matches Samples
	// — that way the chart can show gaps where loss happened.
	SamplesMs []float64 `json:"samplesMs"`
	Errors    []string  `json:"errors,omitempty"`
	StartedAt time.Time `json:"startedAt"`
}

// APIDevicePing measures TCP connect latency to the device's Tailscale IP.
// Connect-time is the right proxy for hydra's usage pattern: every operation
// the GUI initiates eventually opens a new TCP session (SSH for shell exec,
// HTTP for capability/metric posts), so TCP handshake RTT == "command
// dispatch latency the user actually feels". Each sample dials a fresh
// socket; reusing one would measure send/recv, not connect.
func (h *Handler) APIDevicePing(c echo.Context) error {
	id := c.Param("id")

	var req pingRequest
	_ = c.Bind(&req) // body is optional

	count := req.Count
	if count <= 0 {
		count = 5
	}
	if count > 20 {
		count = 20
	}
	port := req.Port
	if port <= 0 {
		port = 22
	}

	ctx := c.Request().Context()
	devices, err := h.deviceLister.ListDevices(ctx, false)
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

	target := dev.TailscaleIP
	if target == "" {
		for _, ip := range dev.IPAddresses {
			if net.ParseIP(ip).To4() != nil {
				target = ip
				break
			}
		}
	}
	if target == "" {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "no usable IP address for device"})
	}

	result := pingResult{
		DeviceID:  dev.ID,
		Target:    target,
		Port:      port,
		Samples:   count,
		StartedAt: time.Now(),
	}
	samples := make([]float64, 0, count)
	rtts := make([]float64, 0, count)

	for i := 0; i < count; i++ {
		if ctx.Err() != nil {
			break
		}
		rtt, perr := tcpProbe(ctx, target, port, 2*time.Second)
		if perr != nil {
			result.Errors = append(result.Errors, perr.Error())
			samples = append(samples, 0)
		} else {
			samples = append(samples, rtt)
			rtts = append(rtts, rtt)
		}
		if i < count-1 {
			time.Sleep(50 * time.Millisecond)
		}
	}

	result.SamplesMs = samples
	result.Success = len(rtts)
	result.Loss = count - result.Success
	if len(rtts) > 0 {
		sorted := append([]float64(nil), rtts...)
		sort.Float64s(sorted)
		result.MinMs = sorted[0]
		result.MaxMs = sorted[len(sorted)-1]
		var sum float64
		for _, v := range sorted {
			sum += v
		}
		result.AvgMs = sum / float64(len(sorted))
		result.P50Ms = sorted[len(sorted)/2]
	}
	return c.JSON(http.StatusOK, result)
}

func tcpProbe(ctx context.Context, host string, port int, timeout time.Duration) (float64, error) {
	addr := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	dialer := net.Dialer{Timeout: timeout}
	start := time.Now()
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	elapsed := float64(time.Since(start).Microseconds()) / 1000.0
	if err != nil {
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			return 0, fmt.Errorf("timeout after %v", timeout)
		}
		return 0, err
	}
	_ = conn.Close()
	return elapsed, nil
}
