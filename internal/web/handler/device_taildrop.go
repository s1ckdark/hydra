package handler

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/labstack/echo/v4"

	"github.com/s1ckdark/hydra/internal/domain"
)

// taildropMaxBytes caps how large an uploaded payload we will accept before
// shelling out. Taildrop itself doesn't impose a hard ceiling, but anything
// above this is almost certainly user error (the Mac will be tying up disk
// and request memory for ages). Surface a friendly 413 instead.
const taildropMaxBytes = 4 * 1024 * 1024 * 1024 // 4 GiB

// APIDeviceTaildrop accepts a multipart file upload and forwards it to the
// target device via the host's `tailscale file cp` CLI. We treat this as a
// privileged shell-out: the server only ever runs the tailscale binary it
// finds on the host, with arguments composed from the resolved device's
// MagicDNS name — never raw user input — so an arbitrary path or option
// cannot be injected through the request.
func (h *Handler) APIDeviceTaildrop(c echo.Context) error {
	id := c.Param("id")
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
	if dev.Name == "" {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "device has no MagicDNS name"})
	}

	fileHeader, err := c.FormFile("file")
	if err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": fmt.Sprintf("missing file field: %v", err)})
	}
	if fileHeader.Size > taildropMaxBytes {
		return c.JSON(http.StatusRequestEntityTooLarge, map[string]string{
			"error": fmt.Sprintf("file too large: %d bytes (max %d)", fileHeader.Size, taildropMaxBytes),
		})
	}

	tsBin, err := resolveTailscaleBinary()
	if err != nil {
		return c.JSON(http.StatusServiceUnavailable, map[string]string{
			"error": err.Error(),
			"hint":  "install Tailscale.app, or add `tailscale` to PATH",
		})
	}

	src, err := fileHeader.Open()
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": fmt.Sprintf("open upload: %v", err)})
	}
	defer src.Close()

	sendCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	// `tailscale file cp <path> target:` fails on the App Store / GUI
	// Tailscale.app build because that CLI runs inside the macOS app
	// sandbox and cannot read paths outside its container ("the GUI
	// version of Tailscale on macOS runs in a macOS sandbox that can't
	// read files"). The stdin form is the documented escape: the daemon
	// reads the payload from us directly, no filesystem access needed.
	// `--name=` preserves the original filename on the receiver.
	filename := filepath.Base(fileHeader.Filename)
	cmd := exec.CommandContext(sendCtx, tsBin, "file", "cp", "--name="+filename, "-", dev.Name+":")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": fmt.Sprintf("stdin pipe: %v", err)})
	}
	stderrBuf := &bytes.Buffer{}
	cmd.Stderr = stderrBuf
	cmd.Stdout = stderrBuf // merge stdout into the same buffer; tailscale prints status there too

	if err := cmd.Start(); err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": fmt.Sprintf("start tailscale: %v", err)})
	}

	written, copyErr := io.Copy(stdin, src)
	closeErr := stdin.Close()
	waitErr := cmd.Wait()

	if copyErr != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{
			"error":  fmt.Sprintf("stream upload: %v", copyErr),
			"stderr": stderrBuf.String(),
		})
	}
	if waitErr != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{
			"error":  fmt.Sprintf("tailscale file cp failed: %v", waitErr),
			"stderr": stderrBuf.String(),
		})
	}
	_ = closeErr // already covered by waitErr if it mattered

	return c.JSON(http.StatusOK, map[string]any{
		"status":   "sent",
		"target":   dev.Name,
		"filename": filename,
		"bytes":    written,
	})
}

// resolveTailscaleBinary tries PATH first (so a user-provided override wins),
// then the two canonical macOS locations for the Tailscale CLI shipped with
// Tailscale.app. Returns an error message that names every path we tried so
// the caller can give the user a useful hint.
func resolveTailscaleBinary() (string, error) {
	if p, err := exec.LookPath("tailscale"); err == nil {
		return p, nil
	}
	candidates := []string{
		"/usr/local/bin/tailscale",
		"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return "", errors.New("tailscale CLI not found (searched $PATH, /usr/local/bin/tailscale, /Applications/Tailscale.app/Contents/MacOS/Tailscale)")
}
