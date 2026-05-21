# Device Detail UI Refresh + Taildrop

Date: 2026-05-21
Status: Approved

## Summary

Restyle the macOS `DeviceDetailView` to match Tailscale's admin device card
visual (addresses card + Ping section header) and add a working **Taildrop**
section so the user can send files to other Tailnet devices — particularly
iPhone/iPad — directly from Hydra.

A toolbar toggle on `DeviceListView` lets the user opt into showing mobile
devices in the sidebar (default off, matching the recent
`/api/devices` filter).

## Motivation

After hiding iOS/Android devices from the default `/api/devices` response
(commit `9349844`), iPhone and iPad are no longer visible in the dashboard.
Those devices are not workers, but they *are* useful Taildrop targets. We
want a first-class way to send a file from the Mac to a phone without
leaving Hydra, and we want the device detail view to feel as polished as
Tailscale's own UI.

## Scope

In scope:

- Refactor `Hydra/Hydra/Views/Devices/DeviceListView.swift` →
  `DeviceDetailView`:
  - New `Tailscale addresses` card (MagicDNS / IPv4 / IPv6, per-row copy).
  - New `Taildrop` GroupBox (drag-drop zone + Select a File button).
  - Existing `Connectivity` GroupBox header `Ping`, button `Ping device`.
- New backend handler in `internal/web/handler/handler.go`:
  - `POST /api/devices/:id/taildrop` — multipart upload → shell-out to
    `tailscale file cp <tmp> <device.name>:`.
- New `DeviceListView` toolbar toggle: "Show mobile devices" (UserDefaults
  persisted) that calls `/api/devices?include_mobile=true` when on.

Out of scope (this iteration):

- Modifying any `Hydra/Hydra/Views/iOS/` view.
- Receiving Taildrop files in Hydra itself.
- Multi-file batch send (one file per send).
- Streaming upload (we accept disk/memory cost up to a few hundred MB).

## Components

### Backend: Taildrop handler

`Hydra.Handler.APIDeviceTaildrop(c echo.Context) error`

1. Parse `id` path param → resolve device via `h.deviceUC.GetDevice`.
2. Read multipart `file` field, write to a unique temp file in
   `os.TempDir()`. Defer removal.
3. Resolve `tailscale` binary path:
   1. `exec.LookPath("tailscale")`
   2. `/usr/local/bin/tailscale`
   3. `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
   4. If none, return `503` with explicit `tailscale CLI not found` message.
4. Run `tailscale file cp <tmp> <device.Name>:` (note trailing colon — the
   CLI requires it). Capture stderr. Use a context with a 5-minute timeout
   so a stuck send doesn't pin the request.
5. On success: `200 {"status":"sent","target":"<name>","bytes":N}`.
6. On non-zero exit: `500 {"error": stderr}` so the UI can surface it.

Route registration: alongside the existing `POST /api/devices/:id/ping`
route — find and add adjacent.

### Frontend: Tailscale addresses card

Replace the `LazyVGrid` "Tailscale IP" field with a separate GroupBox-like
card. Three rows, each a `HStack { label-column · value-column · copy
button on hover }`:

| Row | Source |
|---|---|
| MagicDNS | `device.name` |
| IPv4 | first `device.ipAddresses` entry without `:` |
| IPv6 | first `device.ipAddresses` entry containing `:` |

If IPv6 is missing, skip the row. Mono font for values.

### Frontend: Taildrop section

New `GroupBox("Taildrop")` with:

- Dashed-border rounded rectangle (`StrokeStyle(lineWidth: 1.5, dash:
  [5,4])`).
- Centered: gift icon (`Image(systemName: "gift")`) → "Drag a file here,
  or" → `Button("Select a File…")`.
- Both onDrop (NSItemProvider URL) and button path resolve to the same
  `sendTaildrop(url:)` async function.
- During upload: replace dashed area content with `ProgressView` + filename.
- Result: ephemeral status banner — green check + "Sent to <name>" on
  success, red + stderr on failure. Auto-clear after 5s.

Errors get surfaced verbatim from server stderr so the user can act on them
(e.g., "ephemeral node — recipient must accept").

### Frontend: Show-mobile toggle

`DeviceListView` toolbar gains a third `ToolbarItem`:

- `Toggle(isOn: $prefs.showMobile)` with `Image(systemName:
  "iphone")` label.
- `prefs.showMobile` lives on `DevicePreferences` (already a UserDefaults
  store).
- `DashboardViewModel.load()` reads this and appends `?include_mobile=true`
  to the request when on.

## Data flow (Taildrop send)

```
User drops file
  → DeviceDetailView.sendTaildrop(url:)
    → APIClient.sendTaildrop(deviceId:, fileURL:)
      → POST /api/devices/:id/taildrop  (multipart, "file")
        → Handler.APIDeviceTaildrop
          → exec.Command("tailscale", "file", "cp", tmpPath, name+":")
            → Tailscale daemon delivers
              → recipient sees notification / downloads file
```

## Error handling

- Server-side: device not found → `404`. Multipart parse error → `400`.
  Binary missing → `503` with explicit guidance. Non-zero exit → `500` with
  stderr.
- Client-side: any non-2xx is shown via the ephemeral banner; the panel
  stays usable.
- Filesystem: temp file is removed in a `defer` regardless of outcome.

## Testing

- Unit: `APIDeviceTaildrop` with a stub `exec.Command` that returns
  canned success/failure. Multipart parsing exercised by a handler test in
  `internal/web/handler/`.
- Manual:
  - Send a small file to ipadmini.tail476516.ts.net — confirm device
    notification.
  - Send to a Linux node — confirm file lands in `~/Taildrop/`.
  - Send with `tailscale` removed from PATH → expect 503 with clear message.
  - Toggle Show mobile — confirm iOS devices appear/disappear in sidebar.

## Risks / tradeoffs

- **Host CLI dependency**: We rely on `tailscale` being installed on the
  Mac running Hydra. Mitigated by the 3-step resolver + 503 with guidance.
- **Disk/memory cost for large files**: multipart upload buffers to disk
  via temp file, but the multipart parser may hold partial data in memory.
  Acceptable for the typical Taildrop use case (photos, docs); 1+ GB sends
  will work but are slow.
- **Receiver state**: iOS Tailscale must be running and accepting Taildrop;
  we surface CLI errors but don't pre-check.
- **No progress reporting during the CLI step**: the request stays open
  until `tailscale file cp` returns. For multi-second sends the UI shows
  an indeterminate spinner. Good enough for v1.
