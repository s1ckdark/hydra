# Hydra iOS (B2a)

Minimal iOS app target introduced in sub-project B2a. Shares the cross-platform
service layer with the macOS app; the device-list and terminal UI arrive in B2b.

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
