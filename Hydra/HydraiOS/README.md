# Hydra iOS (B2a/B2b)

Minimal iOS app target introduced in sub-project B2a. Shares the cross-platform
service layer with the macOS app; the device-list and terminal UI (B2b) are now
wired up, making this the iPad SSH terminal MVP.

## Build (simulator)
    cd Hydra
    xcodegen generate            # regenerate Hydra.xcodeproj from project.yml
    xcodebuild -project Hydra.xcodeproj -scheme HydraiOS \
      -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

## Notes
- `project.yml` is the source of truth; `Hydra.xcodeproj` is generated (gitignored).
- iOS uses the pure-Swift Citadel SSH backend (libssh2 is macOS-only).
- macOS build is unchanged: `make hydra-app` (SwiftPM).
- Device install / code signing: B2b.

## Using it (B2b)
1. Settings tab → set server URL (`http://<mac-LAN-IP>:8080`) and SSH username.
2. Settings → SSH 키 관리 → paste your ed25519 private key (or import from Files) → 저장.
3. Devices tab → tap an SSH-enabled node → trust the host key → shell.

Real device install requires signing (automatic signing + your Apple ID team in
Xcode; free personal team re-signs weekly). Citadel needs your ed25519 key
authorized on the target node.
